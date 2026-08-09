import {
  env,
  evictDurableObject,
  reset,
  runInDurableObject,
  SELF,
} from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";

import {
  HEADER_CAPABILITY,
  HEADER_DEVICE_ROUTE,
  HEADER_ROLE,
  HEADER_SESSION_ID,
  SESSION_LIFETIME_MS,
  SESSION_IDLE_TIMEOUT_MS,
  type SessionInitialization,
} from "../src/protocol";
import { hashOpaqueToken, randomOpaqueToken } from "../src/security";

afterEach(async () => {
  await reset();
});

describe("Harc Remote Worker", () => {
  it("exposes only a minimal health response", async () => {
    const response = await SELF.fetch("https://relay.test/health");

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ status: "ok" });
  });

  it("does not route malformed object identifiers", async () => {
    const response = await SELF.fetch(
      "https://relay.test/v1/sessions/not-secret/connect",
    );

    expect(response.status).toBe(404);
  });

  it("forwards binary ciphertext byte-for-byte between exactly two roles", async () => {
    const sessionID = randomOpaqueToken();
    const routeID = randomOpaqueToken();
    const hostCapability = randomOpaqueToken();
    const clientCapability = randomOpaqueToken();
    const now = Date.now();
    const initialization: SessionInitialization = {
      version: 1,
      rendezvousRouteID: routeID,
      sessionID,
      hostCapabilityHash: await hashOpaqueToken(hostCapability),
      clientCapabilityHash: await hashOpaqueToken(clientCapability),
      createdAt: now,
      expiresAt: now + SESSION_LIFETIME_MS,
    };
    const stub = env.RELAY_SESSION.get(env.RELAY_SESSION.idFromName(sessionID));
    const body = JSON.stringify(initialization);
    const initialized = await stub.fetch("https://relay.internal/initialize", {
      method: "POST",
      headers: { "content-length": String(new TextEncoder().encode(body).byteLength) },
      body,
    });
    expect(initialized.status).toBe(201);

    const host = await connect(sessionID, "host", hostCapability);
    const hostReady = expectMessage(host, "ready");
    host.send("ready");

    const client = await connect(sessionID, "client", clientCapability);
    const clientReady = expectMessage(client, "ready");
    client.send("ready");
    await Promise.all([hostReady, clientReady]);

    const ciphertext = crypto.getRandomValues(new Uint8Array(512));
    const received = expectMessage(client);
    host.send(ciphertext.buffer);
    const event = await received;
    expect(await messageBytes(event.data)).toEqual(ciphertext);
    expect(await outstandingCredit(stub)).toEqual({
      host: true,
      client: false,
    });
    const hostAcknowledged = expectMessage(host, "ack");
    client.send("ack");
    await hostAcknowledged;
    expect(await outstandingCredit(stub)).toEqual({
      host: false,
      client: false,
    });

    const reverseCiphertext = crypto.getRandomValues(new Uint8Array(384));
    const reverseReceived = expectMessage(host);
    client.send(reverseCiphertext.buffer);
    const reverseEvent = await reverseReceived;
    expect(await messageBytes(reverseEvent.data)).toEqual(reverseCiphertext);
    expect(await outstandingCredit(stub)).toEqual({
      host: false,
      client: true,
    });
    const clientAcknowledged = expectMessage(client, "ack");
    host.send("ack");
    await clientAcknowledged;
    expect(await outstandingCredit(stub)).toEqual({
      host: false,
      client: false,
    });

    const persisted = await runInDurableObject(
      stub,
      async (_instance, state) => [...(await state.storage.list()).values()],
    );
    expect(JSON.stringify(persisted)).not.toContain(
      new TextDecoder().decode(ciphertext),
    );

    const third = await SELF.fetch(
      `https://relay.test/v1/sessions/${sessionID}/connect`,
      {
        headers: websocketHeaders(sessionID, "host", hostCapability),
      },
    );
    expect(third.status).toBe(409);

    host.close(1000, "done");
    client.close(1000, "done");
    await reset();
  });

  it("arms a bounded idle deadline instead of retaining unused sessions", async () => {
    const sessionID = randomOpaqueToken();
    const now = Date.now();
    const initialization: SessionInitialization = {
      version: 1,
      rendezvousRouteID: randomOpaqueToken(),
      sessionID,
      hostCapabilityHash: await hashOpaqueToken(randomOpaqueToken()),
      clientCapabilityHash: await hashOpaqueToken(randomOpaqueToken()),
      createdAt: now,
      expiresAt: now + SESSION_LIFETIME_MS,
    };
    const stub = env.RELAY_SESSION.get(env.RELAY_SESSION.idFromName(sessionID));
    const body = JSON.stringify(initialization);
    const initialized = await stub.fetch("https://relay.internal/initialize", {
      method: "POST",
      headers: { "content-length": String(new TextEncoder().encode(body).byteLength) },
      body,
    });
    expect(initialized.status).toBe(201);

    const alarm = await runInDurableObject(
      stub,
      async (_instance, state) => state.storage.getAlarm(),
    );
    expect(alarm).not.toBeNull();
    expect(alarm as number).toBeGreaterThanOrEqual(now + SESSION_IDLE_TIMEOUT_MS);
    expect(alarm as number).toBeLessThanOrEqual(
      Date.now() + SESSION_IDLE_TIMEOUT_MS,
    );
  });

  it("atomically consumes each role capability under concurrent replay", async () => {
    const sessionID = randomOpaqueToken();
    const routeID = randomOpaqueToken();
    const hostCapability = randomOpaqueToken();
    const now = Date.now();
    const initialization: SessionInitialization = {
      version: 1,
      rendezvousRouteID: routeID,
      sessionID,
      hostCapabilityHash: await hashOpaqueToken(hostCapability),
      clientCapabilityHash: await hashOpaqueToken(randomOpaqueToken()),
      createdAt: now,
      expiresAt: now + SESSION_LIFETIME_MS,
    };
    const stub = env.RELAY_SESSION.get(env.RELAY_SESSION.idFromName(sessionID));
    const body = JSON.stringify(initialization);
    expect((await stub.fetch("https://relay.internal/initialize", {
      method: "POST",
      headers: { "content-length": String(new TextEncoder().encode(body).byteLength) },
      body,
    })).status).toBe(201);

    const attempts = await Promise.all([
      SELF.fetch(`https://relay.test/v1/sessions/${sessionID}/connect`, {
        headers: websocketHeaders(sessionID, "host", hostCapability),
      }),
      SELF.fetch(`https://relay.test/v1/sessions/${sessionID}/connect`, {
        headers: websocketHeaders(sessionID, "host", hostCapability),
      }),
    ]);
    expect(attempts.map((response) => response.status).sort()).toEqual([101, 409]);

    const accepted = attempts.find((response) => response.status === 101);
    const socket = accepted?.webSocket;
    expect(socket).not.toBeNull();
    socket?.accept();
    socket?.close(1000, "done");
  });

  it("survives Host eviction and enforces the durable admission burst", async () => {
    const routeID = randomOpaqueToken();
    const hostCapability = randomOpaqueToken();
    const host = await connectHost(routeID, hostCapability);
    const deviceRouteID = randomOpaqueToken();
    const deviceCapability = randomOpaqueToken();
    const authorized = expectMessage(host, "authorized");
    host.send(JSON.stringify({
      type: "authorize",
      routeID: deviceRouteID,
      capabilityHash: await hashOpaqueToken(deviceCapability),
      kind: "device",
      expiresAt: Date.now() + 60_000,
    }));
    await authorized;

    const rendezvous = env.HOST_RENDEZVOUS.get(
      env.HOST_RENDEZVOUS.idFromName(routeID),
    );
    await evictDurableObject(rendezvous);

    const bodyRejected = await SELF.fetch(
      `https://relay.test/v1/hosts/${routeID}/sessions`,
      {
        method: "POST",
        headers: {
          [HEADER_CAPABILITY]: deviceCapability,
          [HEADER_DEVICE_ROUTE]: deviceRouteID,
        },
        body: "not-allowed",
      },
    );
    expect(bodyRejected.status).toBe(404);

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const offered = expectMessage(host);
      const issued = await requestRelaySession(
        routeID,
        deviceRouteID,
        deviceCapability,
      );
      expect(issued.status).toBe(201);
      expect(JSON.parse(String((await offered).data)).type).toBe("session");
    }
    const limited = await requestRelaySession(
      routeID,
      deviceRouteID,
      deviceCapability,
    );
    expect(limited.status).toBe(429);
    expect(await limited.json()).toEqual({ code: "rate_limited" });
    host.close(1000, "done");
  });

  it("atomically consumes a pairing admission under concurrent replay", async () => {
    const routeID = randomOpaqueToken();
    const hostCapability = randomOpaqueToken();
    const host = await connectHost(routeID, hostCapability);
    const pairingRouteID = randomOpaqueToken();
    const pairingCapability = randomOpaqueToken();
    const authorized = expectMessage(host, "authorized");
    host.send(JSON.stringify({
      type: "authorize",
      routeID: pairingRouteID,
      capabilityHash: await hashOpaqueToken(pairingCapability),
      kind: "pairing",
      expiresAt: Date.now() + 60_000,
    }));
    await authorized;

    const offered = expectMessage(host);
    const attempts = await Promise.all([
      requestRelaySession(routeID, pairingRouteID, pairingCapability),
      requestRelaySession(routeID, pairingRouteID, pairingCapability),
    ]);
    expect(attempts.map((response) => response.status).sort()).toEqual([201, 401]);
    expect(JSON.parse(String((await offered).data)).type).toBe("session");

    const replay = await requestRelaySession(
      routeID,
      pairingRouteID,
      pairingCapability,
    );
    expect(replay.status).toBe(401);
    host.close(1000, "done");
  });

  it("revokes a device route and rejects the stale capability after replacement", async () => {
    const routeID = randomOpaqueToken();
    const hostCapability = randomOpaqueToken();
    const host = await connectHost(routeID, hostCapability);
    const deviceRouteID = randomOpaqueToken();
    const initialCapability = randomOpaqueToken();
    const replacementCapability = randomOpaqueToken();

    const initiallyAuthorized = expectMessage(host, "authorized");
    host.send(JSON.stringify({
      type: "authorize",
      routeID: deviceRouteID,
      capabilityHash: await hashOpaqueToken(initialCapability),
      kind: "device",
      expiresAt: Date.now() + 60_000,
    }));
    await initiallyAuthorized;

    const initialOffer = expectMessage(host);
    expect((await requestRelaySession(
      routeID,
      deviceRouteID,
      initialCapability,
    )).status).toBe(201);
    expect(JSON.parse(String((await initialOffer).data)).type).toBe("session");

    const revoked = expectMessage(host, "revoked");
    host.send(JSON.stringify({ type: "revoke", routeID: deviceRouteID }));
    await revoked;

    const revokedAdmission = await requestRelaySession(
      routeID,
      deviceRouteID,
      initialCapability,
    );
    expect(revokedAdmission.status).toBe(401);
    expect(await revokedAdmission.json()).toEqual({ code: "unauthorized" });

    const replacementAuthorized = expectMessage(host, "authorized");
    host.send(JSON.stringify({
      type: "authorize",
      routeID: deviceRouteID,
      capabilityHash: await hashOpaqueToken(replacementCapability),
      kind: "device",
      expiresAt: Date.now() + 60_000,
    }));
    await replacementAuthorized;

    const staleAdmission = await requestRelaySession(
      routeID,
      deviceRouteID,
      initialCapability,
    );
    expect(staleAdmission.status).toBe(401);
    expect(await staleAdmission.json()).toEqual({ code: "unauthorized" });

    const replacementOffer = expectMessage(host);
    expect((await requestRelaySession(
      routeID,
      deviceRouteID,
      replacementCapability,
    )).status).toBe(201);
    expect(JSON.parse(String((await replacementOffer).data)).type).toBe("session");
    host.close(1000, "done");
  });
});

async function connectHost(
  routeID: string,
  capability: string,
): Promise<WebSocket> {
  const response = await SELF.fetch(
    `https://relay.test/v1/hosts/${routeID}/connect`,
    { headers: { upgrade: "websocket", [HEADER_CAPABILITY]: capability } },
  );
  expect(response.status).toBe(101);
  const socket = response.webSocket as WebSocket;
  socket.accept();
  return socket;
}

function requestRelaySession(
  routeID: string,
  deviceRouteID: string,
  capability: string,
): Promise<Response> {
  return SELF.fetch(`https://relay.test/v1/hosts/${routeID}/sessions`, {
    method: "POST",
    headers: {
      [HEADER_CAPABILITY]: capability,
      [HEADER_DEVICE_ROUTE]: deviceRouteID,
      "content-length": "0",
    },
  });
}

async function connect(
  sessionID: string,
  role: "host" | "client",
  capability: string,
): Promise<WebSocket> {
  const response = await SELF.fetch(
    `https://relay.test/v1/sessions/${sessionID}/connect`,
    { headers: websocketHeaders(sessionID, role, capability) },
  );
  expect(response.status).toBe(101);
  expect(response.webSocket).not.toBeNull();
  const socket = response.webSocket as WebSocket;
  socket.accept();
  return socket;
}

function websocketHeaders(
  sessionID: string,
  role: "host" | "client",
  capability: string,
): Headers {
  return new Headers({
    upgrade: "websocket",
    [HEADER_CAPABILITY]: capability,
    [HEADER_ROLE]: role,
    [HEADER_SESSION_ID]: sessionID,
  });
}

function expectMessage(
  socket: WebSocket,
  expected?: string,
): Promise<MessageEvent> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("message timeout")), 2_000);
    socket.addEventListener("message", (event) => {
      clearTimeout(timeout);
      if (expected !== undefined) {
        expect(event.data).toBe(expected);
      }
      resolve(event);
    }, { once: true });
  });
}

async function messageBytes(value: unknown): Promise<Uint8Array> {
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  if (value instanceof Blob) {
    return new Uint8Array(await value.arrayBuffer());
  }
  throw new Error("expected binary WebSocket message");
}

async function outstandingCredit(
  stub: DurableObjectStub,
): Promise<{ host: boolean; client: boolean }> {
  return runInDurableObject(stub, async (_instance, state) => {
    const value = { host: false, client: false };
    for (const role of ["host", "client"] as const) {
      const socket = state.getWebSockets(role)[0];
      const attachment = socket?.deserializeAttachment();
      if (attachment !== null &&
          typeof attachment === "object" &&
          "awaitingAcknowledgement" in attachment) {
        value[role] = attachment.awaitingAcknowledgement === true;
      }
    }
    return value;
  });
}
