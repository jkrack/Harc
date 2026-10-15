# Host Library RPC diagnostic checkpoint — 2026-10-15

The reported Library error, `GRPCCore.RPCError error 1`, does not identify a gRPC
status. `RPCError` bridges through NSError without a localized error contract.
Synthetic errors with the distinct statuses `cancelled`, `deadlineExceeded`,
`permissionDenied`, and `unavailable` all bridge to NSError code 1. Treating the
reported number as `cancelled` would be an unsupported diagnosis.

The Library coordinator now uses the existing `HarcTransportErrorDiagnostic`
formatter used by Settings to obtain the typed RPC status. The Library displays
only that status and fixed operation labels; it suppresses arbitrary RPC
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

## Bounded regression evidence

Four new Swift Testing tests cover the actual RPC status/cause boundary,
exclusion of untrusted error descriptions, cached-row and operation presentation,
and an immediately visible retry that
retains cached rows. The last fixture uses an in-memory software identity, a
synthetic temporary cache, and no adoption or route. It neither accesses real
credentials nor opens a network connection.

On Apple Silicon macOS 26.6.2 with Xcode 27, an isolated native SwiftPM projection
of the exact coordinator and supporting sources passed all four tests. Before
the additional privacy test, restoring the old localized-description behavior
and cached-row refresh condition made the original three tests fail with ten
assertions; restoring the proposed source passed all three again. The final
four-test run also verifies that RPC messages and arbitrary localized errors
cannot render credential-like fixtures, transcript-like fixtures, or raw request
text. The projection uses wire Swift files previously
generated from the identical schemas; it omits the generation plugin and app
entrypoint. This is focused source evidence, not an Xcode app or physical-device
qualification. The four tests are added to the existing mobile configuration
CI selector for full-target compilation and execution.

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
