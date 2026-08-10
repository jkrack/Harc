# Host, client, and mobile completion audit

**Date:** 2026-08-09

**Decision:** Source implementation for PRs 0 through 9 is present and the
bounded local regression is green. The complete product goal is **not yet a
release go** because the specification intentionally requires physical iPhone,
secondary-Mac, two-network, and account-owner evidence that cannot be replaced
by local tests. PR 10 remains optional by design.

## Ordered-slice status

| Slice | Current status | Remaining acceptance evidence |
| --- | --- | --- |
| PR 0-2 | Source complete and locally covered: ratified contracts, stable IDs/migrations, and the capture/publication seam preserve standalone Mac behavior. | None for the local source gate. |
| PR 3-5 | Source complete and locally covered: identity, client/Host stores, signed protocol, idempotent ingest, durable receipts, and crash recovery. | Shipping mobile codec selection remains fail-closed until the complete named-device physical matrix passes. |
| PR 6 | Source complete and locally covered: pinned gRPC/TLS, narrow HTTPS, discovery, embedded Host lifecycle, session/revocation, local MCP, and encrypted relay integration. | Physical delayed-background, route-change/leaf-cutover, and final two-network evidence remain. |
| PR 7 | Source complete and locally covered: iPhone capture, protection, recovery, outbox, foreground/background transfer, receipt retention, playback, and export. | The remaining C/T/P/H physical matrix and named-device repetitions remain. |
| PR 8 | Source complete and locally covered: Library snapshot/delta sync, search/detail/playback, cache, mutations, conflict handling, and speaker identity sync. | End-to-end useful-mobile-beta behavior still needs physical qualification. |
| PR 9 | Source complete and locally covered: secondary-Mac role, pairing, separate On This Mac library, local processing, provenance, transfer, and managed privacy controls. | A real secondary Mac must pair, record/transcribe locally, upload, and visibly resolve Host acceptance or reprocessing. |
| PR 10 | Deferred. | Optional and not a release dependency. |

## 0.14.3 pairing failure and regression closure

The observed secondary-Mac failure exposed two independent route-lifecycle
edges:

1. Constructing a gRPC connection owner did not prove DNS, TLS, HTTP/2, or the
   first authenticated RPC. Direct-route construction could therefore appear
   successful and suppress encrypted-relay fallback.
2. The relay WebSocket used a 30-second URLSession resource timeout even though
   the protocol requires a long-lived Host/client tunnel.

Harc 0.14.3 verifies an authenticated, idempotent `getHostInfo` RPC before
selecting either route and uses a 24-hour relay resource lifetime. Failed
direct and relay candidates are shut down before the next attempt or error.

This audit adds a transport-independent route strategy seam and deterministic
tests proving:

- a verified direct route wins without opening the relay;
- a direct first-RPC failure closes direct and falls back to relay;
- a rejected relay is closed and reports both failures; and
- an invitation without a relay reports a direct-only failure.

## Validation in this pass

All build/test commands were capped at two workers and retained warm artifacts.

| Gate | Result |
| --- | --- |
| `xcodegen generate` | Passed |
| Focused `HarcDesktopVerifiedRouteStrategyTests` | 4 tests passed |
| Complete `HarcAppTests` bundle | 17 tests in 6 suites passed |
| macOS application compile/link/embed path | Passed as part of both Xcode test runs |
| Disk floor | 13 GiB available after validation; above the 5 GiB stop floor |

The earlier 0.14.3 release evidence separately records the successful focused
relay tests, pinned-gRPC loopback integration, Developer ID Release build,
notarization, DMG/ZIP hashes, Sparkle publication, and public GitHub release.

## Required completion sequence

1. Install Harc 0.14.3 or newer on both Macs through Sparkle.
2. On the Host, create a fresh **Mac client** invitation and keep the approval
   window open.
3. On the remote Client, open the invitation, compare the four words, approve
   on the Host, and confirm the Host lists the adopted device identity.
4. Record on the Client, confirm its local transcript, complete Host transfer,
   and verify Host acceptance or visible reprocessing without merging the
   Client's prior On This Mac library.
5. Repeat reconnect, revocation, and transfer across two unrelated networks.
6. Complete the named-device iPhone codec and C/T/P/H matrices, physical
   accessibility/upgrade/recovery checks, remaining screenshots, monitored
   support contact, and App Store account fields.

Until those steps are evidenced, the architecture and source are ready for
continued physical acceptance, but the full goal remains open.
