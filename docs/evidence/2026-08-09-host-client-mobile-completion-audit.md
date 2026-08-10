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
selecting either desktop route and uses a 24-hour relay resource lifetime.
This follow-up moves that verified-route policy into `HarcClientTransport` and
uses it for iPhone pairing as well. Both clients now verify `getHostInfo` under
the invitation trust expectation before selecting direct or encrypted relay;
failed candidates are shut down before the next attempt or error.

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
| Focused shared `HarcVerifiedRouteStrategyTests` | 4 tests passed |
| Complete `HarcAppTests` bundle | 17 tests in 6 suites passed |
| iOS simulator compile/link/embed path | Passed for both simulator architectures |
| macOS application compile/link/embed path | Passed after adopting the shared route policy |
| Disk floor | Remained above the 5 GiB stop floor throughout validation |

The earlier 0.14.3 release evidence separately records the successful focused
relay tests, pinned-gRPC loopback integration, Developer ID Release build,
notarization, DMG/ZIP hashes, Sparkle publication, and public GitHub release.

## Physical state advanced after publication

- The local Host completed the real Sparkle update from 0.14.1 (56) to 0.14.3
  (58). The installed app passed strict signature verification and Gatekeeper
  assessment as a notarized Developer ID build, relaunched, and reported that
  the Host listener was running.
- After relaunch, Harc Remote correctly reported that the updated app still
  needs interactive Keychain authorization for the existing Host identity.
  Direct LAN behavior remains available, but cross-network pairing has not
  been re-tested and must not be claimed until that authorization and the
  secondary-Mac flow complete.
- The paired device named Omega was identified as an iPhone 15 Pro Max
  (iPhone16,2). The current 0.14.3 (58) source built with automatic development
  signing, installed over 0.14.2 (57), launched successfully, and remained a
  running process.
- The complete non-UI `HarcMobileAppTests` bundle then ran on Omega: 24 tests
  passed with zero failures. This includes the real-device data-protection and
  backup-exclusion round trip, route-change capture policy, bounded handoff,
  packaged privacy metadata, and deterministic background-batch checks. This
  is physical install/launch/unit evidence only; it does not substitute for
  pairing, microphone capture, codec, background-transition, transfer, or
  Library acceptance evidence.
- Two bounded attempts to run the three non-permission UI/accessibility tests
  stopped before executing any test assertion because XCTest timed out while
  enabling automation mode. At the time, Omega was wired, paired, unlocked,
  booted, and had Developer Mode and developer-disk-image services enabled.
  This is an unresolved physical-test-infrastructure gate, not evidence of an
  app pass or failure; both `.xcresult` bundles are retained in Xcode's Harc
  DerivedData test logs.

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
