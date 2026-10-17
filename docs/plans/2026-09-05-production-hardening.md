# Production hardening execution

Objective: implement and verify the production milestones accepted from the
[2026-09-05 review](../evidence/2026-09-05-production-review.md). This checklist
tracks the full scope; a software-only pass does not close physical or release
qualification.

## Integrity

- [ ] Recovery metadata: preserve failed loads, commit mutations only after
  persistence, surface errors without clearing the inbox, cover restart and
  interrupted recovery publication.
- [ ] Audio finalization: propagate failed final synchronization, retain safe
  retry semantics, verify recoverable stop behavior in the app.
- [ ] Capture loss: bounded buffering, overflow/conversion/source-failure
  evidence, truthful live UI and persisted discontinuities, Stop drain behavior.
- [ ] Fault matrix: disk exhaustion, destination loss, forced termination,
  corrupt metadata, retry/relaunch, and cross-volume publication.

## Software gates

- [x] Fresh focused and full SwiftPM regression with skip accounting
  (latest full run: 1,766 Swift Testing passes / 12 skips; 167 XCTest passes / seven skips;
  zero failures. See Package regression after exclusive voice support gate below
  for the exact tested snapshot; subsequent diagnostic/documentation work is separate).
- [ ] macOS app build, app-hosted tests, Settings and recording UI smoke.
- [ ] iOS Simulator build and app/UI tests.
- [ ] Required CI lanes for the above plus direct/relay pinned-TLS lifecycles.
- [ ] Retained source manifest, logs, xcresults, and explicit gate dispositions.

## Measured behavior

- [ ] Real local STT/diarization/summary corpus and reproducible baseline.
- [ ] Model revision, per-scenario quality thresholds and regression comparison.
- [ ] Multi-hour capture, cold capture/inference latency, memory under load.
- [ ] Installed upgrade and restore/recovery drills with disposable libraries.

## Physical and release closure

- [ ] Named iPhone codec/endurance and C/T/P/H matrix.
- [ ] Real secondary Mac and two-network direct/relay acceptance.
- [ ] Accessibility, lock/background, interruptions, revocation and reconnect.
- [ ] Current security/network/storage documentation and version inventory.
- [ ] Exact macOS notarized/stapled artifact, updater verification and publishing.
- [ ] Exact iOS archive, screenshots, upload/processing and account-owner fields.
- [ ] Current production relay privacy/retention read-back.
- [ ] Final independent platform go/no-go against one sealed candidate.

## Work in progress

### Release CI stall follow-up — 2026-09-26

GitHub run 36212713745 is now terminal/cancelled. Its retained log shows compilation
and XCTest completion, followed by Swift Testing starts at 03:00:12 UTC without
further test results before cancellation at 08:47 UTC. This is not passing release
CI evidence and does not establish a deadlock cause. Full log:
`build/qualification/release-0.14.13/ci-36212713745.log`.

The working-tree workflow now bounds SwiftPM execution to 40 minutes, records only
the child process group's inventory, attempts bounded macOS samples, and terminates
the entire group before returning a nonzero timeout/cancellation result. Existing
always-run artifact retention includes these diagnostics. Four runner tests passed,
including cancellation and a descendant that ignores SIGTERM. A real local timeout
returned 124 and retained process inventory; the sample itself exceeded its six-second
limit, which remained visible rather than masking the timeout. Evidence:
`build/qualification/ci-timeout-20260926/`. The updated workflow has not run remotely.
Current Host review execution is still unvalidated because free disk space remains
below the 5 GiB build floor; the staged Codex update cache was left intact.

2026-09-05: implemented recovery load retry and transactional in-memory updates,
retained the last known recovery inbox on read failure, and propagated final
audio synchronization errors with repeatable close retry. Added regression
tests. Standalone fault checks compiled the actual changed queue and writer
sources and passed corrupt-load preservation, repair, failed-write rollback,
restart, repeated sync failure, successful retry, and intact frame-count checks.
The queue fault harness substitutes only the store dependency; it does not
qualify GRDB or the application lifecycle. Package/app validation is still open.

Subsequent focused package validation used the actual HarcCore, HarcDomain,
HarcStore and local pinned GRDB source, and passed all **14 recovery tests**,
including corrupt loads, transient read failure, failed enqueue/discard,
repair, and restart. A dependency-free package with the exact writer source
and test file passed all **4 writer tests**. Logs and a dirty-tree source hash
manifest are retained under
`build/qualification/production-hardening-2026-09-05/`. These focused packages
avoid unrelated dependency graph checks; they do not replace the full package
or Xcode app gates.

Added the shared macOS test scheme and CI app/UI, iOS Simulator, direct/relay
lifecycle, and artifact-retention steps. `xcodegen generate` succeeded, both
YAML files parsed, and the generated scheme contains both macOS test bundles.
Remote CI execution and branch-protection enforcement remain open. CI now pins Xcode 26.6/build 17F113, verified against the
[official runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
Machine-readable skip enforcement remains follow-up work.

Corrected the obsolete standalone-only network inventory in SECURITY.md and
removed stale hardcoded release labels from README. Production deployment
read-back and exact-release privacy assessment remain open.

The active SwiftPM run uses two workers. Its dependency-status checks were
sampled reading checkout files; observed filenames advanced between probes,
so that run is making filesystem progress even before producing test output.
Do not restart it merely because a short observation window expires.

The main package run subsequently reached compilation. Its log is
`/private/tmp/harc-hardening-tests.log` (exec session 8692; process 87526 at the
last live inspection). The original Xcode build was sampled waiting in
NSFileCoordinator before compilation and was deliberately stopped. A diagnostic
project generated from the same project.yml now lives at
`/private/tmp/harc-app-validation/Harc.xcodeproj`, with source/package references
made absolute and SRCROOT pointing to this checkout. That app build uses two
workers and an automatic 5 GiB disk-floor stop; its log is
`/private/tmp/harc-hardening-macos-temporary-build.log` (exec session 25558;
process 90836 at the last inspection). Verify live handles before acting;
these process identifiers are observations, not durable ownership claims.

CoreDevice lists only Omega, currently unavailable. The user was asked which
named qualification phones and secondary Mac they can make available; no
physical gate has been closed.

### Recovery publication follow-through

The recovery queue now journals a reserved output URL before publication,
retains the cache source until output/Library/queue completion succeed, and
reuses the same output and row after an interrupted attempt. Publication checks
the existing output's PCM before reuse and preserves conflicting files. The
output and default metadata writer synchronize their file contents. Active
source ownership prevents concurrent recover, discard, or replacement. A
persisted recovery intent with no active owner is shown as retryable in the
inbox, including after a completion-write error in the current process.

Enqueue now deduplicates by the same durable source identity as scanning and
rejects rebinding an existing ID to a different source. Recovery also rejects
noncanonical PCM instead of relabeling it as 16 kHz mono audio.

**22 focused real-store tests passed**, including actual AVAudioFile output,
format rejection, failed intent persistence, restart after output creation,
failed completion persistence after database commit, conflict preservation,
concurrent ownership, and terminal-decision preservation. The earlier main
SwiftPM run passed its 18 selected writer/recovery tests before these additional
journal changes; it is not counted as validation of the later changes.

The temporary app build compiled AppDelegate, then exposed two temporary-project
path issues: the relative Info.plist and helper SRCROOT. Those temporary
references were corrected without changing product behavior. The third build
attempt is preparing embedded helpers; its log is
`/private/tmp/harc-hardening-macos-temporary-build-3.log` (exec session 70761).
No app-build pass is claimed yet. Changes are on `codex/production-hardening`.

### Capture drain and app compilation

The third temporary-project macOS build succeeded, including the app shell and
embedded helpers. It was an unsigned diagnostic compile before the following
Stop-drain edit; app-hosted tests, live UI and a fresh incremental app compile
remain open.

The recording pump previously cancelled the system consumer when microphone
iteration ended, losing accepted system buffers and the resampled FIFO tail.
It now awaits the system consumer, propagates watchdog/abort cancellation, and
writes the remaining system samples at their ordinary unity gain. Cancelling
the Stop watchdog now exits its sleep handler instead of cancelling the pump.
A deterministic fake delivers system audio at Stop after the microphone has
finished; its regression checks 12,000 saved frames and tail amplitude.
Current main-package focused validation is in progress in
`/private/tmp/harc-hardening-current-focused.log` (session 14314).

This addresses normal Stop draining only. Producer overflow, conversion and
source-stop evidence, durable integrity metadata and its live/Library/Host
rendering remain open. The capture result has no origin identity until Client
commit; originless integrity observations must survive cache recovery and be
bound there, without inventing an identity or blocking capture on Keychain.
Both the desktop committer and canonical Library projection currently supply
empty discontinuity arrays. Close those paths together with storage and UI;
adding a transient warning alone cannot close the capture-integrity gate.

Fresh main-package validation passed **34 tests in three suites**: writer,
recovery and RecordingSession, including the deterministic system tail test.
The log and source hashes are retained in `current-focused-tests.log` and
`current-focused-manifest.json` under the diagnostic qualification directory.
An incremental temporary-project app compile including the Stop fix is now
running with the same two-worker and disk-floor controls; its log is
`/private/tmp/harc-hardening-macos-temporary-build-4.log`.

The incremental app compile including the Stop-drain fix **passed**; retained
log: `macos-current-build.log`. This closes diagnostic compilation for current
changes, not signing, app-hosted tests or live UI. Full package regression is
now running with two workers, `--no-parallel`, xUnit output and an automatic
5 GiB free-space floor. Logs: `/private/tmp/harc-hardening-full-regression.log`
and `/private/tmp/harc-hardening-full-regression.xml`.

### Full regression and native PCM format safety

The first full regression completed with one failure among 1,599 Swift Testing
tests in 267 suites: `HarcVersion.fallbackVersion` was 0.14.11 while project.yml
is 0.14.12. XCTest ran 123 tests with four skips and no failures. Real-model and
pinned-TLS Swift Testing cases also skipped; exact skip messages are retained
in `full-regression-initial-result.json`, alongside `full-regression-initial.log`.
The requested xUnit file was not created; the log is the evidence. The fallback
is now corrected to 0.14.12 and requires verification.

Capture-boundary inspection found that the mixer force-unwrapped Float32
channel pointers despite system capture accepting Int16/interleaved audio.
The CoreMedia adapter also used raw copies without checking destination sizes.
A native-frame copy helper and CoreMedia's bounded PCM-copy API now replace
those assumptions. Tests cover planar/interleaved Int16, independent ownership,
incomplete storage, converter output and CoreMedia sample copying. These changes
postdate the first full regression and are not covered by it. Focused validation
is running in `/private/tmp/harc-pcm-boundaries.log` (session 37471).

PCM boundary and version validation now passed **21 tests in five suites**.
The tests verify interleaved and planar Int16 conversion, owned sample copies,
exact CoreMedia frames and rejection of genuinely truncated CoreMedia data.
An initial invalid test mutated AVAudioPCMBuffer byte-size metadata, which the
framework normalizes; it was replaced with a real truncated sample fixture.
Logs/source hashes are retained in `pcm-boundary-tests.log` and
`pcm-boundary-manifest.json`. Full regression is rerunning with `--skip-build`
against this freshly compiled, focused-tested binary; its log is
`/private/tmp/harc-hardening-full-regression-current.log`.

The full regression against the freshly compiled binary **passed**: 1,602
Swift Testing tests in 268 suites; XCTest ran 123 tests with four skips and
no failures. Real-model and pinned-TLS cases remain skipped and open. Exact
skip messages, changed-file hashes and base commit are retained in
`full-regression-current-result.json`, with `full-regression-current.log`.
The fifth temporary-project app build now compiles the PCM and version changes
with the two-worker/disk-floor controls; log:
`/private/tmp/harc-hardening-macos-temporary-build-5.log`.

The fifth macOS app build **passed**, including the PCM and fallback-version
changes; retained log: `macos-pcm-build.log`. Xcode's only dependency-resolution
changes were the expected Sparkle entry and origin hash; after the build ended,
those were verified against HEAD and restored. No pins were otherwise changed.

Next integrity work remains durable, originless capture-loss observations that
survive publication/recovery and bind to portable discontinuities at Client
commit, with live and Library warnings. App-hosted tests and live UI remain
open. Existing UI tests isolate the database but intentionally mutate shared
UserDefaults with a restore journal; inspect active recording state and isolate
the diagnostic app's preference domain before exercising them on this Mac.

### Durable capture-integrity implementation

Added bounded source/reason observations in HarcCore, with detection frame
offsets, first/last timestamps and saturated repetition counts. Capture
callbacks queue first-category metadata writes on one serial worker; Stop
flushes final counts before publication. Microphone/system producer streams
are bounded and report dropped buffers. The system mailbox and sample FIFO
report overflow; conversion/writer failures and the Stop watchdog record issues.
Mic engine reconfiguration requests a safe Stop; SCStream delegate failure
records system-source loss.

Standalone publication carries `.capture-issues.json` before relinquishing
the cache source. Recovery carries it before committing the Library and removes
source metadata only after completion. A new v19 migration stores integrity
and portable discontinuities on Recording rows; ordinary edits preserve them.
Client commits bind originless observations to their real identity, with empty
frame ranges marking detection rather than invented silence. Client mirror,
orphan recovery, older-local-recording send, Host commit/replay and Library
projection now propagate evidence. Host-originless local Library rows still
need a deliberate portable identity path before their local integrity report
can appear in a remote detail DTO; do not claim that gap is closed. Historical
rows with no recorded evidence are not thereby proved gap-free.

The menu status points to an independent Activity warning, and Library detail
has a persistent warning. This does not change microphone permission/readiness.
No new environment object was introduced. Actual UI exercise remains open.

57 focused tests passed including bounded FIFO/report behavior, capture-to-
publication evidence without transcripts, recovery metadata/row preservation,
corrupt-sidecar failure and Client replay conflict handling. The macOS app
build including these paths passed (`macos-integrity-build.log`). A new signed
discontinuity Host ingest/Library/replay test is now included in the current
focused run at `/private/tmp/harc-integrity-focused-3.log`. Full package,
app-hosted/UI tests and real source interruption/overflow exercises remain open.

The latest integrity focused run passed **58 tests in six suites**, including
the new signed-discontinuity Host ingest, Library projection and receipt replay
test. Retained evidence: `integrity-focused-tests.log` and
`integrity-source-manifest.json`. Full regression is now running against that
fresh binary at `/private/tmp/harc-hardening-full-regression-integrity.log`.
Actual warning UI/source-failure qualification, local-Host originless metadata
projection, parent-directory durability in publication and the broader physical
fault matrix remain open; file synchronization alone is not a power-loss drill.

Full regression for the integrity source **passed**: 1,610 Swift Testing tests
in 269 suites, plus 123 XCTest tests with four skips and no failures. Retained
log: `full-regression-integrity.log`; skip inventory is in
`integrity-source-manifest.json`. No current compiler or package-test failure
remains. This does not close live UI, app-hosted tests, real hardware, real-model
quality, publication power-loss behavior or originless local-Host projection.

Follow-up test hygiene: tests that return a CapturedRecording without using a
committer should clean its new integrity sidecar as well as the owned cache
WAV. The older Client-store fixture's fixed `/tmp/client-recovered.wav` should
become unique now that mirroring reads sibling integrity evidence. Neither
requires touching unrelated cached audio or existing user recordings.

### App-hosted validation and originless Library warnings

A temporary diagnostic bundle identity (`com.harc.Harc.ProductionValidation`)
isolates UI-test preferences; disposable data and HARC_UI_TESTING isolate its
Library and resident services. **45 app-hosted tests in 11 suites passed**.
The UI runner then failed to initialize automation mode. Computer-use
observation confirmed the Mac is locked and automatic unlock failed. The user
has been asked to unlock it. The xcodebuild invocation ended naturally with
exit 65 before an attempted interrupt; no interrupt signal was sent.
`AppAndUI.xcresult` remains at `/private/tmp/harc-app-validation/`; summary/log
are retained as `macos-app-ui-attempt-summary.json` and
`macos-app-ui-attempt.log`. This is not a UI pass or a product assertion failure.

Added a UI test that seeds a capture issue, checks the Library warning, relaunches
without the seeding flag and checks the persisted warning again, with a retained
screenshot on success. It has not run yet because the desktop is locked.

The originless-Host gap is now represented explicitly instead of manufacturing
an identity: LibraryRecordingDetailV1 has additive bool field 8,
`capture_needs_review`. Absence/false is not a completeness attestation. Detailed
discontinuities retain their origin validation. Domain JSON decoding accepts
legacy absence, Host projection sets the flag from stored integrity, and the
iPhone remote detail displays a capture-quality warning. **58 focused tests
passed**, including originless projection, protocol conversion and legacy JSON
compatibility (`originless-integrity-tests.log`). Full/current platform validation
is still required. The current iOS Simulator build is running with two workers
and a disk guard: `/private/tmp/harc-hardening-ios-simulator-build.log`.

The shared Harc scheme now sets HARC_UI_TESTING for its Test action (generated
and checked, using XcodeGen's documented test environmentVariables support:
https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md). This avoids
ordinary resident startup in app-hosted tests. The separate diagnostic identity
is still necessary to isolate local UI-test preferences. Test-owned capture
sidecars now follow cache-WAV teardown; the Client-store fixture path is unique.

### Publication collision and protocol inventory follow-through

The iOS Simulator build passed with the additive capture warning flag; retained
log: `ios-simulator-integrity-build.log`. The next full package run executed
1,611 Swift Testing tests and found one issue: the deliberate schema addition
needed its reviewed checksum refreshed. The failing run is retained as
`full-regression-originless-before-inventory-refresh.log`. Added an exact field-8
wire fixture and legacy-absence fixture, documented the advisory compatibility
decision, and refreshed only the library schema checksum. The schema guard passes
(7 schemas, 6 services, 27 RPCs, 29 enums). Current tests are rebuilding.

Publication also had authority to replace an existing destination after filename
selection. Removed that replacement branch and added a regression requiring both
the existing master and recoverable source to survive a collision. This closes
the explicit overwrite behavior; it does not establish cross-volume or power-loss
durability. Current focused log: `/private/tmp/harc-publication-protocol-focused.log`.

The publication/protocol focused run passed **32 tests in four suites**. The
subsequent full package regression passed **1,613 Swift Testing tests in 269
suites**, plus **123 XCTest tests with four skips and zero failures**. Logs:
`publication-protocol-focused.log` and `full-regression-publication-protocol.log`.
Real-model and separately scripted lifecycle tests remain explicitly skipped,
not qualified. The current macOS app build is running at
`/private/tmp/harc-hardening-macos-publication-build.log` (supervised two-worker
build with the 5 GiB disk floor). UI remains blocked by the locked desktop.

The app build failed linking harc-mcp: a stale HarcHostTransport release object
referenced the former LibraryRecordingDetail initializer. Inspection also found
a real projection omission: selecting optional detail fields dropped the new
review advisory. Corrected the projection and added a test across warning
true/false and empty/transcript selections, preserving originless identity.
Focused tests are running at `/private/tmp/harc-library-projection-focused.log`.
The failed build is retained as `macos-publication-build-failed.log`; a fresh app
build and updated full regression remain required for this additional correction.

The transport projection regression passed both parameter cases. The updated
full package regression passed **1,614 Swift Testing tests in 270 suites**, plus
**123 XCTest tests with four skips and zero failures**. Evidence:
`library-projection-focused.log`, `full-regression-library-projection.log`, and
`library-projection-source-manifest.json`. Current app/helper build log:
`/private/tmp/harc-hardening-macos-projection-build.log`.

The corrected macOS app build **passed**, including both embedded helpers.
Retained log: `macos-library-projection-build.log`. Updated manifest records the
current full regression and app build. Restored Package.resolved to exact HEAD
bytes only after verifying its differences were the expected Sparkle pin and
originHash churn and all build processes had ended.

Next work remains live UI (Mac unlock requested), current app-hosted/Simulator
qualification, publication directory durability and fault drills, direct/relay
lifecycle, real-model/endurance measurements, and physical/release qualification.
No release, install, commit, or publication has been performed. The overall goal
is active; this is a software validation checkpoint, not production readiness.

### Current local transport qualification

Both prescribed lifecycle wrappers passed on the current source: direct pinned
gRPC TLS and encrypted local relay emulator, each with the actual lifecycle test
executed (not skipped). The sequence covers pair, authorize, Host revoke, reject
old sessions, local forget, same-key re-pair and authorize. Relay uses installed
Wrangler 4.120.0, disposable local Durable Object state and the freshly built test
binary. Retained logs: `pairing-direct-current.log`, `pairing-relay-current.log`;
provenance: `pairing-current-manifest.json`. The desktop tool still reports locked.
Real phones, secondary Mac, two external networks and production relay read-back
remain open. No deployment or user trust-state mutation was performed.

Real-model inspection found cached Parakeet v2 but an incomplete Gemma directory
(config/template only, no model weights/tokenizer). The existing real STT short
fixture is running with timing/RSS reporting and a 5 GiB disk guard at
`/private/tmp/harc-hardening-real-stt.log`. Its default 0.75 WER threshold is only
a diagnostic baseline; it does not qualify the required diverse/long-form corpus.

The first real STT diagnostic loaded cached Parakeet v2 without downloading and
produced `Hello. This is a test recording for HARC.` It failed because the test
reference was only `this is a test` (WER 1.0 against that truncated reference).
The full sentence is independently recorded in the existing dictation fixture
evidence (`docs/dictation-plan.md`). Corrected the reference and tightened the
default WER limit from 0.75 to 0.125 (one error in eight words); effective
reference, output, threshold, WER and timing-entry count are now printed.
The initial run took 19.486 seconds in XCTest, with 29.43 seconds wrapper wall
time and 1,302,609,920 bytes maximum RSS from time(1). It also emitted an E5RT
zero-shape warning after the failed assertion; this remains an observation to
investigate, not a closed quality gate. Retained failure log:
`real-stt-original-reference-failed.log`. Corrected tests are rebuilding.

The corrected short-fixture real STT check passed with **WER 0.0**, maximum
allowed 0.125, and 18 timing entries. XCTest took 17.410 seconds including model
load; wrapper wall time was 20.69 seconds and maximum RSS was 578,912,256 bytes.
The Core ML E5RT zero-shape warning recurred despite the pass and remains open.
`real-stt-diagnostic-manifest.json` retains fixture and local model-file hashes,
effective reference/output/threshold, metrics and limitations. Logs:
`real-stt-corrected-reference.log` and `quality-reference-focused.log`. This is
a 2.97-second diagnostic, not diverse-corpus, diarization or endurance acceptance.
The optional fixture-history Git read was stopped by SIGINT to its verified
owned process after it remained pending; current-source fixture evidence was
already available. No repository data was changed by that cancellation.

After the test-only correction, the full package regression passed again:
**1,614 Swift Testing tests in 270 suites**, plus **123 XCTest tests with four
skips and no failures** (`full-regression-quality-reference.log`). The explicit
real STT run above is separate from the default suite's integration skips. No
application source changed in this qualification turn.

### Recovery file and directory barriers

Added DurableFileIO for atomic metadata replacement, parent-directory fsync,
and Apple F_FULLFSYNC after file/directory synchronization. New directory
components synchronize their parents during creation. Capture-issue metadata
and the default recovery-queue writer use the helper. Recovered WAV publication
must complete file/parent barriers before Library insertion and source cleanup.
Errors propagate; unsupported storage is not silently treated as synchronized.

**29 tests in three suites passed**, including real nested metadata replacement
and an injected output-barrier failure: source bytes remain intact, the Library
row is absent, and retry reuses the reserved output before removing the source.
Evidence: `durability-focused.log`, `durability-source-manifest.json`.
Apple's distinction between fsync and drive-cache flushing informed the barrier:
https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html

This does not close physical power-loss behavior, parent-creation crash/retry
races, cross-volume standalone publication, or database durability. RecordingStore
currently uses the GRDB DatabaseQueue default journal configuration; it does not
explicitly configure fullfsync/extra synchronization. That boundary requires
separate validation before an end-to-end power-loss claim. Full regression and
macOS/iOS compilation for the shared helper are now being checked.

The durability full regression passed **1,617 Swift Testing tests in 271 suites**
and **123 XCTest tests with four skips and zero failures**. The macOS application
and both embedded helpers built successfully. Retained logs:
`full-regression-durability.log` and `macos-durability-build.log`. iOS Simulator
compilation is in progress at `/private/tmp/harc-hardening-ios-durability-build.log`.
Repository corpus inventory still contains only `short-speech.wav`; the user
was asked for a consented, verified real-audio corpus. Synthetic stress tests can
advance software evidence but cannot replace real-meeting accuracy qualification.

The iOS Simulator app build also passed (`ios-durability-build.log`). The shared
barrier helper therefore compiles on both platforms. No physical power-loss or
mobile runtime gate is closed. Expected Xcode-only Package.resolved churn was
checked and restored after both supervised builds ended. The next durability
work includes explicit database commit policy, directory-creation retry/crash
behavior, and recoverable cross-volume standalone publication.

### Persistent database commit policy

File-backed RecordingStore and both on-disk HarcHostStore constructors now set
`synchronous=EXTRA` and `fullfsync=ON` on each connection. Client WAL stores keep
FULL after GRDB's WAL setup and now set fullfsync ON as well. In-memory stores
retain their existing behavior. This protects the commit boundary used by
Library publication, Host receipts/security journals, and Client outbox state.
SQLite documents EXTRA's rollback-journal directory synchronization and FULL's
equivalent WAL behavior here: https://www.sqlite.org/pragma.html#pragma_synchronous
The fullfsync setting requests the supported Apple synchronization method; its
read-back does not prove what a device actually persists during power loss.

**51 tests in four suites passed**, including policy read-back on real file-backed
connections, Library/client reopen, the deferred-serving Host constructor and
all five security-journal failure boundaries. Retained evidence:
`database-durability-focused.log` and `database-durability-source-manifest.json`.
The full package regression and macOS/iOS app builds are being checked.

The database-policy full regression passed **1,618 Swift Testing tests in 271
suites**, plus **123 XCTest tests with four skips and zero failures**. Both the
macOS app/helper build and iOS Simulator app build passed. Evidence:
`full-regression-database-durability.log`, `macos-database-build.log`,
`ios-database-build.log`. The desktop remains locked. A separate current run
of app-hosted tests (without UI selectors) is running in the isolated diagnostic
bundle: `/private/tmp/harc-hardening-macos-app-hosted-database-tests.log`, result
bundle `/private/tmp/harc-app-validation/AppHostedDatabase.xcresult`.

The separate current app-hosted run **passed all 45 tests**, with no skips or
failures (48 parameter-expanded executions). The result bundle is retained at
`/private/tmp/harc-app-validation/AppHostedDatabase.xcresult`; copied summary/log:
`app-hosted-database-summary.json`, `app-hosted-database-tests.log`. The diagnostic
bundle identity and HARC_UI_TESTING root isolate test state. No UI automation was
selected, so Settings/recording UI qualification remains open while the Mac is
locked. Expected Xcode Package.resolved churn was verified and restored after
the test process ended. The database policy milestone now has focused, full
package, both platform compile, and current macOS app-hosted evidence. Physical
power-loss, directory-creation failure/retry, cross-volume publication, endurance,
real-model corpus, mobile runtime and exact-release gates remain unfinished.

### Journaled recording publication across volumes

Standalone recording and media import publication now persist an immutable
`.wav.publication.json` intent before exposing a destination file. The intent
binds the original cache path, destination, byte count and SHA-256. Publication
copies through a journal-owned staging file on the destination volume, verifies
and synchronizes it, then uses an exclusive rename. Retries preserve the chosen
destination and refuse conflicting bytes. The journal remains until the Library
row exists; startup recovery can find it even after the cache WAV was removed.
Library-confirmed cleanup runs off the main actor.

Fault tests cover partial staging, destination synchronization failure, conflicting
contents, corrupt intent, and recovery before/after source removal with/without
a pre-existing queue entry. The first recovery run exposed filesystem-dependent
URL normalization: creating a destination under /private/tmp changed its
standardizedFileURL representation to /tmp. Lexical normalization now preserves
the persisted Library key. The original failure log is retained.

**62 focused tests in seven suites passed.** The full package regression passed
**1,624 Swift Testing tests in 272 suites**, plus **123 XCTest tests with four
skips and zero failures**. The opt-in cross-volume test was separately executed
on a disposable mounted APFS image: distinct filesystem device IDs, exact
2,000,000-byte publication, retry, and journal cleanup passed. The wrapper
verified the actual test ran, detached its volume, and removed its image. This
is a file-publication diagnostic, not an audio-codec or physical power-loss test.

`scripts/qualify-publication-cross-volume.sh` records source hashes and mount
evidence and enforces the disk floor. CI now includes this test after package
compilation; remote CI has not been executed. Retained evidence:
`publication-journal-focused.log`, `publication-journal-normalization-failure.log`,
`full-regression-publication-journal.log`, and `publication-cross-volume/`.
Both app platform builds are being checked. Real removable/network filesystem
behavior, forced interruption/power loss, ENOSPC and directory-creation retry
remain open. All evidence is diagnostic against the dirty working tree.

Both app builds passed: macOS app plus helpers, and iOS Simulator app. Logs:
`macos-publication-journal-build.log`, `ios-publication-journal-build.log`.
The quiet macOS helper phase completed successfully; a brief process sample
was retained locally and no build was restarted. Expected Sparkle-only pin and
originHash churn was verified and restored after both builds ended.
`git diff --check` and wrapper shell syntax passed. Source hashes are retained in
`publication-journal-source-manifest.json`. Earlier app-hosted tests passed before
this journal change; current evidence adds app compilation, not another UI or
app-hosted execution claim. The broader production goal remains active.

### Bounded-memory interrupted recording recovery

Replaced whole-file WAV loading, PCM extraction, comparison and output assembly
with RIFF metadata inspection and 1 MiB transfers. Canonical output is staged in
the destination directory, synchronized and published with an exclusive rename.
Odd-byte incomplete PCM is rejected consistently, including destination reuse.
The existing source remains protected until the Library/queue commit.

Initial focused tests passed (28 tests); the expanded suite included a separate
opt-in 512 MiB sparse PCM fixture (16,777.216 seconds of 16 kHz mono PCM). The
large diagnostic passed copy and retry, but wrapper peak RSS was 1,112,211,456
bytes. This was not accepted as bounded-memory evidence. Per-block autorelease
pools were then added to comparison, output copying and publication hashing.
The updated test reports its own process RSS before/after as well. Current
validation is in progress; the earlier functional logs are retained as
`streaming-recovery-large-before-pools.log` and
`streaming-recovery-full-before-pools.log`. The latter passed 1,627 Swift Testing
tests before the autorelease correction and is not final-source evidence.

The corrected large-file diagnostic passed in **2.222 seconds** (copy plus
matching retry). Its own process peak RSS increased from **90,226,688** to
**101,335,040 bytes**; wrapper maximum RSS was **158,121,984 bytes**, down from
1,112,211,456 before per-block pool draining. The 512 MiB fixture was generated
without a full-size Data allocation and checked for exact output length, a
nonzero final sample, and a single Library row. Multi-block content equality
and a final-block conflict are checked separately in the focused suite. This
qualifies the tested recovery path's memory behavior, not real multi-hour
capture or inference endurance.

Final focused run: **34 tests in two suites passed**, with the large-file and
cross-volume opt-ins skipped there and the large-file test separately executed.
Final full regression: **1,627 Swift Testing tests in 272 suites passed**;
XCTest results and both platform builds are recorded below when terminal.
Evidence: `streaming-recovery-focused.log`, `streaming-recovery-large.log`,
`streaming-recovery-full.log`. AGENTS.md records the opt-in diagnostic and its
6 GiB starting headroom. An automatic review rejected an earlier combined test
rewrite command; no edit occurred from it. An explicit additive patch preserved
all existing tests and was accepted. Nothing remains blocked by that rejection.

Final XCTest: **123 tests, four skips, zero failures**. Both **macOS app/helpers**
and **iOS Simulator app** compiled successfully. Logs:
`macos-streaming-recovery-build.log`, `ios-streaming-recovery-build.log`.
Expected Xcode-only Sparkle/originHash churn was checked and restored after
both build processes ended. `git diff --check` passed. Relevant source and
diagnostic project hashes are retained in `streaming-recovery-source-manifest.json`.
No live UI, app-hosted rerun, physical device, power-loss or release qualification
is implied by these compile checks. The complete production goal remains active.

### Real publication process-interruption qualification

`./scripts/qualify-publication-faults.py` now compiles the three actual Core
publication/integrity/durability sources with a small disposable driver. The
driver pauses after intent preparation, after destination rename before its
final barrier, and after publication/source removal. The supervisor verifies
SIGSTOP on its exact child PID, sends SIGKILL, and launches two independent
restarts against the resulting files. It does not kill any Harc app process or
read user recordings.

**All three boundaries passed, with two restarts each.** Each case retained the
exact 8,388,608-byte payload and identical immutable journal. Source/destination
existence at each interruption was asserted, and no staging file remained after
restart. The journal deliberately remains because this driver does not create a
Library row. Existing queue tests cover that separate commit integration.
This is genuine process termination, not physical power-loss evidence. The
payload is deterministic file content, not a codec or audio-quality fixture.

Evidence: `publication-process-interruption/manifest.json`, compiler/toolchain
logs, per-boundary child/restart logs and worktree inventory. The manifest binds
source and driver hashes. Added a CI step after mounted-volume qualification and
documented the command in AGENTS.md. Python syntax and `git diff --check` passed.
Remote CI has not run. No production source changed in this milestone, so the
preceding full regression/platform builds remain applicable to production code;
the new diagnostic compiled and executed that code independently. Real ENOSPC,
destination disappearance, directory retry, physical power loss and broader
production gates remain open.

### Actual disk exhaustion and detached destination volume

Added `scripts/qualify-publication-storage.py`, which compiles the actual Core
publication sources, mounts an owned 128 MiB APFS image, fills only that image
until ENOSPC, and attempts a 32 MiB publication with insufficient free space.
The cached master and immutable intent survived the actual filesystem failure;
retry after removing the owned filler passed with exact bytes.

The initial detach test **failed**: after unmounting the destination image,
publication recreated its path on the host filesystem and consumed the cache
master. This evidence is retained in `publication-storage-initial/`.

Publication journal version 2 now binds the destination volume UUID before
directory creation, and checks it before publication and before source cleanup.
Filesystems without UUIDs use a mounted-device identifier and fail closed if it
changes. Unbound pre-release version 1 diagnostic intents are preserved and
rejected; their original volume cannot be safely inferred after disappearance.
They were not a shipped release format. The focused suite verifies that an
unbound intent and its source are not overwritten or silently rebound.

**ENOSPC, detachment refusal and original-volume reattachment/retry all passed**
against the updated code. `publication-storage-final/` contains the exact-source
manifest, compile log, mount plists, error chain and successful retry logs.
The image was detached and its owned temporary directory removed. This is an
APFS image diagnostic, not removable hardware or physical power-loss evidence.
Added the storage diagnostic to CI and AGENTS.md; remote CI has not run.

**46 focused tests in four suites passed.** Full regression and platform builds
are pending below. One related gap remains: destination identity needs binding
at capture setup, before the publication journal exists. Standalone/import
sidecar ordering also needs to honor that binding. This milestone protects the
journaled phase and does not close the entire destination-loss gate.

Final volume-bound validation passed: **1,628 Swift Testing tests in 272 suites**,
**123 XCTest tests with four skips and zero failures**, and **macOS app/helpers
plus iOS Simulator builds**. The three real SIGKILL boundaries also passed again
with two independent restarts each (`publication-process-volume-bound/`).
Logs: `volume-bound-focused.log`, `volume-bound-full.log`,
`macos-volume-bound-build.log`, `ios-volume-bound-build.log`. Python syntax and
`git diff --check` passed. Expected Xcode-only lockfile churn was inspected and
restored after both builds ended. `volume-bound-source-manifest.json` retains
source hashes. No current live UI or physical-device evidence was added.
Capture-setup destination binding and sidecar ordering remain the next concrete
source work; the complete production goal remains active.

### Setup-time destination identity and sidecar ordering

RecordingDestination now captures the volume identity when constructed for a
recording or import. Its path selection and journal preparation check that
frozen identity. RecordingPublication.prepare accepts the expected identity
and verifies it before hashing and again afterward; it no longer infers a new
volume after a long finalization if the caller already selected one.
Standalone publication prepares and validates its journal before carrying
capture-integrity sidecars. Journaled recovery validates before sidecar carry;
standalone/import transcript siblings also validate the volume before writing.

The real APFS storage diagnostic now freezes a setup identity, detaches before
any publication journal exists, and attempts publication. **It refused, retained
the exact cache master and created no journal.** Reattaching the original volume
then allowed exact-byte retry. ENOSPC and post-journal detach/reattach checks also
passed again. Evidence: `publication-setup-binding/`. The helper persists its
setup identity only to carry it between diagnostic subprocesses; production
RecordingDestination currently holds that identity in memory.

**Remaining gap:** persist the setup binding beside an in-progress capture and
consume it on startup recovery. A crash before finalization must not discard the
frozen destination identity. This is required before declaring the overall
destination-loss/relaunch gate complete. Focused/full/platform validation of
the current changes is recorded below when terminal.

Setup-binding validation passed: **56 focused tests in six suites**, **1,628
Swift Testing tests in 272 suites**, **123 XCTest tests with four skips and
zero failures**, and both **macOS app/helpers** and **iOS Simulator app builds**.
Logs: `setup-binding-focused.log`, `setup-binding-full.log`,
`macos-setup-binding-build.log`, `ios-setup-binding-build.log`.
`git diff --check` passed; expected Sparkle/originHash churn was verified and
restored after terminal builds. Removed only the two generated diagnostic
Python bytecode files previously created by syntax checking. Source hashes are
retained in `setup-binding-source-manifest.json`. No live UI or device evidence
was added. Durable pre-publication capture binding remains the next source
change; the complete production goal is active.

### Durable pre-publication capture destination binding

Added local `CaptureDestinationBinding` metadata at `.wav.destination.json`.
Standalone committers persist it through a new capture-preparation hook before
RecordingSession creates its WAV; imports persist it before conversion. Client
committers keep their existing authority path through the default no-op hook.
The binding contains the original root and volume identity, refuses replacement,
and uses explicit file/directory synchronization. It is not a network DTO.

A recreated standalone committer restores the saved binding. Startup scanning
uses the saved destination root, and recovery validates the root/volume before
creating output, carrying metadata, and cleaning up. Publication also consumes
a saved binding at its Core boundary, protecting callers that do not explicitly
pass an expected identity. Cancellation/import abort cleans its own binding;
normal cleanup retains it until Library/queue commitment. Corrupt metadata is
preserved and stops the affected recovery instead of inferring new authority.

**64 focused tests in six suites passed**, including restart after changed
preferences, recreated committer behavior, corrupt-binding preservation and an
actual RecordingSession callback proving the binding exists before WAV creation.
The real APFS image diagnostic now uses the production persisted binding type
across subprocesses. ENOSPC, post-journal and pre-journal detachment refusal, and
reattachment/retry all passed (`publication-durable-binding/`). This closes the
previous in-memory-only binding gap at the software/test scope. It is not live
capture endurance or physical-device/power-loss qualification. Full regression
and platform build results are recorded below when terminal.

Final durable-binding validation passed: **1,631 Swift Testing tests in 272
suites**, **123 XCTest tests with four skips and zero failures**, **macOS
app/helpers** and **iOS Simulator app builds**. The three existing real SIGKILL
boundaries passed again (`publication-process-durable-binding/`); the storage
diagnostic independently reloads the saved pre-publication binding in new
processes. No power-loss or live UI evidence is implied.

Logs: `durable-binding-focused.log`, `durable-binding-full.log`,
`macos-durable-binding-build.log`, `ios-durable-binding-build.log`.
`git diff --check` passed and expected Xcode-only Package.resolved churn was
checked/restored after all builds ended. Exact relevant source hashes are in
`durable-binding-source-manifest.json`. The capture-setup persistence gap is
implemented and software-validated. Remaining production gates include
directory-creation retry/failure, endurance/corpus, live UI, named physical
devices and networks, CI enforcement and exact release artifacts. The full
production goal remains active.

### Directory creation retry barrier

Rechecked the desktop through CUA: it remains locked, so live UI qualification
is unavailable. Continued independent filesystem work.

DurableFileIO.createDirectory previously returned immediately for an existing
directory. If mkdir succeeded but parent synchronization failed, retry could
therefore report success without repeating the failed barrier. Existing
directories now require that parent synchronization as well. Concurrent-create
EEXIST handling accepts only an actual directory and still requires the barrier.
No synchronization failure is silently downgraded. This requires the parent
directory to permit the barrier, matching the intended fail-closed behavior.

**56 focused tests in five suites passed.** Fault tests force two consecutive
parent barrier failures, verify that no descendant is created, and then permit
progress only after a successful retry. A separate existing-leaf test confirms
that existence alone cannot bypass a barrier failure. The actual APFS image
ENOSPC and pre/post-journal detach/reattach tests passed again against the changed
helper (`publication-directory-retry/`). Full regression/platform results follow
when terminal. Physical power loss remains unqualified.

Final directory-retry validation passed: **1,633 Swift Testing tests in 272
suites**, **123 XCTest tests with four skips and zero failures**, **macOS
app/helpers** and **iOS Simulator app builds**. Logs:
`directory-retry-focused.log`, `directory-retry-full.log`,
`macos-directory-retry-build.log`, `ios-directory-retry-build.log`.
`git diff --check` passed. Expected Xcode-only Sparkle/originHash churn was
verified and restored after both builds ended. Relevant source hashes are
retained in `directory-retry-source-manifest.json`. The known directory retry
barrier bypass is fixed and software-validated; physical storage/power-loss,
endurance/corpus, live UI, device/network and release gates remain open.
The complete production goal remains active.

### Repeatable local synthetic STT baseline

Added a local `say`/ffmpeg fixture generator and opt-in corpus evaluation in
RealModelGoldenSampleTests. It validates fixture hashes and thresholds before
inference, records per-case results/timings/RTF, checks final-phrase completeness
and timing bounds, and saves results after every case. Generation uses installed
Samantha, Daniel and Karen voices; no user audio is recorded or uploaded.

Five unique files contain approximately 109 seconds of synthetic audio: two
clean voices, a quiet voice (-26 dB amplitude), deterministic nominal 10 dB SNR
noise, and a 48.7-second fixture with five/three-second silent gaps. The longer
file is evaluated twice with VAD on/off, making six evaluation cases. Thresholds
were set before inference (0.12 clean, 0.20 quiet/noisy, 0.15 longer fixture).

**All six cases passed their prespecified thresholds, timing and final-phrase
checks.** The four short cases had WER 0. The longer VAD-on case substituted
`research` for the first `restart` (1/116 words, WER 0.00862069); the exact same
audio with VAD off had WER 0. The substitution reproduced on the paired run.
This is a VAD-associated quality issue requiring investigation, not proof of
a specific trimming defect yet. Current segmentation defaults use 0.1-second
padding and a 14-second maximum speech segment. No production VAD tuning was
changed merely to fit this synthetic example.

The E5RT `slice_by_index: zero shape error` warning recurred despite successful
output. It remains unresolved. Fresh-process model-load measurements differed
(19.038 s initially, 0.509 s on repeat), so these are cache-state-dependent
diagnostics, not first-install or cold-capture latency claims. Initial wrapper
maximum RSS was 579,403,776 bytes; the paired repeat was 171,016,192 bytes.

Evidence under `synthetic-stt/`: corpus/audio hashes, initial and paired results,
raw logs, local voice/OS/ffmpeg inventory, 33 cached model-file hashes (verified
unchanged after inference), source manifest and full regression. Source selects
Parakeet v2 and Silero VAD v6.2.1. **Default full regression passed 1,633 Swift
Testing tests in 272 suites and 124 XCTest tests with five skips, zero failures.**
The real corpus XCTest separately executed with zero failures; its skip in the
ordinary suite is not being counted as real-model qualification.

Only test/tool/documentation code changed in this milestone; production source
retains the preceding successful macOS/iOS compile evidence. Python syntax and
`git diff --check` passed. No new platform build or live UI run is claimed.
Consented real recordings, speaker/summary quality, multi-hour end-to-end
performance, physical devices/networks, CI enforcement and sealed release
evidence remain open. The full production goal remains active.

### Core ML warning isolated to preprocessor model loading

Added a standalone, read-only CoreMLLoadProbe. It loads one cached model with
the configured compute policy, flushes markers around load, and reports input
shapes. It never predicts or reads audio. The Parakeet v2 preprocessor reproduced
the zero-shape warning during CPU-only load and then returned successfully.
Encoder, Decoder, JointDecision and Silero v6.2.1 loaded successfully without
that warning under CPU/Neural Engine policy. The preprocessor reports default
input shapes audio_length=[1], audio_signal=[1,1]. This is an observation, not
a confirmed root cause.

The reproduction separates the warning from Harc capture, VAD and transcription
inputs. It does not prove all-input harmlessness or identify any runtime fallback.
No production compute policy, dependency, or model artifact was changed. The
warning remains unresolved, now with a model/runtime-level reproduction.
`docs/evidence/2026-09-05-coreml-preprocessor-warning.md` records the command,
matrix, limits and next investigation. Per-model logs plus exact probe/model
hashes are in `coreml-load-probe/`. No external issue/message was posted.

The probe compiled and all five model loads returned success; `git diff --check`
passed. Only a diagnostic and documentation changed, so no additional package
or app rebuild was needed and none is claimed. Existing production-source
validation remains applicable. Broader production gates and the active goal
remain open.

### VAD short-gap speech preservation

A real VAD boundary probe isolated two omitted 56 ms intervals in the synthetic
long fixture: 13.668–13.724 s and 47.460–47.516 s. Their normalized RMS levels
were 0.1922 and 0.1093, respectively. Independently reconstructing the default
compact buffer matched the production samples byte-for-byte. Restoring only
these short gaps changed the observed WER from 1/116 to 0. Increasing padding
also passed but retained more audio; no default segmentation padding or maximum
speech duration was changed.

VoicedStitcher now offers bounded short-gap preservation, selected at 100 ms by
Transcriber. It retains the original intervening samples and merges their
region mapping; longer gaps remain trimmed. The raw helper default remains
unchanged for diagnostics. Unit tests check exact sample identity, preserved-gap
and later-region timestamps, and the threshold boundary. **36 focused tests in
eight suites passed.**

The original regression fixture was tightened to WER 0 before evaluating the
fix. Two additional longer quiet/noisy cases reuse the generated text with a
four-second pause and VAD enabled; they retain their 0.20 accuracy threshold.
**All eight corpus cases passed** timing and final-phrase checks. Original
VAD-on and VAD-off cases both had WER 0. The longer quiet case had WER 0; the
longer noisy case had one substitution out of 88 words (0.011364). Other short
cases remained WER 0. This is broader synthetic scenario coverage, not an
independent real-world language/speaker corpus. The Core ML load warning still
appeared and is separately isolated to the preprocessor artifact.

Evidence under `synthetic-stt/`: raw boundary JSON/f32 buffers, variant corpus
and outputs in `vad-probe/`, pre-fix corpus/results/generator snapshots, and
`vad-boundaries-run.log`, `vad-variants-run.log`, `vad-gap-corpus.log`,
`vad-gap-focused.log`. Full regression and platform validation follow when
terminal. Broader real recording, speaker/summary and endurance gates stay open.

Final VAD-gap validation passed: **1,635 Swift Testing tests in 272 suites**,
**125 XCTest tests with six skips and zero failures**, and **macOS app/helpers
plus iOS Simulator project builds**. Real-model corpus evaluation separately
executed and passed all eight cases. Logs: `vad-gap-full.log`,
`macos-vad-gap-build.log`, `ios-vad-gap-build.log`. Expected Xcode-only lockfile
churn was verified/restored after terminal builds; `git diff --check` passed.
`vad-gap-source-manifest.json` records relevant current source hashes.
The known short-gap loss is fixed and software/model-diagnostic validated.
Real-world corpus, speaker/summary accuracy, multi-hour capture, named devices
and networks, live UI, CI enforcement and sealed release gates remain open.
The complete production goal remains active.

### Capture startup dependency and metric audit

Source inspection confirms AppDelegate schedules daemon startup in a separate
Task and does not await it before RecordingSession.start. ChunkedTranscriber.start
only configures the WAV chunker and schedules detached pumps; it does not load
models or await inference. Capture still waits for permissions, destination
binding persistence, pre-roll handling and audio-source startup. Those costs
require runtime measurement; this source audit does not establish a latency SLA.

DaemonLauncher.ensureRunning accepts a successful status response regardless of
modelLoaded, and RequestHandler can return status with modelLoaded false. The
previous inference_ready_ms label overstated that evidence. It is now named
daemon_responsive_ms; actual model-ready and first-inference timings remain open.
Stale comments describing a blocking daemon launch were also corrected.

The macOS app/helpers build passed with two workers and the 5 GiB disk guard.
The initial restricted build failed accessing Swift manifest caches; the normal
cache-access run succeeded. Expected Sparkle-only lockfile churn was verified
and restored after completion. Evidence: macos-startup-audit-build.log and
startup-audit-source-manifest.json. No new live capture or inference latency
measurement is claimed; the broader production goal remains open.

### Daemon startup ownership and cancellation

The launcher audit found actor reentrancy could spawn a second child while an
existing child was still starting: the old path only checked the socket. Its
polling loop also swallowed cancellation from Task.sleep, turning cancelled
startup into continued polling until the deadline. AppDelegate has one shared
launcher, so concurrent feature/startup requests can reach this path.

DaemonLauncher now reuses its running child before spawning, checks cancellation
and a stop generation after status awaits, uses cancellable polling and a
monotonic deadline, and fails when the owned child exits before readiness.
Cancelling one waiter leaves the shared daemon available to other callers;
explicit Stop invalidates all outstanding startup attempts. In-flight IPC still
has the client's existing socket timeout; this is not an immediate-cancellation
claim for a stalled socket operation. An optional log URL lets tests isolate
all logs from the real app. The parent closes its launch log handle after spawn.

Added disposable-process tests for concurrent launch ownership, cancelled and
stopped waiters, cancellation before spawn, early exit and retry. These use a
fake shell executable and sleep child, with no model or real daemon startup.

Validation passed: three new lifecycle tests, then nine related launcher/IPC
tests across two suites, and the macOS app/helpers build. The new tests ran
against the actual HarcClient target; no real-model readiness or capture
latency claim follows from fake-process tests. Logs are retained as
harc-daemon-launcher-focused.log, harc-daemon-client-regression.log and
harc-hardening-macos-daemon-lifecycle-build.log, with source hashes in
daemon-lifecycle-source-manifest.json. Expected lockfile churn was verified
and restored after terminal builds. Full production qualification remains open.

### Recording warmup completion ownership

AppDelegate previously retained a bare warmup Task. A late non-cancellation
error could overwrite readiness after reset or clear a newer task's handle.
RecordingWarmupController now owns an identity for each attempt, suppresses
completion from cancelled/replaced work independently of its returned error,
and clears ownership before delivering the current completion. AppDelegate
uses it for daemon warmup and cancels it on failed start and resetUI. Capture
still does not await warmup, and cancellation does not shut down the shared
speech daemon.

Added controlled-continuation tests that resume old work after replacement or
cancellation and verify callback delivery and successor ownership, plus current
failure delivery. These avoid timing sleeps and do not require a real daemon.

All three controller tests passed (including two parameterized cancellation
cases). The warmup failure text also no longer asserts that recording is safe
before audio capture has necessarily begun. macOS integration build follows.

The macOS app/helpers build passed with two workers and the disk guard.
Expected Sparkle-only lockfile churn was verified and restored after completion.
Evidence: harc-recording-warmup-focused.log,
harc-hardening-macos-recording-warmup-build.log and
recording-warmup-source-manifest.json. No live UI exercise or release
qualification is claimed; the full production goal remains open.

### Xcode CI execution gate

Added a fail-closed xcresult JSON checker to the macOS and iOS CI jobs. It
requires an explicitly passing summary, positive matching summary/tree counts,
zero skipped/failed/expected-failure tests, passing individual cases and
parameter results, required app/UI bundles, and three named UI cases per
platform. Missing or malformed results fail. Gate reports and exported JSON
join the existing uploaded validation artifacts. A regression step exercises
the checker in CI.

Eleven local checker tests passed. The existing AppHostedDatabase.xcresult
exports 45 test cases (48 parameter executions in its device summary). The
checker correctly accepts its app-hosted-only scope and rejects the same
artifact when HarcAppUITests is required. This verifies the distinction between
app-hosted and UI evidence; it is not a new app/UI run. Workflow YAML parsed,
all run scripts passed bash syntax checks, and all six required UI selectors
were matched to current source. Evidence lives in xcode-execution-gate/.

Only CI tooling/documentation changed, so no redundant app rebuild was run.
Remote CI execution, branch protection, SwiftPM skip accounting, and the full
physical/runtime/release gates remain open. This change enforces no skipped
Xcode cases and presence of the named required cases; it does not prove that
every future source test has been included in its scheme.

### SwiftPM skip-accounting correction and CI gate

**Correction to earlier full-suite reports:** Swift Testing's final "test run"
count includes disabled/skipped cases. The VAD-gap run had 1,635 discovered
cases, comprising **1,623 passed and 12 skipped**. Its XCTest run had 125 cases,
comprising **119 passed and six skipped**. Earlier prose describing all 1,635
as passed, or mentioning only the six XCTest skips, overstated executed
coverage. Earlier Swift Testing totals in this log must likewise not be read
as pass counts without consulting their XML. Separately executed model and
physical diagnostic results retain their own scopes.

CI now exports Swift Testing XML and retains serial XCTest terminal records.
The checker reconciles both frameworks' individual cases with completion
records and counts; it rejects failures, incomplete output, unexpected skips,
missing opt-in test inventory and discovery below the reviewed floor. The
policy names all 18 allowed opt-in skips with reasons. An allowed skip is not
qualification; dedicated model/corpus, volume, pairing and memory diagnostics
remain separately required. The discovery floor is a guard against large
omissions, not proof that every possible source test was discovered.

A fresh full regression against the current built binary passed: **1,629 Swift
Testing passes plus 12 skips (1,641 discovered, 274 suites); 119 XCTest passes
plus six skips (125 discovered); zero failures**. The checker passed this real
run. Nineteen combined Xcode/SwiftPM checker regression tests passed, including
missing terminal records, unexpected skips, count mismatches and failures
hidden behind an otherwise passing summary. YAML and workflow shell syntax
validated. Evidence is retained in swift-execution-gate/ with XML, log, JSON
execution report, checker results and source hashes.

Only tooling/documentation changed this turn. No new app build, live UI or
remote CI execution is claimed. Branch protection and the broader model,
physical, endurance and sealed-release gates remain open.

### Current app-hosted refresh and external gate read-back

CUA again reported the Mac locked and requiring manual unlock. Live UI testing
remains blocked; no UI interaction is claimed. Started a fresh current-source
app-hosted run using the isolated ProductionValidation bundle, HARC_UI_TESTING=1
and /private/tmp/harc-app-validation/host-test-data. The supervisor caps workers
at two and enforces the 5 GiB disk floor. A 520-file source/resource hash manifest
was saved before the test result. Helper compilation was verified progressing
through live subprocess inspection during quiet Xcode log intervals.

Read-only GitHub checks found classic main-branch protection absent (HTTP 404,
"Branch not protected") and the active rules endpoint returned an empty array.
Therefore main currently has no protection/ruleset enforcing the proposed CI
checks. No repository settings changed. The candidate workflow still needs
remote verification and required-check enforcement before that gate closes.
Raw read-backs and their timestamp are retained in app-hosted-current/.

Checkpoint: app-hosted refresh remains live in exec session 94322 (supervised
xcodebuild PID 31123 at last inspection), with no test cases started yet. The
log subsequently advanced to additional package-graph resolution. Do not treat
this as terminal or restore Package.resolved until the active build finishes.
Resume the same handle and revalidate live state; no fresh hosted-test pass
has been claimed.

### Hosted runtime diagnostic disposition and local summary model selection

The first current app-hosted attempt was deliberately interrupted after live
samples showed idle Xcode/build services and repeated package resolution. A
separate test-without-building retry disabled automatic package changes and
remote updates, using the already-built diagnostic products. It eventually
launched Harc, but no test cases executed. A sample of that app showed
libXCTestBundleInject entering XCTestDriver and waiting in
_prepareTestConfigurationAndIDESession. It was also deliberately interrupted.
Both supervisors exited 73; neither is a product-test pass or a demonstrated
product-test failure. The second attempt narrows the unresolved gate to XCTest
session setup; it does not prove that package resolution or the locked screen
was its root cause. The logs additionally confirm accessibility is shielded by
the lock screen. Both owned app/Xcode processes were absent after termination.
The verified Sparkle-only lockfile churn was restored after both runs stopped.
Samples, interrupted summaries and logs are in app-hosted-current/.

The installed Gemma directory contains only config/generation_config, while
qwen-3.5-4b-4bit has tokenizer and weights. The existing real summary quality
test now accepts HARC_SUMMARY_MODEL_ID (default unchanged), records the selected
model and generated output, and fails incomplete explicitly enabled installs
instead of skipping. No production model selection or quality assertion changed.
The Qwen model's eleven local files were hashed into local-summary-qwen/ before
qualification. This will be a Qwen-specific synthetic transcript diagnostic;
it cannot qualify the incomplete default Gemma model or a real meeting corpus.

Local summary qualification results: the selector compiled; its disabled run
skipped one test as expected and is not a quality pass. The enabled Qwen run
first failed before inference because SwiftPM could not find the default Metal
library. Both Xcode and SwiftPM MLX checkouts were verified at revision
61b9e011e09a62b489f6bd647958f1555bdf2896. Inspection of MLX's loader confirmed
colocated mlx.metallib support. The Xcode-built default.metallib was temporarily
copied beside the SwiftPM test binary, with its hash retained; no app artifact
was modified. It was removed after the run with an exact-hash ownership check.

With that runtime resource, Qwen loaded and generated a structured summary in
11.548 seconds. The unchanged quality assertion **failed**, reporting missing
pricing-risk and legal-review facts. The output says "pricing risks remain
unresolved" and prohibits discounts until legal completes review; these appear
to be paraphrases requiring scorer review. No threshold was weakened and no
summary-quality pass is claimed. WER and speaker fields in this summary-only
fixture use reference scaffolding; their zeros do not qualify STT or diarization.
The generated action-item attribution also still warrants semantic review.

An explicitly enabled default-Gemma run then failed clearly at incomplete-model
preflight (one failure, zero skips, before inference), demonstrating fail-closed
handling of the installed config-only directory. All eleven Qwen model file
hashes remained unchanged after execution. Logs, model/runtime/source hashes
and the generated summary are retained in local-summary-qwen/. Only test code
changed, so no additional app build was needed. No runtime process from these
attempts remains active. The model-quality and broader production gates stay open.

### Summary commitment scoring correction

Scorer review found a false-positive beyond the paraphrase issue. The fixture
required an Amy-owned Michelle follow-up, although Amy only requests that note
in the transcript. SummaryPrompt's existing contract admits only actual
commitments. The corrected reference therefore requires Jason's explicit
commitment, retains the requested Michelle follow-up as a summary/note fact,
and does not assign it to Amy. The complete candidate was corrected accordingly.

The evaluator now rejects action items outside the reference commitments,
instead of merely checking that required items appear somewhere. It also reads
action deadlines from the parser's structured due field. Seven focused tests
passed: complete/incomplete baselines, WER, three unsupported-owner variants,
prohibition-versus-commitment, structured deadline, and replay of the retained
Qwen output. The replay is rejected for the Amy and Priya action items; no fresh
model invocation occurred and no model-quality pass is claimed.

The literal summary-fact paraphrase problem remains open. The current token
scorer is not a general semantic entailment checker: this correction closes the
specific unsupported-action coverage gap but does not prove every factual or
attribution claim. No production prompt, model or accuracy threshold changed.
This is test-only work; no redundant app rebuild was run. Logs and hashes are in
summary-action-scoring/. The broader production gates remain open.

### Rejected prompt-only commitment experiment

Tested stronger generic instructions separating commitments from requests,
prohibitions and approval conditions, with explicit ownership rules. The local
Qwen fixture still assigned the Michelle follow-up to Amy and emitted the
approval condition as an action. The candidate failed the unchanged scorer;
no improvement or summary-quality pass is claimed. Its summary also illustrates
another token-scoring limitation: "before any discount is approved" was flagged
as an approved-discount claim despite being a condition.

A provenance check caught that the test binary retained an earlier candidate
format-example annotation because a small edit followed build startup. The
exact tested candidate was reconstructed and verified verbatim in the binary,
then retained with the binary hash and model output. It is explicitly an
intermediate experiment, not evidence for a later source variant.

The unproven production prompt change was reverted completely. Rebuilt and
passed **five XCTest prompt tests and seven Swift Testing scorer tests**, with
zero skips/failures. Verified the restored template is present in the new test
binary, the candidate ownership instruction is absent, and SummaryPrompt.swift
matches its original repository bytes. Removed the temporary Metal resource.
No production code change remains from this experiment; no additional app build
was needed. Evidence is in summary-prompt-experiment/. The next step requires
better verified extraction or scoring, not accepting this unsuccessful wording
change as hardening. One failed candidate does not establish that all prompting
approaches fail. The full production goal remains open.

### Review-candidate source identity and gate index

Added a source snapshot/verifier covering all tracked and non-ignored untracked
repository contents, executable state, in-repository symlink identity/referents
and commit identity. Added/changed/deleted files or a different commit invalidate
a snapshot. External symlinks and inconsistent inventory digests fail closed.
Snapshot output inside the repo must be ignored and cannot overwrite an existing
file. Writers/builds must be stopped during recording/checking; this is not an
atomic filesystem snapshot. All results remain explicitly unqualified.

Ten temporary-repository regression tests passed, including file/permission and
commit changes, ignored output, tampered inventory, and false qualification
claims. All 29 tooling/checker tests passed together. Workflow YAML and shell
syntax validated; CI now runs the source-snapshot regressions as well.

Created docs/evidence/2026-09-05-candidate-status.md as the compact gate index.
It distinguishes diagnostic component evidence from missing exact-candidate
runtime, model, physical, CI-enforcement and distribution evidence. No release
readiness claim, commit, remote workflow run or repository setting change was
made. The initial dirty source snapshot is recorded after this log update at
review-candidate-source.json in the ignored evidence directory and verified
immediately; future non-ignored changes require a replacement snapshot.

### Summary claim-review evidence

The lexical evaluator previously called word co-occurrence a forbidden claim,
including the valid prerequisite “Legal must complete their review before any
discount is approved.” It now reports unresolved claim-review concerns with the
actual summary text and explicitly identifies them as lexical matches, not
established contradictions. These concerns still block automatic qualification;
no negation or conditional heuristic clears a result. Unsupported action owners
remain an independent failure.

Focused GoldenSampleEvaluationTests passed: eight tests, including two
three-case parameterized tests (12 executions), zero skips. Cases cover actual
approval, negated approval and approval requiring legal review; all retain
evidence and block qualification. The retained model-output replay still fails
unsupported-owner checks. Evidence is in summary-claim-review/. No model or
production prompt changed, and no app-runtime or model-quality pass is claimed.
CUA again reported the Mac locked; no app-hosted/UI retry was started.

This evaluator and documentation change supersedes the frozen source inventory.
Its prior package/build/pairing results remain attached to that exact snapshot.

### Production relay privacy read-back and audit fixes

Read-only inspection observed production version
6aee297a-49ea-4f92-8dab-3bdad4037976 at 100%, disabled Worker Logpush and
observability, no ordinary Tail Workers and successful health. Account Logpush
inspection failed HTTP 403. The original deployed checker missed streaming
tails; the tightened checker fails when that field is absent, as it was in the
actual API response. Production privacy/retention therefore remains unqualified.

Both audit scripts now deliver bearer headers via curl stdin, suppress shell
tracing and default curl config, reject CR/LF token injection, and keep tokens
out of curl argv. Empty account responses now return failure rather than a
misleading success. Five audit test methods with disposable CLI doubles passed;
all 34 tooling tests passed. No credentials are embedded in fixtures or logs.
Evidence and limitations: production-relay-readback/ in the ignored evidence
directory. No production deployment or configuration mutation was performed.

### Deployed relay code identity and idle-retention execution

The read-only content API returned a single 27,822-byte index.js, exactly equal
to a fresh local dry-run bundle (SHA-256
07244b9ea01e7c27f31750aa5825a825348c6f4935d7a39618789bd3411ae7ae). Deployment
read-back afterward retained version 6aee297a-49ea-4f92-8dab-3bdad4037976 at 100%.
Two alternate settings endpoints still omitted streaming-tail state, so that
privacy gate remains open alongside the account Logpush HTTP 403.

Added actual alarm-execution tests after session eviction. Expired idle sessions
delete stored state and reject the old capability; non-expired sessions preserve
state and re-arm their deadline. All 19 local relay tests passed, zero skips,
and TypeScript typecheck passed. Initial test timeouts came from an unread
initialization HTTP response preventing eviction; the fixture now drains it.
A restricted test launch failed loopback EPERM and restricted typecheck stalled
in a filesystem read; normal-service retries passed. No production logic changed.

Evidence is in production-relay-readback/, including deployed/local hashes,
source hashes, deployment read-back and retained diagnostic/final logs. This
binds code identity and local cleanup execution; it does not prove live
production/provider retention or account-wide privacy.

### Model install readiness after external file loss

ModelManager previously treated a readable install marker as sufficient even
when weights had been deleted or truncated. Bootstrap, requireInstalled and
startDownload now validate the marker's model ID, revision and total size plus
each catalog file's regular-file type and byte count. A damaged install becomes
absent, and requesting its download can repair it. Readiness inspection does not
delete files or markers. Download-time SHA verification remains unchanged;
startup metadata checks are deliberately not a same-size corruption detector.

All 45 HarcModels tests passed, zero skips, including missing/truncated files,
a directory substituted for a file, mismatched records, deletion after bootstrap
and successful download repair. The diagnostic macOS app build passed. Xcode's
expected Sparkle/originHash-only lockfile churn was recorded and restored after
completion. Evidence: model-install-readiness/ under the ignored evidence root.
No UI execution, model accuracy, signed release or fresh full-suite pass is
claimed for this change. The initial incomplete default-model directory was
already absent without a marker; this fixes the stale-marker case.

### Single-owner summary model operations

SummarizerService no longer relies on the summary queue alone to serialize
multi-gigabyte model use. Summary, chat answer, dictation transform and preload
share a cancellable FIFO operation slot across loading and generation. Reuse
binds model ID and directory. Unload invalidates an in-flight load and cancels
queued operations; late completion cannot restore residency. Idle eviction
cannot run during an active operation. A noncooperative loader can still finish
before its resources are released; instant cancellation is not claimed.

Ten existing service tests plus five suspended-operation ownership regressions
passed, as did 63 summary-queue/dictation caller tests, all with zero skips.
The diagnostic macOS build passed. Expected Xcode-only resolution churn was
retained as evidence and normalized after terminal build completion. Logs and
source identities are under summarizer-ownership/. These are software ownership
checks, not real-model RAM measurements, summary-quality or UI qualification.

### Cancellation normalization and fresh aggregate regression

A loader can throw an ordinary error after cancellation or memory-pressure
unload. The load boundary now preserves cancellation in both cases instead of
reporting a fresh model failure. Parameterized delayed-failure tests passed and
verified a subsequent request can load successfully.

Fresh full package results: 1,640 Swift Testing passes plus 12 named skips;
122 XCTest passes plus six named skips; zero failures. Log/XML skip accounting
passed. The diagnostic macOS build passed, and only expected Xcode lockfile
churn was normalized after completion. Evidence: post-model-hardening/.
Real-model quality, UI, physical, release and App Store scopes remain open.

### Six-case real summary attribution baseline

Added an opt-in real-model attribution contrast set for unaccepted/accepted
requests, conditional possibility, refusal, changed owner and a cancelled quoted
commitment. References explicitly avoid assigning requests or refusals as work.
The existing scorer tests passed after compilation; the new opt-in case is
named in the CI skip policy.

Offline Qwen inference through the unchanged production service/prompt failed
three of six cases: unaccepted request, refusal and cancelled commitment. One
XCTest ran all six cases with three assertion failures, zero skips, in 16.977s.
The venue case also invented an existing reservation in its prose. This is
evidence of a factual-generation issue, not merely parser/scorer disagreement.

Full output, expected/actual actors, exact test binary/source/prompt and model
identities are retained under summary-attribution/. The temporary matched-MLX
Metal runtime was removed after completion. Single-run synthetic attribution
checks neither qualify full summary quality nor the incomplete default Gemma
installation. No production prompt or model preference was changed.

### Worked-example prompt comparison

A generic worked-example prompt candidate improved the six Qwen attribution
contrast cases from three failures to zero, but still failed the original renewal
case by assigning a prohibition and unaccepted request to Priya and Amy. It was
not adopted. Production SummaryPrompt was restored byte-for-byte; rebuilt
prompt/evaluator tests passed (13 total), and the candidate-only instruction
was confirmed absent from the restored test binary.

The first combined model attempt hit the 5 GiB disk guard before producing a
test result. With no builds active, audited isolated Xcode intermediates, module
cache and index directories were removed; built products, logs, source, models
and user data were preserved. Separate model processes then completed after
headroom recovered. No cause is asserted for the original space change.
Temporary Metal runtime removed. Evidence: summary-attribution-examples/.
Single-run synthetic results do not qualify general or default-Gemma quality.

### Runtime and CI prerequisite refresh

CUA still reports a locked desktop. xctrace lists only the local Mac online and
Omega offline, with no physical iPhone available. Those gates remain blocked
by unavailable runtime/device access.

The current GitHub runner-images inventory confirms macos-26 maps to arm64 and
provides Xcode 26.6 / 17F113 at the pinned path. Both CI lanes now assert arm64
at execution in addition to checking Xcode. YAML, every shell step and diff
whitespace checks passed. Evidence/source links: qualification-prerequisites/.
This is prerequisite verification, not a remote CI run or branch enforcement.

### Default model installation and first Gemma result

Completed the existing partial default Gemma installation from the exact catalog
revision after auditing/removing two regenerable compiler module caches. All
eight files passed pinned size/hash verification before writing the install
marker. No preferences changed; the download preserved the 5 GiB floor.

Direct XCTest selection was checked against one existing unit test, then used
for offline Gemma inference without rebuilding caches. Gemma loaded/generated
in 7.447s but the renewal gate failed: the parsed result has no Jason action
despite acknowledging his commitment in prose. The current harness logs a
reconstructed result, so generation versus parser loss remains unresolved until
raw output is captured. Lexical fact/conditional concerns are not adjudicated
as contradictions. One test ran, one failure, zero skips; no disk interruption.
Temporary Metal runtime removed. Evidence: default-model-install/.

### Default Gemma raw-response and attribution diagnosis

The existing test binary ran under LLDB without recompilation. Captured raw
renewal output explicitly emitted the no-actions sentinel despite describing
Jason's commitment: generation omission is confirmed for this rerun. One test,
one failure, zero skips. LLDB exit 0 is not a passing test: its child exited 1.

Gemma's existing six-case attribution set failed four cases: unaccepted request,
conditional possibility, declined task and changed owner. The two remaining
cases passed actor/count checks only. One XCTest, four assertions, zero skips.
No disk interruption or prompt change; temporary Metal runtime removed.
Evidence is retained in default-model-install/. Summary quality remains open.

### Preserve malformed summary action output

SummaryParser now retains raw response text and sets parseWarning when action
lines cannot all be understood, including empty/truncated sections, non-checkbox
lists, mixed sentinel/tasks and empty tasks. Valid checkbox tasks remain
structured. The explicit no-items sentinel still parses cleanly.

Eleven repository XCTest methods passed against the actual parser/output sources
in a small standalone executable. Initial runner setup attempts failed to locate
XCTest/its Swift overlay/runtime; the final explicit framework/library setup ran
all eleven cases successfully. This avoids a full cache rebuild near the disk
floor, and is not an app-build or UI qualification. Evidence:
summary-parser-preservation/. The app persists result.summary, so previously
dropped text survives, but currently does not propagate parseWarning to a UI
indicator. The model attribution failures remain separate unresolved work.

### Persist summary formatting review notices

Both recording and session generation now persist SummaryParseResult.markdownForStorage,
which prefixes malformed output with a plain-language review notice and retains
the response. Existing desktop/mobile summary displays and exports consume that
saved text. Malformed generation no longer updates a recording's suggested title.
No schema/protocol migration is needed to retain this notice across clients.

Sixteen parser/output XCTest cases passed using actual sources in the standalone
harness. AppDelegate passed Swift frontend syntax parsing; full app compilation
and visible UX remain unverified because disk headroom is close to the 5 GiB
floor and the desktop was last observed locked. Evidence: summary-parser-preservation/
storage-result.*. This notice covers formatting, not semantic model accuracy.

### Summary package validation refresh

With no compiler/test processes active, removed audited regenerable protobuf
compiler intermediates, the SwiftPM index, and the standalone parser module
cache. Built products, models, source and evidence were retained. A normal
SwiftPM build with two workers and a 5.25 GiB guard completed in 381.72 seconds;
minimum observed free space was 6,865,117,184 bytes. No disk interruption.

The focused selection passed 26 XCTest cases and six Swift Testing concurrency
tests (seven executions including a two-case parameterization), with no skips
or failures. ModeTransformTests was a filename, not a matching class; subsequent
explicit direct-XCTest selections of ModeTransformPromptTests and
SummarizerServiceTransformTests each passed five cases. Total scope: 36 XCTest
cases plus six concurrency tests. Lockfile unchanged; diff whitespace clean.

Evidence: summary-parser-preservation/package-tests* and *Transform*.log. This
now validates the parser/storage-text changes in the package build, but does not
cover HarcApp compilation or visible UI. CUA still reports a locked Mac.

### App refresh stopped at storage guard

Attempted the diagnostic Xcode build with two workers and indexing disabled.
The 5.25 GiB guard stopped it at 5,628,502,016 bytes free; log reports BUILD
INTERRUPTED, xcodebuild terminated by SIGTERM. No active compiler/test children
remained afterward. Preserved Xcode's effective lockfile and restored only the
verified Sparkle/originHash churn. Evidence: summary-app-validation/.

This is an incomplete app check, not a compile failure or pass. Additional disk
headroom is required before retrying; UI work separately requires manual unlock.

### Resumed macOS build after approved cleanup

User-approved removal of SwiftPM debug output, shared Xcode module cache and
earlier disposable validation caches recovered 4.48 GiB. Current Xcode
intermediates, models, recordings and evidence were preserved. The resumed
diagnostic Xcode app/helper build completed successfully (exit 0), with two
workers and no disk interruption. Minimum observed free space: 10,590,101,504
bytes. Artifact digests: summary-app-validation-resumed/artifacts.json.

No compiler/test children remained; verified originHash-only lockfile churn was
preserved then normalized. This closes app compilation for the latest summary
changes, not UI or release qualification. CUA still reported a locked desktop.

### Headless raw-output quality evaluation

Test-only container capture now preserves raw responses without changing model
parameters. Renewal scoring uses actual output instead of reconstructed Markdown;
contrast cases retain raw text and parse warnings. The evaluator rejects format
warnings. Clean package build and nine evaluator tests passed.

One offline Gemma renewal run verified capture and failed format/aggregate quality
(two assertions, zero skips, 6.604 seconds). Raw output used non-checkbox bullets
and listed Jason's commitment plus Priya's prohibition and Amy's unaccepted
request. This single generation differs from the earlier no-action response; it
does not establish stable or general model quality. No prompt change was adopted.
Evidence: raw-summary-evaluation/. Temporary Metal runtime removed.

Headless builds, unit tests and model diagnostics continue without a graphical
session. Only interactive/visible UI qualification requires an unlocked session.


### Unlocked-session app and UI validation — 2026-09-06

After the user logged in, the final combined diagnostic run passed 49 cases:
45 app-hosted and four selected UI cases, with zero failures, skips or expected
failures. The exported result summary/tree passed the execution checker with
both required bundles and all four bundle/class/method selectors. Evidence:
`unlocked-app-ui-final-2026-09-06/`; result bundle:
`/private/tmp/harc-app-validation/UnlockedFinal-20260906.xcresult`.
Minimum observed free space was 6,547,636,224 bytes, with two build workers.

The UI tests had stale expectations for a removed Library radio group, a fixed
window title and foreground activation reopening a window. Updated them to use
the current Library controls, stable recording selectors, and the status item's
Library command. The capture warning test verifies persistence across relaunch.
These changes repair test navigation; they do not change application behavior.

An initial build stopped because helper inputs changed during compilation.
The temporary diagnostic project now builds helpers from a 995-file source
snapshot outside Documents using an already-local dependency cache. Repository
build scripts were not changed. A clone of the original helper cache stalled in
clonefileat and was stopped; the incomplete copy is preserved. Manifests, build
logs and binary hashes are retained. Xcode-only lockfile churn was verified,
preserved in evidence, and normalized to the committed lockfile.

Direct CUA inspection of the disposable diagnostic app confirmed the visible
capture-interruption warning and rendered General and Transcription Settings.
The XCTest screenshot attachment showed Codex rather than Harc and is excluded
from visual evidence. The diagnostic app was quit after inspection. No user
recordings or settings were changed.

This is an ad-hoc diagnostic build, not a sealed release candidate. The full UI
suite and CI fake-recording loop were not selected. Summary attribution quality,
real capture/endurance, physical devices, cross-network acceptance, remote CI
and signed release/App Store qualification remain open.


### Complete current macOS workflow regression — 2026-09-06

The original complete UI suite had four passes and six failures. It still
referenced removed Wiki/Review and standalone Note editor surfaces. Replaced
those obsolete tests with current recording search, transcript editing and
persistence checks; retained capture-warning, Library, inspector and Settings
coverage. The suite now has eight relevant cases rather than ten legacy cases.
CI explicitly requires every current selector. No skip policy was relaxed.

The expanded checks exposed and now cover three application defects:

- A stopped recording can become selected before its Library row arrives.
  The row observation now initializes the empty editor from its own latest
  recording, with cancellation/selection guards and protection for dirty edits.
- Clearing a loaded transcript removed the editor before replacement typing.
  Keep the active editor when its text becomes empty during editing.
- SwiftUI's Settings-only scene replaced the installed main menu without Edit.
  A one-time installation flag prevented repair, breaking Select All. Check the
  actual menu before app events and restore the resident menu when needed.
  A scene-command experiment did not fix the captured menu and was reverted.

The transcript NSTextView now has a label and stable accessibility identifier.
Tests verify exact replacement text including symbols, undo/redo, autosave and
relaunch; search verifies Select All replacement, title/transcript hits, no
results and clearing. The fake recording test verifies Markdown/JSON output,
visible transcript and relaunch. It bypasses physical capture and inference.

Final combined diagnostic result: **53 passed, zero failed, zero skipped**:
45 app-hosted cases and all eight UI cases. The exported execution checker
passed all required bundles and selectors. Eleven checker regressions passed.
Minimum free disk was 9,475,960,832 bytes. Evidence:
`macos-workflows-final-2026-09-06/`; result bundle:
`/private/tmp/harc-app-validation/MacWorkflowsFinal-20260906.xcresult`.
Hashes bind current changed source/test/CI files and the app/helper executables.

An intermediate run hit the disk guard and was interrupted, not passed.
Repeated the previously approved SwiftPM debug-output cleanup only after
confirming no compiler/test process was using it; recovered 3,812,589,568 bytes.
The disposable app left by the interrupted runner was quit. Xcode outputs,
models, recordings and qualification artifacts were retained. Cleanup evidence:
`repeated-approved-debug-cleanup.json`. Verified Xcode-only lockfile churn was
saved and normalized. This is still a dirty ad-hoc diagnostic candidate, not a
release or physical-device qualification. Summary-quality failures and remaining
real-world, cross-network, CI/deployment and release gates remain open.


### Expanded summary attribution gate — 2026-09-06

Investigated the next open software gate with local synthetic inference against
the existing Xcode-built summary implementation. The unchanged default-model
prompt passed 3/15 actor/format checks; a shorter candidate passed 13/15 but
still produced completed and unaccepted tasks. A worked-example candidate
passed 11 completed cases before the disk guard stopped it. Production prompt
remains unchanged; incomplete/lexical evidence does not qualify accuracy.

Expanded the existing opt-in contrast test from six to 14 cases and added
selected action/deadline/condition term checks. The exact changed method was
type-checked against current modules; no full package or live expanded XCTest
pass is claimed. Preserved raw responses, probe sources, hashes and execution
records. Reclaimed the audited obsolete original helper cache while retaining
the current isolated cache and all user data. Details and remaining work:
[summary attribution investigation](../evidence/2026-09-06-summary-attribution.md).


### Summary coverage continuation — 2026-09-06

Reclaimed the authorized iPhone 17 Pro Simulator; free space settled near 13 GiB.
Continued synthetic summary experiments and added a missing-status scorer
regression. A replay of the repository evaluator passed; no full XCTest/Xcode
run was claimed. Prompt-only and task-only alternatives still fail. Combining
retained full-summary commitments with independent factual prose passes the
15-case development rubric, but remains a retrospective diagnostic requiring
end-to-end, unseen-case, second-model and latency validation before integration.
See [current evidence](../evidence/2026-09-06-summary-attribution.md).


### Sequential accuracy diagnostic — 2026-09-06

Executed both summary passes in one loaded-model process, rather than assembling
old runs. Gemma passed 15 development and 8 frozen fresh lexical checks; the fresh
set also passed at production-default sampling. Qwen has a genuine cancelled-task
failure plus a lexical condition false alarm. Manual review still found weak
prose deadline fidelity on Gemma, so production integration remains open. Eight
malformed-response assembly cases passed; generation exceptions and cancellation
are not covered by that evidence. See the [latest accuracy evidence](../evidence/2026-09-06-summary-attribution.md).


### Restart: concrete summary boundary fixes — 2026-09-06

Implemented disclosure of input-budget omissions in persisted summary text,
review for empty summaries, and rejection of late results after cancellation
or unload. Focused exact-source tests passed (35 XCTest, seven Swift Testing);
the real diagnostic macOS app build succeeded. This prevents specific incomplete
results being presented as successful summaries; it does not solve model
reasoning or restore excluded transcript content.
See [boundary evidence](../evidence/2026-09-06-summary-boundaries.md).

### Full transcript summary implementation — 2026-09-06

Replaced suffix-only over-budget summarization with chronological section
extraction and bounded reconciliation. Failures and cancellation cannot save
partial notes. Focused tests and app compilation passed; an actual-service Gemma
run retained the early/middle/late fixture's constraints and excluded a withdrawn
booking. The fixture was tuned after observed omissions, so untouched accuracy
and production-sized long-input gates remain open. See
[full-coverage evidence](../evidence/2026-09-06-summary-full-coverage.md).

### Summary termination completion gate — 2026-09-06

Preserved real runtime stop reasons and enforced them across all summary passes.
Capped/unexpected early stops now fail visibly, while user cancellation/unload
retains cancellation behavior. Focused tests, real app compilation and a forced
local runtime cap confirmed rejection and successor progress. The successor's
format warning remains a model-quality concern, not a passing accuracy result.
See [termination evidence](../evidence/2026-09-06-summary-termination.md).


### Summary attribution candidate rejected — 2026-09-06

The two-pass implementation improved the measured baseline, but semantic errors
remain. An additional prompt candidate preserved individual refusal scope in
Gemma yet made Qwen invent completed booking work. Reject that candidate rather
than promote aggregate automated passes. Eight fresh cases now extend the opt-in
contrast test; raw app-backed results and manual findings are retained. The next
correction must ground claims in source statements and preserve reported-speech
time and task status. Accuracy and full workflow gates remain open. See
[attribution evidence](../evidence/2026-09-06-summary-attribution-scope.md) and
[two-pass evidence](../evidence/2026-09-06-summary-short-accuracy.md).


### Source grounding and refusal publication — 2026-09-06

Structured exact-source evidence did not establish semantic correctness and the
candidate was not integrated. A bounded reasoning run failed before a final answer;
a sampling-only comparison still missed tasks and invented facts. Retain these
negative results rather than treat quotation matches as accuracy. The current
service now rejects explicit refusal tasks on short and reconciled long paths;
actual Qwen reproduction confirmed rejection and three successful successor tasks.
This is a publication safeguard, not completion of the accuracy goal. See
[grounding evidence](../evidence/2026-09-06-summary-grounding.md) and
[guard evidence](../evidence/2026-09-06-summary-refusal-guard.md).


### Speaker overlap delivery — 2026-09-07

Real pinned-TLS signed processing submission and replay now pass directly and
through the local encrypted-relay emulator, preserving overlap in Library text
and structured JSON. Fixed the production Client bundle's missing required
diarization entry; six actual builder tests and the app build pass. Audio ingest,
physical two-network operation, and real-meeting speaker identification remain
open. See the signed-overlap section of
[speaker accuracy evidence](../evidence/2026-09-06-speaker-accuracy.md).

Speaker evidence binding is now a reproduced production blocker: confirming one
recording/index can enroll multiple historical voice payloads, and Host matching
can disagree with its downloadable recognition pack. The failing diagnostic and
coordinated implementation requirements are in
[speaker evidence binding](2026-09-07-speaker-evidence-binding.md).

### Cross-meeting speaker recognition remains below target — 2026-09-07

Actual three-chunk Client processing on nine minutes of a second AMI meeting
produced 20.68% diagnostic WER and three visible incomplete recovery ranges.
Unchanged enrollment from the first meeting identified only 46.62% of the known
speaker's lexical activity; two excerpts had no accepted identity. Per-cluster
reference analysis shows the main rejected clusters contain substantial isolated
known-speaker activity, while short enrollment prototypes are internally variable.
Keep production thresholds unchanged pending independently selected enrollment
and multiple-known-person evaluation. Same-day public training-set audio cannot
qualify generalization, live capture or production accuracy. Exact results and
limitations are in [speaker accuracy evidence](../evidence/2026-09-06-speaker-accuracy.md).

### Host worker speaker persistence — 2026-09-07

The actual Host worker now has a successful real-model execution against a
disposable on-disk Library: transcript, turns, overlap, embeddings and enrolled
voice decisions survived process exit, with ready projection and no pending work.
Fixed the worker to use its launcher's returned daemon socket. The app build passed.
This seeded 180-second fixture qualifies the exercised processing/persistence path;
wrong-name accuracy, failure/restart behavior, device ingress and long-form gates
remain open. See the actual-worker section of
[speaker accuracy evidence](../evidence/2026-09-06-speaker-accuracy.md).

### Notarized release and installed Host follow-up — 2026-09-25

Published Harc 0.14.13/build 68 from source `6eff91dc522bbd46860942bee8cd0b33db6675fe`; publication commit `7cb2d18772bb249d86a2de74ba4843711dca68c8` changes only the appcast. This focused release contains receipt repair and Client transfer diagnostics, plus Xcode 27 helper-path compatibility. It excludes the broader uncommitted accuracy and production-hardening changes in this checkout.

Apple accepted notarization `877a86c9-f4c2-4b7e-ab64-a7912f424f55`. The stapled DMG passed signature, Gatekeeper, version/build, architecture and embedded-source checks. Sparkle's Ed25519 signature verified independently against the app public key. Both uploaded asset digests matched local files; an independently downloaded DMG matched SHA-256 `5dd624b3a595aeaa1d4ede8ab1bc4879ef4c50d202b89d0afc687ccf544bcf1e`. The remote feed and annotated tag were verified after publication.

The installed Mac mini Host upgraded through the actual Sparkle UI from diagnostic 0.14.12/build 67.1 to 0.14.13/build 68. The installed source identity and macOS signature/Gatekeeper checks passed. After relaunch, Settings showed Host available to paired devices and Harc Remote connected. This is one observed installed upgrade, not the required repeated two-Mac matrix. No live receipt repair was authorized by macOS owner authentication during this run; the pre-update repair table contained zero rows. Client installation and recording/processing/speaker convergence remain unverified.

The released candidate previously passed 21 focused receipt/diagnostic tests and three direct/relay transport checks. GitHub CI run `36212713745` is still running package tests at this checkpoint; no full release CI pass is claimed. Separately, 75 current-worktree Python validation/scoring tests and the schema guard passed. Those checks cover unshipped tooling and schema consistency, not runtime accuracy. Evidence is retained under `build/qualification/release-0.14.13/`.

### Deployed Cloudflare relay round trip — 2026-09-25

The existing staging lifecycle script passed against the real Cloudflare staging Worker using disposable random route/capability IDs and synthetic 4 KiB payloads. It exercised offline rejection, bidirectional payload/acknowledgement exchange, Host-control reconnect with the same durable route, a new working session, revoked and stale capability rejection, and replacement authorization. This proves the exercised deployed relay byte path; it does not exercise inner pinned TLS, the installed Host or work Client, audio ingestion, or real two-network recovery. No production pairing or recording data was used.

The deployed privacy guard failed closed because streaming_tail_consumers was absent. A separate filtered read-back of both documented script-settings and settings endpoints on both production and staging confirmed Logpush false and ordinary Tail Workers empty/null, but neither endpoint reported streaming Tail Workers. Cloudflare's published ScriptSetting schema lists logpush, observability, tags and tail_consumers; it does not establish absence of streaming consumers from omission. No deployment or guard was weakened. Keep complete privacy qualification open pending authoritative evidence for this setting. Logs and filtered read-back are retained as cloudflare-*-20260925 files under build/qualification/release-0.14.13/.

### Authenticated protocol through deployed Cloudflare — 2026-09-25

Fresh binaries built from clean published commit 7cb2d18772bb249d86a2de74ba4843711dca68c8 passed two isolated Swift Testing cases against the deployed staging relay: pinned TLS bootstrap/Library/resumed upload RPCs, then pairing/authorization/Host revocation/forget/same-key re-pair. The upload fixture checks chunk-state continuation and absence of fixture plaintext in relay frames. The source checkout remained clean. Both cases ran rather than skipped. See deployed-protocol-results-20260925.json and linked logs under build/qualification/release-0.14.13/.

These tests use disposable Host/Client services and transfer state fixtures; they do not prove the installed production Host and work Client converge, actual canonical audio durability, independent-network reachability, or voice identification accuracy. The missing streaming Tail Worker privacy read-back remains open.

### Xcode 27 test-result accounting — 2026-09-25

Fresh release regression completed with 1,581 Swift Testing passes/10 skips and 119 XCTest passes/4 skips, zero failures. Xcode 27 swiftbuild emits sibling XML suites and separate per-target completion summaries, including empty targets and singular test/suite wording. Updated scripts/check-swift-test-results.py to reconcile each XML suite with its corresponding completion and each serial XCTest completion with its preceding cases. Discovery floors, expected opt-ins, unexpected-skip rejection, duplicate cases, malformed nested result rejection, and failure checks remain enforced.

Added seven compatibility/adversarial cases; all 82 Python tooling tests passed. The actual release log parses to the verified counts but correctly fails the newer current-tree policy because the release lacks subsequently added tests and has lower discovery counts. No policy thresholds were lowered, and this is not a current-tree app test pass. Evidence: xcode27-checker-tests.log and xcode27-checker-validation.json under build/qualification/release-0.14.13/.

### Release local model smoke — 2026-09-25

With HARC_INTEGRATION_TESTS=1, the published source's DiarizerTests and TranscriberTests filter passed 29 cases with no skips: 13 model/helper cases plus 16 chunked-transcriber regressions also matched by the filter. Four exercised real local models: short-speech segmentation, normalized speaker embeddings, and transcription/word timings with VAD off/on. These close the exercised model smoke skips for this fixture; they do not qualify cross-meeting speaker identity, WER/DER, summaries, the current dirty source, or end-to-end device delivery. Evidence and fixture hash are retained in release-real-models-20260925-summary.json and its log under build/qualification/release-0.14.13/.

### Release short-fixture word accuracy — 2026-09-25

The exact published source passed its real STT golden test with the documented full reference sentence supplied through HARC_STT_GOLDEN_REFERENCE and HARC_STT_MAX_WER=0.125: one executed test, no skips or failures, 18.439 seconds. This proves the configured WER bound and nonempty timing output for this short fixture; the released test does not print the exact WER. Its original truncated default reference remains in the release source; the existing corrected test in this working tree is unshipped. The Core ML E5RT zero-shape warning recurred after test completion and remains unresolved. Log and source/fixture hashes are retained in release-stt-wer-20260925-summary.json under build/qualification/release-0.14.13/. No speaker identity, long-form or production device-sync claim follows from this result.

### Core ML warning isolated without inference — 2026-09-25

A small CoreML-only probe loaded and released each installed model in a separate process, with no predictions or audio inputs. Parakeet v2 Preprocessor.mlmodelc using its production cpuOnly setting reproduced the E5RT ios17.slice_by_index zero-shape warning, while returning a model and exiting zero. Encoder, Decoder and JointDecision using cpuAndNeuralEngine did not reproduce it. Silero VAD 6.2.1 was clean using both cpuOnly and its production cpuAndNeuralEngine setting. This localizes a reproducible warning to the preprocessor load/release lifecycle independently of transcription, but does not prove harmlessness or identify a Core ML internal root cause. No application/model configuration was changed or warning suppressed. Probe, individual logs and hashes are in release-0.14.13/coreml-load-diagnostic/.

### Fresh current-source package regression — 2026-09-25

Following the Host speaker inventory read fix, the freshly built current working tree passed a serial full package run: 1,764 Swift Testing and 167 XCTest cases passed, zero failures, with 12 and 7 explicitly permitted skips respectively. The Xcode 27-aware checker passed its discovery minimums, per-target execution accounting and exact skip policy without changes to thresholds. The 1,086-file source snapshot matched after execution (tree SHA-256 764812d7ed141d16522e78228a36fec8e18f91948b22f97a800b6ea52a6f0237). Evidence is retained under build/qualification/current-package-20260925/.

This supersedes older package evidence for this current snapshot only. It does not turn skipped model, large-file, pairing or cross-volume gates into passes, and does not cover HarcApp-hosted tests, installed behavior, physical Client/Host convergence or release qualification. The published release remains a distinct source snapshot.

### Current source over deployed Cloudflare staging — 2026-09-25

The freshly built current-source pinned gRPC and pairing lifecycle tests passed through the deployed staging relay: two executed tests, no skips, 9.403 seconds total. The lifecycle additionally exercised overlap artifact replay, deferral of speaker-bearing artifacts without lossy projection, negotiated bound speaker admission/replay, opaque cluster mapping and rejection of tampered retained evidence. Disposable identities and fixture transfer state were used; the owned opt-in marker was removed after execution. Evidence: build/qualification/current-relay-20260925/. This covers the current package snapshot separately from the earlier released-source run, not the installed production Host/work Client or physical recording delivery and voice accuracy.

### Package regression after exclusive voice support gate — 2026-09-25

The current package passed a fresh serial regression with two build workers: 1,766 Swift Testing and 167 XCTest passes, zero failures, and the same 12/7 permitted opt-in skips. The result checker passed without policy changes. The 1,086-file snapshot matched after execution (tree SHA-256 3b36bf26426ff20273883defc59c8f29f83345e0d407150523c14ba5ea18cd3b), before this evidence append. Evidence: build/qualification/current-package-followup-20260925/. This includes the exclusive-support safeguard and current diagnostic test changes, but does not qualify skipped real-model cases, app-hosted tests, production device convergence, or speaker accuracy. The existing release CI run 36212713745 was separately confirmed still in progress; it was not restarted. Disk free space ended at 6.3 GiB, above the 5 GiB operational floor; no cleanup was performed.

After subsequent model diagnostics crossed the disk floor, an audit found 4.2 GiB of obsolete generated output in /private/tmp/harc-01413-publish/.build/out. No build process used that checkout; its source was clean at the published commit, and the separately retained notarized DMG still matched the verified release SHA-256. Removed only that generated output, preserving release source, dependencies, artifacts/evidence and the current scratch build. Free space after removal was 10,183,450,624 bytes. Exact audit/removal record: build/qualification/current-package-followup-20260925/obsolete-release-build-cleanup.json. This reopens bounded diagnostics; it does not close any functional qualification gate.
