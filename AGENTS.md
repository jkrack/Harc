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
- Dictation (`docs/dictation-plan.md`): Push-to-talk via `KeyboardShortcuts`. 
  `DictationController` in `Sources/HarcUI/` owns the state machine. Mic-only 
  capture via `MicDictationRecorder` + `AudioFileWriter` (temp WAV in 
  `~/Library/Caches/Harc/dictation/`), warm daemon transcription (`dictate()` 
  wrapper, no VAD/diarization), and insert-at-cursor via `FrontmostAppPaster`. 
  `DictationModeStore` holds built-in + user modes (name, icon, prompt, model, 
  per-mode hotkey, context toggles). `SummarizerService.transform()` post-processes 
  via LLM modes. `DictationHistoryStore` logs recent dictations. `DictationHUDView` 
  (NSPanel, non-activating) shows live waveform + status. `DictationKeepWarmController` 
  pings daemon to prevent idle shutdown. Mutual-exclusion guard vs recording.
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

**Known flaky tests:** `SummarizationQueueStoreTests.isQueued` and 
`RecordingSessionTests` (duty-cycle) pass in isolation but occasionally fail 
when run in the full suite. Run individually if suspect:

    swift test --filter SummarizationQueueStoreTests.isQueued
    swift test --filter RecordingSessionTests

After changing package/project/version metadata, run:

    xcodegen generate

For local release artifacts, use:

    ./scripts/build-local.sh

### Package.resolved churns during releases — that is expected

`Harc.xcodeproj` sits in the same directory as `Package.swift`, so Xcode
never creates its own `xcshareddata/swiftpm/Package.resolved` — both tools
share the root one and disagree about a single pin:

- `swift build` / `swift test` resolve from `Package.swift` → **no Sparkle**
- `xcodebuild` (i.e. `build-release.sh`) also sees `project.yml` → **adds Sparkle**

Whichever ran last wins, so the file cannot be clean for both. The committed
state is deliberately the **SwiftPM version, without the Sparkle pin**,
because everyday `swift build`/`swift test` then leaves it untouched and only
a release build dirties it.

So: a `Package.resolved` diff that only adds Sparkle is a release-build
artifact — **leave it out of the commit** (`git checkout Package.resolved`).
Do not "fix" it by committing the Sparkle pin; that inverts the noise onto
every test run. Sparkle's version is pinned by `from:` in `project.yml`,
and the framework is embedded and signed from there, so nothing about the
shipped build depends on that pin being present here.

## Release Ritual

Releases auto-install via Sparkle, so the appcast must be updated with a
signed entry for every release — in this order:

1. Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`,
   run `xcodegen generate`, build with `./scripts/build-release.sh`
   (Developer ID + hardened runtime + secure timestamps). Do NOT ship
   `build-local.sh` output — it is ad-hoc signed and not notarizable.
2. Notarize and staple, in that order:
   `xcrun notarytool submit build/release-dist/Harc-<version>.dmg --keychain-profile harc-notary --wait`
   then `xcrun stapler staple build/release-dist/Harc-<version>.dmg`.
   Confirm with `spctl -a -vvv -t install build/release-dist/Harc.app`
   → expect `source=Notarized Developer ID`.
3. Copy the **stapled** DMG to `Harc-local.dmg` (the asset name every
   appcast enclosure points at) and zip it to `Harc-local-dmg.zip`.
   Stapling rewrites the DMG, so it must happen before signing — the
   signature must cover the exact bytes that get uploaded.
4. Sign that DMG and get the appcast entry:
   `./scripts/make-appcast.sh <version> <build> build/release-dist/Harc-local.dmg`
   (EdDSA private key lives in the login Keychain, service
   "https://sparkle-project.org"; sign_update may prompt — Always Allow).
5. Insert the printed `<item>` at the top of `appcast.xml`'s `<channel>`.
6. Commit (including `appcast.xml`), tag `vX.Y.Z`, push main + tag. The
   appcast is served from main via raw.githubusercontent — pushing main
   publishes it.
7. `gh release create vX.Y.Z --latest` attaching BOTH
   `build/release-dist/Harc-local-dmg.zip` and `Harc-local.dmg` — the
   appcast enclosure points at the release's `Harc-local.dmg` asset, so
   the uploaded DMG must be the exact bytes signed in step 4.

## Documentation

Keep this file current when repository structure, build tooling, validation
commands, or non-negotiable product constraints change. Prefer documenting the
behavioral invariant and the validation command over copying implementation
details that will drift quickly.
