# Host, Client, and Mobile Implementation Status

**Date:** 2026-08-04

**Branch:** `codex/host-client-mobile`

**Specification:** [2026-08-02 Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

## Outcome

The planned PR 0-9 source surface is implemented on the feature branch. PR 10
remains intentionally deferred because the specification makes its inference
extraction, agent, VPN, iPad, and migration work optional after the vertical
slice is stable.

The local implementation, standalone regression, iOS Simulator build/tests,
and unsigned macOS application build gates are green. This is not yet a
mobile-release-complete or TestFlight-complete claim: physical iPhone
capture/background-transfer gates and the real secondary-Mac acceptance run
require hardware outside this coding session.

## Implemented slices

| Slice | Result | Representative commits |
| --- | --- | --- |
| PR 0-2 | Baseline, stable domain identity/migrations, capture/publication seam | `9b74920`, `666bdd1`, `e868a34` |
| PR 3-4 | Device identity, transfer/client/host stores, protobuf and exact signed wire contracts | `a403275`, `117050e` |
| PR 5 | Canonical ingest, durable signed receipts, processing publication | `0151fc6` |
| PR 6 | Pairing/TLS, pinned gRPC, narrow HTTPS upload, discovery, resident Host lifecycle, local MCP authority, UI and CLI | `77f0556` through `06c7ff7` |
| PR 7 | iPhone durable capture, QR adoption, lossless chunks, persistent outbox, production background transfer/relaunch reconciliation, receipt flow, and standalone local playback/export | `2e0c58b` through current branch |
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
- The application-hosted `HarcMobileAppTests` target completed 7/7 tests on an
  arm64 iPhone 17 Pro simulator. These cover the generated privacy/background
  configuration, deterministic bounded HARCAB1 construction and exact replay,
  the required disclosure before a local master is handed to the system
  export destination, and rejection of unresolved Bonjour service endpoints
  until Network.framework supplies a concrete host and port. They also prove
  that a 48 kHz stereo to 44.1 kHz mono route change rebuilds the converter
  while preserving one durable master and that a late reconfiguration request
  fails promptly after writer termination instead of waiting indefinitely.
- The production iPhone composition now mints request-bound background upload
  capabilities, builds immutable file-backed HARCAB1 batches, persists the
  batch-to-URLSession-task mapping before resume, reconciles task state after
  relaunch, retries recoverable terminal tasks without duplicating active
  tasks, and reports durable completion back into the outbox.
- A failed persisted Host route now triggers bounded Bonjour rediscovery. A
  recovered route is persisted only after pinned TLS, adopted-Host validation,
  capability negotiation, and authenticated session opening all succeed.
- iPhone capture now records old/new input-route descriptors, drains the old
  accepted buffers, and rebuilds the engine, tap, and canonical converter for
  route or engine-configuration changes without splitting the durable master.
  Media loss/reset remains a visible terminal event. A writer or storage
  failure publishes only the last synchronized durable prefix, with explicit
  failure and recovery discontinuities, rather than returning a false
  whole-file success.
- The Record screen now exposes protected masters under **On This iPhone** for
  playback and explicit foreground export without a Host. The share sheet is
  reachable only after disclosing that the selected destination is outside the
  adopted-Host trust boundary; export neither changes receipt state nor deletes
  the local master.
- Mobile recording and Host-library detail now surface capture interruptions,
  route changes, canonical-audio availability, and signed speaker-label edit,
  add, and remove controls.
- The non-shipping `HarcMobileSpikesTests` target completed 14/14 qualification-
  logic tests on the same simulator. Schema-5 reports bind each run to a unique
  report and app-process launch, the exact app version/build, signing team, and
  source SHA. Simulator, iOS-app-on-Mac, incomplete, unsigned, or non-phone
  evidence cannot satisfy the physical codec gate.
- The `harcctl qualify-codec-matrix` validator completed 10/10 focused CLI tests.
  It independently revalidates all four oldest/current iPhone and CAF+ALAC/FLAC
  report cells, rejects reused app processes, and leaves codec selection as a
  reviewed decision. A real schema-5 quick-mode report produced by the iPhone
  Simulator was rejected with `quick or unknown modes cannot qualify`.
- The physical execution procedure is recorded in
  `docs/operations/mobile-physical-qualification.md`; each codec candidate must
  run for three hours from a fresh app process on both named physical iPhones.
- The complete standalone SwiftPM regression passed 1,498 Swift Testing cases
  in 253 suites plus 121 XCTest cases. Nine real-model/daemon Swift Testing
  cases and four model-quality XCTest cases remain explicitly opt-in through
  `HARC_INTEGRATION_TESTS=1`; the Unified Parakeet fixture gate also passed in
  isolation on the installed model.
- The complete unsigned arm64 macOS `Harc` application build completed with
  `** BUILD SUCCEEDED **`, including the embedded `harc-stt` and `harc-mcp`
  helpers.
- A testable `Harc` policy module emitted successfully, and all committed source
  diffs passed `git diff --check`.
- Earlier slice-specific evidence remains in this directory for PRs 3 through 6.

The full regression exposed and resolved four integration defects: a stale
bootstrap factory API feasibility reference, a stale reviewed protobuf source
checksum, a trapping signed Darwin device identifier conversion in the
file-backed HARCAB1 scanner, and two assertions that checked a legacy JSON
sidecar instead of the canonical OKF Markdown projection. Real-model tests are
now consistently opt-in so ordinary CI and local regression runs do not start
several CoreML stacks concurrently.

## Gates still open

| Gate | Status | Required evidence |
| --- | --- | --- |
| Clean full SwiftPM tests | Green | `swift test --jobs 2` passed 1,498 Swift Testing cases in 253 suites and 121 XCTest cases on 2026-08-04; 13 real-model/model-quality cases were intentionally skipped by their opt-in contract. |
| Unsigned macOS app build | Green | Bounded unsigned arm64 `Harc` build completed with `** BUILD SUCCEEDED **` on 2026-08-04. |
| iOS Simulator build | Green | The unsigned arm64 Debug build and application-hosted tests completed successfully on 2026-08-04. |
| iOS Simulator test execution | Green | `HarcMobileAppTests` passed 7/7 and `HarcMobileSpikesTests` passed 14/14 on an arm64 iPhone 17 Pro simulator running iOS 26.5 on 2026-08-04. The focused codec-matrix CLI suite passed 10/10. |
| Physical iPhone C1/C2/T1/T2 | Open | Three successful runs on the oldest and current supported test iPhones, with device, OS, build, hashes, and logs. |
| Codec release qualification | Open on hardware | Produce the four fresh-process schema-5 reports and validate them with `harcctl qualify-codec-matrix`; then review the selected codec and background behavior against the physical-device thresholds. |
| Secondary-Mac PR 9 gate | Open on hardware | Pair a real second Mac, record/system-capture and transcribe locally, upload concurrently, then observe Host acceptance or visible reprocessing. |
| External TestFlight hardening | Deferred | Consent/indicator verification, privacy and export metadata, reviewer-accessible demo/sample flow, accessibility, upgrade/recovery, and Beta Review notes. |

`xcrun devicectl list devices` reported no attached physical devices on
2026-08-04, so no physical-gate result is inferred from the Simulator runs.

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
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2 \
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
