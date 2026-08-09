# Harc Remote staging redaction evidence

**Date:** 2026-08-09
**Environment:** `harc-remote-relay-staging`
**Qualified final version:** `6d537995-70ea-40d0-aed7-4442d93a0efa`

## Result

The safe staging redaction gate passes. A purpose-built Tail Worker consumed a
bounded synthetic exercise, immediately reduced every event to fixed aggregate
counters, and persisted no raw request, URL, header name/value, Cloudflare
metadata object, route, capability, canary, log, exception, or application
payload. Raw `wrangler tail` was not used.

The observer was detached before it was deleted. The restored staging Worker
then read back with Logpush disabled, no Tail Workers, persistent observability
disabled, one version at 100%, and health OK. Its real `4429
receiver_overloaded` regression also passed after detachment.

## Named exercise

The checked-in `scripts/test-relay-redaction-staging.sh` workflow:

1. verifies the fail-closed source and deployed staging privacy settings;
2. validates generated observer bindings, TypeScript, unit/Durable Object
   integration tests, and dry-run bundles;
3. deploys `harc-remote-redaction-observer` with its own persistent
   observability disabled;
4. creates a temporary staging config from the qualified source config and
   adds exactly that observer as the sole Tail Worker;
5. verifies the temporary staging settings still have Logpush and persistent
   logs/traces disabled;
6. sends six named synthetic plaintext canaries, runs the real overload path,
   and runs pinned TLS 1.3 bootstrap, Library, reconciliation, and resume;
7. validates the aggregate-only report; and
8. restores normal staging, deletes the observer, rechecks privacy/health, and
   reruns overload on the restored version.

The cleanup path restores staging before deleting the observer. If restoration
fails, it deliberately leaves the observer deployed so staging never points at
a missing consumer.

## Aggregate report

The passing observer report contained only these fixed fields and counts:

| Aggregate | Count |
| --- | ---: |
| Tail batches / producer events | 85 / 85 |
| Ignored producer events | 0 |
| Fetch / hibernatable or other non-fetch events | 19 / 66 |
| Health / Host-connect / Host-session / session-connect endpoints | 4 / 1 / 2 / 4 |
| Other endpoint categories | 8 |
| Request header fields discarded | 261 |
| Sensitive header occurrences discarded | 28 |
| Named canary headers discarded | 6 |
| Cloudflare metadata objects discarded | 11 |
| Plaintext canary occurrences observed and discarded | 6 |
| Plaintext canaries in logs/exceptions | 0 |
| Log / exception / diagnostic records | 0 / 0 / 0 |
| Truncated events | 0 |
| Non-OK outcomes | 8 |

The non-OK aggregate includes the deliberately closed/cancelled WebSocket
paths; the overload and pinned-TLS harnesses both passed, and the observer saw
no exception or diagnostic record. As with the load dashboard, operations must
not equate expected WebSocket cleanup with an application/resource failure.

Unit tests prove that even when the observer receives a secret header value,
URL route, or named plaintext canary, its serialized report contains only
counts. The Durable Object integration test proves those counters are the only
persisted/exposed schema. The observer configuration itself has Logpush, Tail
Workers, Workers Logs, and Traces disabled.

## Deployment lifecycle

- Temporary observer version: `f414164d-3115-4a11-b5c6-7fad7e9e1501`
- Temporary observer-attached staging version:
  `bd4fe66c-b021-419c-9834-141eeab2fece`
- Restored no-observer staging version:
  `6d537995-70ea-40d0-aed7-4442d93a0efa`
- Temporary observer deletion: succeeded
- Final staging settings/health read-back: passed at 16:24:58 UTC
- Final restored-version overload regression: passed
- Post-ingestion Observability query: passed at 16:33 UTC with zero staging
  Worker events and zero traces over the preceding hour

## Decision

- **Pass:** safe complete-flow staging transformation, named canary detection
  and discard, no persisted raw evidence, inner TLS application flow, overload,
  observer detachment/deletion, restored privacy/health behavior, and delayed
  zero-event/zero-trace dashboard evidence.
- **Prohibited:** raw relay tailing remains prohibited because it bypasses the
  aggregate transformation and exposes request/network metadata.
- **Still open:** two unrelated networks, reconnect/revocation, and confirmation
  that records from the superseded production sampled configuration have aged
  out and no broader account-level export exists.
