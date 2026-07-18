# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Harc** — a macOS speech-to-text menu bar app with two surfaces. (1) Meeting capture: start recording on toggle-hotkey, transcribe diarized audio in background, save to searchable library, paste into LLM. (2) Dictation: hold hotkey, speak, release to insert text at cursor with optional AI mode (Clean-up, Email, Message, Answer, etc.) — all local.

Status: v0.4.1, shipped and stable. Native macOS 26 (Liquid Glass) UI in `HarcUI` + `HarcApp`. Daemon-backed STT (Parakeet), GRDB-backed library, MLX summarization, speaker re-identification, push-to-talk dictation with modes all in place.

## Hard Constraints

Non-negotiable product decisions. Flag to the user before violating.

- **Apple Silicon only** (arm64). Target macOS 26+ (Tahoe). Free use of Neural Engine, Metal, Accelerate, Core ML, Liquid Glass / `.glassEffect()`.
- **Fully local inference.** No cloud STT, no external telemetry. All audio stays on-device.
- **Menu bar resident.** Primary UI is a SwiftUI `MenuBarExtra` panel; the main library window opens on demand. Not a dock/window-first app.
- **English-first.** Multilingual is a non-goal — it unlocks the best model choice (Parakeet).

## Primary Use Cases

### 1. Long-form meeting capture → LLM paste

The user runs Harc quietly in the menu bar during meetings (15 min to 1+ hour), stops recording at the end, and pastes the transcript into an LLM for summarization/Q&A.

Design implications:

- **Reliability > latency.** No one cares about live partial text. They care that an hour of meeting audio produces a complete, accurate transcript. Never lose context is the north star.
- **Toggle, not push-to-talk.** Start/stop via hotkey or menu. Visible recording indicator in the menu bar (e.g. red dot).
- **Durability is load-bearing.** Write raw audio to disk as a WAV file during recording, not only in memory. An hour of work must survive app crash, system sleep, or power loss. Worst case the user re-runs transcription on the recovered file.
- **Incremental background transcription during recording.** Not streaming to the UI — process the durable WAV in rolling ~60s chunks in the background while recording continues. Bounded memory, transcript is ~90% done the moment the user hits stop, and chunk boundaries are natural crash-recovery points.
- **Capture system audio + mic, not just mic.** Single biggest quality win for meetings. Use `ScreenCaptureKit` for system audio and `AVAudioEngine` for the mic, mix to a single WAV. Trade-off: requires Screen Recording permission.
- **Diarization on by default.** Speaker labels (`Speaker 1:`, `Speaker 2:`) massively improve what a downstream LLM can do with the transcript.
- **VAD gating.** Meeting audio from the user's mic is typically 40–70% silence. Voice-activity detection cuts transcription work sharply with no quality loss. FluidAudio's built-in VAD is used.

### 2. Push-to-talk dictation with AI modes

The user holds a hotkey, speaks, releases to insert the transcribed text at the cursor in any app. Modes allow AI post-processing (Clean-up, Email, Message, Bullet List, Answer with context awareness, or custom).

Design implications:

- **Sub-second latency on warm path.** Daemon stays warm; no model cold-load. User expects instant insertion.
- **Mic-only capture.** No system audio needed for short clips. `MicCapture` + brief `AudioFileWriter` temp WAV to `~/Library/Caches/Harc/dictation/`.
- **Non-activating HUD.** The floating panel (NSPanel, `.nonactivatingPanel`) shows live waveform and status but never steals focus. Synthetic Cmd-V via `FrontmostAppPaster` inserts into the frontmost app.
- **Modes reuse warm summarizer.** LLM post-processing (modes) shares the single resident `SummarizerService` to avoid model thrash. Mode default model = active summarizer model.
- **Mutual exclusion with recording.** Dictation and meeting recording share mic and daemon. Guard via `RecordingState.isRecording`; refuse to start if either is active.

## Engine Approach

The STT engine is a **separate Swift executable** that runs as a long-lived daemon, not an in-process library. The app launches it on demand and talks to it over IPC. This keeps model load cost amortized across recordings, isolates model/audio crashes from the UI, and lets the engine shut itself down when idle.

The daemon follows this shape:

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
- **Meeting Library Window:** `HarcWindowRootView` — the primary window. `NavigationSplitView` with a sidebar of recordings (grouped by Pinned / Today / Yesterday / This Week / month buckets), a detail pane (transcript + summary), and an `Inspector` (speaker editor + file metadata).
- **Menu-bar Panel:** `MenuBarPanelView` — the slim `MenuBarExtra.window`-style panel: recording state line, level bars, Start/Stop, Open Library. Includes a dictation mode pill and recent dictation history. 30-second post-stop tray (for recordings) with Copy and Paste buttons.
- **Dictation HUD:** `DictationHUDView` — a non-activating `NSPanel` (Liquid Glass pill) positioned above the Dock on the pointer's screen. Shows live waveform (listening) or status text (other phases), status dot, active-mode chip with shortcut, context indicator, and stop/cancel buttons.
- **Dictation History Window:** `DictationHistoryWindowView` — searchable window over recent dictations (voice-vs-AI toggle when a mode transformed the text). Copy and re-process actions (re-process is copy-only by design — the window is key, so a synthetic paste would land in Harc itself).
- **Settings:** `HarcSettingsForm` — a `Form` with grouped Sections:
  - Recording settings (destination, hotkey, auto-paste guard)
  - Dictation settings (hotkey, HUD position, keep-warm toggle, insertion behavior)
  - Modes settings (list, create/edit modes, per-mode hotkeys, model picker)
  - Models (download/manage STT and summarizer tiers)
- **Transcript Editor:** `TranscriptEditorView` — a separate window for editing transcript text, with a native `.toolbar` and Inspector sections.
- **App Bridge:** `HarcAppBridge` — the observable that wires `RecordingState`, `PostStopTrayState`, `DictationState`, frontmost-app name, scope-history FFT, and panel actions through to the SwiftUI scene.

## Decided

These architectural choices are locked in. Update this section only when rethinking a constraint.

- **Chunking strategy:** Fixed 60s rolling windows with overlap-stitching. Matches FluidAudio's tolerance and provides natural crash-recovery points.
- **Recording format:** WAV, 16 kHz, mono. Model's native rate; no resampling.
- **Storage:** GRDB/SQLite for the recordings library and metadata. Small config-like data (dictation modes, dictation history) is JSON in Application Support.
- **File naming:** Time-based (`YYYY/YYYY-MM-DD/HH-mm-ss.wav`). The doubled year keeps each day's directory self-identifying out of context.
- **Hotkey library:** KeyboardShortcuts (sindresorhus). Published, accessible API for per-mode binding.
- **Diarization:** FluidAudio's built-in model. Good enough for meeting and dictation on Apple Silicon.
- **Distribution:** Notarized `.app` direct download via GitHub Releases. DMG for easy install. Homebrew cask considered for later.
