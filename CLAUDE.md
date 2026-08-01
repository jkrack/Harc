# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Harc** — a macOS speech-to-text menu bar app with two surfaces. (1) Meeting capture: start recording on toggle-hotkey, transcribe diarized audio in background, save to searchable library, paste into LLM. (2) Dictation: hold hotkey, speak, release to insert text at cursor with optional AI mode (Clean-up, Email, Message, Answer, etc.) — all local.

Status: v0.10.0. Native macOS 26 (Liquid Glass) UI in `HarcUI` + `HarcApp`. Daemon-backed STT (Parakeet), GRDB-backed library, MLX summarization, speaker re-identification, push-to-talk dictation with modes all in place. Settings is a searchable sidebar; recordings project to Open Knowledge Format artifacts. v0.8.0 added retroactive record, hybrid search and archive reprocessing. v0.10.0 adds virtual day sessions (migration v14 `sessions` + `session_recordings`; combined summaries; `session-*.md` OKF docs), the `harc-mcp` agent bridge (second embedded executable — MCP over stdio, direct GRDB access, store-mediated write-back), and notes (migration v15; user-editable, agent-append-only).

**The audio path has never been exercised end-to-end.** The primary
development Mac is a Mac mini with no microphone, so meeting capture and
dictation have only ever been verified at the build-and-unit-test level —
never recorded, never transcribed, never inserted at a cursor. Every library
row that has existed on that machine came from UI-test seeding. On any Mac
with an input device, running one real recording (record → chunked transcribe
→ summary → OKF artifacts → library row) and one real dictation is the
highest-value validation available, and it is the largest untested surface in
the product.

That gap is also why the app now reports capture readiness from the presence
of an input device rather than from permission alone: for months it displayed
"Capture ready" on hardware that could not capture a sample.

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
      index.md              # OKF day index — links to each meeting document
      HH-mm-ss.wav          # raw mixed audio
      HH-mm-ss.md           # OKF markdown: frontmatter + summary + action items + transcript
      HH-mm-ss.json         # transcript + word timestamps + diarization + metadata
```

The `.md` is an Open Knowledge Format (OKF v0.1) document — YAML frontmatter
(`type`, `title`, `resource`, `tags`, `timestamp`) followed by `## Summary`,
`## Action Items`, and `## Transcript` sections. It is a *projection* of the
GRDB row (DB stays authoritative): `RecordingStore` regenerates it after
every content mutation via `OKFProjection`, so the bundle is always current
and directly consumable by agents/Obsidian. Pre-OKF `.txt` sidecars are
still read as a legacy fallback but never written.

The doubled year in the date folder keeps each day's directory self-identifying if it's copied, emailed, or moved out of context.

**Default destination:** `~/Documents/Harc/`. User-visible so files are easy to find without digging through `~/Library`.

**Write strategy — record local, move on stop:** the rolling WAV is always written to `~/Library/Caches/Harc/recordings/<uuid>.wav` during recording. On successful stop, it's atomically moved into the destination folder. This protects against iCloud/Dropbox sync latency, external-drive disconnects, and slow network volumes during a live recording.

**Sandbox note:** if distribution ever moves to the Mac App Store, arbitrary destination folders require security-scoped bookmarks rather than plain path strings. For notarized direct distribution, a `URL` path persisted in `UserDefaults` is sufficient.

## UI

The UI is native SwiftUI on macOS 26 with a deliberately small, closed
design system in `Sources/HarcUI/DesignSystem/`:

- **Type — five roles, no literals** (`HarcType.swift`): `.harcTitle`,
  `.harcBody`, `.harcLabel`, `.harcCaption`, `.harcMono`. Do not use
  `.caption`/`.subheadline`/etc. directly; pick the role. Rare deliberate
  exceptions carry a `// token-exempt:` comment.
- **Color — meaning first** (`HarcColor.swift`): status colors come only
  from `Color.harc(_:)` with `HarcStatusIntent` (ready / working /
  attention / failure / live). `HarcBrand` stays exactly two brand values
  (`live` red, icon `gradient`); `WavePalette` stays the three waveform
  blues; the transcript speaker ramp lives in `TranscriptDetailEditor`.
  `Color.accentColor` remains for interactive tint — it is not a status.
- **Spacing — 4pt scale** (`HarcSpacing.swift`): xs/sm/md/lg/xl/xxl
  (4/8/12/16/24/32). Hairline 1–3pt tweaks are allowed as literals.

The predecessor rule was "no tokens, use system" — it stopped brand tokens
and did not stop tokens; warning ended up yellow in four files and orange
in three. The closed set is the same restraint, now reviewable: "use
these" can be checked in a diff, "use system" could not. Liquid Glass via
`.glassEffect()`, system materials and `Color.primary`/`.secondary`
remain the substrate.

Surfaces (post v0.9.0 overhaul — the audit-driven redesign):
- **Meeting Library Window:** `HarcWindowRootView` — the primary window.
  `NavigationSplitView`; Record is a permanent card at the top of the
  sidebar (`RecordCardView` — idle / recording with timer+envelope+Stop /
  finishing / retroactive-armed; the design-doc 3e states), holding the
  `harc.library.capture.recordButton` identifier in every state. Below it
  the sidebar is navigation only:
  a date-scope popover ("All dates ▾") under search, then flat day-grouped
  recording sections (title / time·duration·speakers / snippet rows), the
  in-progress recording as a pinned selectable `.live` row, and People as a
  peer section. The detail pane is the **single editing surface**: editable
  title, one waveform player, summary card, and the transcript hosted in
  `TranscriptDetailEditor` (editable NSTextView — speaker-color channel,
  ⌘-click-to-seek, autosave on pause with a quiet "Saved"). There is no
  separate editor window. `ActivityView` (sheet) is the sole full renderer
  of readiness, recovery and running jobs; the footer is the live status
  line + LOCAL badge.
- **Menu-bar Panel:** `MenuBarPanelView` — hard budget, never scrolls:
  state line, level bars, Record/Dictate, one status row (tap → Activity),
  last capture, footer. All conditional detail lives behind the status row.
- **Recording Island:** `RecordingIslandView` + `RecordingIslandPanel` — a
  non-activating floating pill at top-center (DictationHUD panel pattern),
  existing only while a recording (or its save/discard tail) does. One
  state at a time: resting (pulsing dot · elapsed · live bars), hover-
  expanded after a 120ms dwell (Stop / Discard, 34pt targets), mic-silent
  amber (≈2.4s of near-zero frames), "Saving → Library", and the
  discard-undo countdown. Dims to 40% while the Library window is key.
- **Quick Capture:** `QuickCaptureView` + `QuickCapturePanel` — ⌘⇧R from
  any app; Spotlight-style key-capable non-activating panel: name field,
  system-audio toggle (`prefs.systemAudioEnabled`), "include the last N"
  when the pre-roll ring is armed, Start ↵. The title lands on
  `Recording.title` at ingest (wins over the async suggestion). ⌃⌥R still
  starts instantly with a timestamp name. Discard is stop-with-suppressed-
  side-effects + a 10s undo window; expiry routes through
  `RecordingDeletionService`.
- **Dictation HUD:** `DictationHUDView` — a non-activating `NSPanel`
  (Liquid Glass pill, fixed 360pt) above the Dock. Three states by shape
  and motion: pulsing live dot (listening), spinner (working), static
  symbol (resolved). Messages wrap inside the fixed pill.
- **Dictation History Window:** `DictationHistoryWindowView` — searchable window over recent dictations (voice-vs-AI toggle when a mode transformed the text). Copy and re-process actions (re-process is copy-only by design — the window is key, so a synthetic paste would land in Harc itself).
- **Settings:** `HarcSettingsForm` — a `NavigationSplitView` (sidebar +
  detail), the shape System Settings itself uses. Panes are declared by the
  `SettingsPane` enum; each renders one section-returning view inside a
  grouped `Form`:
  - **General** — appearance, launch at login
  - **Recording** — destination, hotkey, auto-stop, auto-paste guard, meeting detection
  - **Transcription** — diarization, VAD, chunk duration, vocabulary
  - **Dictation** — hotkey, trigger style, insertion, keep-warm, history
  - **Modes** — list, create/edit modes, per-mode hotkeys, per-app rules
  - **AI Models** — download/manage summarizer tiers, active model, auto-summarize
  - **Agents** — connect MCP clients to the bundled harc-mcp bridge; the read/write contract for agents
  - **About** — version, updates, storage, permission repair

  The sidebar is searchable via `SettingsSearchIndex`, which maps the words
  users actually type ("diarization", "vad", "tcc") to the pane that holds
  the setting. **Adding a setting means adding an index entry** — a pane with
  no entries is unreachable by search, and `SettingsSearchIndexTests` fails
  the build if one exists.

  This replaced a single 21-section scroll. Keep panes topic-complete: the
  flat form let transcription knobs drift into three non-adjacent places and
  produced two pickers bound to the same `activeSummarizerID`.
- **App Bridge:** `HarcAppBridge` — the observable that wires `RecordingState`, `PostStopTrayState`, `DictationState`, frontmost-app name, scope-history FFT, and panel actions through to the SwiftUI scene.

## Decided

These architectural choices are locked in. Update this section only when rethinking a constraint.

- **Chunking strategy:** Fixed 60s rolling windows with **2s overlap-stitching**: each chunk's slice extends 2s past its nominal boundary (consumption still advances nominally), so adjacent chunks both hear the boundary word whole; the assembler dedupes the shared text by longest-common-word-run at read time, keeping the predecessor's version (full left context) and falling back to a hard join when the overlap has no confident match. Stitching compares whitespace-split chunk *text* — never joined `Word` tokens, which are SentencePiece pieces and reassemble garbled. (Pre-stitch hard cuts split boundary words; a field recording showed "…rn." artifacts at exactly 60s edges.) Every chunk failure is retried with backoff; a chunk that exhausts retries becomes a visible `[m:ss–m:ss could not be transcribed…]` marker in the transcript, repairable via archive re-transcribe from the durable WAV. An energetic chunk that comes back empty under VAD is retried once without VAD (far-field speakers read as silence otherwise).
- **Recording format:** WAV, 16 kHz, mono. Model's native rate; no resampling.
- **Storage:** GRDB/SQLite for the recordings library and metadata. Small config-like data (dictation modes, dictation history) is JSON in Application Support.
- **File naming:** Time-based (`YYYY/YYYY-MM-DD/HH-mm-ss.wav`). The doubled year keeps each day's directory self-identifying out of context.
- **Hotkey library:** KeyboardShortcuts (sindresorhus). Published, accessible API for per-mode binding.
- **Diarization:** FluidAudio's built-in model. Good enough for meeting and dictation on Apple Silicon.
- **Distribution:** Notarized `.app` direct download via GitHub Releases. DMG for easy install. Homebrew cask considered for later.
- **Virtual day sessions, not physical merges:** multiple same-day recordings group into a `sessions` row (`session_recordings` join, one session per recording, hard-delete = dissolve). Members keep their audio, timestamps, and rows untouched; the session carries only a title + combined summary (built by `SessionPromptAssembler` — concatenated member `PromptTranscript`s with Person-resolved speaker labels) and projects to `<day-dir>/session-HH-mm-ss.md` (frontmatter `type: Session`, links to member docs, **no transcript section**). Physically merging was rejected: `wav_path` is the user-facing key everywhere, per-file ms timestamps don't compose, and the player assumes one WAV.
- **Agent access via `harc-mcp`, not in-app cloud:** a second embedded SwiftPM executable (`Sources/HarcMCP`, MCP Swift SDK, stdio transport, bundled to `Contents/MacOS/harc-mcp` by `scripts/build-mcp.sh`) exposes hybrid search + store-mediated writes (title/tags/speaker names/summary/notes; transcripts read-only). Notes (`notes_markdown` on recordings **and** sessions, migration v15, OKF `## Notes` section between Action Items and Transcript) are the enrichment channel: user-editable in both detail panes (`NotesCardView`), **append-only for agents** (`append_note` stamps `*— author, date*`; `RecordingStore.appendNote` never rewrites existing content). Notes are deliberately NOT in the FTS index — search stays over transcripts. It opens the same GRDB file directly — hence `busyMode = .timeout(5)` in `RecordingStore.onDisk` — and posts `com.harc.storeDidChangeExternally` on `DistributedNotificationCenter` after writes so the running app refetches (ValueObservation can't see other processes' commits). The app itself stays fully local: no API keys, no chat UI, no network code. Agent writes must go through `RecordingStore` mutators — direct `.md` edits get clobbered by the next OKF reprojection.
