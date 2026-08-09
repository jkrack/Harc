#!/usr/bin/env node

import { createHash, randomBytes } from "node:crypto";
import WebSocket from "ws";

const origin = process.env.HARC_RELAY_STAGING_ORIGIN;
if (origin === undefined) {
  fail("HARC_RELAY_STAGING_ORIGIN is required");
}

const parsedOrigin = new URL(origin);
if (parsedOrigin.protocol !== "https:" ||
    !parsedOrigin.hostname.includes("staging") ||
    parsedOrigin.hostname === "relay.adaptcontext.com") {
  fail("refusing to exercise an origin that is not an HTTPS staging host");
}

const routeID = opaqueToken();
const hostCapability = opaqueToken();
const deviceRouteID = opaqueToken();
const deviceCapability = opaqueToken();
const sockets = [];
let stage = "preflight health";

try {
  const healthBefore = await fetch(`${origin}/health`);
  assert(healthBefore.ok, `preflight health returned ${healthBefore.status}`);

  stage = "Host control connection";
  const hostControl = connectWebSocket(
    `/v1/hosts/${routeID}/connect`,
    { "x-harc-relay-capability": hostCapability },
  );
  sockets.push(hostControl);
  await opened(hostControl);

  stage = "device authorization";
  const authorized = nextTextMessage(hostControl);
  hostControl.send(JSON.stringify({
    type: "authorize",
    routeID: deviceRouteID,
    capabilityHash: hashToken(deviceCapability),
    kind: "device",
    expiresAt: Date.now() + 60_000,
  }));
  assert(await authorized === "authorized", "device route was not authorized");

  stage = "session admission";
  const sessionOffer = nextTextMessage(hostControl);
  const sessionResponse = await fetch(`${origin}/v1/hosts/${routeID}/sessions`, {
    method: "POST",
    headers: {
      "content-length": "0",
      "x-harc-relay-capability": deviceCapability,
      "x-harc-relay-device-route": deviceRouteID,
    },
  });
  assert(sessionResponse.status === 201,
    `session admission returned ${sessionResponse.status}`);
  const clientOffer = await sessionResponse.json();
  const hostOffer = JSON.parse(await sessionOffer);
  assert(hostOffer.type === "session", "Host did not receive a session offer");
  assert(hostOffer.sessionID === clientOffer.sessionID,
    "Host and client session IDs differ");

  stage = "session peer connections";
  const host = connectWebSocket(
    `/v1/sessions/${clientOffer.sessionID}/connect`,
    sessionHeaders(clientOffer.sessionID, "host", hostOffer.capability),
  );
  const client = connectWebSocket(
    `/v1/sessions/${clientOffer.sessionID}/connect`,
    sessionHeaders(clientOffer.sessionID, "client", clientOffer.capability),
  );
  sockets.push(host, client);
  await Promise.all([opened(host), opened(client)]);

  stage = "session readiness";
  const hostReady = nextTextMessage(host);
  const clientReady = nextTextMessage(client);
  host.send("ready");
  client.send("ready");
  assert(await hostReady === "ready" && await clientReady === "ready",
    "relay peers did not become ready");

  stage = "receiver overload";
  const firstFrame = nextBinaryMessage(client);
  const hostClosed = closed(host);
  const clientClosed = closed(client);
  host.send(randomBytes(256));
  await firstFrame;
  host.send(randomBytes(256));

  const [hostClose, clientClose] = await Promise.all([hostClosed, clientClosed]);
  assert(hostClose.code === 4429 && clientClose.code === 4429,
    `expected both peers to close 4429, got host=${hostClose.code} client=${clientClose.code}`);
  assert(hostClose.reason === "receiver_overloaded" &&
    clientClose.reason === "receiver_overloaded",
  `unexpected close reasons host=${hostClose.reason} client=${clientClose.reason}`);

  stage = "post-test health";
  hostControl.close(1000, "done");
  const healthAfter = await fetch(`${origin}/health`);
  assert(healthAfter.ok, `post-test health returned ${healthAfter.status}`);

  console.log("Staging receiver-overload check passed.");
  console.log(`  Origin:       ${origin}`);
  console.log("  Admission:    authorized");
  console.log("  First frame:  relayed");
  console.log("  Host close:   4429 receiver_overloaded");
  console.log("  Client close: 4429 receiver_overloaded");
  console.log("  Health:       ok");
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Staging receiver-overload check failed during ${stage}: ${message}`);
  process.exitCode = 1;
} finally {
  for (const socket of sockets) {
    if (socket.readyState === WebSocket.OPEN ||
        socket.readyState === WebSocket.CONNECTING) {
      socket.terminate();
    }
  }
}

function connectWebSocket(path, headers) {
  const websocketOrigin = origin.replace(/^https:/u, "wss:");
  return new WebSocket(`${websocketOrigin}${path}`, { headers });
}

function sessionHeaders(sessionID, role, capability) {
  return {
    "x-harc-relay-capability": capability,
    "x-harc-relay-role": role,
    "x-harc-relay-session-id": sessionID,
  };
}

function opaqueToken() {
  return randomBytes(32).toString("base64url");
}

function hashToken(token) {
  return createHash("sha256").update(token).digest("base64url");
}

function opened(socket) {
  if (socket.readyState === WebSocket.OPEN) {
    return Promise.resolve();
  }
  return event(socket, "open");
}

function closed(socket) {
  return event(socket, "close").then(([code, reason]) => ({
    code,
    reason: reason.toString(),
  }));
}

function nextTextMessage(socket) {
  return event(socket, "message").then(([data, isBinary]) => {
    assert(!isBinary, "expected a text control message");
    return data.toString();
  });
}

function nextBinaryMessage(socket) {
  return event(socket, "message").then(([data, isBinary]) => {
    assert(isBinary, "expected a binary relay frame");
    return data;
  });
}

function event(socket, name) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error(`${name} timeout`));
    }, 10_000);
    const onEvent = (...args) => {
      cleanup();
      resolve(args);
    };
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off(name, onEvent);
      socket.off("error", onError);
    };
    socket.once(name, onEvent);
    socket.once("error", onError);
  });
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function fail(message) {
  console.error(`Staging receiver-overload check failed: ${message}`);
  process.exit(1);
}
