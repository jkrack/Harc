import { DurableObject } from "cloudflare:workers";

import {
  HEADER_CAPABILITY,
  HEADER_ROLE,
  HEADER_SESSION_ID,
  SESSION_IDLE_TIMEOUT_MS,
  type RelayRole,
  type SessionInitialization,
  type SocketAttachment,
  isSessionInitialization,
  isSocketAttachment,
} from "./protocol";
import {
  MAX_CONTROL_MESSAGE_BYTES,
  MAX_RELAY_FRAME_BYTES,
  constantTimeEqual,
  hashOpaqueToken,
  isOpaqueToken,
} from "./security";

const SESSION_STORAGE_KEY = "session";
export class RelaySession extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS used_roles (
        role TEXT PRIMARY KEY CHECK (role IN ('host', 'client'))
      );
    `);
  }

  override async fetch(request: Request): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (pathname === "/initialize" && request.method === "POST") {
      return this.initialize(request);
    }
    if (pathname === "/connect" && request.method === "GET") {
      return this.connectPeer(request);
    }
    return response("not_found", 404);
  }

  override async webSocketMessage(
    socket: WebSocket,
    message: string | ArrayBuffer,
  ): Promise<void> {
    const attachment = socket.deserializeAttachment();
    if (!isSocketAttachment(attachment)) {
      this.closeAll(4400, "invalid_session_state");
      return;
    }
    if (Date.now() >= attachment.expiresAt) {
      this.closeAll(4408, "session_expired");
      this.ctx.waitUntil(this.releaseAndDelete(attachment));
      return;
    }
    const peerRole: RelayRole = attachment.role === "host" ? "client" : "host";
    const peers = this.ctx.getWebSockets(peerRole);

    if (typeof message === "string") {
      if (message === "ack" && attachment.ready) {
        if (peers.length !== 1 || peers[0]?.readyState !== WebSocket.OPEN) {
          this.closeAll(4409, "peer_unavailable");
          return;
        }
        const peerAttachment = peers[0].deserializeAttachment();
        if (!isSocketAttachment(peerAttachment) ||
            !peerAttachment.ready ||
            !peerAttachment.awaitingAcknowledgement) {
          this.closeAll(4409, "peer_not_ready");
          return;
        }
        peers[0].serializeAttachment({
          ...peerAttachment,
          awaitingAcknowledgement: false,
        });
        peers[0].send("ack");
        return;
      }
      if (message !== "ready" || attachment.ready) {
        this.closeAll(4400, "binary_frames_required");
        return;
      }
      const readyAttachment: SocketAttachment = {
        ...attachment,
        ready: true,
      };
      socket.serializeAttachment(readyAttachment);
      const peer = peers[0];
      const peerAttachment = peer?.deserializeAttachment();
      if (peer?.readyState === WebSocket.OPEN &&
          isSocketAttachment(peerAttachment) &&
          peerAttachment.ready) {
        socket.send("ready");
        peer.send("ready");
      }
      return;
    }

    if (peers.length !== 1 || peers[0]?.readyState !== WebSocket.OPEN) {
      this.closeAll(4409, "peer_unavailable");
      return;
    }
    const peer = peers[0];

    const peerAttachment = peer.deserializeAttachment();
    if (!attachment.ready ||
        !isSocketAttachment(peerAttachment) ||
        !peerAttachment.ready) {
      this.closeAll(4409, "peer_not_ready");
      return;
    }
    if (message.byteLength > MAX_RELAY_FRAME_BYTES) {
      this.closeAll(4413, "frame_too_large");
      return;
    }
    if (attachment.awaitingAcknowledgement) {
      this.closeAll(4429, "receiver_overloaded");
      return;
    }
    try {
      const lastPayloadAt = Date.now();
      socket.serializeAttachment({
        ...attachment,
        awaitingAcknowledgement: true,
        lastPayloadAt,
      });
      await this.ctx.storage.setAlarm(
        Math.min(lastPayloadAt + SESSION_IDLE_TIMEOUT_MS, attachment.expiresAt),
      );
      peer.send(message);
    } catch {
      this.closeAll(4503, "relay_unavailable");
    }
  }

  override async webSocketClose(
    socket: WebSocket,
    _code: number,
    _reason: string,
    _wasClean: boolean,
  ): Promise<void> {
    const attachment = socket.deserializeAttachment();
    if (isSocketAttachment(attachment)) {
      this.closeAll(4001, "peer_disconnected", socket);
      await this.releaseAndDelete(attachment);
    }
  }

  override async webSocketError(
    socket: WebSocket,
    _error: unknown,
  ): Promise<void> {
    const attachment = socket.deserializeAttachment();
    this.closeAll(4503, "relay_unavailable", socket);
    if (isSocketAttachment(attachment)) {
      await this.releaseAndDelete(attachment);
    }
  }

  override async alarm(): Promise<void> {
    const session = await this.ctx.storage.get<SessionInitialization>(
      SESSION_STORAGE_KEY,
    );
    if (session !== undefined) {
      const lastPayloadAt = this.ctx.getWebSockets().reduce(
        (latest, socket) => {
          const attachment = socket.deserializeAttachment();
          return isSocketAttachment(attachment)
            ? Math.max(latest, attachment.lastPayloadAt)
            : latest;
        },
        session.createdAt,
      );
      const deadline = Math.min(
        lastPayloadAt + SESSION_IDLE_TIMEOUT_MS,
        session.expiresAt,
      );
      if (Date.now() < deadline) {
        await this.ctx.storage.setAlarm(deadline);
        return;
      }
      this.closeAll(4408, "session_expired");
      await this.releaseAndDelete({
        version: 1,
        role: "host",
        ready: false,
        awaitingAcknowledgement: false,
        sessionID: session.sessionID,
        rendezvousRouteID: session.rendezvousRouteID,
        expiresAt: session.expiresAt,
        lastPayloadAt,
      });
    } else {
      this.closeAll(4408, "session_expired");
      await this.ctx.storage.deleteAll();
    }
  }

  private async initialize(request: Request): Promise<Response> {
    if (await this.ctx.storage.get(SESSION_STORAGE_KEY) !== undefined) {
      return response("already_initialized", 409);
    }

    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (!Number.isFinite(contentLength) ||
        contentLength <= 0 ||
        contentLength > MAX_CONTROL_MESSAGE_BYTES) {
      return response("invalid_request", 400);
    }

    let value: unknown;
    try {
      value = await request.json();
    } catch {
      return response("invalid_request", 400);
    }
    const now = Date.now();
    if (!isSessionInitialization(value, now)) {
      return response("invalid_request", 400);
    }

    await this.ctx.storage.put(SESSION_STORAGE_KEY, value);
    await this.ctx.storage.setAlarm(
      Math.min(now + SESSION_IDLE_TIMEOUT_MS, value.expiresAt),
    );
    return response("initialized", 201);
  }

  private async connectPeer(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return response("websocket_required", 426);
    }

    const role = request.headers.get(HEADER_ROLE);
    const capability = request.headers.get(HEADER_CAPABILITY);
    const requestedSessionID = request.headers.get(HEADER_SESSION_ID);
    if ((role !== "host" && role !== "client") ||
        !isOpaqueToken(capability) ||
        !isOpaqueToken(requestedSessionID)) {
      return response("unauthorized", 401);
    }

    // Hash before consulting one-time state so no external await can split the
    // validation and role reservation critical section below.
    const suppliedHash = await hashOpaqueToken(capability);

    const session = await this.ctx.storage.get<SessionInitialization>(
      SESSION_STORAGE_KEY,
    );
    if (session === undefined || session.sessionID !== requestedSessionID) {
      return response("unauthorized", 401);
    }
    if (Date.now() >= session.expiresAt) {
      return response("session_expired", 410);
    }
    if (this.ctx.getWebSockets(role).length !== 0) {
      return response("role_already_used", 409);
    }

    const expectedHash = role === "host"
      ? session.hostCapabilityHash
      : session.clientCapabilityHash;
    if (!constantTimeEqual(suppliedHash, expectedHash)) {
      return response("unauthorized", 401);
    }

    const used = this.ctx.storage.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM used_roles WHERE role = ?",
      role,
    ).one();
    if (used.count !== 0) {
      return response("role_already_used", 409);
    }
    this.ctx.storage.sql.exec(
      "INSERT INTO used_roles (role) VALUES (?)",
      role,
    );
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const attachment: SocketAttachment = {
      version: 1,
      role,
      ready: false,
      awaitingAcknowledgement: false,
      sessionID: session.sessionID,
      rendezvousRouteID: session.rendezvousRouteID,
      expiresAt: session.expiresAt,
      lastPayloadAt: session.createdAt,
    };
    server.serializeAttachment(attachment);
    this.ctx.acceptWebSocket(server, [role]);

    return new Response(null, { status: 101, webSocket: client });
  }

  private closeAll(code: number, reason: string, except?: WebSocket): void {
    for (const socket of this.ctx.getWebSockets()) {
      if (socket !== except && socket.readyState < WebSocket.CLOSING) {
        socket.close(code, reason);
      }
    }
  }

  private async releaseAndDelete(attachment: SocketAttachment): Promise<void> {
    const rendezvous = this.env.HOST_RENDEZVOUS.get(
      this.env.HOST_RENDEZVOUS.idFromName(attachment.rendezvousRouteID),
    );
    const release = new Request("https://relay.internal/release", {
      method: "POST",
      headers: { [HEADER_SESSION_ID]: attachment.sessionID },
    });
    try {
      await rendezvous.fetch(release);
    } finally {
      await this.ctx.storage.deleteAll();
    }
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
