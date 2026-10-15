# Host Library RPC diagnostic checkpoint — 2026-10-15

The reported Library error, `GRPCCore.RPCError error 1`, does not identify a gRPC
status. `RPCError` bridges through NSError without a localized error contract.
Synthetic errors with the distinct statuses `cancelled`, `deadlineExceeded`,
`permissionDenied`, and `unavailable` all bridge to NSError code 1. Treating the
reported number as `cancelled` would be an unsupported diagnosis.

The Library coordinator now uses the existing `HarcTransportErrorDiagnostic`
formatter used by Settings to obtain the typed RPC status. The Library displays
only that status, fixed operation labels, and explicitly allowlisted app-owned
pairing-repair guidance; it suppresses arbitrary RPC
messages, localized descriptions, and underlying causes, and
identifies retained cached rows. Starting another refresh immediately shows
progress even when cached rows exist. The request still coalesces while active;
this change adds no retries, timeout policy, authorization, transport, or codec
changes. A cancelled refresh does not publish a stale failure.

A refresh opens an authenticated session, drains protected edits if authorized,
updates Library metadata, optionally updates speaker profiles, and completes the
connection. A speaker-profile failure can follow a successful metadata update.
Rows displayed beside an error therefore do not prove that the whole refresh
succeeded or identify which operation failed.

## Refresh cancellation ownership

Shutdown cancels the active refresh and releases its task handle. Previously,
that old task could finish after a new refresh started and unconditionally clear
the new handle and progress flag. A negative control reproduces the resulting
extra request. Each refresh now owns a unique identifier; only the current
request may publish a result or clear its handle. Shutdown immediately publishes
a terminal cancelled state, rendered on both clients without claiming a
successful sync, including the capture screen’s Library status projection. The
existing capture-experience test suite is included in mobile CI with a regression
for the terminal presentation. A session returned after
cancellation is closed without running Library work. Snapshot, delta, and
speaker-pack responses check cancellation before publishing into the cache.

The lifecycle accepts an internal opened-session abstraction for deterministic
fault injection. Production always opens through the existing authenticated
Host connector and retains the same scope checks and RPC operations. No launch
argument, remote setting, authorization fallback, or alternate production
connection path is added.

## Bounded regression evidence

Twelve Swift Testing tests exercise 29 single or parameterized cases:

- Initial and cached loads failing at Host connection, protected edits, metadata,
  speaker profiles, or connection completion. Later failures retain metadata
  already committed by the successful metadata operation.
- A successful retry clearing the previous error and publishing updated rows.
- Active-refresh coalescing; stale success/error responses completing before or
  after the newer request; cancellation while opening a session; and an absent
  Library-read grant closing without running Library work.
- Terminal shutdown state before and after late success/failure, with and without
  cached rows; fixed typed pairing-repair instructions retaining cached rows.
- Actual RPC status preservation, exclusion of arbitrary RPC/localized/cause
  text, oversized untrusted RPC payloads producing at most 140 displayed characters
  (fixed repair guidance remains below 240),
  and a no-adoption fixture retaining its local cache without a network route.

On Apple Silicon macOS 26.6.2 with Xcode 27, the exact-source native SwiftPM
projection passed 43 tests across the lifecycle, Library cache, receipt
persistence, outbox, and background isolation suites. Restoring the old unowned
cleanup only in that projection makes the four-case stale-response regression
fail with four assertions, including an unexpected third open. A second negative control removing the
repair allowlist and terminal shutdown state makes both new regressions fail
with twelve assertions across six cases. Restoring the proposed source passes. Earlier, restoring the old localized-description and
cached-row refresh behavior made the original three tests fail with ten
assertions.

All fixtures use synthetic temporary caches and in-memory software identities.
No real credentials, network route, or recording content is accessed. Projection
source hashes match the branch; wire Swift files were previously generated from
identical schemas, with the generation plugin and app entrypoint omitted only in
the focus harness. The suite is included in the full mobile configuration CI
selector.

These controlled sessions do not fault-inject real HTTP/2 or pinned-TLS calls,
prove device credential behavior, or close the physical transfer/restart matrix.
The production cancellation checks at concrete snapshot/delta/speaker response
boundaries are compiled by the app targets; the controlled-session race tests
exercise lifecycle publication and task ownership rather than those wire calls.
Full app/CI results must be recorded separately before calling the exact source
validated.

## Acceptance still open

The real backend RPC status and failure stage have not been recovered from the
reported generic message. No live app was refreshed, restarted, installed, or
reconfigured for this diagnostic change. A coordinated diagnostic build and one
refresh must expose the real error before a backend fix is claimed.

A matching-source Mac development artifact at main `c802dce6` is separate from
this change. Matching source versions removes one validation variable but does
not establish the cause of the Library failure.

Production upload remains behind the existing physical-device codec gate.
“Saved locally” and “Protected master ready for Host transfer” do not establish
an upload or Host receipt. Core sync acceptance remains:
**phone → Host durable receipt → phone Library**.
