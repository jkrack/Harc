# Host, Client, and Mobile Implementation Status

**Date:** 2026-08-03

**Branch:** `codex/host-client-mobile`

**Specification:** [2026-08-02 Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

## Outcome

The planned PR 0-9 source surface is implemented on the feature branch. PR 10
remains intentionally deferred because the specification makes its inference
extraction, agent, VPN, iPad, and migration work optional after the vertical
slice is stable.

This is not yet a release-complete or TestFlight-complete claim. Physical iPhone
capture/background-transfer gates and the real secondary-Mac acceptance run
require hardware outside this coding session.

## Implemented slices

| Slice | Result | Representative commits |
| --- | --- | --- |
| PR 0-2 | Baseline, stable domain identity/migrations, capture/publication seam | `9b74920`, `666bdd1`, `e868a34` |
| PR 3-4 | Device identity, transfer/client/host stores, protobuf and exact signed wire contracts | `a403275`, `117050e` |
| PR 5 | Canonical ingest, durable signed receipts, processing publication | `0151fc6` |
| PR 6 | Pairing/TLS, pinned gRPC, narrow HTTPS upload, discovery, resident Host lifecycle, local MCP authority, UI and CLI | `77f0556` through `06c7ff7` |
| PR 7 | iPhone durable capture, QR adoption, lossless chunks, persistent outbox, foreground/background transfer and receipt flow | `2e0c58b` through `ce82a30` |
| PR 8 | Host Library snapshot/delta sync, search, detail, verified audio playback, signed metadata mutations and conflicts | `4aa7858` through `8c5e3bd` |
| PR 9 | Mac Client pairing/outbox, Host Library, signed edge artifacts, Host arbitration, managed audio cache policy | `33e0b2e` through `c5bba8c` |

## Validation completed in this pass

- `xcodegen generate` completed successfully from canonical `project.yml`.
- The changed `HarcPreferences` and General Settings surface passed a focused
  macOS Swift 6 typecheck.
- The shared Host Library coordinator, pinned session connector, metadata
  mutation, audio download/cache, and playback policy sources passed a focused
  macOS Swift 6 typecheck with current transport modules.
- The desktop Host connection, processing artifact, Client transfer, Client
  pairing, Client runtime, and Host Library window sources passed together in a
  focused macOS Swift 6 typecheck.
- The generated `HarcMobile` scheme completed an unsigned arm64 iOS Simulator
  build with architecture and Xcode target concurrency explicitly bounded.
- A testable `Harc` policy module emitted successfully, and all committed source
  diffs passed `git diff --check`.
- Earlier slice-specific evidence remains in this directory for PRs 3 through 6.

## Gates still open

| Gate | Status | Required evidence |
| --- | --- | --- |
| Clean full SwiftPM tests | Open | Run `swift test --jobs 2` after all iCloud-backed package artifacts are materialized. |
| Unsigned macOS app build | Open | Run the plan's bounded Harc `xcodebuild` command and the standalone regression matrix. |
| iOS Simulator build | Green | Unsigned arm64 Debug build completed with `** BUILD SUCCEEDED **` on 2026-08-03. |
| iOS Simulator test execution | Environment-blocked | `CoreSimulatorService` is unavailable after the machine crash; rerun `HarcMobileAppTests` after the service or Mac is restarted. |
| Physical iPhone C1/C2/T1/T2 | Open | Three successful runs on the oldest and current supported test iPhones, with device, OS, build, hashes, and logs. |
| Codec release qualification | Open on hardware | Confirm the selected CAF/ALAC implementation and background behavior against the physical-device thresholds. |
| Secondary-Mac PR 9 gate | Open on hardware | Pair a real second Mac, record/system-capture and transcribe locally, upload concurrently, then observe Host acceptance or visible reprocessing. |
| External TestFlight hardening | Deferred | Consent/indicator verification, privacy and export metadata, reviewer-accessible demo/sample flow, accessibility, upgrade/recovery, and Beta Review notes. |

An initial generic Simulator invocation attempted both arm64 and x86_64 despite
`ONLY_ACTIVE_ARCH`; it was stopped to protect the machine. The successful run
therefore pins `ARCHS=arm64` and excludes x86_64 explicitly.

## Safe validation commands

Keep concurrency bounded on the affected machine:

```bash
xcodegen generate
swift test --jobs 2
xcodebuild \
  -project Harc.xcodeproj \
  -scheme Harc \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 2 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  -skipPackagePluginValidation \
  build
xcodebuild \
  -project Harc.xcodeproj \
  -scheme HarcMobile \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -jobs 2 \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2 \
  CODE_SIGNING_ALLOWED=NO \
  -skipPackagePluginValidation \
  build
```

Do not infer success from source typechecks alone. Release status changes only
after the full builds and hardware matrices produce recorded evidence.
