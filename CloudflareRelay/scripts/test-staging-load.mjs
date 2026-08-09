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

const idleHostCount = boundedInteger("HARC_RELAY_IDLE_HOSTS", 1_000, 1, 2_000);
const batchSize = boundedInteger("HARC_RELAY_CONNECT_BATCH", 40, 1, 100);
const holdSeconds = boundedInteger("HARC_RELAY_HOLD_SECONDS", 30, 5, 300);
const transferBytes = boundedInteger(
  "HARC_RELAY_TRANSFER_BYTES",
  16 * 1_024 * 1_024,
  1,
  256 * 1_024 * 1_024,
);
const frameBytes = boundedInteger(
  "HARC_RELAY_FRAME_BYTES",
  256 * 1_024,
  1,
  1_048_576,
);

const hosts = [];
const sessionSockets = [];
const latencies = [];
let retries = 0;
let peakRSS = process.memoryUsage().rss;
const startedAt = performance.now();
const memorySampler = setInterval(() => {
  peakRSS = Math.max(peakRSS, process.memoryUsage().rss);
}, 100);

try {
  const healthBefore = await fetch(`${origin}/health`);
  assert(healthBefore.ok, `preflight health returned ${healthBefore.status}`);

  for (let offset = 0; offset < idleHostCount; offset += batchSize) {
    const count = Math.min(batchSize, idleHostCount - offset);
    const results = await Promise.allSettled(
      Array.from({ length: count }, (_, index) => openHost(offset + index)),
    );
    hosts.push(...results
      .filter((result) => result.status === "fulfilled")
      .map((result) => result.value));
    const failed = results.find((result) => result.status === "rejected");
    if (failed?.status === "rejected") {
      throw failed.reason;
    }
    if (hosts.length % 100 === 0 || hosts.length === idleHostCount) {
      console.log(`Opened ${hosts.length}/${idleHostCount} idle Host connections.`);
    }
  }

  const allOpenAt = performance.now();
  assert(hosts.length === idleHostCount,
    `expected ${idleHostCount} open Hosts, found ${hosts.length}`);
  assert(hosts.every(({ socket }) => socket.readyState === WebSocket.OPEN),
    "one or more Host connections closed before the active transfer");

  const transfer = await runActiveTransfer(hosts[0]);
  const heldMilliseconds = performance.now() - allOpenAt;
  if (heldMilliseconds < holdSeconds * 1_000) {
    await delay(holdSeconds * 1_000 - heldMilliseconds);
  }

  assert(hosts.every(({ socket }) => socket.readyState === WebSocket.OPEN),
    "one or more idle Host connections closed during the hold interval");
  const healthAfter = await fetch(`${origin}/health`);
  assert(healthAfter.ok, `post-load health returned ${healthAfter.status}`);

  const totalMilliseconds = performance.now() - startedAt;
  const sortedLatencies = [...latencies].sort((left, right) => left - right);
  const report = {
    status: "passed",
    origin,
    idleHostsRequested: idleHostCount,
    idleHostsOpened: hosts.length,
    connectionRetries: retries,
    connectWallMilliseconds: rounded(allOpenAt - startedAt),
    connectionLatencyMilliseconds: {
      p50: percentile(sortedLatencies, 0.50),
      p95: percentile(sortedLatencies, 0.95),
      p99: percentile(sortedLatencies, 0.99),
      max: rounded(sortedLatencies.at(-1) ?? 0),
    },
    allConnectedHoldSeconds: holdSeconds,
    activeTransferBytes: transfer.bytes,
    activeTransferFrames: transfer.frames,
    activeTransferSeconds: rounded(transfer.milliseconds / 1_000),
    activeTransferMiBPerSecond: rounded(
      (transfer.bytes / 1_048_576) / (transfer.milliseconds / 1_000),
    ),
    generatorPeakRSSMiB: rounded(peakRSS / 1_048_576),
    totalRunSeconds: rounded(totalMilliseconds / 1_000),
    healthBefore: "ok",
    healthAfter: "ok",
  };

  console.log("Staging load check passed.");
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Staging load check failed: ${message}`);
  process.exitCode = 1;
} finally {
  clearInterval(memorySampler);
  await Promise.allSettled(sessionSockets.map(closeGracefully));
  for (let offset = 0; offset < hosts.length; offset += 100) {
    await Promise.allSettled(
      hosts.slice(offset, offset + 100).map(({ socket }) => closeGracefully(socket)),
    );
  }
}

async function openHost(index) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const routeID = opaqueToken();
    const capability = opaqueToken();
    const socket = connectWebSocket(
      `/v1/hosts/${routeID}/connect`,
      { "x-harc-relay-capability": capability },
    );
    const beganAt = performance.now();
    try {
      await opened(socket, 20_000);
      latencies.push(performance.now() - beganAt);
      retries += attempt - 1;
      return { index, routeID, capability, socket };
    } catch (error) {
      lastError = error;
      socket.terminate();
      if (attempt < 3) {
        await delay(100 * attempt);
      }
    }
  }
  throw new Error(`Host ${index} failed after 3 attempts: ${errorMessage(lastError)}`);
}

async function runActiveTransfer(primaryHost) {
  const deviceRouteID = opaqueToken();
  const deviceCapability = opaqueToken();
  const authorized = nextTextMessage(primaryHost.socket);
  primaryHost.socket.send(JSON.stringify({
    type: "authorize",
    routeID: deviceRouteID,
    capabilityHash: hashToken(deviceCapability),
    kind: "device",
    expiresAt: Date.now() + 5 * 60_000,
  }));
  assert(await authorized === "authorized", "active route was not authorized");

  const hostOfferPromise = nextTextMessage(primaryHost.socket);
  const sessionResponse = await fetch(
    `${origin}/v1/hosts/${primaryHost.routeID}/sessions`,
    {
      method: "POST",
      headers: {
        "content-length": "0",
        "x-harc-relay-capability": deviceCapability,
        "x-harc-relay-device-route": deviceRouteID,
      },
    },
  );
  assert(sessionResponse.status === 201,
    `active session admission returned ${sessionResponse.status}`);
  const clientOffer = await sessionResponse.json();
  const hostOffer = JSON.parse(await hostOfferPromise);
  assert(hostOffer.type === "session", "Host did not receive an active session offer");
  assert(hostOffer.sessionID === clientOffer.sessionID,
    "Host and client active session IDs differ");

  const host = connectWebSocket(
    `/v1/sessions/${clientOffer.sessionID}/connect`,
    sessionHeaders(clientOffer.sessionID, "host", hostOffer.capability),
  );
  const client = connectWebSocket(
    `/v1/sessions/${clientOffer.sessionID}/connect`,
    sessionHeaders(clientOffer.sessionID, "client", clientOffer.capability),
  );
  sessionSockets.push(host, client);
  await Promise.all([opened(host), opened(client)]);

  const hostReady = nextTextMessage(host);
  const clientReady = nextTextMessage(client);
  host.send("ready");
  client.send("ready");
  assert(await hostReady === "ready" && await clientReady === "ready",
    "active relay peers did not become ready");

  const transferStartedAt = performance.now();
  let sent = 0;
  let frames = 0;
  while (sent < transferBytes) {
    const size = Math.min(frameBytes, transferBytes - sent);
    const received = nextBinaryMessage(client);
    const acknowledged = nextTextMessage(host);
    host.send(randomBytes(size));
    const frame = await received;
    assert(frame.byteLength === size,
      `active frame size mismatch: expected ${size}, found ${frame.byteLength}`);
    client.send("ack");
    assert(await acknowledged === "ack", "active frame was not acknowledged");
    sent += size;
    frames += 1;
  }
  const milliseconds = performance.now() - transferStartedAt;
  await Promise.allSettled([closeGracefully(host), closeGracefully(client)]);
  return { bytes: sent, frames, milliseconds };
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

function opened(socket, timeoutMilliseconds = 10_000) {
  if (socket.readyState === WebSocket.OPEN) {
    return Promise.resolve();
  }
  return event(socket, "open", timeoutMilliseconds).then(() => undefined);
}

function nextTextMessage(socket) {
  return event(socket, "message", 20_000).then(([data, isBinary]) => {
    assert(!isBinary, "expected a text control message");
    return data.toString();
  });
}

function nextBinaryMessage(socket) {
  return event(socket, "message", 20_000).then(([data, isBinary]) => {
    assert(isBinary, "expected a binary relay frame");
    return data;
  });
}

async function closeGracefully(socket) {
  if (socket.readyState === WebSocket.CLOSED) {
    return;
  }
  if (socket.readyState === WebSocket.CONNECTING) {
    socket.terminate();
    return;
  }
  const closed = event(socket, "close", 5_000).catch(() => undefined);
  socket.close(1000, "load_complete");
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

function percentile(sorted, fraction) {
  if (sorted.length === 0) return 0;
  const index = Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1);
  return rounded(sorted[index]);
}

function rounded(value) {
  return Math.round(value * 100) / 100;
}

function boundedInteger(name, fallback, minimum, maximum) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    fail(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return parsed;
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
  console.error(`Staging load check failed: ${message}`);
  process.exit(1);
}
