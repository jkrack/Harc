import { HostRendezvous } from "./host-rendezvous";
import { RelaySession } from "./relay-session";
import {
  HEADER_DEVICE_ROUTE,
  HEADER_SESSION_ID,
} from "./protocol";
import { isOpaqueToken } from "./security";

export { HostRendezvous, RelaySession };

const hostConnectPattern = /^\/v1\/hosts\/([A-Za-z0-9_-]{43})\/connect$/u;
const hostSessionPattern = /^\/v1\/hosts\/([A-Za-z0-9_-]{43})\/sessions$/u;
const sessionConnectPattern = /^\/v1\/sessions\/([A-Za-z0-9_-]{43})\/connect$/u;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return Response.json(
        { status: "ok" },
        { headers: securityHeaders() },
      );
    }

    const hostConnect = hostConnectPattern.exec(url.pathname);
    if (request.method === "GET" && hostConnect !== null) {
      const routeID = hostConnect[1];
      if (!isOpaqueToken(routeID)) {
        return notFound();
      }
      const rendezvous = env.HOST_RENDEZVOUS.get(
        env.HOST_RENDEZVOUS.idFromName(routeID),
      );
      return rendezvous.fetch(rewriteRequest(request, "/connect"));
    }

    const hostSession = hostSessionPattern.exec(url.pathname);
    if (request.method === "POST" && hostSession !== null) {
      const routeID = hostSession[1];
      const deviceRouteID = request.headers.get(HEADER_DEVICE_ROUTE);
      if (!isOpaqueToken(routeID) ||
          !isOpaqueToken(deviceRouteID) ||
          (request.body !== null &&
            request.headers.get("content-length") !== "0")) {
        return notFound();
      }
      const admitted = await env.SESSION_RATE_LIMITER.limit({
        key: `${routeID}:${deviceRouteID}`,
      });
      if (!admitted.success) {
        return Response.json(
          { code: "rate_limited" },
          { status: 429, headers: securityHeaders() },
        );
      }
      const rendezvous = env.HOST_RENDEZVOUS.get(
        env.HOST_RENDEZVOUS.idFromName(routeID),
      );
      return rendezvous.fetch(rewriteRequest(request, "/session"));
    }

    const sessionConnect = sessionConnectPattern.exec(url.pathname);
    if (request.method === "GET" && sessionConnect !== null) {
      const sessionID = sessionConnect[1];
      if (!isOpaqueToken(sessionID)) {
        return notFound();
      }
      const headers = new Headers(request.headers);
      headers.set(HEADER_SESSION_ID, sessionID);
      const session = env.RELAY_SESSION.get(
        env.RELAY_SESSION.idFromName(sessionID),
      );
      return session.fetch(new Request("https://relay.internal/connect", {
        method: "GET",
        headers,
      }));
    }

    return notFound();
  },
} satisfies ExportedHandler<Env>;

function rewriteRequest(request: Request, pathname: string): Request {
  return new Request(`https://relay.internal${pathname}`, {
    method: request.method,
    headers: request.headers,
  });
}

function securityHeaders(): Headers {
  return new Headers({
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "content-type": "application/json; charset=utf-8",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  });
}

function notFound(): Response {
  return Response.json(
    { code: "not_found" },
    { status: 404, headers: securityHeaders() },
  );
}
