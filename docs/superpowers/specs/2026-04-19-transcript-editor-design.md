# Transcript Editor Design

**Status:** Draft
**Author:** Harc team
**Date:** 2026-04-19
**Target release:** v1 (MVP)

---

## 1. Problem & User Story

Harc's auto-transcripts are roughly 90% correct — good enough to summarize, not good enough to quote. The last 10% (proper nouns, jargon, acronyms, homophones) is precisely the material users most want to capture accurately for meeting notes and downstream LLM pastes. Today the only way to fix a transcript is to open the `.txt` in a text editor with no audio context, re-listen in QuickTime in a separate window, and manually sync.

**User story:**

> As a Harc user, after a 45-minute meeting I open the recording from the Library, hit space to play, click-seek to the first place that sounds wrong, fix the word, keep playing, fix the next one, and hit Cmd-S. When I paste the transcript into my LLM an hour later it matches what was actually said.

This is the single highest-leverage quality-of-life feature Harc can ship post-MVP — it converts the output from "mostly right draft" into "ground-truth record."

## 2. Scope

### In scope (v1 MVP)

- Dedicated Transcript Editor **window** launched from the Library (double-click a row or "Open in Editor" button).
- **Audio playback:** play/pause, seek scrubber, skip ±5s, time display.
- **Text editing:** full `NSTextView`-backed editor with standard macOS undo/redo, cut/copy/paste, find.
- **Click-a-word to seek:** using word timestamps from the `.json` sidecar.
- **Save:** atomic write of the `.txt`; DB row touched so the Library preview refreshes.
- Missing-file / corrupt-json fallbacks (graceful degradation — text-only edit still works).

### Explicitly out of scope (future work)

- **Speaker rename** (no "Speaker 1 → Alice" UI).
- **Segment split / merge** at speaker boundaries.
- **Waveform rendering.** A plain slider scrubber is v1.
- **Per-word re-alignment after text edit.** `.json` is frozen on first edit; v1 does not attempt to rebuild word timestamps.
- Re-running transcription from the editor.
- Collaborative / multi-window editing of the same file.
- Export (PDF / markdown / SRT).

## 3. Architecture

### 3.1 Module placement

| Layer | Type | Placement |
|---|---|---|
| Window host | `NSWindowController` subclass | `HarcApp/WindowControllers/TranscriptEditorWindowController.swift` |
| Root SwiftUI view | `View` | `Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift` |
| View model | `@MainActor final class` | `Sources/HarcUI/TranscriptEditor/TranscriptEditorViewModel.swift` |
| Audio playback | Actor wrapping `AVAudioPlayer` | `Sources/HarcUI/TranscriptEditor/TranscriptAudioPlayer.swift` |
| NSTextView bridge | `NSViewRepresentable` | `Sources/HarcUI/TranscriptEditor/TranscriptTextView.swift` |
| Transcript model loader | struct | `Sources/HarcUI/TranscriptEditor/TranscriptDocument.swift` |

**Why `HarcUI` (not a new target):** the editor is a UI concern and only needs read access to `HarcStore.Recording` + `HarcCore.TranscribeResult`. No engine changes; no audio-capture changes. Fits the existing `HarcUI` charter ("pure-UI library").

### 3.2 Dependency graph

```
TranscriptEditorWindowController
        │
        ▼
  TranscriptEditorView  (SwiftUI)
        │
        ▼
  TranscriptEditorViewModel (@MainActor, ObservableObject)
        │
        ├──► TranscriptDocument       (static load: .json + .txt → in-memory model)
        ├──► TranscriptAudioPlayer    (actor: play/pause/seek over AVAudioPlayer)
        └──► RecordingStore           (touch updatedAt on save; update transcriptText/preview)
```

The VM is the single place that holds editor state:

```swift
@MainActor
public final class TranscriptEditorViewModel: ObservableObject {
    @Published public private(set) var document: TranscriptDocument
    @Published public var editedText: String      // bound to NSTextView
    @Published public private(set) var isDirty: Bool
    @Published public private(set) var isPlaying: Bool
    @Published public private(set) var currentTimeSec: Double
    @Published public private(set) var durationSec: Double
    @Published public private(set) var saveError: String?
    @Published public private(set) var audioMissing: Bool
    @Published public private(set) var wordIndexStale: Bool  // true once user has edited text
    // …
}
```

### 3.3 Audio playback — why a fresh `AVAudioPlayer` wrapper, not `HarcAudio`

`HarcAudio` is a **capture / record** engine — `AVAudioEngine` + `ScreenCaptureKit` + custom mixer + file writer. It doesn't do playback and has no concept of seek/scrub. Adding playback there would be a miscategorization (and would pull capture concerns into a feature that never records).

A thin actor wrapping `AVFoundation.AVAudioPlayer` is enough: `prepareToPlay`, `play`, `pause`, `currentTime` getter/setter, a 20Hz timer polling `currentTime` to drive the scrubber. The editor is single-file playback, single-window — none of the complexity that justified `AVAudioEngine` in capture.

```swift
public actor TranscriptAudioPlayer {
    private var player: AVAudioPlayer?

    public func load(url: URL) throws        // throws AudioPlaybackError.fileMissing/fileUnreadable
    public func play()
    public func pause()
    public func seek(to seconds: Double)
    public var currentTime: Double { get }
    public var duration: Double { get }
}
```

The 20Hz polling runs on the VM's main-actor side (Swift `Timer` or `Task { for await … }` loop); the VM reads `await player.currentTime` and publishes it. 20Hz is fast enough for a smooth scrubber on a 60Hz display and slow enough that the timer cost is negligible.

## 4. Edit Model — decision: **option (a), text-only, with a stale-flag on `.json`**

### 4.1 Decision

v1 edits the **plain-text transcript only**. The `.json` sidecar (word timestamps + speaker segments) is preserved as originally written by the daemon and used **read-only** for audio features (click-to-seek, word highlight-during-playback). The moment the user modifies the text, a `wordIndexStale: Bool` flag is set in memory; click-to-seek becomes best-effort (find a token match; fall back to seeking to the line's speaker-segment start if no match).

### 4.2 Save artifacts

On save:

1. `<stem>.txt` is rewritten atomically with the edited text.
2. `<stem>.json` is **not** rewritten. Its `joinedText` field becomes stale vs `.txt`; this is known and documented.
3. The DB row's `transcript_text` is updated (so FTS search + Library preview reflect the edit). `updated_at` bumps.
4. A tiny marker is added to the `.json` **metadata section only** (no re-alignment): a top-level optional `manualEditAt: Date` — advisory, so anything reading the JSON later knows the words no longer strictly match the text. This is a backward-compatible additive field in `SessionTranscript`.

### 4.3 Justification

- **(a) is implementable in a day.** (b) requires a diff-and-reanchor algorithm that has to handle insertions, deletions, word splits, and punctuation without drifting timestamps — a multi-week problem, and error-prone on long transcripts.
- **90% of the value** of a transcript editor is *fix the text and save it*. The audio-synced playback and click-to-seek are a force multiplier, but the edit itself is table stakes.
- **Click-to-seek degrades gracefully** in option (a). The `.json` holds the original words at their original times; the edited `.txt` is a superset (with fixes). We can still find most words via lightweight token matching; where we can't, we fall back to the nearest speaker-segment boundary. This is acceptable for polish-editing, which is usually small-delta.
- (b) is captured in "Future work" — the plumbing for a word-offset index is laid down in v1 so a future diff-aligner can slot in without breaking the file format.

### 4.4 Trade-off, explicit

After the first save, `.json`'s `joinedText` differs from `.txt`. That's a bug only for consumers who assumed they're identical (currently only the ingestor at startup, which reads `.txt` directly — so no live bug). The `manualEditAt` marker flags it for future tooling.

## 5. Audio Playback UX

### 5.1 Layout

```
┌──────────────────────────────────────────────────────────────────┐
│  Meeting with Lamia — 2026-04-18 10:32          [Reveal] [Save] │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [ Scrollable NSTextView of the transcript — word-aligned     ] │
│  [ with the audio, current-word softly highlighted during      ] │
│  [ playback, fully editable with native undo                   ] │
│                                                                  │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│  ◀◀ 5s   ▶/❚❚   5s ▶▶       ──●──────────────    00:12 / 45:31  │
└──────────────────────────────────────────────────────────────────┘
```

The transport bar is a bottom toolbar; the text fills the remaining pane.

### 5.2 Keyboard shortcuts

| Shortcut | Action | Notes |
|---|---|---|
| Space | Toggle play / pause | **Only when the text view doesn't have focus** — otherwise a user typing a space bar mid-edit would pause playback. Implement via a "play/pause" button first-responder; or `NSEvent` local monitor on the window that inspects `firstResponder`. |
| ← / → | Seek -5s / +5s | Same focus carve-out. |
| ⌘S | Save | Standard. |
| ⌘Z / ⌘⇧Z | Undo / Redo on the text | Provided automatically by `NSTextView`. |
| ⌘F | Find | Provided automatically by `NSTextView`. |

Space-to-toggle-while-editing is the trickiest detail. We resolve it by **binding the transport keys to the window's toolbar buttons' key equivalents** (`keyEquivalent = " "`, modifier mask `[]`) but **only active when the text view is not first responder**. We check via `NSWindow.firstResponder` in a local event monitor; if the text view has focus, we defer to the text view.

### 5.3 Click-a-word to seek

- On load, the VM builds an in-memory `WordIndex` from `TranscribeResult.words`: each word gets a `range` in the plain text and a `startMs` / `endMs`.
- On a Cmd-click inside the text view, the bridge posts the character offset to the VM; the VM finds the enclosing `WordIndex` entry and calls `player.seek(to: startMs / 1000.0)`.
- Plain click: normal cursor positioning (don't seek — don't surprise the user during editing).
- Once `wordIndexStale` is true, the VM finds the **original** word by matching the token text at the cursor against the original word list with a small window (±3 words), best-effort. If no hit, it seeks to the nearest speaker-segment start from `.json`. The UI shows a faint "timestamps may be approximate after your edits" inline hint.

### 5.4 Current-word highlight during playback

Driven by the 20Hz polling: the VM computes the word whose `[startMs, endMs)` contains `currentTimeSec * 1000`, and passes that `NSRange` to the text view bridge, which applies a temporary attribute (`backgroundColor: harcPrimary.opacity(0.15)`). Removed when playback stops. Skipped once `wordIndexStale` is true (the range is no longer guaranteed correct).

## 6. Text Editing

### 6.1 `NSTextView` vs SwiftUI `TextEditor` — decision: `NSTextView`

`TextEditor` is a wrapper around `UITextView`/`NSTextView` with deliberately limited API. For this feature we need:

- **Precise attribute control** — we apply a `backgroundColor` attribute to a specific range to highlight the current word during playback. `TextEditor` doesn't expose this.
- **Range↔character-offset reporting** for click-to-seek.
- **Standard macOS behavior** — undo, find, spelling, services menu — which `NSTextView` gives us for free.

The cost is one `NSViewRepresentable` shim (~80 lines) and a tiny `Coordinator` bridging selection / mutation events back to the VM. Well-trodden SwiftUI ↔ AppKit pattern.

### 6.2 Undo

`NSTextView` sets up its own `UndoManager` automatically; the window's `UndoManager` chains from the text view. No bespoke stack; no bespoke coalescing.

### 6.3 Dirty tracking

`isDirty` flips true on the first mutation notification from the text view. Window title gets a macOS-standard dot ("●") when dirty. Closing an unsaved window triggers the standard "Save / Don't Save / Cancel" sheet.

## 7. Save Flow

1. User hits ⌘S (or closes the window and picks Save).
2. VM calls `TranscriptDocument.save(editedText:)` which:
   - Writes to `<stem>.txt.tmp` with `.atomic`, verifies the write (stat size > 0), then `rename()` replaces `<stem>.txt`.
   - On success, updates the GRDB row via a new `RecordingStore.updateTranscriptText(id:, text:)` method (sets `transcript_text` + `updated_at`).
   - Sets `isDirty = false`, `saveError = nil`.
3. Failure modes:
   - **Disk full / permission denied** → show inline banner with the underlying error, leave `isDirty = true`.
   - **DB update fails** but file write succeeded → warn but treat as success; the ingestor will pick the text up on next app launch as a fallback.
   - **JSON `manualEditAt` stamping fails** → log, don't block the save.

The DB update is additive: a new `RecordingStore.updateTranscriptText(id:, text:)` method that sets `transcript_text` and `updated_at` (does not touch `manualEditAt`-on-Recording, which does not exist; that marker lives in the JSON).

## 8. Launch Flow from Library

### 8.1 Gestures

| Gesture | Behavior |
|---|---|
| Double-click a row in the Library table | **Opens Transcript Editor** (primary path). |
| Single-click a row | Selects it (existing behavior; side panel preview). Does **not** open the editor. |
| "Open in Editor" button in the detail pane | Opens Transcript Editor. Replaces today's "Read Full Transcript →" link target so the primary action is the editor, not the read-only detail window. |
| Right-click > "Open in Editor" | Alternative entry point. |

The existing read-only `TranscriptionDetailWindowController` is kept for now (it's a fine preview) but the main affordance is now the editor.

### 8.2 Missing-WAV handling

A user might have manually deleted or moved the `.wav` after recording. When the editor opens:

- If the WAV exists → editor opens normally with playback enabled.
- If the WAV is missing → editor still opens, but the transport bar is replaced by a warning banner: *"Audio file not found — you can still edit the transcript. [Reveal expected location]"*. All text editing works; seek/play/word-highlight disabled.

### 8.3 Per-recording window singleton

Opening the editor for the same recording twice surfaces the existing window (same pattern as `detailWindows` dict in `AppDelegate`). AppDelegate holds `editorWindows: [String: TranscriptEditorWindowController]` keyed by `wavPath`.

### 8.4 Save/close coordination with Library

Library observation via `ValueObservation` already republishes on `transcript_text` change; no extra plumbing. The window controller on close removes itself from `editorWindows`.

## 9. Error Handling

| Situation | Handling |
|---|---|
| `.wav` missing on open | Open in text-only mode with banner (§8.2). |
| `.json` missing or corrupt | Open in text-only mode with banner "Word timestamps unavailable — click-to-seek and word highlight disabled." Text editing works. |
| `.txt` missing but `.json` present | Load `.txt` content from `SessionTranscript.joinedText` as the initial text. |
| `.txt` missing and `.json` missing | "No transcript available" error state; editor opens empty but usable — user can type from scratch; save creates the files. |
| Attempt to open editor twice on same recording | Second request surfaces the existing window (no second save target). |
| Disk full / permission denied on save | Inline banner; stays dirty. |
| App quit with dirty window | Standard "Save / Don't Save / Cancel" sheet (AppKit default via `NSDocument`-style `windowShouldClose` hook). |
| Underlying `.wav` changes size during editing (extremely unlikely) | `AVAudioPlayer` is loaded once at open; subsequent disk changes don't affect the loaded player. Fine. |

Concurrent-edit protection is **not a concern in v1** — Harc is single-user, single-process, and editor windows are per-recording singletons.

## 10. Testing

### 10.1 Unit tests (Swift Testing, `HarcUITests`)

Pure-logic, no UI rendering:

- `TranscriptDocumentTests` — load-from-URLs covers all six missing/present permutations of `.wav`/`.txt`/`.json`.
- `WordIndexTests` — `wordAtCharOffset`, `wordAtTimeMs`, boundary conditions (first char, last char, whitespace between words, empty text).
- `TranscriptEditorViewModelTests` — in-memory happy path: load → play → pause → seek → edit (isDirty goes true) → save (isDirty clears, DB updated).
- `TranscriptAudioPlayerTests` — load missing file throws; load a tiny fixture wav resolves `duration` correctly; seek clamps to [0, duration].
- `RecordingStoreTests` (addition) — `updateTranscriptText(id:, text:)` updates the row and bumps `updated_at`.

### 10.2 Manual UX checks (runbook in the plan's "Verification" sections)

- Open editor → space toggles playback.
- Click a word mid-transcript → audio seeks there.
- Edit a word → playback still works; word highlight stops updating.
- Save, close, reopen → edits persist; Library row preview updated.
- Delete the `.wav` → reopen → banner shows; text edit still saves.

## 11. Settings

No new settings for v1. Flagged for future: editor font size preference, auto-scroll-follow-playback toggle. Settings still moves to the tabbed design (General / Recording / Library / Processing) as planned; the editor needs nothing there.

## 12. Future Work

- **Speaker rename** with per-segment mapping persisted into the `.json`.
- **Segment split / merge** at speaker boundaries — UI for drag-to-split, cmd-backspace to merge into prior segment.
- **Waveform rendering** in the transport strip (probably via `AVAssetReader` → downsampled RMS buckets, cached into a sidecar `.peaks` file).
- **Word-timestamp re-alignment after edits** (the option-(b) path). A diff between original `joinedText` and edited `.txt` gives insertions / deletions / replacements; a longest-common-subsequence re-anchor would update `startMs` / `endMs` on retained words and interpolate for inserted ones. Captured here so future work doesn't need to re-architect v1.
- **Export to SRT / VTT** — with speaker labels.
- **Re-run transcription from the editor** on a specific range (useful for regions where the model tripped).

## 13. Open Questions

- Should "Open in Editor" replace the existing read-only detail window entirely, or coexist? Current assumption: coexist in v1, re-evaluate after usage.
- Auto-scroll to the current-word during playback? Assumption: **yes, but only if the user hasn't scrolled manually in the last 3s** (standard media-player behavior). Captured as a v1 polish ticket in the plan.
