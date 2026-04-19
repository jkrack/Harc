# Transcript Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v1 Transcript Editor — a dedicated `NSWindow` launched from the Library that plays the recording's audio, supports play/pause/seek/click-to-seek, lets the user edit the `.txt` with standard macOS undo, and saves atomically back to disk + DB.

**Design doc:** `docs/superpowers/specs/2026-04-19-transcript-editor-design.md`

**Architecture (1-paragraph summary):** A new `TranscriptEditorWindowController` in `HarcApp/WindowControllers/` hosts a SwiftUI `TranscriptEditorView` backed by a `@MainActor TranscriptEditorViewModel`. The VM owns a `TranscriptAudioPlayer` actor (thin `AVAudioPlayer` wrapper for play/pause/seek) and a `TranscriptDocument` (loads `.txt` + `.json`, keeps a `WordIndex` for click-to-seek). The text is edited via an `NSViewRepresentable` `TranscriptTextView` wrapping `NSTextView` (standard undo, find, and a current-word background attribute driven by a 20Hz playback-position poll). Save atomically writes the `.txt`, updates the GRDB row via a new `RecordingStore.updateTranscriptText(id:, text:)`, and stamps an advisory `manualEditAt` onto the `.json`. All new code lives in `Sources/HarcUI/TranscriptEditor/` and `Tests/HarcUITests/TranscriptEditor/`. No engine / capture changes.

**Tech Stack:** Swift 6.0, SwiftPM, SwiftUI, AppKit (`NSWindowController`, `NSTextView`, `NSViewRepresentable`), `AVFoundation.AVAudioPlayer`, GRDB (via `HarcStore`). macOS 14+.

---

## Prerequisites

- Existing `LibraryWindowRootView`, `TranscriptionDetailWindowController`, `Recording`, `RecordingStore`, `SessionTranscript` / `TranscribeResult` types.
- `SessionTranscript` already on disk as `<stem>.json` — exposes `.joinedText`, `.words: [Word]` (with `startMs/endMs`), `.speakers: [SpeakerSegment]`.
- `HarcDesign` tokens in `Sources/HarcUI/DesignTokens.swift`.

## Scope Boundary

**In (v1 MVP):**
- New Transcript Editor window reachable from the Library (double-click row + "Open in Editor" button + context menu).
- Play / pause / seek / ±5s skip / click-word-to-seek.
- Editable text (NSTextView), standard undo, dirty tracking, atomic save.
- Missing-audio / missing-json fallbacks.

**Out (future work, captured in design doc):**
- Speaker rename, segment split/merge, waveform rendering.
- Per-word re-alignment after edits.
- Export formats.
- Any new Settings.

## File Structure

After this plan:

```
Harc/
├── Sources/
│   ├── HarcUI/
│   │   └── TranscriptEditor/                              (new directory)
│   │       ├── TranscriptDocument.swift                   T2
│   │       ├── WordIndex.swift                            T2
│   │       ├── TranscriptAudioPlayer.swift                T3
│   │       ├── TranscriptEditorViewModel.swift            T4
│   │       ├── TranscriptTextView.swift                   T5
│   │       ├── TranscriptEditorTransportView.swift        T6
│   │       └── TranscriptEditorView.swift                 T6
│   └── HarcStore/
│       └── RecordingStore.swift                           (modified, T1)
├── HarcApp/
│   ├── AppDelegate.swift                                  (modified, T7)
│   ├── WindowControllers/
│   │   └── TranscriptEditorWindowController.swift         T7
│   └── (existing)
└── Tests/
    ├── HarcStoreTests/
    │   └── RecordingStoreTranscriptTextTests.swift        T1
    └── HarcUITests/
        └── TranscriptEditor/                              (new directory)
            ├── TranscriptDocumentTests.swift              T2
            ├── WordIndexTests.swift                       T2
            ├── TranscriptAudioPlayerTests.swift           T3
            └── TranscriptEditorViewModelTests.swift       T4
```

### Responsibilities

- **`RecordingStore.updateTranscriptText(id:, text:)`** — add an atomic GRDB update for the `transcript_text` column + `updated_at`. Tiny; shares shape with `updateSuggestedTitle`.
- **`TranscriptDocument`** — pure struct (`Sendable`). Static `load(recording:) throws -> TranscriptDocument` that reads the `.txt` and `.json`, tolerates missing files, returns a document carrying `initialText`, `words`, `speakers`, `wavURL?`, `jsonURL?`, `txtURL?`, and a `WordIndex`. `save(editedText:, to:)` atomically writes `.txt` and stamps `manualEditAt` on the JSON.
- **`WordIndex`** — computed from `[Word]` + joined text; provides `wordAt(charOffset: Int) -> Word?` and `wordAt(timeMs: Int) -> (Word, NSRange)?`. Precomputes an `[NSRange]` in parallel with the word list via string scanning.
- **`TranscriptAudioPlayer`** — actor wrapping `AVAudioPlayer`. Methods: `load(url:) throws`, `play()`, `pause()`, `seek(to:)`, properties `currentTime`, `duration`, `isPlaying`. Errors: `AudioPlaybackError.fileMissing / fileUnreadable / fileFormatUnsupported`.
- **`TranscriptEditorViewModel`** — `@MainActor public final class … : ObservableObject`. Owns document + player. Publishes: `editedText`, `isDirty`, `isPlaying`, `currentTimeSec`, `durationSec`, `audioMissing`, `wordIndexStale`, `saveError`, `currentHighlightRange`. Methods: `togglePlay()`, `seek(to:)`, `skip(by:)`, `seekToWord(atCharOffset:)`, `markEdited()`, `save()`.
- **`TranscriptTextView`** — `NSViewRepresentable` around `NSTextView`. Exposes a binding to `String` + a one-way attribute for "current word highlight" range + callbacks for cmd-click (char offset) and edit notifications.
- **`TranscriptEditorTransportView`** — bottom transport bar: play/pause button, ±5s buttons, scrubber (`Slider`), time readout.
- **`TranscriptEditorView`** — assembles title bar, text view, transport. Banner views for missing-audio / stale-index states.
- **`TranscriptEditorWindowController`** — thin `NSWindowController` convenience init; sets title, size, close-behavior.
- **`AppDelegate`** — adds `editorWindows: [String: TranscriptEditorWindowController]`, routes `openEditor(for:)` from Library callbacks.

### Why split this way

- `TranscriptDocument` and `WordIndex` are 100% pure; easily unit-tested, no AppKit.
- `TranscriptAudioPlayer` is an actor so concurrent Main-actor reads of `currentTime` during playback are safe.
- The NSTextView bridge is isolated in one file; if we ever migrate to a new SwiftUI-native primitive it's a single swap.
- VM holds all `@Published` state so the view layer stays declarative.

## Testing Notes

- Unit-testable: `TranscriptDocument`, `WordIndex`, `TranscriptAudioPlayer` (with a fixture WAV), `TranscriptEditorViewModel` (happy path + missing-audio path), `RecordingStore.updateTranscriptText`.
- Not unit-tested: `TranscriptTextView` (NSViewRepresentable), transport layout, launch flow from Library, keyboard focus shuffling for spacebar. Verified manually per the per-task runbooks below.
- A small fixture `.wav` (1 second of silence) lives under `Tests/HarcUITests/Fixtures/` for player tests. `AVAudioPlayer` doesn't need ScreenCaptureKit permissions so tests run in CI headless.

---

## Task Dependencies

```
T1 (DB column) ──┐
T2 (Document + WordIndex) ──┐
T3 (AudioPlayer) ──┐        │
                   ▼        ▼
                   T4 (ViewModel)
                        │
                        ▼
             T5 (NSTextView bridge)
                        │
                        ▼
           T6 (View + Transport composition)
                        │
                        ▼
       T7 (WindowController + Library launch wiring)
                        │
                        ▼
       T8 (Manual smoke-test runbook)
```

T2 and T3 are independent and can be done in parallel if splitting across agents. T4 depends on both. T5 is independent of T4 at the type level but feeds into T6. T6 is the integration point. T7 wires it into the shipping app. T8 is the end-to-end verification.

---

### Task 1 (S): `RecordingStore.updateTranscriptText(id:, text:)`

Add a small writer so editor saves reflect in DB / FTS / Library preview.

**Files:**
- Modify: `Sources/HarcStore/RecordingStore.swift`
- Create: `Tests/HarcStoreTests/RecordingStoreTranscriptTextTests.swift`

**Steps:**

- [ ] Add method on `RecordingStore`:
  ```swift
  public func updateTranscriptText(id: Int64, text: String) async throws {
      try await dbQueue.write { db in
          let count = try Recording.filter(key: id).updateAll(
              db,
              [
                  Recording.Columns.transcriptText.set(to: text),
                  Recording.Columns.updatedAt.set(to: Date()),
              ]
          )
          guard count > 0 else { throw StoreError.notFound }
      }
  }
  ```
- [ ] Write unit test: insert a recording, call `updateTranscriptText`, re-fetch, assert `transcriptText` matches and `updatedAt` moved forward.
- [ ] Confirm FTS index updates — the existing migrator includes `recordings_fts` triggers (verify in `DatabaseMigrator+Harc.swift`); a trigger-backed FTS should pick up the row automatically. If not, this task also adds a manual `UPDATE recordings_fts` block. Document the outcome inline.

**Verification:**
- `swift test --filter RecordingStoreTranscriptTextTests` — all green.
- Add a quick search-after-edit smoke: upsert a recording with text "alpha", call updateTranscriptText to "bravo", call `store.search(query: "bravo")` — expect one result.

---

### Task 2 (M): `TranscriptDocument` + `WordIndex`

Pure-Swift models. No AppKit, no AVFoundation.

**Files:**
- Create: `Sources/HarcUI/TranscriptEditor/TranscriptDocument.swift`
- Create: `Sources/HarcUI/TranscriptEditor/WordIndex.swift`
- Create: `Tests/HarcUITests/TranscriptEditor/TranscriptDocumentTests.swift`
- Create: `Tests/HarcUITests/TranscriptEditor/WordIndexTests.swift`

**Steps:**

- [ ] `TranscriptDocument`:
  - Properties: `initialText: String`, `words: [Word]`, `speakers: [SpeakerSegment]`, `wavURL: URL?`, `txtURL: URL`, `jsonURL: URL?`, `wordIndex: WordIndex`, `audioAvailable: Bool`, `jsonAvailable: Bool`.
  - Static `load(recording: Recording) throws -> TranscriptDocument` that:
    - Prefers `.txt` contents; falls back to `SessionTranscript.joinedText` from the JSON; if both missing, uses `""`.
    - Loads words/speakers from JSON if readable; empty arrays otherwise.
    - Sets `audioAvailable` by `FileManager.default.fileExists(atPath:)`.
  - `save(editedText:) async throws -> URL` atomic-writes `<stem>.txt.tmp` then `rename` to `<stem>.txt`, returns the final URL. Also updates the JSON's `manualEditAt` (load, set, atomic rewrite) — swallow errors on the JSON stamp (log to stderr, don't fail the save).
  - Add optional `manualEditAt: Date?` to `SessionTranscript` (backward-compatible additive field; Codable default-decoding already tolerant). Watch out: `TranscriptWriter.writeSiblings` encoder emits pretty-printed JSON — re-encode the same way to avoid churn.
- [ ] `WordIndex`:
  - Init `WordIndex(words: [Word], text: String)` that walks `words` in order, finds each word's `NSRange` in `text` (case-insensitive, whitespace-tolerant; scan-forward pointer so we never re-scan earlier text).
  - `wordAt(charOffset: Int) -> (Word, NSRange)?`
  - `wordAt(timeMs: Int) -> (Word, NSRange)?`  binary-searches on `startMs`.
  - Handles mismatch gracefully: if a word can't be located in the text, skip it (rather than aborting the whole index).
- [ ] Unit tests:
  - **TranscriptDocumentTests** — fixtures directory with:
    - both-present (normal case),
    - `.txt`-missing (falls back to JSON joinedText),
    - `.json`-missing (text-only, words empty),
    - both-missing (empty doc),
    - `.wav`-missing (`audioAvailable == false`).
    - Save-then-reload round-trip: edit text, save, re-load, assert text matches.
    - Save also writes `manualEditAt` into the JSON.
  - **WordIndexTests** — simple transcripts:
    - `"hello world"` with words `[hello@0-500, world@500-1000]` → `wordAt(charOffset: 0)` == hello, `wordAt(charOffset: 6)` == world, `wordAt(charOffset: 5)` is whitespace → nil or the nearest word (document the choice; recommend nil).
    - `wordAt(timeMs: 0)` == hello, `wordAt(timeMs: 499)` == hello, `wordAt(timeMs: 500)` == world, `wordAt(timeMs: 2000)` == nil (past end).
    - Empty words / empty text → all lookups return nil without crashing.

**Verification:**
- `swift test --filter TranscriptDocumentTests --filter WordIndexTests` — all green.
- Manual: generate a doc from a real recording's `.txt`/`.json`, verify `wordIndex.wordAt(timeMs: 5000)` returns a plausible word for a 5-second offset.

---

### Task 3 (S): `TranscriptAudioPlayer` actor

Thin wrapper over `AVAudioPlayer`.

**Files:**
- Create: `Sources/HarcUI/TranscriptEditor/TranscriptAudioPlayer.swift`
- Create: `Tests/HarcUITests/TranscriptEditor/TranscriptAudioPlayerTests.swift`
- Add a tiny fixture: `Tests/HarcUITests/Fixtures/one-second.wav` (1s of silence at 16kHz mono, 16-bit PCM). Script: generate via `ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -sample_fmt s16 -y one-second.wav` and check the file in. If `Package.swift`'s HarcUITests target doesn't have resources, add `.copy("Fixtures")`.

**Steps:**

- [ ] Define `public enum AudioPlaybackError: Error { case fileMissing, fileUnreadable(String) }`.
- [ ] `public actor TranscriptAudioPlayer`:
  - `public init()`
  - `public func load(url: URL) throws` — validates existence then `try AVAudioPlayer(contentsOf: url)`; stores the player; calls `prepareToPlay()`.
  - `public func play()` / `public func pause()`
  - `public func seek(to seconds: Double)` — clamps to `[0, duration]`, sets `player.currentTime`.
  - `public var currentTime: Double` / `public var duration: Double` / `public var isPlaying: Bool` (async getters since actor).
- [ ] Tests (Swift Testing, `@Test`):
  - Load missing URL → throws `.fileMissing`.
  - Load fixture WAV → duration ≈ 1.0 (`#expect(duration > 0.9 && duration < 1.1)`).
  - `seek(to: -10)` clamps to 0; `seek(to: 999)` clamps to `duration`.
  - `play()` then check `isPlaying == true` (allow a tiny delay via `Task.sleep(for: .milliseconds(50))`); `pause()` flips it.

**Verification:**
- `swift test --filter TranscriptAudioPlayerTests` — green.
- Open `one-second.wav` in QuickTime to sanity-check the fixture.

---

### Task 4 (M): `TranscriptEditorViewModel`

Glues the document + player; all `@Published` state lives here.

**Files:**
- Create: `Sources/HarcUI/TranscriptEditor/TranscriptEditorViewModel.swift`
- Create: `Tests/HarcUITests/TranscriptEditor/TranscriptEditorViewModelTests.swift`

**Steps:**

- [ ] Class skeleton:
  ```swift
  @MainActor
  public final class TranscriptEditorViewModel: ObservableObject {
      @Published public private(set) var document: TranscriptDocument
      @Published public var editedText: String
      @Published public private(set) var isDirty: Bool = false
      @Published public private(set) var isPlaying: Bool = false
      @Published public private(set) var currentTimeSec: Double = 0
      @Published public private(set) var durationSec: Double = 0
      @Published public private(set) var currentHighlightRange: NSRange? = nil
      @Published public private(set) var audioMissing: Bool
      @Published public private(set) var wordIndexStale: Bool = false
      @Published public private(set) var saveError: String? = nil

      private let player: TranscriptAudioPlayer
      private let recording: Recording
      private let store: RecordingStore
      private var pollTask: Task<Void, Never>?

      public init(recording: Recording, store: RecordingStore, player: TranscriptAudioPlayer = .init()) async throws { ... }
  }
  ```
- [ ] In init: call `TranscriptDocument.load(recording:)`; if `audioAvailable`, `try await player.load(url: document.wavURL!)`; read `durationSec` from player; set `editedText = document.initialText`.
- [ ] Methods:
  - `func togglePlay()` — if `audioMissing`, no-op. Otherwise toggles and kicks off/cancels poll task.
  - `func seek(to seconds: Double)` — forwards to player; updates `currentTimeSec`.
  - `func skip(by seconds: Double)` — `seek(to: currentTimeSec + seconds)`.
  - `func seekToWord(atCharOffset offset: Int)` — look up in `document.wordIndex`; if `wordIndexStale`, use a fuzzy best-match (see design doc §5.3); on hit, seek; on miss, fall back to nearest speaker-segment start.
  - `func markEdited(newText: String)` — sets `editedText`, `isDirty = true`, `wordIndexStale = true`, clears `currentHighlightRange`.
  - `func save() async` — calls `document.save(editedText:)`; on success, calls `store.updateTranscriptText(id: recording.id!, text: editedText)`; sets `isDirty = false`, `saveError = nil`. On failure, sets `saveError`.
  - `func stopPlayback()` — `pollTask?.cancel()`, pause player, isPlaying = false.
- [ ] Poll task: while `isPlaying`, `Task { while !Task.isCancelled { let t = await player.currentTime; self.currentTimeSec = t; if !wordIndexStale { self.currentHighlightRange = document.wordIndex.wordAt(timeMs: Int(t * 1000))?.1 }; try? await Task.sleep(for: .milliseconds(50)) } }`.
- [ ] Unit tests with an in-memory `RecordingStore.inMemory()` + a fixture-backed `Recording`:
  - Load → `editedText == document.initialText`, `isDirty == false`.
  - `markEdited("new")` → `isDirty == true`, `wordIndexStale == true`.
  - `save()` → file on disk has the new text; `store.fetchByWavPath(...).transcriptText == "new"`.
  - `audioMissing` path: load with `wavPath` pointing at a non-existent file → `audioMissing == true`; `togglePlay()` is a no-op; save still works.
  - Simulate save failure by passing a txt path in a read-only directory → `saveError != nil`, `isDirty` stays true.

**Verification:**
- `swift test --filter TranscriptEditorViewModelTests` — all green.
- Review concurrency: `@MainActor` on the class means all `@Published` writes are main-actor. Poll task must hop back to main-actor for mutations (use `Task { @MainActor in ... }` or `await MainActor.run`).

---

### Task 5 (M): `TranscriptTextView` (`NSViewRepresentable`)

Bridge so SwiftUI can embed an `NSTextView` with range highlighting + click callbacks.

**Files:**
- Create: `Sources/HarcUI/TranscriptEditor/TranscriptTextView.swift`

**Steps:**

- [ ] Define:
  ```swift
  struct TranscriptTextView: NSViewRepresentable {
      @Binding var text: String
      let highlightRange: NSRange?
      let onTextChange: (String) -> Void
      let onCommandClick: (Int) -> Void   // char offset

      func makeNSView(context: Context) -> NSScrollView { ... }
      func updateNSView(_ scrollView: NSScrollView, context: Context) { ... }
      func makeCoordinator() -> Coordinator { Coordinator(self) }
  }
  ```
- [ ] Inside `makeNSView`: build an `NSScrollView` with a fully-configured `NSTextView` inside (standard macOS textview settings: `isRichText = false`, `allowsUndo = true`, `isAutomaticQuoteSubstitutionEnabled = false`, font = system body, text container inset `{8, 8}`). Set `delegate = context.coordinator`. Configure `NSScrollView` for `hasVerticalScroller = true`, `autohidesScrollers = true`.
- [ ] Coordinator:
  - `NSTextViewDelegate.textDidChange(_:)` → read `textView.string`, call `parent.onTextChange(newValue)`.
  - Install a local-monitor `NSEvent` handler at `makeNSView` time for `.leftMouseDown` filtered to `.command` modifier; convert the event's window point to the text view's character offset via `characterIndexForPoint(_:)` and call `parent.onCommandClick(offset)`. (Store + remove in `dismantleNSView`.)
- [ ] `updateNSView`:
  - If the binding's `text` differs from `textView.string`, set it (guarded so we don't fight the user mid-typing — compare and no-op if already equal).
  - Apply highlight: first remove any previously applied background attribute for the temporary "harc-current-word" key on the entire range; then if `highlightRange` non-nil and in bounds, apply `.backgroundColor = harcPrimary.opacity(0.15)` on that range.
  - Track previously-applied range in the Coordinator so we can clear it cheaply.
- [ ] Spacebar focus carve-out: install a local `NSEvent` monitor (on window become-key) for `.keyDown` events. If the event's `characters` is `" "` and the window's `firstResponder` is not the text view, call back to the parent VM's `togglePlay()` — or better: **defer this to T6** by wiring keyboard shortcuts from the window-level toolbar. (Cleanest: give the transport's play button a `keyboardShortcut(.space, modifiers: [])` in SwiftUI and rely on SwiftUI's handling, which defers to the text view when it has focus. Verify behavior in T8's runbook.)

**Verification:**
- `swift build` compiles the module.
- Visual: drop the view into a SwiftUI Previews harness with a hardcoded string and verify editing works, undo works, and pass-through of `onTextChange`.
- Command-click: wire a print-statement to `onCommandClick` and confirm character offset is plausible on click.

---

### Task 6 (M): `TranscriptEditorView` + `TranscriptEditorTransportView`

The composed UI.

**Files:**
- Create: `Sources/HarcUI/TranscriptEditor/TranscriptEditorTransportView.swift`
- Create: `Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift`

**Steps:**

- [ ] `TranscriptEditorTransportView`:
  - Horizontal stack: `⟲ 5s` button, play/pause button (SF Symbol toggle), `5s ⟳` button, `Slider(value: $vm.currentTimeSec, in: 0...vm.durationSec)` with `.onChange` calling `vm.seek(to:)`, right-aligned time readout `MM:SS / MM:SS`.
  - Follow `HarcDesign` tokens: buttons are 32pt circle tiles like `RecordingIconTile`; slider uses `.tint(.harcPrimary)`.
  - Audio-missing mode: transport replaced by a `WarningBanner` composable ("Audio file not found — [Reveal expected location]") — tapping shows the parent folder in Finder via `NSWorkspace.shared.activateFileViewerSelecting`.
  - Play button gets `.keyboardShortcut(.space, modifiers: [])` + `.keyboardShortcut(.leftArrow, modifiers: [])` bound to `skip(by: -5)` and `.rightArrow` bound to `skip(by: 5)`.
- [ ] `TranscriptEditorView`:
  - Top bar: title (`recording.displayTitle`, with `●` prefix when dirty), "Reveal in Finder" button, "Save" button (`⌘S`, disabled unless `isDirty`).
  - Middle: `TranscriptTextView(text: $vm.editedText, highlightRange: vm.currentHighlightRange, onTextChange: vm.markEdited, onCommandClick: vm.seekToWord)`. If `wordIndexStale`, show inline hint chip "Timestamps approximate after edits".
  - Bottom: `TranscriptEditorTransportView(vm: vm)`.
  - If `vm.saveError` != nil: toast-style banner at top.
- [ ] Follow existing padding / color conventions (see `TranscriptionDetailView.swift` and `LibraryWindowRootView.swift`).

**Verification:**
- `swift build` compiles.
- SwiftUI Previews: a mock VM (constructor accepts a fully-formed `TranscriptDocument`) renders the view in light + dark appearances; transport displays; typing into the text area updates a preview `Text` echoing `vm.editedText` (sanity).

---

### Task 7 (S): Wire launch flow from Library

Window controller + `AppDelegate` plumbing + Library entry points.

**Files:**
- Create: `HarcApp/WindowControllers/TranscriptEditorWindowController.swift`
- Modify: `HarcApp/AppDelegate.swift`
- Modify: `Sources/HarcUI/LibraryWindowRootView.swift`

**Steps:**

- [ ] `TranscriptEditorWindowController`:
  ```swift
  @MainActor
  final class TranscriptEditorWindowController: NSWindowController, NSWindowDelegate {
      private let vm: TranscriptEditorViewModel
      private let onClose: () -> Void

      init(vm: TranscriptEditorViewModel, onClose: @escaping () -> Void) {
          self.vm = vm
          self.onClose = onClose
          let host = NSHostingController(rootView: TranscriptEditorView().environmentObject(vm))
          let window = NSWindow(contentViewController: host)
          window.title = "Harc Editor"
          window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
          window.setContentSize(NSSize(width: 900, height: 640))
          window.center()
          super.init(window: window)
          window.delegate = self
      }

      func windowShouldClose(_ sender: NSWindow) -> Bool {
          guard vm.isDirty else { return true }
          // Standard save/don't save/cancel alert
          let alert = NSAlert()
          alert.messageText = "Save changes to transcript?"
          alert.addButton(withTitle: "Save")
          alert.addButton(withTitle: "Cancel")
          alert.addButton(withTitle: "Don't Save")
          let response = alert.runModal()
          switch response {
          case .alertFirstButtonReturn: Task { await vm.save(); sender.close() }; return false
          case .alertSecondButtonReturn: return false
          case .alertThirdButtonReturn: return true
          default: return true
          }
      }

      func windowWillClose(_ notification: Notification) { onClose() }
  }
  ```
- [ ] In `AppDelegate`:
  - Add `private var editorWindows: [String: TranscriptEditorWindowController] = [:]`.
  - Add `private func openEditor(for recording: Recording)` modeled on the existing `openDetail(for:)`:
    - If existing window keyed on `wavPath` → surface it.
    - Else create VM async: `Task { let vm = try await TranscriptEditorViewModel(recording: recording, store: store!); … }`.
    - Create the window controller with a close callback that removes the entry from `editorWindows`.
  - Where the current Library `onOpen:` closure calls `openDetail(for:)`, change it to `openEditor(for:)`.
- [ ] In `LibraryWindowRootView`:
  - Add a new callback prop: `let onOpenInEditor: (Recording) -> Void`. Leave `onOpen` in place but wire both: `onOpen` = read-only detail (kept), `onOpenInEditor` = new editor path.
  - Detail pane: rename the hero play button's action to `onOpenInEditor(rec)`. Keep "Read Full Transcript →" pointing at `onOpen` for now.
  - Table `primaryAction:` (double-click) switches to `onOpenInEditor(rec)`.
  - Context-menu "Open" gains a second entry "Open in Editor" wired to `onOpenInEditor`.
- [ ] Propagate `onOpenInEditor` through `LibraryWindowController`'s init (add a parameter).

**Verification:**
- Build: `swift build` / Xcode scheme runs.
- Runbook (see T8 for the full version):
  1. Open Library window.
  2. Double-click a row with existing `.wav` + `.txt` + `.json` → editor opens, audio loads.
  3. Open the same row again → same window is surfaced (not duplicated).
  4. Open a row missing its `.wav` → editor opens with the "Audio file not found" banner; editing still works.

---

### Task 8 (S): Manual smoke-test runbook

No new code; this task is a one-page Markdown checklist added to the PR description (not checked in).

**Steps:**

- [ ] Run the app fresh with a real recording library:
  - [ ] Open Library.
  - [ ] Double-click a row with audio present → editor opens; audio duration populated.
  - [ ] Press space while transport (not text) has focus → playback toggles.
  - [ ] Click inside the text view, type a space → does **not** toggle playback (text focus wins).
  - [ ] Press ⌘← / ⌘→ or the skip buttons → time jumps ±5s.
  - [ ] Drag the scrubber → audio seeks.
  - [ ] Cmd-click a word mid-transcript → audio seeks to that word's start.
  - [ ] Type a correction in the text → title shows ● dirty marker; "stale timestamps" hint appears.
  - [ ] ⌘S → dirty marker clears; close and reopen → edit persists; Library row preview reflects new text.
  - [ ] Close with unsaved edits → Save/Don't Save/Cancel sheet appears and behaves.
- [ ] Delete the source `.wav` then reopen → audio-missing banner; text editing still works and saves.
- [ ] Corrupt the `.json` (write garbage to it) then reopen → word-timestamps-unavailable hint; text editing still works.
- [ ] Ensure no regressions: Library table, popover, recording start/stop, Settings window all still work.

**Verification:**
- Check each box in the runbook and capture any defects as follow-up tickets.

---

## Rollback

All changes are additive:
- New files under `Sources/HarcUI/TranscriptEditor/` and `HarcApp/WindowControllers/TranscriptEditorWindowController.swift`.
- Small additive method on `RecordingStore` (new, doesn't break callers).
- `SessionTranscript` gains an optional field (`manualEditAt`) — old JSONs without it decode fine (`decodeIfPresent`).
- `LibraryWindowRootView` gains a new closure prop (breaking change at the init site, but Harc is single-caller — `LibraryWindowController` — so a same-PR update covers it).

Reverting the PR cleanly removes the feature.

## Effort summary

| Task | Hunch |
|---|---|
| T1 RecordingStore method | S |
| T2 TranscriptDocument + WordIndex | M |
| T3 TranscriptAudioPlayer | S |
| T4 TranscriptEditorViewModel | M |
| T5 TranscriptTextView bridge | M |
| T6 Views + Transport | M |
| T7 WindowController + wiring | S |
| T8 Manual smoke | S |

Rough wall-clock for one focused engineer: **2–3 days of implementation + 0.5 day polish**.
