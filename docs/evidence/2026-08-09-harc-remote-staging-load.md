# Harc Remote staging load and cost evidence

**Date:** 2026-08-09
**Environment:** `harc-remote-relay-staging`
**Worker version:** `df830ae2-434d-4096-a3da-6ba21f2621a7`
**Origin:** `https://harc-remote-relay-staging.jlworker.workers.dev`

## Result

The bounded 1,000-idle-Host staging load gate passes. All requested Host
rendezvous connections opened, no connection retry was required, the active
opaque transfer completed through the production one-frame-credit protocol,
and relay health remained OK. Cloudflare reported no Worker application error,
resource-limit error, internal error, or exception.

The run fits within the current Workers Paid monthly included allowances. Its
overage-equivalent cost is under one cent even if every displayed counter is
priced as though the account had already exhausted those allowances. Actual
invoice impact still depends on aggregate account usage during the billing
month; this evidence is not a promise of unlimited free relay service.

## Harness

`CloudflareRelay/scripts/test-staging-load.mjs` is a fail-closed, staging-only
harness. It refuses the production origin, emits no route or capability values,
and reports aggregate measurements only. The qualified run used:

- 1,000 simultaneous idle Host rendezvous WebSockets;
- batches of 40 connection attempts;
- a 30-second interval with all 1,000 Hosts connected;
- one 16 MiB opaque active transfer in 64 256-KiB frames; and
- the production acknowledgement/one-outstanding-frame protocol.

## Measured result

| Measurement | Result |
| --- | ---: |
| Hosts requested/opened | 1,000 / 1,000 |
| Connection retries | 0 |
| Connection wall time | 47.230 seconds |
| Connection latency p50 / p95 / p99 | 807 / 907 / 1,236 ms |
| Maximum connection latency | 16.286 seconds |
| All-connected hold | 30 seconds |
| Active payload | 16,777,216 bytes / 64 frames |
| Active transfer time / throughput | 5.50 seconds / 2.91 MiB/s |
| Local load-generator peak RSS | 214.09 MiB |
| Total run | 77.25 seconds |
| Health before / after | OK / OK |

A preceding 10-Host, 1-MiB smoke run also passed before the required run.

## Platform measurements

The authenticated Cloudflare dashboard showed these aggregate measurements for
the staging Worker and its Durable Object classes over the surrounding 24-hour
window. That window also contains the earlier staging overload and smoke tests,
so these are conservative rather than isolated load-run counters.

- Worker: about 1,000 invocations, zero application errors, median CPU 0.46 ms,
  p99 CPU 1.06 ms, and p99 memory 1.66 MB.
- `HostRendezvous`: about 2,000 requests, 74.31 GB-s duration, roughly 1,000
  rows read and 4,000 rows written, p99 memory 1.59 MB, and no CPU-limit,
  memory-limit, internal, or exception errors.
- `RelaySession`: 179 requests, 0.86 GB-s duration, 23 rows read, 44 rows
  written, p99 memory 4 MB, and no CPU-limit, memory-limit, internal, or
  exception errors.
- Combined displayed Durable Object duration: 75.17 GB-s.
- Durable Object WebSocket traffic was hibernatable; no non-hibernatable
  WebSocket messages were reported.

Cloudflare classifies normal WebSocket cleanup as `Client disconnected` in the
Durable Object error chart. The chart therefore showed expected disconnect
counts even though the Worker error rate was zero, all harness assertions
passed, and health remained OK. Operations must report expected client
disconnects separately from CPU-limit, memory-limit, internal, exception, and
unexpected-disconnect failures.

## Cost interpretation

The account dashboard identified Workers Paid as the current plan. Current
Cloudflare documentation lists these monthly included allowances:

- Workers: 10 million requests and 30 million CPU milliseconds;
- Durable Objects: 1 million requests and 400,000 GB-s;
- SQLite-backed Durable Objects: 25 billion rows read, 50 million rows written,
  and 5 GB-month stored data; and
- no Worker data-transfer or throughput charge.

The measured counters are far below each allowance. Applying current overage
rates to the displayed counters without subtracting allowances still produces
an upper-bound equivalent below $0.01 for this exercise. The dominant synthetic
counter is SQLite row writes, not bandwidth or idle WebSocket duration.

Sources: [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
[Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/),
and [Durable Object WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).

## Privacy and cleanup

After the run, deployed privacy checks passed for staging and production:
Logpush disabled, no Tail Workers, persistent observability disabled, and live
health OK. After the ingestion-delay window, authenticated staging dashboard
queries returned zero retained Worker events and zero traces.

The synthetic Host rendezvous objects contain only randomly generated staging
route-capability hashes and schema state, never user content, identities,
recordings, transcripts, or emitted secrets. Host identity is intentionally
durable in the product design, so these 1,000 synthetic objects are not
individually addressable after the aggregate-only harness discards their
capabilities. Namespace reset or a staging-only lifecycle policy is a separate
operator decision; it is not required to prove payload non-retention and must
not be performed against production.

## Decision

- **Pass:** 1,000 simultaneous idle Host connections, representative active
  transfer, bounded generator memory, health, platform resource posture,
  no-persistent-observability read-back, and current-plan cost feasibility.
- **Operational hardening:** alert on real resource/application failures and
  unexpected disconnect rate, not the dashboard's undifferentiated
  `Client disconnected` count; decide a lifecycle for synthetic staging Host
  state before recurring large runs.
- **Still open:** two unrelated networks, reconnect/revocation, and
  old-record/account-export-expiry closeout. The full staging inner-TLS and safe
  aggregate redaction flows passed separately after this load run.
