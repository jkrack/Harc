# Summarization — Stage 4: UI + Copy-for-Prompt

**Feature:** The user-visible flip for local summarization. Stages 1–3 wired the target, service, queue, migration, trigger, and on-launch catch-up; the database has populated summary columns for freshly-recorded meetings, but no view reads them. Stage 4 ships `SummaryCardView` in `TranscriptionDetailView`, the `## Summary` / `## Action Items` prepend in `ExportService.promptString`, and a new `Summarization` tab in Settings.

**Date:** 2026-04-24
**Status:** draft — ready for implementation
**Supersedes:** §7 and §11 "Stage 4" of `2026-04-22-local-summarization-design.md`. §1–§6 and §12 (Stage 3 refresh) of the original spec remain authoritative.

---

## 1. Scope

**In scope:**

- `SummaryCardView` in `HarcUI` — six-state view, mounted in `TranscriptionDetailView` between the title block and `SpeakerNameEditor`
- `ExportService.promptString(for:includeSummary:)` prepends `## Summary` / `## Action Items` above a new `## Transcript` heading; `PromptFrontMatter.render` gains `summary_model` and `summarized_at` keys via an overload
- New `Sources/HarcUI/Settings/SummarizationSettingsView.swift` — Summarization tab with mirrored tier picker + three behavioral toggles
- `SummarizationQueueStore` extended with `@Published var lastFailures: [Int64: String]` so the card can render the `.failed` state without holding its own subscription
- AppDelegate cleanup: remove the stderr-log task that Stage 3 added as a stopgap (Section 7); decode the `SessionTranscript` sidecar off the MainActor in `performSummarization` (hand-off note 6)

**Out of scope (deliberate deltas from original spec):**

- **Interactive action-item checkboxes.** Supersedes §7.2's "Checkboxes on action items toggle `done` and persist via `RecordingStore.updateSummary`" and §11 Stage 4's "Action-item checkboxes that persist via updateSummary". Per-item done state and a checklist UX are their own feature — tracking task completion, syncing to external todo systems, re-parsing on regenerate without losing user flips, etc. V1 renders action items as a read-only bullet list. The `done: Bool` field on `ActionItem` and the `ActionItemsMarkdown.render` helper stay — they're exercised by `performSummarization` when serializing for storage. The UI ignores `done` in v1.
- **Markdown / Docx summary integration.** Amended 2026-04-25: Markdown and DOCX exports are primary user outputs, so they now include `Summary`, `Action Items`, and `Transcript` sections when the existing include-summary preference is enabled and complete summary columns exist. The original Stage 4 copy-for-prompt-only scoping is superseded by this follow-up.
- **Settings-driven summary regeneration on tier change.** Changing `activeSummarizerID` does not retroactively re-summarize. Users regenerate per-recording via the card's `↻` button.
- **`parseWarning` badging.** The field doesn't round-trip per Stage 3 hand-off note 2. V1 accepts the loss.
- **Streaming tokens into the card.** The queue serializes per §4.2; the card flips from `.inFlight` to `.summary` once `performSummarization` writes. No partial rendering.

---

## 2. `SummaryCardView` state machine

A single SwiftUI view. Not an actor, not observable itself — reads state from three environment objects plus a plain `Recording` value and an `activeSummarizerID: String` prop.

### 2.1 View signature

```swift
public struct SummaryCardView: View {
    let recording: Recording
    let activeSummarizerID: String
    let onClearSummary: (Int64) -> Void

    @EnvironmentObject private var queueStore: SummarizationQueueStore
    @EnvironmentObject private var modelStore: ModelManagerStore
}
```

`activeSummarizerID` is passed as a value rather than read via `@EnvironmentObject private var prefs` so snapshot tests can instantiate the view without the full `HarcPreferences` singleton. `onClearSummary` bubbles to the enclosing view-model, parallel to the existing `onRename` / `onSpeakerNamesChanged` callbacks.

### 2.2 State resolution

Computed in a single `CardState.resolve(...)` pure helper each render. Priority order, top wins:

| State | Precondition |
|---|---|
| `.inFlight` | `queueStore.current == recording.id` |
| `.queued` | `queueStore.isQueued(recording.id) && queueStore.current != recording.id` |
| `.summary` | `recording.summaryMarkdown != nil` |
| `.failed(message)` | `queueStore.lastFailures[recording.id] != nil` |
| `.installRequired` | `!modelStore.state(of: activeSummarizerID).isInstalled` |
| `.empty` | default |

**Why `.summary` beats `.failed`.** When a regenerate fails, `performSummarization` throws before it reaches `updateSummary`, so the persisted summary is preserved intact. A user who had a summary and hit Retry should continue to see that summary (still valuable) rather than have it replaced by a failure row. The silent-failure accepted here is a conscious trade — if regenerate failures become frequent enough to need surfacing on top of an existing summary, add a small warning chip in the card header in v2.

`.installRequired` intentionally sits *below* `.summary`: a recording summarized with tier X still renders its summary even if the user later switches the active tier to Y before installing it.

### 2.3 Per-state rendering

All layouts use tokens from `HarcDesign`. Card uses `accent.opacity(0.06)` fill + `accent.opacity(0.3)` stroke matching `ModelRequirementView`. Radius `HarcDesign.Radius.lg` (8pt).

**`.empty`** — Minimal card: muted icon, "No summary yet." subtitle, primary `Generate` button →`Task { await queueStore.queue.enqueue(recording.id) }`.

**`.installRequired`** — Render `ModelRequirementView(descriptor: ModelCatalog.descriptor(for: activeSummarizerID)!, reason: "Generate summaries and action items from your meeting transcripts.")`. Owner of `onLater` is nil — there's no per-feature dismiss; the user toggles auto-summarize in Settings instead.

**`.queued` / `.inFlight`** — Progress card (mono spinner + copy):

- `.inFlight`: "Summarizing with \(tierName)…" + `Cancel` button → `Task { await queueStore.queue.cancel(recording.id) }`. No position text; current is always position 1.
- `.queued`: "Queued · #\(position) of \(totalInFlight)" with same Cancel button. `position` and `totalInFlight` come from the store's public accessors.

**`.failed(message)`** — Error card:

- `Warning` icon (`HarcDesign.warning`), "Summarization failed" header, one-line `message` body (already-localized `error.localizedDescription` captured at `.finished(.failure)` time)
- `Retry` button → `Task { await queueStore.queue.enqueue(recording.id) }`. Retrying clears the failure via Section 2.4's cache-clear-on-enqueue rule.
- `Dismiss` button → clears `lastFailures[recording.id]` via a new `queueStore.dismissFailure(_:)` method.

**`.summary`** — The full card from the mockup:

```
┌──────────────────────────────────────────────────────────┐
│ 🧠 Summary  · generated with Standard · 2 min ago   ↻ ⋯ │
│                                                          │
│ <summary prose, SwiftUI markdown rendering>              │
│                                                          │
│ ACTION ITEMS                                             │
│  • Jason: rewrite tiering page (Friday)                  │
│  • Amy: schedule follow-up on pricing                    │
│  • Sam: file GDPR ticket                                 │
└──────────────────────────────────────────────────────────┘
```

- Tier lookup: `ModelCatalog.descriptor(for: recording.summaryModelID)?.tier` → "Standard"/"Quality"/"Max". Falls back to `recording.summaryModelID` (verbatim) if the descriptor has been removed from the catalog (unlikely but survives a future catalog compaction).
- Summary prose: `Text(.init(markdown: recording.summaryMarkdown))` for inline emphasis. Falls back to plain `Text(recording.summaryMarkdown)` if markdown parsing fails (shouldn't — SwiftUI is lenient).
- "2 min ago" — computed via `RelativeDateTimeFormatter` from `recording.summaryGeneratedAt`. SwiftUI re-renders on timeline invalidation; good-enough freshness without extra state.
- Action items: parse via `SummaryParser.parseActionItems(recording.actionItemsMarkdown ?? "")`. Render each `ActionItem` as `• <actor>: <text> (<due>)` with `HarcDesign.inkPrimary` for actor, `inkTertiary` italic for due. The `_None identified._` sentinel → the entire section renders as italic "No action items identified." instead of an empty bullet list. `done` is ignored.
- `↻` button → `Task { await queueStore.queue.enqueue(recording.id) }`. Enqueuing an id that already has a persisted summary is fine; when the job runs, `updateSummary` overwrites. Dedupe in the queue actor is already in place for the double-click case.
- `⋯` overflow menu (SwiftUI `Menu`):
  - **Copy summary** → pasteboard ← `recording.summaryMarkdown`
  - **Copy action items** → pasteboard ← `recording.actionItemsMarkdown`
  - **Clear summary** → `onClearSummary(recording.id!)` bubbles to the VM, which calls `Task { try? await store.clearSummary(id: id) }`. The VM already observes the store's `observeAll` stream, so the UI re-renders to `.empty` automatically.

### 2.4 Staleness banner

Above the card, outside it (a sibling view in `TranscriptionDetailView`'s VStack). Renders only when `cardState == .summary` and the drift check fires.

**Drift check:**

```swift
private func isStale(recording: Recording) -> Bool {
    guard let source = recording.summarySourceWordCount, source > 0 else { return false }
    let current = recording.transcriptText?
        .split(whereSeparator: \.isWhitespace)
        .count ?? 0
    let diff = abs(current - source)
    return Double(diff) / Double(source) > 0.05
}
```

- Source = word count at generation time (already persisted in column)
- Current = word count of the *cached* transcript on the row. Not re-derived from the JSON sidecar; for long meetings that would be a perceptible hitch. The transcript in `recording.transcriptText` is kept fresh by the existing upsert pipeline.

**Banner shape:** amber background (`warning.opacity(0.10)` fill, `warning.opacity(0.35)` stroke), "Summary is based on an older transcript — regenerate?" + inline Regenerate link action.

**Not dismissible.** The banner self-clears when the user regenerates (`summary_source_word_count` updates, drift drops to ~0%) or when edits bring the transcript back within 5% of the captured count.

### 2.5 Failure cache on the store

`SummarizationQueueStore` gains:

```swift
@Published public private(set) var lastFailures: [Int64: String] = [:]

public func dismissFailure(_ id: Int64) {
    lastFailures.removeValue(forKey: id)
}
```

The `apply(_:)` handler adds two branches:

- `.finished(id, .failure(err))` where `err is CancellationError` → no-op (cancel is user-initiated, not a failure to surface).
- `.finished(id, .failure(err))` otherwise → `lastFailures[id] = err.localizedDescription`.
- `.enqueued(id)` → `lastFailures.removeValue(forKey: id)` (retrying clears the banner).

This is the minimum change to surface `.finished(.failure)` without leaking error observation into every card.

---

## 3. `TranscriptionDetailView` integration

### 3.1 Mount point

Between line 69 (end of title HStack) and line 71 (`SpeakerNameEditor`):

```swift
SummaryCardView(
    recording: recording,
    activeSummarizerID: prefs.activeSummarizerID,
    onClearSummary: onClearSummary
)
```

### 3.2 New view dependencies

`TranscriptionDetailView` gains:

- `@EnvironmentObject private var prefs: HarcPreferences` — for `activeSummarizerID` and `includeSummaryInPrompt`
- `@EnvironmentObject private var queueStore: SummarizationQueueStore` — passed down as `.environmentObject` is inherited automatically; no new injection needed
- `@EnvironmentObject private var modelStore: ModelManagerStore` — same
- Init param `onClearSummary: (Int64) -> Void` — parallels existing callbacks

### 3.3 Copy/Paste toolbar updates

Lines 106–122 of the current `TranscriptionDetailView` currently call `ExportService.promptString(for:)`. Both the overflow menu item and the Paste button update to:

```swift
ExportService.promptString(for: recording, includeSummary: prefs.includeSummaryInPrompt)
```

### 3.4 Callback wiring at parent

Each `TranscriptionDetailView(recording:...)` call site adds:

```swift
onClearSummary: { id in
    Task { try? await store.clearSummary(id: id) }
}
```

Both `LibraryViewModel` and `RecordingsViewModel` already observe `store.observeAll(pinnedFirst:)` in a `for await` loop, so the cleared row re-emits and the view re-renders to `.empty` automatically — no explicit `vm.reload()` needed.

---

## 4. Copy-for-Prompt integration

Option B from brainstorming — surgical change, `ExportInput` unchanged.

### 4.1 `PromptSummaryBlock` value type

New file `Sources/HarcExport/PromptSummaryBlock.swift`:

```swift
public struct PromptSummaryBlock: Equatable, Sendable {
    public let summaryMarkdown: String
    public let actionItemsMarkdown: String
    public let modelID: String
    public let generatedAt: Date

    public init(summaryMarkdown: String, actionItemsMarkdown: String, modelID: String, generatedAt: Date) {
        self.summaryMarkdown = summaryMarkdown
        self.actionItemsMarkdown = actionItemsMarkdown
        self.modelID = modelID
        self.generatedAt = generatedAt
    }

    public static func make(from recording: Recording) -> PromptSummaryBlock? {
        guard let s = recording.summaryMarkdown,
              let a = recording.actionItemsMarkdown,
              let m = recording.summaryModelID,
              let g = recording.summaryGeneratedAt else { return nil }
        return PromptSummaryBlock(summaryMarkdown: s, actionItemsMarkdown: a, modelID: m, generatedAt: g)
    }
}
```

### 4.2 `PromptFrontMatter.render` overload

Current signature:

```swift
static func render(_ input: ExportInput, timeZone: TimeZone = .current) -> String
```

New overload (the existing one forwards to this with `summary: nil`):

```swift
static func render(_ input: ExportInput, summary: PromptSummaryBlock?, timeZone: TimeZone = .current) -> String
```

When `summary != nil`, after the existing `speakers:` emission (or as the last line before the closing `---`), append:

```
summary_model: <yamlScalar(summary.modelID)>
summarized_at: <formatRecorded(summary.generatedAt, timeZone: timeZone)>
```

Both pass through `yamlScalar` / `formatRecorded` for consistency. Existing callers that pass only `input` keep working via the default-parameter overload.

### 4.3 `ExportService.promptString` update

New signature:

```swift
public static func promptString(for recording: Recording, includeSummary: Bool = true) -> String
```

Body:

```swift
let input = ExportInputBuilder.build(from: recording)
let summary = includeSummary ? PromptSummaryBlock.make(from: recording) : nil
let header = PromptFrontMatter.render(input, summary: summary)
let body = MarkdownExporter.render(input)
let summaryBlock = summary.map(renderSummaryBlock) ?? ""
return compose(header: header, summaryBlock: summaryBlock, body: body)
```

`renderSummaryBlock(_ s: PromptSummaryBlock) -> String` returns:

```
## Summary
<s.summaryMarkdown>

## Action Items
<s.actionItemsMarkdown>
```

`compose(header:summaryBlock:body:)` joins non-empty pieces with `\n\n`, and — critically — inserts `## Transcript\n` between the summary block and the body when both are present. `MarkdownExporter` produces a headerless transcript body; injecting the header matches spec §7.4's shape exactly and only happens when a summary is prepended, so existing (summary-less) exports are byte-identical to today's output.

### 4.4 `ExportService.write` threading

`write(recording:format:to:)` gains an `includeSummary: Bool = true` parameter used only in the `.prompt` branch (forwarded into the internal `promptString(for:includeSummary:)` call).

**Complete call-site inventory** — threading `prefs.includeSummaryInPrompt` at each site where the prompt blob reaches a user:

| Call site | File | Action | Threading |
|---|---|---|---|
| Paste button | `HarcUI/TranscriptionDetailView.swift:116` | Copy & paste to frontmost | `prefs.includeSummaryInPrompt` |
| Copy for Prompt | `HarcUI/TranscriptionDetailView.swift:143` | Copy to pasteboard | `prefs.includeSummaryInPrompt` |
| Library copy | `HarcUI/LibraryWindowRootView.swift:807` | Copy to pasteboard | `prefs.includeSummaryInPrompt` |
| Library export | `HarcUI/LibraryWindowRootView.swift:836` | Save `.prompt.md` file | `prefs.includeSummaryInPrompt` |
| Editor copy | `HarcUI/TranscriptEditor/TranscriptEditorView.swift:294` | Copy to pasteboard | `prefs.includeSummaryInPrompt` |
| Editor export | `HarcUI/TranscriptEditor/TranscriptEditorView.swift:313` | Save `.prompt.md` file | `prefs.includeSummaryInPrompt` |
| Auto-paste | `HarcApp/AppDelegate.swift:778` | Copy & paste post-recording | hard-coded `false` or default `true` — see note |

**Auto-paste note.** `AppDelegate.runAutoPaste(for:)` fires immediately after `stopRecording`, before any summarization has happened. At that point the recording's summary columns are all nil, so `PromptSummaryBlock.make(from:)` returns nil and no summary block is emitted regardless of the flag. Threading `prefs.includeSummaryInPrompt` here is harmless but cosmetically confusing; the cleanest implementation is to leave the auto-paste call using the default `true` and rely on the nil-short-circuit in `make(from:)` for correctness.

### 4.5 Default backwards-compat

`promptString(for:)` — the zero-arg form — remains callable via the default parameter. Existing tests that snapshot today's output keep passing; new snapshot tests add coverage for the summary-present and summary-absent-because-pref-false branches.

---

## 5. Summarization Settings tab

New file `Sources/HarcUI/Settings/SummarizationSettingsView.swift`, inserted into `SettingsView.TabView` between Processing and Models.

### 5.1 Form shape

```
Header:
    Summarization
    Harc summarizes finished recordings locally using Gemma 4.

Section "Model":
    Active model  [Standard | Quality | Max]       (segmented picker)
    footer:      Install or remove tiers from the Models tab. [Open Models]
                 (if active tier not installed:) The active summarizer is not installed.
                 Auto-summarize and the Generate button will have no effect.

Section "Behavior":
    ☐ Automatically summarize after recording          (autoSummarizeEnabled)
      ☐ Also when on battery                            (autoSummarizeOnBatteryEnabled)
        footer: Gemma 4 is multi-GB resident and uses power.
    ☐ Include summary in Copy for Prompt                (includeSummaryInPrompt)
       footer: Prepends ## Summary and ## Action Items above the transcript when copying.
```

### 5.2 Bindings

Four bindings, all `@Published` on `HarcPreferences`:

- `$prefs.activeSummarizerID`
- `$prefs.autoSummarizeEnabled`
- `$prefs.autoSummarizeOnBatteryEnabled` — UI-disabled when parent toggle is off (visual only; UserDefaults still honors the value)
- `$prefs.includeSummaryInPrompt`

The segmented picker reuses the pattern from `ModelsSettingsView.activeSummarizerPicker` (lines 108–123 of that file) — `ForEach(ModelCatalog.descriptors(for: .summarizer))`, `.disabled(!models.state(of: d.id).isInstalled)`.

### 5.3 "Open Models" tab switch

`SettingsView` currently has no `selection` binding on its `TabView`. Add one:

```swift
public struct SettingsView: View {
    @State private var selectedTab: Tab = .general
    public enum Tab: Hashable { case general, recording, library, processing, summarization, models }

    public var body: some View {
        TabView(selection: $selectedTab) {
            // ... existing tabs, each with .tag(Tab.X) ...
            SummarizationSettingsView(onOpenModels: { selectedTab = .models })
                .tabItem { Label("Summarization", systemImage: "sparkles") }
                .tag(Tab.summarization)
            // ...
        }
    }
}
```

`SummarizationSettingsView`'s "Open Models" button invokes `onOpenModels()`. Zero new state on `HarcPreferences`.

### 5.4 Environment

`SettingsWindowController` already injects both `prefs` and `modelStore` — no controller changes needed.

---

## 6. AppDelegate cleanup

Two Stage-3 tech-debt items get resolved once Stage 4 UI is in place.

### 6.1 Remove stderr failure log

Lines 915–930 of `AppDelegate.swift` attach a `Task` to `queue.events()` and print `.finished(.failure)` messages to stderr. The Stage 3 refresh doc called this a stopgap for Stage-3-era QA, explicitly marked for removal once Stage 4 surfaces failures visibly.

Delete the entire block. The card's `.failed` state and Section 2.5's `SummarizationQueueStore.lastFailures` cache replace it. Keep a comment pointing at the store's failure cache so the removal's intent survives.

### 6.2 Move JSON sidecar decode off MainActor

Hand-off note 6 from Stage 3: `AppDelegate.performSummarization` is `@MainActor`-isolated and currently does `Data(contentsOf: URL(...))` + `JSONDecoder().decode(SessionTranscript.self, ...)` on that actor. For hour-long meetings that's a multi-MB decode on the UI thread, producing a visible hitch when a summary kicks off.

Fix: wrap the I/O + decode in `Task.detached(priority: .utility)` and `await` the result before the MainActor-bound `modelManager` lookup:

```swift
let sessionTranscript: SessionTranscript = try await Task.detached(priority: .utility) {
    let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode(SessionTranscript.self, from: data)
}.value
```

`PromptTranscriptAdapter.make` is a pure static function, safe to call from MainActor after the detached decode returns. The later `service.summarize(...)` call is already an actor hop, so no additional adjustment needed there.

---

## 7. Edge cases & behavioral defaults

Decisions made during brainstorming that aren't otherwise spelled out above.

- **Mid-queue model switch.** If the user changes `prefs.activeSummarizerID` while jobs are queued, `performSummarization` reads `prefs.activeSummarizerID` at run time, so remaining jobs use the new tier. Matches the spec §1 user story 3 intent ("regenerate with the currently-active summarizer"). No snapshotting at enqueue time.
- **Regenerate on a summary already in progress.** Dedupe in `SummarizationQueue` already no-ops. The `↻` button in the `.summary` state is technically reachable during a brief window before `@Published` updates propagate; clicking it is harmless.
- **Cancel behavior.** `Task { await queueStore.queue.cancel(recording.id) }`. For a queued job this removes it silently (the queue docstring: "the queue never emits for work it never started"). For an in-flight job it cancels the Task, which triggers `SummarizerService.summarize`'s `Generation` stream teardown, which throws `CancellationError`, which the queue swallows (CancellationError → no-op in `apply(_:)`).
- **`MarkdownExporter` header gap.** The existing renderer doesn't emit a `## Transcript` heading. `ExportService.promptString` injects it only when a summary block precedes the body (Section 4.3's `compose`). Summary-less prompt exports stay byte-identical to today's output — zero regression surface.
- **`PromptSummaryBlock.make` partial data.** If any of the four source fields is nil, `make` returns nil and the summary block is omitted entirely, even if the rest are populated. Guards against half-rendered front-matter after a failed migration or a partially-cleared summary. Consistent with Stage 3's "five columns as a package" invariant.

---

## 8. Test plan

### 8.1 HarcUITests — card state machine

Priority: behavioral tests (not snapshot) that instantiate `SummaryCardView` with prepared `Recording` + in-memory `SummarizationQueueStore` + `ModelManagerStore` stubs and assert which subview appears.

- `.empty` when all summary columns are nil and summarizer is installed
- `.installRequired` when all summary columns are nil and summarizer state is `.absent`
- `.queued` when `queueStore.pending.contains(id) && queueStore.current != id`
- `.inFlight` when `queueStore.current == id`
- `.summary` when `summaryMarkdown != nil`
- `.failed` when `lastFailures[id] != nil && summaryMarkdown == nil && current != id`
- Precedence: in-flight beats summary; summary beats failed; failed beats install-required; install-required beats empty
- Staleness banner: shows when word-count drift > 5%, hides when <= 5%, hides when `summarySourceWordCount == nil`, hides when `transcriptText == nil`

Implementation: behavioral tests via the `CardState.resolve(...)` pure helper (§9). The view itself is thin — it switches on `CardState` and renders each case. No dependency on `ViewInspector` or snapshot-diff tooling.

### 8.2 HarcSummarizeTests — queue store failure cache

- Event `.finished(id, .failure(SomeError))` → `lastFailures[id]` populated with the localized description
- Event `.finished(id, .failure(CancellationError()))` → `lastFailures[id]` unchanged (nil)
- Event `.enqueued(id)` → `lastFailures.removeValue(forKey: id)` called (clears prior failure on retry)
- `dismissFailure(id)` removes the entry

### 8.3 HarcExportTests — promptString + front-matter

- Front-matter: `render(input, summary: nil)` produces byte-identical output to the old `render(input)` (regression guard)
- Front-matter: `render(input, summary: .some(...))` includes `summary_model:` and `summarized_at:` after `speakers:` and before the closing `---`
- `promptString(recording, includeSummary: true)` with summary present: has `## Summary`, `## Action Items`, `## Transcript` headings in that order; front-matter includes both new keys
- `promptString(recording, includeSummary: true)` with summary absent (all 5 columns nil): byte-identical to `promptString(recording, includeSummary: false)` — both produce today's output
- `promptString(recording, includeSummary: false)` with summary present: summary block dropped, no new front-matter keys, no `## Transcript` heading injected — today's shape preserved
- `PromptSummaryBlock.make` returns nil when any of four required columns is nil

### 8.4 HarcUITests — Settings tab

- `SummarizationSettingsView` with all four prefs at default: picker shows active tier, three toggles in expected states, tier rows reflect install state from injected `ModelManagerStore`
- "Open Models" button invokes the `onOpenModels` callback once
- Toggling `autoSummarizeEnabled` off disables the battery sub-toggle visually
- Tier rows disabled when their install state is not `.installed`

### 8.5 AppDelegate — manual QA

Not unit-tested (the Stage 3 refresh doc explicitly flags AppDelegate as manual QA territory).

- Record a short meeting → detail pane shows `.inFlight` → `.summary` flip within a minute or two
- Start a long recording, cancel mid-summary → card returns to `.empty` without a `.failed` row (cancel is user-initiated, not a surfaced error)
- Kill the active summarizer by uninstalling from Models → detail pane flips to `.installRequired`
- Toggle `autoSummarizeEnabled` off → record → no auto-enqueue → `.empty` with Generate button
- Paste button on a summarized recording → pasteboard contains `## Summary` / `## Action Items` / `## Transcript` when `includeSummaryInPrompt = true`; untouched shape when false
- Hour-long recording → the MainActor hitch from the pre-Section-6.2 code is absent; spinner starts smoothly

---

## 9. File layout

**New:**

- `Sources/HarcUI/SummaryCardView.swift` — the view
- `Sources/HarcUI/SummaryCardState.swift` — the `CardState` enum + pure `resolve(...)` helper for testability
- `Sources/HarcUI/Settings/SummarizationSettingsView.swift` — the Settings tab
- `Sources/HarcExport/PromptSummaryBlock.swift` — the value type

**Modified:**

- `Sources/HarcUI/TranscriptionDetailView.swift` — mount point, new init param, Copy/Paste threading
- `Sources/HarcUI/SettingsView.swift` — tab binding, new tab insertion
- `Sources/HarcSummarize/SummarizationQueueStore.swift` — `lastFailures` dict + `dismissFailure`
- `Sources/HarcExport/PromptFrontMatter.swift` — new overload with `summary:` param
- `Sources/HarcExport/ExportService.swift` — new `includeSummary:` param threading
- `HarcApp/AppDelegate.swift` — remove stderr log (Section 6.1), move JSON decode off MainActor (Section 6.2)
- Wherever `TranscriptionDetailView(recording:...)` is instantiated — wire `onClearSummary`

**Deps:**

- `HarcUI` already depends on `HarcSummarize` (added in Stage 3) and `HarcModels`. No dep changes.
- `HarcExport` has no new dep; `PromptSummaryBlock` is self-contained and reads from `Recording` which `HarcExport` already depends on.

---

## 10. Implementation phasing (subagent-driven tasks)

Six independently-reviewable tasks, bottom-up:

1. **`PromptSummaryBlock` + `PromptFrontMatter.render` overload + `ExportService.promptString` / `write` threading.** Deliverables: new file, updated renderer, updated export service, snapshot tests for all four summary × pref branches. No UI impact.
2. **`SummarizationQueueStore.lastFailures` + `dismissFailure` + event-apply branches.** Deliverables: store extension, unit tests covering the four event paths (success, failure, cancel-failure, enqueue-clears).
3. **`SummaryCardState` pure helper + unit tests.** Deliverables: enum + pure `resolve(recording:queueStore:modelStore:activeSummarizerID:)` function, behavioral unit tests for state precedence + staleness.
4. **`SummaryCardView` rendering each state.** Deliverables: view file, visual correctness via `ViewInspector` or snapshot tests (decision during task) for the six states. Mount in `TranscriptionDetailView`; thread `onClearSummary` at the call site.
5. **`SummarizationSettingsView` + `SettingsView` tab binding.** Deliverables: new settings view, tab binding refactor, unit tests for the callback + toggle interlocks.
6. **AppDelegate cleanup.** Deliverables: remove stderr-log block, wrap JSON decode in `Task.detached`. No new tests (covered by manual QA Section 8.5).

Tasks 1–3 can ship in parallel (no cross-dependencies). Task 4 depends on 2 + 3. Task 5 is independent. Task 6 is a finalizer — merge last so the stderr log stays for QA until the UI flip lands.

Tasks 1, 2, 3, 5, 6 are mechanical TDD (Haiku implementer + Sonnet spec-compliance review + `superpowers:code-reviewer` for tasks with real logic). Task 4 is concurrency- and design-token-sensitive — Sonnet implementer, full review pipeline.

---

## 11. What ships visibly after Stage 4 merges

The user-visible flip. After merge:

- The detail pane shows a summary card for every recording that has one (auto-summarized since Stage 3 landed, or manually triggered via `Generate`).
- Recordings without a summary show `Generate` (or `Install Gemma`, or a progress row, or a failure row) instead of nothing.
- Copy-for-Prompt prepends the summary + action items above the transcript when the pref is on.
- Settings → Summarization gives users a single place to tune auto-summarize + prompt-copy behavior.
- The stderr log from Stage 3 is gone; failures surface in the card instead.
- The MainActor hitch on summary start (hour-long recordings) is gone.

Stage 4 is the last stage planned under the original 2026-04-22 spec. Post-ship open questions — cross-recording summary, custom prompts, editable summaries — are v2+ territory and get their own specs.
