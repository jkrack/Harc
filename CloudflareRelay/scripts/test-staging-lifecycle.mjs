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
const firstDeviceCapability = opaqueToken();
const replacementDeviceCapability = opaqueToken();
const sockets = [];
let stage = "preflight health";

try {
  const healthBefore = await fetch(`${origin}/health`);
  assert(healthBefore.ok, `preflight health returned ${healthBefore.status}`);

  stage = "Host-offline admission";
  await expectAdmissionFailure(
    deviceRouteID,
    firstDeviceCapability,
    503,
    "host_offline",
  );

  stage = "initial Host control connection";
  let hostControl = await connectHostWithRetry();

  stage = "persistent device authorization";
  await authorize(hostControl, firstDeviceCapability);

  stage = "initial tunnel";
  const firstSession = await issueSession(
    hostControl,
    firstDeviceCapability,
  );
  await qualifySession(firstSession, "initial");

  stage = "Host-control interruption";
  await closeGracefully(hostControl, "network_change");
  await waitForHostOffline(firstDeviceCapability);

  stage = "Host-control reconnect";
  hostControl = await connectHostWithRetry();

  stage = "replacement tunnel after reconnect";
  const replacementSession = await issueSession(
    hostControl,
    firstDeviceCapability,
  );
  assert(replacementSession.sessionID !== firstSession.sessionID,
    "replacement tunnel reused the interrupted session ID");
  await qualifySession(replacementSession, "replacement");

  stage = "device revocation";
  const revoked = nextTextMessage(hostControl);
  hostControl.send(JSON.stringify({ type: "revoke", routeID: deviceRouteID }));
  assert(await revoked === "revoked", "Host did not confirm revocation");

  stage = "revoked admission rejection";
  await expectAdmissionFailure(
    deviceRouteID,
    firstDeviceCapability,
    401,
    "unauthorized",
  );

  stage = "replacement authorization";
  await authorize(hostControl, replacementDeviceCapability);

  stage = "stale capability rejection";
  await expectAdmissionFailure(
    deviceRouteID,
    firstDeviceCapability,
    401,
    "unauthorized",
  );

  stage = "replacement capability admission";
  const reauthorizedSession = await issueSession(
    hostControl,
    replacementDeviceCapability,
  );
  await qualifySession(reauthorizedSession, "reauthorized");

  stage = "post-test health";
  await closeGracefully(hostControl, "qualification_complete");
  const healthAfter = await fetch(`${origin}/health`);
  assert(healthAfter.ok, `post-test health returned ${healthAfter.status}`);

  console.log("Staging relay lifecycle check passed.");
  console.log(`  Origin:                    ${origin}`);
  console.log("  Host offline:              503 host_offline");
  console.log("  Initial tunnel:            bidirectional bytes + acknowledgements");
  console.log("  Host-control reconnect:    same durable route and capability");
  console.log("  Replacement tunnel:        new session, bidirectional bytes");
  console.log("  Revoked admission:         401 unauthorized");
  console.log("  Stale capability:          401 unauthorized");
  console.log("  Replacement authorization: admitted and relayed");
  console.log("  Health:                    ok");
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Staging relay lifecycle check failed during ${stage}: ${message}`);
  process.exitCode = 1;
} finally {
  await Promise.allSettled(sockets.map((socket) =>
    closeGracefully(socket, "cleanup")));
}

async function connectHostWithRetry() {
  let lastError;
  for (let attempt = 1; attempt <= 10; attempt += 1) {
    const socket = connectWebSocket(
      `/v1/hosts/${routeID}/connect`,
      { "x-harc-relay-capability": hostCapability },
    );
    sockets.push(socket);
    try {
      await opened(socket);
      return socket;
    } catch (error) {
      lastError = error;
      socket.terminate();
      if (attempt < 10) {
        await delay(250 * attempt);
      }
    }
  }
  throw new Error(`Host reconnect failed: ${errorMessage(lastError)}`);
}

async function authorize(hostControl, capability) {
  const authorized = nextTextMessage(hostControl);
  hostControl.send(JSON.stringify({
    type: "authorize",
    routeID: deviceRouteID,
    capabilityHash: hashToken(capability),
    kind: "device",
    expiresAt: Date.now() + 5 * 60_000,
  }));
  assert(await authorized === "authorized", "device route was not authorized");
}

async function issueSession(hostControl, capability) {
  const hostOfferPromise = nextTextMessage(hostControl);
  const response = await requestSession(deviceRouteID, capability);
  if (response.status !== 201) {
    void hostOfferPromise.catch(() => undefined);
    throw new Error(
      `session admission returned ${response.status}: ${await response.text()}`,
    );
  }
  const clientOffer = await response.json();
  const hostOffer = JSON.parse(await hostOfferPromise);
  assert(hostOffer.type === "session", "Host did not receive a session offer");
  assert(hostOffer.sessionID === clientOffer.sessionID,
    "Host and client session IDs differ");
  return {
    sessionID: clientOffer.sessionID,
    hostCapability: hostOffer.capability,
    clientCapability: clientOffer.capability,
  };
}

async function qualifySession(session, label) {
  const host = connectWebSocket(
    `/v1/sessions/${session.sessionID}/connect`,
    sessionHeaders(session.sessionID, "host", session.hostCapability),
  );
  const client = connectWebSocket(
    `/v1/sessions/${session.sessionID}/connect`,
    sessionHeaders(session.sessionID, "client", session.clientCapability),
  );
  sockets.push(host, client);
  await Promise.all([opened(host), opened(client)]);

  const hostReady = nextTextMessage(host);
  const clientReady = nextTextMessage(client);
  host.send("ready");
  client.send("ready");
  assert(await hostReady === "ready" && await clientReady === "ready",
    `${label} tunnel peers did not become ready`);

  await relayFrame(host, client, `${label}-host-to-client`);
  await relayFrame(client, host, `${label}-client-to-host`);
  await Promise.allSettled([
    closeGracefully(host, `${label}_complete`),
    closeGracefully(client, `${label}_complete`),
  ]);
}

async function relayFrame(sender, receiver, label) {
  const payload = randomBytes(4_096);
  const received = nextBinaryMessage(receiver);
  const acknowledged = nextTextMessage(sender);
  sender.send(payload);
  const relayed = await received;
  assert(Buffer.compare(payload, relayed) === 0,
    `${label} payload changed in transit`);
  receiver.send("ack");
  assert(await acknowledged === "ack", `${label} was not acknowledged`);
}

async function waitForHostOffline(capability) {
  let lastStatus = 0;
  for (let attempt = 1; attempt <= 10; attempt += 1) {
    const response = await requestSession(deviceRouteID, capability);
    lastStatus = response.status;
    if (response.status === 503) {
      const body = await response.json();
      assert(body.code === "host_offline",
        `expected host_offline, found ${JSON.stringify(body)}`);
      return;
    }
    await response.arrayBuffer();
    await delay(250 * attempt);
  }
  throw new Error(`Host remained available after disconnect; last status ${lastStatus}`);
}

async function expectAdmissionFailure(route, capability, status, code) {
  const response = await requestSession(route, capability);
  assert(response.status === status,
    `expected admission ${status}, found ${response.status}`);
  const body = await response.json();
  assert(body.code === code,
    `expected admission code ${code}, found ${JSON.stringify(body)}`);
}

function requestSession(route, capability) {
  return fetch(`${origin}/v1/hosts/${routeID}/sessions`, {
    method: "POST",
    headers: {
      "content-length": "0",
      "x-harc-relay-capability": capability,
      "x-harc-relay-device-route": route,
    },
  });
}

function connectWebSocket(path, headers) {
  const websocketOrigin = origin.replace(/^https:/u, "wss:");
  return new WebSocket(`${websocketOrigin}${path}`, {
    headers,
    perMessageDeflate: false,
  });
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
  return event(socket, "open", 10_000).then(() => undefined);
}

function nextTextMessage(socket) {
  return event(socket, "message", 10_000).then(([data, isBinary]) => {
    assert(!isBinary, "expected a text control message");
    return data.toString();
  });
}

function nextBinaryMessage(socket) {
  return event(socket, "message", 10_000).then(([data, isBinary]) => {
    assert(isBinary, "expected a binary relay frame");
    return Buffer.from(data);
  });
}

async function closeGracefully(socket, reason) {
  if (socket.readyState === WebSocket.CLOSED) {
    return;
  }
  if (socket.readyState === WebSocket.CONNECTING) {
    socket.terminate();
    return;
  }
  const closed = event(socket, "close", 5_000).catch(() => undefined);
  socket.close(1000, reason);
  await closed;
  if (socket.readyState !== WebSocket.CLOSED) {
    socket.terminate();
  }
}

function event(socket, name, timeoutMilliseconds) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error(`${name} timeout`));
    }, timeoutMilliseconds);
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

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function errorMessage(value) {
  return value instanceof Error ? value.message : String(value);
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function fail(message) {
  console.error(`Staging relay lifecycle check failed: ${message}`);
  process.exit(1);
}
