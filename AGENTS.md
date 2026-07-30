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
- **Never silently drop transcript audio.** Chunk failures retry with
  backoff (all errors, not just model_not_loaded); exhausted chunks become
  visible in-transcript markers + `ChunkedTranscriber.failedRanges`, never
  a silent hole. Empty-under-VAD chunks with audible energy get one no-VAD
  retry. A change that can discard a chunk without a marker is a bug.
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

**Known flaky suites — all timing-based, all load-induced.** Under the full
parallel suite these intermittently fail, and take 15–30 s for work that runs
in ~0.1 s alone; that time ratio is the tell. Observed together on 2026-07-25:

- `SummarizationQueue` / `SummarizationQueueStore`
- `PostStopTrayState` (TTL auto-fade)
- `DictationKeepWarmController` (ping counts)
- `LibraryMaintenanceStore` ("indexing clears the index backlog")

Re-run the named suite alone before treating one as a regression:

    swift test --filter "SummarizationQueue|PostStopTrayState|DictationKeepWarm"

**`swift test` does not cover `HarcApp/`.** AppDelegate, the window
controllers and the NSPanel HUD compile only in the Xcode app target, so a
green package suite says nothing about them. Always finish with an
`xcodebuild` before calling the tree green.

**Neither tests nor the compiler catch a missing `@EnvironmentObject`.** It is
a runtime `assertionFailure` — a SIGTRAP in Release. A crash of exactly this
kind shipped into `main` and survived a 686-test green run because nothing
constructs the SwiftUI `Settings` scene. When a view gains an environment
dependency, add it to `harcSettingsEnvironment(...)` rather than to one call
site, and open the pane in a real build.

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

`build-release.sh` produces only the DMG; the `.zip` in step 3 is a manual
`ditto -c -k --sequesterRsrc` of the **stapled** DMG. Every published release
so far carries both assets.

Ordering hazard in steps 6–7: the appcast is served from `main`, so pushing
publishes an update feed pointing at a release asset that does not exist yet.
Existing users' Sparkle clients will see the new version and fail to download
it until step 7 lands. Do them back to back, or create the release first.

### Releases can only be cut from the Mac that holds the keys

Three credentials are machine-bound and none of them are in this repo:

- the **Developer ID Application** certificate + private key (login keychain)
- the **`harc-notary`** notarytool profile (login keychain)
- the **Sparkle EdDSA private key** (login keychain, service
  `https://sparkle-project.org`, account `ed25519`)

A second Mac can clone, build, test and run `build-local.sh` (ad-hoc) with no
setup, but cannot notarize or produce a valid appcast signature until those
are exported to it. The Sparkle key in particular has no recovery path — lose
it and existing installs can never be updated again, because Sparkle pins the
public key. Back it up before it is ever needed.

## Verifying UI changes on screen

The computer-use MCP **cannot see Harc**. `request_access` reports
`not_installed` for the app, the bundle ID and the full path, because Harc is
`LSUIElement=1` and the enumeration skips menu-bar agents — and with native
screenshot filtering, Harc is composited out of every MCP screenshot.

What works instead, from an ordinary shell:

- **Observe:** `screencapture -x -R x,y,w,h out.png`, then read the PNG.
  Unfiltered, and it captures the menu-bar panel.
- **Drive:** `osascript` + System Events. Settings panes switch via
  `set selected of row N of outline 1 of scroll area 1 of group 1 of
  splitter group 1 of group 1 of window "<pane>"`; the panel toggles via
  `click menu bar item 1 of menu bar 2`.
- **Scroll and click:** System Events has no scroll verb and `click at` is
  unreliable. Compile a small `CGEvent` helper — the panel and Settings panes
  only respond to real wheel events.
- The Settings window's title is the **selected pane name**, not "Harc
  Settings", so address windows by current pane.

Do not read accessibility labels through AppleScript's `description`: it
returns the *role* ("button") for SwiftUI controls, which reads as a missing
label when one is present. Query `AXDescription` via the AX API directly.

## v0.9.0 UI overhaul — structural facts agents must know

- There is **no TranscriptEditor window**. `Sources/HarcUI/TranscriptEditor/`
  is gone; the Library detail pane edits in place via
  `TranscriptDetailEditor` + `TranscriptDocument` (loader/saver, OKF-aware).
  `WordIndex`, `TranscriptAudioPlayer`, `TranscriptFind` live at the top of
  `Sources/HarcUI/`.
- `LibrarySelection` has a `.live` case for the in-progress recording. It is
  never persisted and never restorable — `PersistedLibrarySelection` refuses
  it and the resolver invalidates it.
- Design tokens are mandatory (`Sources/HarcUI/DesignSystem/`): five type
  roles (`.harcTitle/Body/Label/Caption/Mono`), status colors only via
  `Color.harc(_:)`, spacing via `HarcSpacing`. Deliberate exceptions carry
  `// token-exempt:`. Grep-audit before declaring UI work done.
- The menu-bar panel must never scroll. New conditional surfaces go behind
  the status row into `ActivityView`, not into the panel.
- Readiness/recovery have one renderer: `ActivityView`. Do not add a second;
  that is how the `pendingRecoveryCount: 0` suppression hack was born.

## Documentation

Keep this file current when repository structure, build tooling, validation
commands, or non-negotiable product constraints change. Prefer documenting the
behavioral invariant and the validation command over copying implementation
details that will drift quickly.
