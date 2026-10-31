# Production candidate gate report

**Disposition: not qualified for release.** The implementation remains a dirty
candidate on `codex/production-hardening`, based on
`3ad6bc930dc7248f7a30160a321329bdd2e2b4ca`, version **0.14.12 (67)**. It is not a
new release, archive, or uploaded build. The original review began from a clean
checkout; the accumulated hardening work still needs a sealed candidate review.

This report indexes evidence; it does not promote historical component tests
to exact-candidate qualification. Detailed commands, failures and limitations
are in [the execution log](../plans/2026-09-05-production-hardening.md).
Ignored local artifacts live under
`build/qualification/production-hardening-2026-09-05/`.

| Required gate | Available evidence | Remaining work |
| --- | --- | --- |
| Capture/recovery integrity | Implemented durable publication, destination binding, transactional recovery and visible capture issues; focused fault tests and controlled volume/process diagnostics passed | Current app lifecycle, live capture and physical interruption verification |
| SwiftPM regression | Post-model-hardening run: 1,640 Swift Testing passes + 12 skips; 122 XCTest passes + six skips; zero failures, with log/XML accounting | Fresh full run bound to the final sealed candidate; opt-in skips remain separate gates |
| macOS app build | Diagnostic app/helper build passed after model-readiness, ownership, cancellation and summary parser/storage-notice changes | Latest diagnostic app build passed with menu restoration and transcript lifecycle fixes; sealed-candidate and signed-artifact qualification remain |
| macOS app-hosted tests | Fresh combined diagnostic run passed 45 app-hosted cases plus all eight current UI cases, zero skips; execution gate passed all eight required selectors | Refresh against final sealed candidate |
| macOS UI | Complete current macOS UI suite passed eight cases, zero skips: capture warning, Library detail, search, inspector, fake recording persistence, Settings, exact transcript editing/undo/redo/relaunch. Earlier direct CUA inspection confirmed warning and General/Transcription rendering | Real capture/recovery, broader accessibility and exact-candidate qualification remain; synthetic recording does not exercise physical audio or inference |
| iOS software/UI | Simulator build passed against the frozen source snapshot; physical and UI scopes remain distinct | Exact-candidate app and UI results with no required cases skipped |
| Direct/relay pairing | Frozen candidate direct pinned-TLS and local encrypted-relay lifecycle tests each passed one case, zero skips | Real secondary Mac and two-network acceptance; refresh if relevant implementation changes |
| CI enforcement | Workflow lanes, skip accounting and local checker regressions implemented | Run remotely; main read-back found no classic protection or active branch rules; enforce required checks after verification |
| STT/VAD quality | Eight synthetic cases passed after the short-gap preservation fix; source/model evidence retained | Consented diverse real recordings, speaker quality and long-form accuracy; Core ML preprocessor warning remains unresolved |
| Summary quality | Latest local Gemma probe: production prompt passed 3/15 synthetic actor/format checks; shorter candidate 13/15; worked-example candidate passed 11 before disk interruption. Production prompt unchanged. Expanded opt-in contrast cases and task-term checks type-check | Complete/repeat candidate comparison, independent examples, Qwen comparison and raw factual review. [Investigation](2026-09-06-summary-attribution.md); real-world summary quality remains unqualified |
| Endurance/performance | Bounded-memory large-file recovery diagnostic passed; daemon responsiveness is separate from inference readiness | Multi-hour live capture under inference load, real capture/inference latency and thermal/memory behavior |
| Upgrade/restore | Recovery components exercised with disposable files/libraries | Installed upgrade and restore drills against the candidate |
| Physical mobile/desktop | Software and emulator evidence only | Named iPhones, secondary Mac, C/T/P/H, lock/background, interruption, revocation and reconnect matrix |
| macOS release | Existing published release is not this hardening candidate | New clean source/version, exact signed/notarized/stapled bytes, updater and publication checks |
| iOS/App Store | No current exact archive/upload/account-owner closure | Candidate archive, device/screenshots/evidence, processing result and owner-approved metadata |
| Privacy/security deployment | Production Worker Logpush/ordinary tails/observability read-back passed; stricter streaming-tail check lacks a returned field; account Logpush returned HTTP 403 | Authoritative streaming-tail and account export/retention evidence and platform security disposition; deployed code exactly matches a fresh local bundle, with 19 local relay tests passing |

## Source identity

`python3 scripts/production-source-snapshot.py --write <ignored-output.json>`
records all tracked and non-ignored untracked files, their bytes, executable
state, the current commit and a canonical inventory digest. Verify it with
`--check <ignored-output.json>` while writers/builds are stopped. Changes to
source, tests, documentation or the commit require a new snapshot. Outputs
must be ignored when written inside the repository and are never overwritten.

A matching source snapshot **does not validate tests, binaries, models, hardware,
security or release readiness**. Its qualification field always remains
`unqualified`. Pair it with exact artifact digests and gate-specific evidence;
do not attach old green results merely because their filenames look current.
The initial review-candidate snapshot is retained at
`build/qualification/production-hardening-2026-09-05/review-candidate-source.json`.

The frozen 993-file snapshot (tree digest `15b1e188d1c7acda07c460484c7bc78b8a821394a8545361b153ed703e8bf363`) now has full package, macOS/iOS build and local pairing evidence in `review-candidate-validation.*` and `review-candidate-pairing/`. Subsequent quality-evaluator and documentation edits supersede that source inventory; those results remain evidence for the recorded snapshot, not an automatically qualified new candidate.

## 2026-10-15 trustworthy-candidate pass

**Disposition: trustworthy software candidate for the next physical qualification
step; not release-qualified.** This pass validated the current dirty tree based on
`3ad6bc930dc7248f7a30160a321329bdd2e2b4ca`. It did not version, sign, notarize,
publish, deploy the relay, or upload an iOS archive.

The live checkout is under macOS Documents file coordination. Recursive Xcode,
SwiftPM, and source-snapshot operations there blocked on 39 cloud-offloaded
documentation, image, and script files. Validation therefore used
`/private/tmp/harc-trustworthy-candidate-20261015`, with the product source and
test directories copied individually. Checksum dry-runs confirmed byte identity
for `Sources`, `Tests`, all macOS and mobile app/test source directories,
`Protos`, `project.yml`, and `Package.swift` before compilation. The sealed build
graph contains 902 files with aggregate SHA-256
`159769249ce50b5777e1b0c9e7f2782de617ca724cf91418f1d7a3611073910b`;
the `project.yml`/`Package.swift`/`Package.resolved` aggregate is
`759c5b20cbf9970ddc8c5342fae527b45fe23cb8404d0dcf157d87187c9d8b7a`.
This is a build-graph identity record, not the repository-wide source seal.

| Gate | Result | Qualification limit |
| --- | --- | --- |
| HarcMobile Debug compile | Passed for generic iOS Simulator, two workers, signing disabled | No Simulator runtime was installed, so the app was not launched |
| HarcMobile test-bundle compile | Passed for arm64 generic iOS Simulator, two workers, signing disabled | Tests compiled but could not execute without a Simulator runtime |
| Host-health implementation | App and test target compile together; the existing `Desktop connected` state machine and presentation tests are included in the sealed graph | Requires Simulator and then physical Host/iPhone observation |
| Relay privacy configuration | Passed; production and staging configurations are fail-closed | Configuration test only; no deployment mutation |
| Relay TypeScript | Passed | Local isolated tree |
| Relay core tests | 19/19 passed with at most two workers | Local Worker runtime, not deployed staging |
| Relay redaction observer | 1/1 passed | Local Worker runtime, not account-level log-retention proof |
| Focused SwiftPM Host regressions | Not completed: stopped by the disk guard at about 5.29 GiB free while dependencies were rebuilding | No failing test was observed; this is an open gate, not a pass |

The mobile compile produced only three existing warnings that `@preconcurrency`
has no effect on `AVAudioPlayerDelegate` conformances. Xcode returned success for
both the app build and build-for-testing. Regenerable Xcode products and the
partial SwiftPM rebuild were cleaned after the run; free space was restored
without deleting source, recordings, models, or retained evidence.

Remaining gates are explicit: execute the mobile tests on an installed Simulator
runtime, run the focused and then aggregate Host regression suites with adequate
disk headroom, perform direct and relayed pairing/transfer with the real Host and
client, exercise background/lock/route-change recovery on the named iPhone, and
only then seal a clean commit and run release signing/notarization/publication.
