# Harc Remote staging lifecycle evidence

**Date:** 2026-08-09
**Environment:** `harc-remote-relay-staging`
**Worker version:** `6d537995-70ea-40d0-aed7-4442d93a0efa`
**Origin:** `https://harc-remote-relay-staging.jlworker.workers.dev`

## Result

The real staging relay-level reconnect and revocation gate passes. The checked-
in harness used only freshly generated opaque synthetic routes and capabilities,
refused the production hostname, emitted no secret values, and bracketed the
exercise with deployed privacy and health read-backs.

## Passing sequence

`./scripts/test-relay-lifecycle-staging.sh` proved:

1. session admission without an online Host returned `503 host_offline`;
2. a persistent device route was authorized by the Host;
3. the initial tunnel connected exactly one Host and one client, became ready,
   and relayed random binary frames byte-for-byte in both directions with the
   end-to-end acknowledgement protocol;
4. closing the Host-control transport made admission return `503 host_offline`;
5. a fresh Host-control WebSocket reconnected with the same durable route and
   Host capability;
6. the persistent device grant admitted a new session with a different session
   ID, and that replacement tunnel again passed bidirectional acknowledged
   binary transfer;
7. Host revocation returned `revoked`, after which the old device grant returned
   `401 unauthorized`;
8. reauthorizing the same device route with a replacement capability left the
   old capability rejected and admitted the replacement; and
9. the reauthorized tunnel passed bidirectional transfer and final health.

The final read-back at 16:40:53 UTC showed the same Worker version at 100%,
Logpush disabled, no Tail Workers, persistent observability disabled, and health
OK. At 16:43 UTC, after Cloudflare's dashboard ingestion window, authenticated
queries returned zero staging Worker events and zero traces over the preceding
hour.

An initial harness invocation was discarded because its diagnostic formatter
eagerly consumed a successful response body. The harness was corrected before
any product result was accepted, and its shell wrapper now guarantees the final
privacy read-back even when the body of the exercise fails.

The Worker regression suite now has a focused revoke/replace case proving the
same state transition locally. The focused Worker file passed 8/8 tests; the
full relay validation passed 17/17 unit tests plus the separate Durable Object
observer integration test, generated-type checks, TypeScript, privacy guard,
and production/observer dry-run bundles.

## Scope boundary

- **Pass:** real relay-level Host-offline handling, transport interruption,
  same-route Host reconnect, fresh-session replacement, durable device grant,
  revocation, stale-capability rejection, replacement authorization, binary
  integrity, acknowledgements, privacy configuration, and health.
- **Pass:** delayed zero-event/zero-trace evidence for the lifecycle interval.
- **Still open:** iPhone and secondary-Mac behavior across two unrelated
  physical networks, direct-LAN preference/recovery in those environments, and
  visible app state during physical revocation. This staging harness does not
  impersonate those device/network acceptance cells.
