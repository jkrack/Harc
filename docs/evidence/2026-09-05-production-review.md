# Production review — 2026-09-05

Reviewed commit: `3ad6bc930dc7248f7a30160a321329bdd2e2b4ca`.
Source version: **0.14.12 (67)**. The checkout was clean at review start.

**Decision: hold the next broad production release for a focused reliability
milestone.** The existing module boundaries are a viable foundation. There are
concrete capture/recovery defects to close, and the current automated and
physical evidence does not establish whole-product production readiness.

This is a risk-based source review, with small executable fault reproductions,
not an exhaustive security audit or physical qualification. No application code
was changed. Historical passing runs are not counted as current validation.

## Findings, in implementation order

### 1. P1 — A failed recovery metadata load can become destructive success

`Sources/HarcStore/RecoveryQueue.swift:223` sets `loaded = true` before reading
and decoding `recovery.json`. If either operation throws, subsequent calls skip
loading and use the initially empty array. A later enqueue or cache scan can
overwrite the original queue, losing status and destination metadata, including
discard decisions. `HarcApp/AppDelegate.swift:2866` also converts a failed fetch
into an empty visible inbox.

**Reproduced using the unchanged production queue source**, with a minimal
in-memory RecordingStore substitute: write malformed JSON, call `fetchAll`
twice, then enqueue. The first fetch threw; the second returned zero artifacts;
enqueue replaced the malformed file. This proves the state-management defect,
not actual loss of a user's audio.

**Next change:** mark loading complete only after successful decoding; preserve
the original on failure; expose an actionable metadata error. Keep failed
persistence from making in-memory state look durably committed. Add tests for
corrupt JSON, transient read failure, failed writes, and recovery after restart.

**Acceptance:** repeated reads/writes after a failed load cannot overwrite the
original metadata or silently clear the recovery UI.

### 2. P1 — Final audio synchronization failures are swallowed

`Sources/HarcAudio/AudioFileWriter.swift:68` declares a throwing `close`, but
discards the final `fsyncFileAtURL` error with `try?`. `RecordingSession.stop`
therefore cannot distinguish successful synchronization from failure before
returning the captured master. The existing writer tests cover valid output,
idempotent close, and format mismatch, but not this failure path.

**Reproduced using the unchanged writer source:** write audio, rename the open
file, then close. The final open-for-fsync fails because its path no longer
exists, yet `close` returns success. This exercises suppressed error handling;
it is not a simulated power-loss or disk-full qualification.

**Next change:** propagate finalization/sync failure into the recoverable stop
path and retain enough state for safe retry. Define the required durability
boundary for publication and source cleanup; audit cross-volume moves under
the same contract.

**Acceptance:** injected final-sync failure never produces a successful durable
completion claim; the master remains recoverable, including after relaunch.

### 3. P1 — Capture loss is not represented in the recording result

`Sources/HarcAudio/RecordingSession.swift:443` drops the oldest raw system
buffers above its 256-buffer limit without returning a loss count or timing.
Resampling/mixing errors at lines 303 and 324 are logged but do not create
durable warnings. The returned capture hardcodes `discontinuities: []` at line
267. Downstream transcript chunk markers cannot recover audio never written.

**Reproduced with the exact queue implementation extracted unchanged into a
small harness:** 300 numbered buffers submitted before draining yielded 256,
starting at buffer 44. This confirms the overflow behavior; its frequency on
physical hardware was not measured.

The related `SystemAudioCapture` constructs `SCStream` with `delegate: nil`
(`Sources/HarcAudio/SystemAudioCapture.swift:90`). No `didStopWithError` handler
was found in the audio/app sources. Mid-recording system-capture failure needs
an explicit path distinct from the existing start-time mic-only fallback.

**Next change:** represent loss and source termination with timestamps and
durable warnings/discontinuities, make the live state truthful, and define
bounded buffering across the whole pipeline. Audit mic-driven cadence and
remaining system buffers at Stop. Avoid solving overflow by unbounded growth.

**Acceptance:** stall the consumer, exceed queue capacity, inject conversion
failure, and terminate system capture. Each case either preserves accepted
audio or visibly records what was lost; Stop preserves the valid prefix.

### 4. P1 — CI does not cover the shipped app surface

`.github/workflows/ci.yml` runs SwiftPM tests, protocol checks, a macOS Debug
build, and the embedded STT version command. It does not build HarcMobile, run
`HarcAppTests` or `HarcMobileAppTests`, exercise UI scenes, or explicitly invoke
the direct/relay pairing lifecycle scripts. These targets and scripts already
exist; the primary need is connecting them to enforced validation.

**Next change:** add macOS app-hosted tests and an iOS Simulator build/test lane;
run Settings and recording UI smoke tests; execute both pinned-TLS lifecycle
paths in a suitable environment; retain logs/xcresults and a source manifest.
Use a pinned supported toolchain and explicit skip accounting. Add a separate
release-candidate lane for signed artifacts and hardware-dependent checks.

**Acceptance:** an app-only compile failure, missing environment dependency,
or pairing lifecycle regression fails an applicable required check. Physical
tests remain distinct from Simulator/emulator checks.

### 5. P2 — Current quality tests are insufficient to protect product quality

`Tests/HarcQualityTests/GoldenSampleEvaluationTests.swift:56` makes real model
tests opt-in. The real STT case uses one short fixture and a default maximum
word error rate of **0.75** (line 101). The deterministic tests primarily verify
the evaluator using prepared candidate text. The real summary case supplies
reference transcript and speaker turns, so it is not end-to-end diarization
evidence.

**Next change:** establish a consented, local evaluation corpus covering long
audio, silence, noise, accents, overlapping speakers, and mic/system mixtures.
Record model revision and configuration with measured WER, speaker errors,
hallucinations, coverage, processing time, peak memory, and output size. Set
per-scenario tolerances from measured baselines and intended product claims.

**Acceptance:** a model/dependency change cannot be released without a retained
real-output comparison; missing models in a qualification run are an open gate,
not a quality pass. Keep all inference and audio inside the approved boundary.

### 6. P2 — Security and release documentation contradict the implementation

`SECURITY.md:3` says adopted-device transport does not exist and nothing leaves
the Mac through Harc. Line 31 labels it unimplemented. In contrast, the current
project packages a relay origin and the resident runtime configures Host/Remote;
README describes Host/Client/Remote as available. README still names 0.14.3.

The current App Store preflight reports:
`OPEN App Store evidence candidate must match HarcMobile 0.14.12 (67)`.

**Next change:** reconcile the public network inventory, MCP behavior, storage,
opt-in relay metadata, and release version against shipped behavior. Make one
candidate manifest authoritative for source, version/build, artifacts, and gate
results; avoid carrying forward a green status from mutable historical prose.

**Acceptance:** public privacy/security claims match enabled code paths, and
qualification reports reject a mismatched source or artifact. Verify external
account/retention facts separately; this review did not inspect cloud accounts.

## Recommended milestones

1. **Capture and recovery integrity:** fix findings 1–3 in small changes with
   fault-injection tests. Include the load → capture → stop → publish → recover
   lifecycle, restart boundaries, ENOSPC, destination loss, and metadata errors.
2. **Enforced software baseline:** close finding 4, obtain a fresh complete
   package run plus both app builds/tests, and retain the exact results. Address
   flaky timing tests with controllable clocks where practical rather than
   treating unlimited reruns as a gate.
3. **Measured product behavior:** close finding 5; measure cold start separately
   from inference readiness and run multi-hour capture under inference load.
   Add installed-upgrade and restore/recovery drills using disposable libraries.
4. **Physical qualification:** execute the existing named iPhone matrix, a real
   secondary Mac, and two real networks against a sealed candidate. Check lock,
   interruption, device loss, revocation, reconnect, VoiceOver, and large text.
   Hardware access is required; emulator success cannot close these gates.
5. **Release closure:** reconcile finding 6; verify exact macOS signed/stapled
   bytes and update behavior; produce the exact iOS archive, screenshots, upload
   result, and owner-approved metadata. Record independent platform decisions.

Prefer a macOS reliability milestone first, then qualify Host/Client/Remote and
mobile distribution independently. Do not expand scope while the capture and
recovery defects remain open. Preserve the existing private-inference and
adopted-host architecture.

`HarcApp/AppDelegate.swift` is 5,442 lines. After lifecycle behavior has tests,
extract recording lifecycle, recovery, and mode orchestration into focused
controllers. Its size is a maintenance risk, not by itself proof of a defect;
a broad rewrite before the integrity fixes would make those fixes harder to
validate.

## Validation and limits

- Protocol schema guard passed: 7 schemas, 6 services, 27 RPCs, 29 enums.
- Repository App Store preflight completed with one open candidate-version
  evidence mismatch. Public URL verification, archive verification, and account
  state were not requested by that invocation.
- Standalone Swift fault harnesses reproduced findings 1–3. Queue metadata
  reproduction used a substitute store; overflow used the extracted production
  queue; writer reproduction used the real AVAudioFile implementation.
- Focused SwiftPM validation was attempted with two workers. Its first attempt
  could not access the compiler cache under the sandbox; a normal-cache retry
  stalled for five minutes while dependency `git status -s` subprocesses
  remained outstanding, with no test output. It was stopped. The root cause
  was not established; this is neither a passing test run nor a demonstrated
  product regression. No fresh Xcode build or aggregate test pass is claimed.
- No physical device, live capture, production relay, App Store Connect, or
  published DMG verification was performed. This report does not certify any of
  those surfaces or an exhaustive review of every module.

## Platform disposition

| Surface | Review disposition |
| --- | --- |
| Architecture | Retain; the focused module boundaries support incremental hardening |
| Current software baseline | Not certified by this review; fresh aggregate validation required |
| Next macOS release | Hold for capture/recovery findings and exact-candidate validation |
| Host/Client/Remote | Physical acceptance and current deployment evidence remain unverified |
| HarcMobile production/App Store | No-go on available evidence; candidate mismatch and physical/external gates remain open |
