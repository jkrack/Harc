# AGENTS.md

Guidance for Codex when working in this repository.

## Project

**Harc** is a local-first macOS speech-to-text app. It lives in the menu bar,
captures long meetings, transcribes on Apple Silicon, stores recordings and
transcripts in a searchable library, and prepares context for LLM paste workflows.

The repo is no longer greenfield. Treat the current SwiftPM/Xcode project as
authoritative.

## Hard Constraints

Flag the user before violating these product decisions.

- **Local inference only.** No cloud STT, no external telemetry, no off-device
  audio processing.
- **Apple Silicon first.** The package currently targets macOS v26 in
  `Package.swift`; verify deployment-target changes against `project.yml`.
- **Menu bar resident.** The primary recording surface is the status item and
  compact panel, with the Library as the fuller workspace.
- **Long-form reliability over live latency.** Durable audio and recoverable
  stop/failure states matter more than live partial transcript UI.

## Architecture Map

- `HarcApp/` contains the macOS app shell, app delegate, entitlements, window
  controllers, and asset catalogs.
- `Sources/HarcCore/` defines shared IPC, version, runtime log, and vocabulary
  types.
- `Sources/HarcSTT/` is the `harc-stt` executable daemon. It receives IPC
  requests and uses FluidAudio for transcription, VAD, diarization, and stitching.
- `Sources/HarcClient/` launches and talks to the daemon, chunks WAV files,
  assembles transcript output, writes sibling transcript files, and handles
  vocabulary replacement.
- `Sources/HarcAudio/` captures microphone/system audio, mixes levels, writes
  WAV files, and manages recording destinations.
- `Sources/HarcStore/` owns the GRDB-backed library, people, recovery queue,
  cache recovery, and migrations.
- `Sources/HarcUI/` contains SwiftUI/AppKit-facing state and views, including
  the menu bar panel, Library, settings, local-stack readiness, recovery inbox,
  transcript editor, and speaker identity UI.
- Dictation (`docs/dictation-plan.md`): `DictationController` in
  `Sources/HarcUI/` drives mic-only capture (`MicDictationRecorder` in
  `Sources/HarcAudio/`, temp WAV in `~/Library/Caches/Harc/dictation/`), a
  one-shot `dictate()` to the daemon, and insert-at-cursor via
  `FrontmostAppPaster`.
- `Sources/HarcSummarize/`, `Sources/HarcModels/`, `Sources/HarcExport/`,
  `Sources/HarcMeetingDetect/`, and `Sources/HarcVoiceprint/` cover optional AI
  summaries, model management, export formats, meeting detection, and speaker
  embeddings.

## Reliability Rules

- Recording starts in `~/Library/Caches/Harc/recordings/` and finalizes into the
  user-visible destination hierarchy.
- Recovery is product-critical. `RecoveryQueue` persists artifacts in
  Application Support and scans cache WAVs into recoverable inbox rows.
- A recovery artifact's source path is its durable scan identity. Do not recreate
  duplicate pending rows for the same cache file after metadata changes,
  especially if the user already discarded or failed it.
- Capture readiness should distinguish blocked recording requirements from
  degraded quality and optional AI features. Missing destination/microphone/STT
  can block recording; missing summaries/search/paste helpers must not make core
  capture look broken.
- System audio denial is degraded "mic only" capture, not a hard block.
- Dictation clips in `~/Library/Caches/Harc/dictation/` are disposable — never
  route them into the recording recovery inbox. `DictationCacheCleaner` deletes
  orphans.

## Common Validation

Run focused tests for the surface you changed, then broaden only as risk
requires.

    swift test --filter RecordingCacheRecoveryTests
    swift test --filter LocalStackHealthTests
    swift test --filter CustomerExperienceE2ETests
    swift test

After changing package/project/version metadata, run:

    xcodegen generate

For local release artifacts, use:

    ./scripts/build-local.sh

## Documentation

Keep this file current when repository structure, build tooling, validation
commands, or non-negotiable product constraints change. Prefer documenting the
behavioral invariant and the validation command over copying implementation
details that will drift quickly.
