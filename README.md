<div align="center">

# Harc

**Meeting memory for your Mac.**

Record a meeting, get a speaker-labelled transcript you can paste into an LLM.
Hold a key anywhere, speak, and the text lands at your cursor.
Everything runs on your Mac — no cloud, no account, no telemetry.

[Download](https://github.com/jkrack/Harc/releases/latest) ·
[Features](#what-it-does) ·
[Privacy](#privacy) ·
[Install](#install)

macOS 26 (Tahoe) or later · Apple Silicon · ~460 MB speech model

</div>

---

<!-- HERO SCREENSHOT: Library window with a real transcript, speaker labels and a
     generated summary. Needs a Mac with a microphone and one real recording —
     see docs/screenshots.md for the capture checklist. -->

## What it does

Harc is two tools that happen to share a speech engine.

### 1. Meeting capture

Start recording from the menu bar or a hotkey. Harc captures **your microphone
and the system audio together**, so the people on the call end up in the
transcript too — not just you. Audio is written to disk as it records, and
transcription runs in the background in rolling chunks, so the transcript is
essentially finished the moment you press stop.

The design goal is not low latency. It is **never losing an hour of audio**:
the recording survives a crash, a sleep, or a power loss, and a recovery inbox
offers to rebuild anything that was interrupted.

<!-- SCREENSHOT: menu-bar panel mid-recording, showing elapsed time and levels. -->

### 2. Push-to-talk dictation

Hold ⌃⌥D, speak, release. The text is inserted at your cursor in whatever app
you were already in. A floating pill shows the waveform without stealing
focus.

Modes reshape what you said before it lands — clean up the filler, turn it
into an email, a message, a bullet list, or answer a question about the text
you have selected. All of it runs through a local model.

<img src="docs/images/welcome-dictation.png" alt="Dictation: hold the hotkey, speak, release — text lands at the cursor" width="820">

<!-- SCREENSHOT: the dictation HUD mid-dictation, live waveform + mode chip. -->

## Feature list

**Capture**
- Microphone **and** system audio, mixed to one recording (via ScreenCaptureKit)
- Toggle recording from the menu bar, a global hotkey (⌃⌥R by default), or the Library window
- **Retroactive record** — optionally keep the last 1–10 minutes in memory, so a recording can start *before* you pressed the button
- Auto-stop on silence, with a warning before it fires, plus a hard duration cap
- Meeting detection: notices when a video-call app launches and offers to record
- Durable WAV on disk during capture; a recovery inbox for anything interrupted

**Transcription**
- Parakeet TDT 0.6B v3 running on the Neural Engine via Core ML
- Speaker diarization on by default — `Speaker 1:` / `Speaker 2:` labels a downstream LLM can use
- Speaker re-identification links the same voice to a named person across recordings
- Voice-activity detection skips silence, which is most of a meeting's mic track
- A vocabulary list rewrites names, acronyms and jargon the model mishears
- **Re-transcribe the archive** when a better engine ships, so old recordings improve too

**Library**
- Searchable across every transcript, with optional **hybrid search** that blends meaning into keyword results
- Calendar, pinning, and date grouping in the sidebar
- Transcript editor, speaker renaming, and an inspector with file metadata
- Every recording is written as `WAV` + `JSON` + an **Open Knowledge Format** Markdown document — plain files in a folder you choose, readable by Obsidian or any agent, with the database as an index rather than a silo

**Dictation**
- Push-to-talk or toggle, on a hotkey you choose
- Inserts at the cursor in any app, or copies to the clipboard instead
- Restores whatever you had copied once the text lands
- Keeps the speech model warm so there is no cold-load pause
- Searchable history of recent dictations, kept locally and switchable off
- Refuses to run while a meeting recording is active — mic and daemon are single-user resources

<img src="docs/images/settings-dictation.png" alt="Dictation settings: hotkey, trigger style, insertion behaviour and history" width="820">

**AI, on device**
- Meeting summaries and action items from a local MLX model
- Summarizer tiers from 3.6 GB to 18 GB — download only what your Mac can run, with RAM guidance per tier
- Dictation modes (Clean-up, Email, Message, Bullet List, Answer, or your own), each with an optional hotkey and per-app rules

<img src="docs/images/settings-models.png" alt="AI Models settings: on-device summarizer tiers with size and RAM guidance" width="820">

<img src="docs/images/settings-modes.png" alt="Dictation modes: built-in and custom text transformations" width="820">

## Privacy

<img src="docs/images/welcome-local-first.png" alt="Local first: speech, diarization, summaries and audio all stay on the Mac" width="820">

- **No cloud speech-to-text.** Audio never leaves the machine.
- **No account, no sign-in, no telemetry.**
- Models are downloaded once from Hugging Face, version-pinned and
  checksum-verified. After that, Harc works offline.
- Auto-paste refuses to type into password managers and the login window, and
  that list is not editable away.
- Retroactive record is **off by default**, and when you turn it on the app
  says plainly that it holds the microphone open while idle — macOS shows its
  orange indicator the whole time.

Harc is source-available under [PolyForm Noncommercial](https://polyformproject.org/licenses/noncommercial/1.0.0),
so you can read exactly what it does with your audio.

## Install

1. Download the DMG from [Releases](https://github.com/jkrack/Harc/releases/latest)
   and drag `Harc.app` to `/Applications`. Builds are signed and notarized, so
   there is nothing to un-quarantine.
2. Launch it. The welcome flow asks for Microphone and Screen Recording, and
   for Accessibility if you want dictation to insert text.
3. The speech model (~460 MB) downloads on first run — the menu-bar panel
   shows progress. Recording works as soon as it lands. Summarizer models are
   optional and install from Settings → AI Models.

<img src="docs/images/welcome-canvas.png" alt="Harc's welcome flow" width="820">

Updates arrive through Sparkle; Harc checks on its own and installs in place.

## Requirements

| | |
|---|---|
| **macOS** | 26 (Tahoe) or later |
| **Chip** | Apple Silicon (arm64) — no Intel build |
| **Disk** | ~460 MB speech model, plus 3.6–18 GB per summarizer tier you choose |
| **RAM** | 8 GB works; 16 GB recommended if you want summaries |
| **Language** | English only, by design — it is what allows the best model choice |

Screen Recording permission is what allows Harc to capture the *other* side of
a call. Decline it and recording still works, mic-only.

## How it works

The speech engine is a separate executable (`harc-stt`) that Harc launches and
talks to over a Unix socket, so model load cost is paid once and a crash in
the audio stack cannot take the UI with it. Recording writes a durable WAV to
a cache directory; a background worker feeds finished ~60-second chunks to the
daemon while capture continues, then the finished bundle is moved atomically
into your chosen folder. The library is GRDB/SQLite, and the Markdown document
is a projection of it — regenerated after every edit, never the source of
truth.

`AGENTS.md` has the architecture map, the reliability rules, and the release
ritual.

## Build from source

Requires Xcode / Swift 6.2 and Homebrew.

    brew install xcodegen
    swift test            # SwiftPM suite
    xcodegen generate     # produce Harc.xcodeproj
    open Harc.xcodeproj   # build + run the Harc app target

`swift test` does not compile `HarcApp/` — always finish with an `xcodebuild`
before calling the tree green. See `AGENTS.md` for known-flaky suites and the
full validation workflow.

## Uninstall

Quit Harc, delete `Harc.app`, then remove what you don't want to keep
(Settings → About → Storage lists the same paths with sizes):

    ~/Documents/Harc                                # recordings + transcripts (yours — keep!)
    ~/Library/Application Support/Harc              # library DB, modes, history, summarizer models
    ~/Library/Application Support/FluidAudio/Models # speech models
    ~/Library/Caches/Harc                           # caches + daemon log
    ~/.harc                                         # daemon socket

## License

[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)
— see `LICENSE`. Open for personal and other noncommercial use; commercial use
requires a separate license. Official signed builds are available from
[Releases](https://github.com/jkrack/Harc/releases).
