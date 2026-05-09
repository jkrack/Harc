# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Harc** — a macOS speech-to-text menu bar app. Records meetings quietly on a hotkey, transcribes locally on Apple Silicon, and drops the text into an always-on clipboard history for pasting into an LLM.

The app is built and runnable: menu bar shell, daemon-backed STT, mic + system-audio capture, GRDB-backed library, settings, transcript editor, and on-device summarization are all in place. Active dev surface is speaker re-identification (real ECAPA-TDNN replacing the stub) and distribution (notarized direct-download).

## Hard Constraints

Non-negotiable product decisions. Flag to the user before violating.

- **Apple Silicon only** (arm64). Target macOS 14+. Free use of Neural Engine, Metal, Accelerate, Core ML.
- **Fully local inference.** No cloud STT, no external telemetry. All audio stays on-device.
- **Menu bar resident.** Primary UI is an `NSStatusItem` with a popover/panel. Not a dock/window-first app.
- **English-first.** Multilingual is a non-goal — it unlocks the best model choice (Parakeet).

## Primary Use Case

**Long-form meeting capture → LLM paste.** The user runs Harc quietly in the menu bar during meetings (15 min to 1+ hour), stops recording at the end, and pastes the transcript into an LLM for summarization/Q&A.

Design implications — these shape every architectural decision:

- **Reliability > latency.** No one cares about live partial text. They care that an hour of meeting audio produces a complete, accurate transcript. Never lose context is the north star.
- **Toggle, not push-to-talk.** Start/stop via hotkey or menu. Visible recording indicator in the menu bar (e.g. red dot).
- **Durability is load-bearing.** Write raw audio to disk as a WAV file during recording, not only in memory. An hour of work must survive app crash, system sleep, or power loss. Worst case the user re-runs transcription on the recovered file.
- **Incremental background transcription during recording.** Not streaming to the UI — process the durable WAV in rolling ~60s chunks in the background while recording continues. Bounded memory, transcript is ~90% done the moment the user hits stop, and chunk boundaries are natural crash-recovery points.
- **Capture system audio + mic, not just mic.** Single biggest quality win for meetings. `ScreenCaptureKit` for system audio + `AVAudioEngine` for the mic, mixed to a single WAV. Trade-off: requires Screen Recording permission.
- **Diarization on by default.** Speaker labels (`Speaker 1:`, `Speaker 2:`) massively improve what a downstream LLM can do with the transcript.
- **VAD gating.** Meeting audio from the user's mic is typically 40–70% silence. Voice-activity detection cuts transcription work sharply with no quality loss. Currently FluidAudio's built-in.

## Build & Run

Requires Xcode 15.4+ and Homebrew. Apple Silicon only.

```sh
brew install xcodegen

# SwiftPM-only loop (fast iteration on libraries + daemon)
swift test                                # all targets
swift test --filter HarcCoreTests         # one target
swift build -c release --product harc-stt --arch arm64

# App target (regenerate the Xcode project from project.yml first)
xcodegen generate
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
open Harc.xcodeproj                       # for interactive dev

# Local distributable .app + .dmg (ad-hoc signed)
scripts/build-local.sh                    # → build/local-dist/Harc.{app,dmg}
```

The Xcode build runs `scripts/build-daemon.sh` as a post-compile step. That script rebuilds `harc-stt` into `.build-daemon/` and copies + codesigns it into `Harc.app/Contents/MacOS/harc-stt`. If you rename the daemon target or change its Package.swift product, update that script too.

CI (`.github/workflows/ci.yml`) runs `swift test` and an unsigned Debug Xcode build, then verifies `harc-stt --version` from the produced bundle.

## Repository Layout

Two top-level Swift surfaces:

- `Sources/` — SwiftPM library + executable targets (Package.swift). All shared code lives here.
- `HarcApp/` — the macOS app target (managed by `project.yml` → `xcodegen` → `Harc.xcodeproj`). Thin: `AppDelegate`, `WindowControllers/`, and tiny glue. Real UI lives in the `HarcUI` SwiftPM module.

SwiftPM modules, by role:

| Module | Role |
|---|---|
| `HarcCore` | IPC types: `IPCRequest`, `IPCResponse`, `TranscribeResult`, word/speaker timestamps. Shared by app + daemon. |
| `HarcModels` | Recording domain models. |
| `HarcAudio` | Mic + system-audio capture, mixer, durable WAV writer, level metering, `RecordingSession`, `RecordingDestination`. |
| `HarcClient` | Daemon launcher, IPC client, chunked transcriber, WAV chunker, transcript assembly + file writes. |
| `HarcSTT` | The `harc-stt` executable. `Daemon`, `Transcriber` (FluidAudio wrapper), `Diarizer`, `SocketServer`, signal handlers. |
| `HarcStore` | GRDB-backed `RecordingStore`, append-only migrations (currently v1–v8), FTS5 transcript search, speaker-embeddings table. |
| `HarcSummarize` | On-device summarization via MLX-LLM + HuggingFace. |
| `HarcMeetingDetect` | Heuristics for "is the user in a meeting". |
| `HarcVoiceprint` | Speaker embeddings (currently `StubSpeakerEmbedder`; real ECAPA-TDNN is the active dev item). |
| `HarcExport` | Transcript export/serialization. |
| `HarcUI` | All SwiftUI: popover, recording controls, library, transcription detail, transcript editor, settings tabs, summary cards, design tokens. |

Test targets mirror module names (`HarcCoreTests`, `HarcSTTTests`, etc.).

## Architecture

### Daemon model

The STT engine is a **separate Swift executable** (`harc-stt`) launched as a child process by the app, not an in-process library. Model load cost is amortized across recordings, model/audio crashes are isolated from the UI, and the engine self-shuts when idle.

- **IPC:** Unix domain socket at `~/.harc/stt.sock`, newline-delimited JSON. One request → one response per connection.
- **Requests:** `transcribe` (file path; options for timestamps, diarize, language), `status`, `shutdown`. Base64 audio is supported but file paths are the primary path given durable recording.
- **Responses:** `result` (text + speaker segments + word timestamps + processing_ms), `status`, `error`.
- **Model:** [FluidAudio](https://github.com/FluidInference/FluidAudio) running Parakeet TDT 0.6B v3 on ANE/Metal via Core ML. Pre-loaded on daemon start so the first request isn't blocked by cold load.
- **Lifecycle:** pre-load model → accept loop → 30 min idle-timeout self-shutdown → unlink socket on SIGTERM/SIGINT.
- **Daemon entry:** [Sources/HarcSTT/HarcSTTCLI.swift](Sources/HarcSTT/HarcSTTCLI.swift), `Daemon.run()` in [Sources/HarcSTT/Daemon.swift](Sources/HarcSTT/Daemon.swift).
- **App-side launch:** [Sources/HarcClient/DaemonLauncher.swift](Sources/HarcClient/DaemonLauncher.swift) — checks socket liveness, spawns child `Process` if dead, waits up to 60s for the socket. Daemon stdout/stderr → `~/Library/Caches/Harc/daemon.log`.
- **App-side IPC:** [Sources/HarcClient/HarcSTTClient.swift](Sources/HarcClient/HarcSTTClient.swift) — open-send-read-close roundtrip per call.

### Audio pipeline

Capture and durable storage in [`Sources/HarcAudio/`](Sources/HarcAudio):

- **`MicCapture`** — `AVAudioEngine` tap, async stream of PCM buffers in hardware-native format.
- **`SystemAudioCapture`** — `ScreenCaptureKit` `SCStream`, async stream of system-audio PCM.
- **`AudioMixer`** — resamples both streams to 16 kHz mono, weighted sum (mic 0.7, system 0.3).
- **`AudioFileWriter`** — incremental 16 kHz mono Int16 WAV with periodic fsync (5s).
- **`LevelComputer`** — RMS (dBFS) + 5-band FFT for menu-bar bars and silence detection.
- **`RecordingSession`** — orchestrator. Starts mic + system, pumps the mix into the writer, hands the growing WAV to the chunked transcriber.

### Transcription during recording

[`Sources/HarcClient/ChunkedTranscriber.swift`](Sources/HarcClient/ChunkedTranscriber.swift) polls the growing WAV every ~2s, slices off completed 60s chunks via `WAVChunker`, sends each to the daemon. On stop, the tail chunk is flushed and segments are assembled. Transcript ends up `~90%` done the moment the user hits stop.

### Storage

**Recordings on disk** ([`Sources/HarcAudio/RecordingDestination.swift`](Sources/HarcAudio/RecordingDestination.swift)):

```
<destination-folder>/
  YYYY/
    YYYY-MM-DD/
      HH-mm-ss.wav          # raw 16 kHz mono mixed audio
      HH-mm-ss.txt          # plain transcript (pasteboard-ready)
      HH-mm-ss.json         # transcript + word timestamps + diarization + metadata
```

The doubled year in the date folder keeps each day's directory self-identifying if it's copied, emailed, or moved out of context. Default base: `~/Documents/Harc/`. Filename collisions get `-1`, `-2`, … appended.

**Write strategy — record local, then move on stop.** The rolling WAV is always written to `~/Library/Caches/Harc/recordings/<uuid>.wav` during recording. On successful stop, it's atomically moved (`replaceItemAt`) into the destination folder. This protects against iCloud/Dropbox sync latency, external-drive disconnects, and slow network volumes during a live recording. **If the app crashes mid-recording, the cached WAV is the recovery artifact** — point a manual transcribe at it.

**Sandbox note:** if distribution ever moves to the Mac App Store, arbitrary destination folders require security-scoped bookmarks rather than plain path strings. For notarized direct distribution (current target), a `URL` path persisted in `UserDefaults` is sufficient.

**Library DB:** GRDB/SQLite at `~/Library/Application Support/Harc/Harc.db`. Schema in [`Sources/HarcStore/DatabaseMigrator+Harc.swift`](Sources/HarcStore/DatabaseMigrator+Harc.swift). FTS5 over transcript text (Porter tokenizer over unicode61). The DB indexes recordings and stores derived data (titles, tags, speaker names, embeddings, summaries); the audio + transcript files on disk are the source of truth.

### App shell

- **Entry:** [`HarcApp/AppDelegate.swift`](HarcApp/AppDelegate.swift) wires up the `NSStatusItem`, popover, daemon launcher, store, summarization queue, and global hotkey listener.
- **Hotkey:** [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts). Definitions in [`Sources/HarcUI/HotkeyNames.swift`](Sources/HarcUI/HotkeyNames.swift).
- **Window controllers** ([`HarcApp/WindowControllers/`](HarcApp/WindowControllers)): Settings (6 tabs), Library (search, pin, rename, delete), TranscriptionDetail (view + summary + speaker labels), TranscriptEditor (direct text edits).
- **Popover:** [`Sources/HarcUI/PopoverRootView.swift`](Sources/HarcUI/PopoverRootView.swift) — start/stop, live levels, post-stop tray with copy/paste.

## Non-obvious conventions

- **Audio format is an invariant.** Everything downstream of the mixer assumes 16 kHz mono Int16 WAV — Parakeet's native rate, no resampling on the daemon side. Changing `AudioFileWriter`'s output format requires updating the daemon's FluidAudio call and the chunker.
- **Chunking is fixed 60s windows.** Decided over VAD-aligned or FluidAudio long-form because FluidAudio's tolerance for hour-long input wasn't proven at the time and fixed windows give cleaner crash-recovery boundaries. Default in `ChunkedTranscriber`.
- **GRDB migrations are append-only.** Currently v1 → v8. Never delete or reorder; add v9. Earlier versions adjusted FTS scope (v4 narrowed to transcript-only) and added speaker embeddings, summaries, tags.
- **Daemon binary lookup is multi-path.** `DaemonLauncher` resolves in order: app bundle (`Contents/MacOS/harc-stt`) → `HARC_STT_BINARY` env var → `.build/debug/harc-stt` (test fallback). When developing the daemon outside the app, set `HARC_STT_BINARY` so the app finds your local build.
- **Speaker embedder is stubbed.** `StubSpeakerEmbedder` returns deterministic placeholder vectors. The schema and UI assume a real ECAPA-TDNN; don't ship features that depend on cross-recording speaker identity until that's swapped in.
- **Entitlements** ([`HarcApp/Harc.entitlements`](HarcApp/Harc.entitlements)) include `device.audio-input` and `cs.disable-library-validation` (the latter to load FluidAudio's `.dylib` without a full entitlement chain — fine for ad-hoc local builds, revisit before notarized distribution).
- **`AGENTS.md` exists** for Codex but is currently a stale duplicate of an earlier CLAUDE.md. Don't trust it; trust this file.

## Open Decisions

Capture the *why* here when these get resolved.

- **Speaker re-identification.** Real ECAPA-TDNN model + cross-recording speaker linking (the embeddings table is sized for it, but only the stub embedder is wired up).
- **Editable filename slug.** `HH-mm-ss.wav` is fixed at write time; an optional meeting-name slug (`HH-mm-ss-standup.wav`) editable post-hoc or prompted on stop is still TBD.
- **Distribution.** Notarized `.app` direct download is the current target; `build-local.sh` produces ad-hoc signed artifacts only. Homebrew cask is on the table.
- **Diarization quality bar.** FluidAudio's diarizer is on by default, but whether it's good enough on noisy multi-speaker meetings to anchor downstream UX (vs. swapping in a pyannote-style model) is an empirical question.
