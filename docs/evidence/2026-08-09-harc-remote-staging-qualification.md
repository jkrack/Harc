# Harc Remote staging qualification

**Date:** 2026-08-09
**Environment:** `harc-remote-relay-staging`
**Origin:** `https://harc-remote-relay-staging.jlworker.workers.dev`

## Result

The real Cloudflare `4429 receiver_overloaded` branch, post-redeployment
behavior, 1,000-idle-Host load/cost gate, pinned-TLS application flow, safe
aggregate redaction, and relay-level lifecycle gates pass. Persistent staging
observability is disabled. Cloudflare's raw real-time tail surface remains
prohibited.

## Evidence

1. Initial staging version `f2998e42-4fdd-460d-9947-7fb63249c60f` deployed at
   100% with the staging Durable Object and rate-limit bindings.
2. A synthetic Host and client completed admission and readiness. The first
   256-byte binary frame relayed. Sending a second binary frame before the
   receiver acknowledgement closed both peers with code `4429` and reason
   `receiver_overloaded`; `/health` remained OK.
3. A short-lived `wrangler tail` inspection was stopped immediately after it
   demonstrated that Cloudflare's raw tail includes request headers, source
   network metadata, and synthetic relay capabilities. The exercise used no
   recording, transcript, device identity, invitation, or application
   plaintext. Workers Logs, Traces, Logpush, and Tail Workers remained disabled,
   so the inspected events were not persisted by the relay configuration.
4. The repository removed the raw-tail command and extended the fail-closed
   privacy guard across production and staging. The guard also rejects any npm
   script that exposes `wrangler tail` for this project.
5. Staging was redeployed as version
   `df830ae2-434d-4096-a3da-6ba21f2621a7`. The complete synthetic overload test
   passed again after redeployment.
6. At 2026-08-09 15:31 UTC, the deployed staging read-back showed exactly that
   version at 100%, Logpush disabled, no Tail Workers, observability disabled,
   and live health OK.
7. At 15:33 UTC, after the documented ingestion-delay window, authenticated
   dashboard queries returned zero Workers events and zero traces for
   `scriptName = "harc-remote-relay-staging"` over the preceding hour. The raw
   real-time tail session therefore did not create retained Workers Logs or
   Traces under the disabled configuration.
8. The full relay check passed: production and staging privacy guards,
   production/observer generated types, TypeScript, 4 files/17 unit tests, one
   Durable Object integration test, and both production/observer dry-run
   bundles.
9. A bounded staging-only harness opened 1,000/1,000 idle Host rendezvous
   connections with zero retries, held them all for 30 seconds, and completed a
   16-MiB acknowledged opaque transfer at 2.91 MiB/s. Health remained OK. The
   detailed resource, privacy, and cost record is in
   [staging load and cost evidence](2026-08-09-harc-remote-staging-load.md).
10. Post-load privacy read-backs passed for production and staging. After the
    ingestion-delay window, staging dashboard queries again returned zero
    retained Worker events and zero traces.
11. The real pinned TLS 1.3 integration test passed through the deployed staging
    origin twice. It completed claim/bootstrap, an authenticated Library
    snapshot, interrupted-upload reconciliation, and resumable upload. The
    second run used the staging-only wrapper, which refused any other origin and
    proved the deployed privacy settings unchanged at 15:53 and 15:56 UTC.
12. Final production and staging read-backs at 15:56 UTC again showed their
    qualified versions at 100%, Logpush disabled, no Tail Workers, observability
    disabled, and health OK.
13. A purpose-built temporary Tail Worker reduced 85 complete-flow staging
    events to fixed counters. It discarded 261 header fields, 28 secret-header
    occurrences, six named canary headers and their six plaintext values, and
    11 Cloudflare metadata objects. It retained zero logs, exceptions,
    diagnostics, truncated events, raw markers, paths, headers, or values. See
    [staging redaction evidence](2026-08-09-harc-remote-staging-redaction.md).
14. The observer was detached and deleted. Restored staging version
    `6d537995-70ea-40d0-aed7-4442d93a0efa` read back at 100% with Logpush
    disabled, no Tail Workers, observability disabled, and health OK at 16:24:58
    UTC; its real overload regression passed again.
15. At 16:33 UTC, after the ingestion-delay window, authenticated dashboard
    queries returned zero staging Worker events and zero traces over the
    preceding hour for the final observer exercise and restored deployment.
16. The staging lifecycle harness then passed `503 host_offline`, initial and
    replacement bidirectional acknowledged tunnels, same-route Host-control
    reconnect, revocation, stale-capability rejection, and replacement
    authorization. The final 16:40:53 UTC read-back retained version
    `6d537995-70ea-40d0-aed7-4442d93a0efa` at 100% with Logpush disabled, no
    Tail Workers, observability disabled, and health OK. See
    [staging lifecycle evidence](2026-08-09-harc-remote-staging-lifecycle.md).
17. At 16:43 UTC, after the dashboard ingestion window, authenticated lifecycle-
    interval queries returned zero staging Worker events and zero traces over
    the preceding hour.

## Decision

- **Pass:** distinct staging deployment, real Cloudflare overload close path,
  post-redeployment regression, 1,000-idle-Host load/cost feasibility, staging
  inner TLS, safe aggregate redaction, health, and deployed no-retention
  settings.
- **Open:** two unrelated physical networks, direct-route recovery and visible
  app revocation state, plus old-record/account-export-expiry closeout.
- **Prohibited:** raw Cloudflare real-time tailing of relay traffic. It exposes
  more routing and network metadata than Harc's evidence policy permits.
