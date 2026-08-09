import { DurableObject } from "cloudflare:workers";

import {
  HEADER_CAPABILITY,
  HEADER_DEVICE_ROUTE,
  HEADER_SESSION_ID,
  MAX_ACTIVE_SESSIONS_PER_HOST,
  MAX_RELAY_ROUTES_PER_HOST,
  SESSION_LIFETIME_MS,
  SESSION_ADMISSION_BURST,
  SESSION_ADMISSION_REFILL_MS,
  parseHostControlCommand,
  type AdmissionKind,
  type SessionInitialization,
} from "./protocol";
import {
  MAX_CONTROL_MESSAGE_BYTES,
  constantTimeEqual,
  hashOpaqueToken,
  isOpaqueToken,
  randomOpaqueToken,
  tokenMatchesHash,
} from "./security";

interface CapabilityRow {
  [key: string]: SqlStorageValue;
  route_id: string;
  capability_hash: string;
  kind: AdmissionKind;
  expires_at: number;
  consumed: number;
  rate_tokens: number;
  rate_updated_at: number;
}

interface CountRow {
  [key: string]: SqlStorageValue;
  count: number;
}

const HOST_CAPABILITY_HASH_KEY = "host-capability-hash";

export class HostRendezvous extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS relay_capabilities (
          route_id TEXT PRIMARY KEY,
          capability_hash TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('device', 'pairing')),
          expires_at INTEGER NOT NULL,
          consumed INTEGER NOT NULL DEFAULT 0 CHECK (consumed IN (0, 1)),
          rate_tokens REAL NOT NULL DEFAULT 3,
          rate_updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS active_sessions (
          session_id TEXT PRIMARY KEY,
          expires_at INTEGER NOT NULL
        );
      `);
    });
  }

  override async fetch(request: Request): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (pathname === "/connect" && request.method === "GET") {
      return this.connectHost(request);
    }
    if (pathname === "/session" && request.method === "POST") {
      return this.issueSession(request);
    }
    if (pathname === "/release" && request.method === "POST") {
      return this.releaseSession(request);
    }
    return response("not_found", 404);
  }

  override async webSocketMessage(
    socket: WebSocket,
    message: string | ArrayBuffer,
  ): Promise<void> {
    if (typeof message !== "string") {
      socket.close(4400, "control_text_required");
      return;
    }

    const command = parseHostControlCommand(message, Date.now());
    if (command === null) {
      socket.close(4400, "invalid_control_message");
      return;
    }

    if (command.type === "revoke") {
      this.ctx.storage.sql.exec(
        "DELETE FROM relay_capabilities WHERE route_id = ?",
        command.routeID,
      );
      socket.send("revoked");
      return;
    }

    const now = Date.now();
    this.ctx.storage.sql.exec(
      "DELETE FROM relay_capabilities WHERE expires_at <= ?",
      now,
    );
    const existing = this.ctx.storage.sql.exec<CountRow>(
      "SELECT COUNT(*) AS count FROM relay_capabilities WHERE route_id = ?",
      command.routeID,
    ).one();
    const count = this.ctx.storage.sql.exec<CountRow>(
      "SELECT COUNT(*) AS count FROM relay_capabilities",
    ).one();
    if (existing.count === 0 && count.count >= MAX_RELAY_ROUTES_PER_HOST) {
      socket.send("route_limit");
      return;
    }

    this.ctx.storage.sql.exec(
      `INSERT INTO relay_capabilities
        (route_id, capability_hash, kind, expires_at, consumed,
         rate_tokens, rate_updated_at)
       VALUES (?, ?, ?, ?, 0, ?, ?)
       ON CONFLICT(route_id) DO UPDATE SET
         capability_hash = excluded.capability_hash,
         kind = excluded.kind,
         expires_at = excluded.expires_at,
         consumed = 0,
         rate_tokens = excluded.rate_tokens,
         rate_updated_at = excluded.rate_updated_at`,
      command.routeID,
      command.capabilityHash,
      command.kind,
      command.expiresAt,
      SESSION_ADMISSION_BURST,
      now,
    );
    socket.send("authorized");
  }

  override webSocketClose(
    _socket: WebSocket,
    _code: number,
    _reason: string,
    _wasClean: boolean,
  ): void {}

  override webSocketError(_socket: WebSocket, _error: unknown): void {}

  private async connectHost(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return response("websocket_required", 426);
    }
    if (this.ctx.getWebSockets("host").length !== 0) {
      return response("host_already_connected", 409);
    }

    const capability = request.headers.get(HEADER_CAPABILITY);
    if (!isOpaqueToken(capability)) {
      return response("unauthorized", 401);
    }

    const storedHash = await this.ctx.storage.get<string>(
      HOST_CAPABILITY_HASH_KEY,
    );
    if (storedHash === undefined) {
      await this.ctx.storage.put(
        HOST_CAPABILITY_HASH_KEY,
        await hashOpaqueToken(capability),
      );
    } else if (!await tokenMatchesHash(capability, storedHash)) {
      return response("unauthorized", 401);
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.serializeAttachment({ version: 1, role: "host-control" });
    this.ctx.acceptWebSocket(server, ["host"]);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async issueSession(request: Request): Promise<Response> {
    const host = this.ctx.getWebSockets("host")[0];
    if (host?.readyState !== WebSocket.OPEN) {
      return response("host_offline", 503);
    }

    const deviceRoute = request.headers.get(HEADER_DEVICE_ROUTE);
    const capability = request.headers.get(HEADER_CAPABILITY);
    if (!isOpaqueToken(deviceRoute) || !isOpaqueToken(capability)) {
      return response("unauthorized", 401);
    }

    // Complete all cryptographic awaits before reading or reserving durable
    // admission state. Durable Object events may interleave at arbitrary
    // external awaits, while the SQLite critical section below is synchronous.
    const suppliedCapabilityHash = await hashOpaqueToken(capability);
    const sessionID = randomOpaqueToken();
    const hostCapability = randomOpaqueToken();
    const clientCapability = randomOpaqueToken();
    const [hostCapabilityHash, clientCapabilityHash] = await Promise.all([
      hashOpaqueToken(hostCapability),
      hashOpaqueToken(clientCapability),
    ]);

    const now = Date.now();
    this.ctx.storage.sql.exec(
      "DELETE FROM active_sessions WHERE expires_at <= ?",
      now,
    );
    const count = this.ctx.storage.sql
      .exec<CountRow>("SELECT COUNT(*) AS count FROM active_sessions")
      .one();
    if (count.count >= MAX_ACTIVE_SESSIONS_PER_HOST) {
      return response("host_session_limit", 429);
    }

    const row = this.ctx.storage.sql
      .exec<CapabilityRow>(
        `SELECT route_id, capability_hash, kind, expires_at, consumed,
                rate_tokens, rate_updated_at
         FROM relay_capabilities WHERE route_id = ?`,
        deviceRoute,
      )
      .toArray()[0];
    if (row === undefined ||
        row.expires_at <= now ||
        row.consumed !== 0 ||
        !constantTimeEqual(suppliedCapabilityHash, row.capability_hash)) {
      return response("unauthorized", 401);
    }

    const elapsed = Math.max(0, now - row.rate_updated_at);
    const replenished = Math.min(
      SESSION_ADMISSION_BURST,
      row.rate_tokens + elapsed / SESSION_ADMISSION_REFILL_MS,
    );
    if (replenished < 1) {
      this.ctx.storage.sql.exec(
        `UPDATE relay_capabilities
         SET rate_tokens = ?, rate_updated_at = ? WHERE route_id = ?`,
        replenished,
        now,
        deviceRoute,
      );
      return response("rate_limited", 429);
    }
    this.ctx.storage.sql.exec(
      `UPDATE relay_capabilities
       SET rate_tokens = ?, rate_updated_at = ? WHERE route_id = ?`,
      replenished - 1,
      now,
      deviceRoute,
    );

    const expiresAt = now + SESSION_LIFETIME_MS;
    const initialization: SessionInitialization = {
      version: 1,
      rendezvousRouteID: this.ctx.id.name ?? "",
      sessionID,
      hostCapabilityHash,
      clientCapabilityHash,
      createdAt: now,
      expiresAt,
    };
    if (!isOpaqueToken(initialization.rendezvousRouteID)) {
      return response("invalid_route", 500);
    }


    const offer = JSON.stringify({
      type: "session",
      sessionID,
      capability: hostCapability,
      expiresAt,
    });
    if (new TextEncoder().encode(offer).byteLength > MAX_CONTROL_MESSAGE_BYTES) {
      return response("relay_unavailable", 503);
    }

    // Reserve quota and consume a one-time pairing route before the external
    // session initialization await. Deleting the pairing row makes replay
    // fail closed; rollback uses INSERT OR IGNORE so it cannot overwrite a
    // newer Host authorization for the same route.
    if (row.kind === "pairing") {
      this.ctx.storage.sql.exec(
        `DELETE FROM relay_capabilities
         WHERE route_id = ? AND capability_hash = ? AND consumed = 0`,
        deviceRoute,
        row.capability_hash,
      );
    }
    this.ctx.storage.sql.exec(
      "INSERT INTO active_sessions (session_id, expires_at) VALUES (?, ?)",
      sessionID,
      expiresAt,
    );

    const rollbackReservation = (): void => {
      this.ctx.storage.sql.exec(
        "DELETE FROM active_sessions WHERE session_id = ?",
        sessionID,
      );
      if (row.kind === "pairing") {
        this.ctx.storage.sql.exec(
          `INSERT OR IGNORE INTO relay_capabilities
            (route_id, capability_hash, kind, expires_at, consumed,
             rate_tokens, rate_updated_at)
           VALUES (?, ?, ?, ?, 0, ?, ?)`,
          row.route_id,
          row.capability_hash,
          row.kind,
          row.expires_at,
          replenished - 1,
          now,
        );
      }
    };

    const session = this.env.RELAY_SESSION.get(
      this.env.RELAY_SESSION.idFromName(sessionID),
    );
    const body = JSON.stringify(initialization);
    let initialized: Response;
    try {
      initialized = await session.fetch("https://relay.internal/initialize", {
        method: "POST",
        headers: {
          "content-length": String(new TextEncoder().encode(body).byteLength),
          "content-type": "application/json",
        },
        body,
      });
    } catch {
      rollbackReservation();
      return response("relay_unavailable", 503);
    }
    if (!initialized.ok) {
      rollbackReservation();
      return response("relay_unavailable", 503);
    }

    try {
      host.send(offer);
    } catch {
      rollbackReservation();
      return response("host_offline", 503);
    }

    return Response.json(
      { sessionID, capability: clientCapability, expiresAt },
      {
        status: 201,
        headers: {
          "cache-control": "no-store",
          "content-type": "application/json; charset=utf-8",
        },
      },
    );
  }

  private releaseSession(request: Request): Response {
    const sessionID = request.headers.get(HEADER_SESSION_ID);
    if (!isOpaqueToken(sessionID)) {
      return response("invalid_request", 400);
    }
    this.ctx.storage.sql.exec(
      "DELETE FROM active_sessions WHERE session_id = ?",
      sessionID,
    );
    return new Response(null, { status: 204 });
  }
}

function response(code: string, status: number): Response {
  return Response.json(
    { code },
    {
      status,
      headers: {
        "cache-control": "no-store",
        "content-type": "application/json; charset=utf-8",
      },
    },
  );
}
