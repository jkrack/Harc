# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Harc** — a macOS speech-to-text menu bar app. Records meetings quietly on a hotkey, transcribes locally on Apple Silicon, and drops the text into an always-on clipboard history for pasting into an LLM.

Status: built and runnable. Native macOS 26 (Liquid Glass) UI in `HarcUI` + `HarcApp`. Daemon-backed STT, GRDB-backed library, MLX summarization, speaker re-identification all in place.

## Hard Constraints

Non-negotiable product decisions. Flag to the user before violating.

- **Apple Silicon only** (arm64). Target macOS 26+ (Tahoe). Free use of Neural Engine, Metal, Accelerate, Core ML, Liquid Glass / `.glassEffect()`.
- **Fully local inference.** No cloud STT, no external telemetry. All audio stays on-device.
- **Menu bar resident.** Primary UI is a SwiftUI `MenuBarExtra` panel; the main library window opens on demand. Not a dock/window-first app.
- **English-first.** Multilingual is a non-goal — it unlocks the best model choice (Parakeet).

## Primary Use Case

**Long-form meeting capture → LLM paste.** The user runs Harc quietly in the menu bar during meetings (15 min to 1+ hour), stops recording at the end, and pastes the transcript into an LLM for summarization/Q&A.

Design implications — these shape every architectural decision:

- **Reliability > latency.** No one cares about live partial text. They care that an hour of meeting audio produces a complete, accurate transcript. Never lose context is the north star.
- **Toggle, not push-to-talk.** Start/stop via hotkey or menu. Visible recording indicator in the menu bar (e.g. red dot).
- **Durability is load-bearing.** Write raw audio to disk as a WAV file during recording, not only in memory. An hour of work must survive app crash, system sleep, or power loss. Worst case the user re-runs transcription on the recovered file.
- **Incremental background transcription during recording.** Not streaming to the UI — process the durable WAV in rolling ~60s chunks in the background while recording continues. Bounded memory, transcript is ~90% done the moment the user hits stop, and chunk boundaries are natural crash-recovery points.
- **Capture system audio + mic, not just mic.** Single biggest quality win for meetings. Use `ScreenCaptureKit` for system audio and `AVAudioEngine` for the mic, mix to a single WAV. Trade-off: requires Screen Recording permission.
- **Diarization on by default.** Speaker labels (`Speaker 1:`, `Speaker 2:`) massively improve what a downstream LLM can do with the transcript.
- **VAD gating.** Meeting audio from the user's mic is typically 40–70% silence. Voice-activity detection cuts transcription work sharply with no quality loss. Silero or FluidAudio's built-in.

## Engine Approach

The STT engine is a **separate Swift executable** that runs as a long-lived daemon, not an in-process library. The app launches it on demand and talks to it over IPC. This keeps model load cost amortized across recordings, isolates model/audio crashes from the UI, and lets the engine shut itself down when idle.

Reference pattern (from prior work in `/Users/jlane/GitHub/OpenBrain/swift/openbrain-stt/`):

- SwiftPM executable target, `.macOS(.v26)`.
- **Model:** [FluidAudio](https://github.com/FluidInference/FluidAudio) running Parakeet TDT 0.6B v3 on ANE/Metal via Core ML. Pre-loaded in the background on daemon startup so the first request isn't blocked by cold load.
- **IPC:** Unix domain socket at `~/.harc/stt.sock`, newline-delimited JSON — one request per line, one response per line.
- **Requests:** `transcribe` (file path for the durable WAV; options for timestamps, diarize, language), `status`, `shutdown`. Base64 audio is supported but file paths are the primary path given durable recording.
- **Responses:** `result` (text + speaker segments + word timestamps + processing_ms), `status`, `error`.
- **Lifecycle:** pre-load model on start → accept loop → idle-timeout self-shutdown (30 min default) → clean socket on SIGTERM/SIGINT.

Harc implements its own version — own binary (`harc-stt`), own socket path, free to diverge on protocol. Must verify FluidAudio handles hour-long audio gracefully; if not, the daemon chunks with overlap and stitches at boundaries.

## Harc-Specific Architecture (planned)

1. **Menu bar app** — SwiftUI `MenuBarExtra` panel. Owns daemon lifecycle as a child process. Recording state visible in the menu bar icon.
2. **Audio capture** — `AVAudioEngine` (mic) + `ScreenCaptureKit` (system audio), mixed and written to a rolling WAV in a local cache directory (`~/Library/Caches/Harc/recordings/<uuid>.wav`). Atomically moved to the user-chosen destination folder on successful stop (see Recording Storage below).
3. **Background transcription worker** — while recording, feed completed ~60s chunks of the WAV to the daemon. Accumulate results. On stop, flush the final chunk and assemble.
4. **Global hotkey** — toggle start/stop. Requires Accessibility or Input Monitoring entitlement.
5. **Clipboard history** — persistent, searchable, pinnable store of transcripts. GRDB/SQLite indexes transcripts and points at the on-disk files; the main library window shows a list and copies the full transcript on select.
6. **Paste behavior** — copy full transcript to pasteboard; optional auto-paste into the frontmost app.

## Recording Storage

User-configurable destination folder with date-based organization. The user picks a folder in Settings; Harc writes every recording there with a predictable hierarchy.

**Layout:**

```
<destination-folder>/
  YYYY/
    YYYY-MM-DD/
      HH-mm-ss.wav          # raw mixed audio
      HH-mm-ss.txt          # plain transcript (pasteboard-ready)
      HH-mm-ss.json         # transcript + word timestamps + diarization + metadata
```

The doubled year in the date folder keeps each day's directory self-identifying if it's copied, emailed, or moved out of context.

**Default destination:** `~/Documents/Harc/`. User-visible so files are easy to find without digging through `~/Library`.

**Write strategy — record local, move on stop:** the rolling WAV is always written to `~/Library/Caches/Harc/recordings/<uuid>.wav` during recording. On successful stop, it's atomically moved into the destination folder. This protects against iCloud/Dropbox sync latency, external-drive disconnects, and slow network volumes during a live recording.

**Sandbox note:** if distribution ever moves to the Mac App Store, arbitrary destination folders require security-scoped bookmarks rather than plain path strings. For notarized direct distribution, a `URL` path persisted in `UserDefaults` is sufficient.

## UI

The UI is native SwiftUI on macOS 26. There is no custom design system — `HarcBrand` (in `Sources/HarcUI/HarcBrand.swift`) is the entire palette: a recording-red `live` color and a brand `gradient` for the app icon and About panel. Everything else uses `Color.accentColor`, `Color.primary` / `.secondary`, system materials, system fonts, and Liquid Glass via `.glassEffect()`.

Surfaces:
- `HarcWindowRootView` — the primary window. `NavigationSplitView` with a sidebar of recordings (grouped by Pinned / Today / Yesterday / This Week / month buckets), a detail pane (transcript + summary), and an `Inspector` (speaker editor + file metadata).
- `MenuBarPanelView` — the slim `MenuBarExtra.window`-style panel: recording state line, level bars, Start/Stop, Open Library, and a 30-second post-stop tray with Copy and Paste-into-frontmost-app buttons.
- `HarcSettingsForm` — a single `Form` with grouped Sections, hosted in the SwiftUI `Settings {}` scene.
- `TranscriptEditorView` — a separate window for editing transcript text, with a native `.toolbar` and the same Inspector sections as the main window.
- `HarcAppBridge` — the small observable that wires `RecordingState`, `PostStopTrayState`, frontmost-app name, scope-history FFT, and the panel actions through to the SwiftUI scene.

## Open Decisions

Capture the *why* here when these get resolved:

- **Chunking strategy.** Fixed 60s windows vs VAD-aligned windows vs FluidAudio's native long-form handling — depends on what FluidAudio/Parakeet tolerates.
- **Recording format.** WAV 16kHz mono is the model's native rate; writing that directly avoids resampling. Confirm ScreenCaptureKit → 16kHz mono mix is clean.
- **Clipboard-history storage.** GRDB/SQLite is the default assumption. Pending confirmation.
- **File naming.** `HH-mm-ss.wav` is the default; optional meeting-name slug (e.g. `HH-mm-ss-standup.wav`) TBD — editable after the fact, or prompted on stop?
- **Hotkey library.** MASShortcut, KeyboardShortcuts (sindresorhus), or raw Carbon `RegisterEventHotKey`.
- **Diarization quality.** FluidAudio's diarizer vs a separate pyannote-style model — confirm it's good enough on meeting audio before building UI around it.
- **Distribution.** Notarized `.app` direct download, Homebrew cask, or both.

## Build & Run

To be documented once the project is scaffolded. Expected shape: top-level SwiftPM workspace or Xcode project with two targets — `Harc` (menu bar app) and `harc-stt` (STT daemon executable, embedded in the app bundle).
