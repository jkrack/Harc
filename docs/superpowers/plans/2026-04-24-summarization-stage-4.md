# Summarization Stage 4 — UI + Copy-for-Prompt

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip the user-visible surface for local summarization. After this plan merges, `TranscriptionDetailView` renders a `SummaryCardView` whose six states (`inFlight`, `queued`, `summary`, `failed`, `installRequired`, `empty`) cover every Stage 3 queue + persistence outcome; Copy-for-Prompt prepends a `## Summary` / `## Action Items` block when the pref is on; a new Summarization tab in Settings exposes the auto-summarize + prompt-copy toggles.

**Architecture:** Six bite-sized additions that compose cleanly on Stage 3's already-wired queue, store, and preferences. `HarcExport` gains `PromptSummaryBlock` + a render overload on `PromptFrontMatter` + an `includeSummary:` flag on `ExportService.promptString` / `write`. `HarcSummarize` gains failure tracking on `SummarizationQueueStore`. `HarcUI` gains `SummaryCardState` (pure helper), `SummaryCardView` (thin switch), `SummarizationSettingsView`, and tab-selection binding on `SettingsView`. `TranscriptionDetailView` mounts the card + threads the pref through Copy/Paste. `AppDelegate` drops the Stage 3 stderr stopgap and moves the sidecar JSON decode off MainActor.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI, GRDB (already wired), Swift Testing (`@Suite` / `@Test` / `#expect`), existing mlx-swift-lm deps (not touched here).

**Spec:** `docs/superpowers/specs/2026-04-24-summarization-stage-4-design.md` (supersedes §7 and §11 Stage 4 of the 2026-04-22 parent spec).

**Hand-off notes still load-bearing from Stages 2 + 3:**
1. `SummarizationQueue.cancel(current)` propagates a `CancellationError` through the `.finished` event. Failure-cache logic (§2.5 spec) must swallow it.
2. `SummarizationQueueStore.queue` is a public property; UI can call `queueStore.queue.enqueue(id)` / `.cancel(id)` directly.
3. `SummaryPrompt` / `SummaryParser` / `ActionItem` / `ActionItemsMarkdown` are shipped — consumed but not modified.
4. The `@Published` refresh path is intact — toggling UserDefaults via `HarcPreferences` re-renders any `@EnvironmentObject` consumer without manual notification work.

---

## File structure

**Created:**

- `Sources/HarcExport/PromptSummaryBlock.swift` — value type + `make(from: Recording)` factory
- `Sources/HarcUI/SummaryCardState.swift` — `CardState` enum + pure `CardState.resolve(...)` helper + `isStale(...)` helper
- `Sources/HarcUI/SummaryCardView.swift` — the view (thin switch on CardState)
- `Sources/HarcUI/Settings/SummarizationSettingsView.swift` — the Summarization Settings tab
- `Tests/HarcExportTests/PromptSummaryBlockTests.swift` — factory + Equatable
- `Tests/HarcUITests/SummaryCardStateTests.swift` — the six state precedence tests + staleness

**Modified:**

- `Sources/HarcExport/PromptFrontMatter.swift` — new `render(_:summary:timeZone:)` overload; existing `render(_:timeZone:)` becomes a forwarder
- `Sources/HarcExport/ExportService.swift` — `promptString(for:includeSummary:)` + `write(recording:format:to:includeSummary:)` with default-true backwards compat; `compose(header:summaryBlock:body:)` private helper
- `Sources/HarcSummarize/SummarizationQueueStore.swift` — `@Published lastFailures: [Int64: String]`, `dismissFailure(_:)`, new branches in `apply(_:)`
- `Sources/HarcUI/TranscriptionDetailView.swift` — `@EnvironmentObject var prefs`, new init param `onClearSummary`, `SummaryCardView` mounted between line 69 (title HStack end) and line 71 (SpeakerNameEditor), Copy/Paste threading at lines 116 + 143
- `Sources/HarcUI/SettingsView.swift` — `@State var selectedTab`, `.tag(...)`, new Summarization tab
- `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift` — accept + inject `prefs`, `queueStore`, `modelStore`, `onClearSummary`
- `HarcApp/AppDelegate.swift` — pass env objects + `onClearSummary` in `openDetail`; remove stderr-log block (lines 915–930); wrap sidecar JSON decode in `Task.detached` (in `performSummarization`)
- `Sources/HarcUI/LibraryWindowRootView.swift` — thread `prefs.includeSummaryInPrompt` at lines 807 + 836
- `Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift` — thread `prefs.includeSummaryInPrompt` at lines 294 + 313
- `Tests/HarcExportTests/ExportServiceTests.swift` — new test cases for the four `(includeSummary × summary-present)` branches
- `Tests/HarcExportTests/PromptFrontMatterTests.swift` — new test cases for the `summary: nil` (byte-identical) + `summary: .some(...)` (two new keys) branches
- `Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift` — failure cache tests

**Not modified:** `Package.swift`, `Tests/HarcStoreTests/*`, `MarkdownExporter.swift`, `DocxExporter.swift`, `ExportInput.swift`, `ActionItemsMarkdown.swift`, `SummaryParser.swift`, `SummarizationQueue.swift`, `Recording.swift`, `RecordingStore.swift`.

---

## Task 1 — `PromptSummaryBlock` + `PromptFrontMatter` overload + `ExportService` threading

**Files:**
- Create: `Sources/HarcExport/PromptSummaryBlock.swift`
- Modify: `Sources/HarcExport/PromptFrontMatter.swift`
- Modify: `Sources/HarcExport/ExportService.swift`
- Create: `Tests/HarcExportTests/PromptSummaryBlockTests.swift`
- Modify: `Tests/HarcExportTests/PromptFrontMatterTests.swift`
- Modify: `Tests/HarcExportTests/ExportServiceTests.swift`

### Step 1.1 — Write failing test for `PromptSummaryBlock.make`

- [ ] Create the new test file.

```swift
// Tests/HarcExportTests/PromptSummaryBlockTests.swift
import Testing
import Foundation
import HarcStore
@testable import HarcExport

@Suite("PromptSummaryBlock")
struct PromptSummaryBlockTests {
    @Test("make returns nil when any of the four required columns is nil")
    func makeNilWhenAnyFieldMissing() {
        let base = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(),
            summaryMarkdown: nil,
            actionItemsMarkdown: "- [ ] task",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: Date(),
            summarySourceWordCount: 100
        )
        #expect(PromptSummaryBlock.make(from: base) == nil)

        var r2 = base; r2.summaryMarkdown = "s"; r2.actionItemsMarkdown = nil
        #expect(PromptSummaryBlock.make(from: r2) == nil)

        var r3 = base; r3.summaryMarkdown = "s"; r3.summaryModelID = nil
        #expect(PromptSummaryBlock.make(from: r3) == nil)

        var r4 = base; r4.summaryMarkdown = "s"; r4.summaryGeneratedAt = nil
        #expect(PromptSummaryBlock.make(from: r4) == nil)
    }

    @Test("make returns populated block when all four required columns are present")
    func makePopulated() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(),
            summaryMarkdown: "The team agreed…",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 100
        )
        let block = PromptSummaryBlock.make(from: rec)
        #expect(block?.summaryMarkdown == "The team agreed…")
        #expect(block?.actionItemsMarkdown == "- [ ] Jason: ship it")
        #expect(block?.modelID == "gemma-4-e2b-it-4bit")
        #expect(block?.generatedAt == date)
    }

    @Test("Equatable identity")
    func equatable() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let a = PromptSummaryBlock(summaryMarkdown: "s", actionItemsMarkdown: "a", modelID: "m", generatedAt: date)
        let b = PromptSummaryBlock(summaryMarkdown: "s", actionItemsMarkdown: "a", modelID: "m", generatedAt: date)
        #expect(a == b)
    }
}
```

### Step 1.2 — Run tests to verify they fail

Run: `swift test --filter PromptSummaryBlockTests`
Expected: FAIL — `PromptSummaryBlock` is undefined.

### Step 1.3 — Implement `PromptSummaryBlock.swift`

- [ ] Create the source file.

```swift
// Sources/HarcExport/PromptSummaryBlock.swift
import Foundation
import HarcStore

/// Extracted summary metadata for the prompt export. Non-nil only when a
/// recording has all four required summary columns populated; partial data
/// returns nil rather than a half-rendered block.
public struct PromptSummaryBlock: Equatable, Sendable {
    public let summaryMarkdown: String
    public let actionItemsMarkdown: String
    public let modelID: String
    public let generatedAt: Date

    public init(
        summaryMarkdown: String,
        actionItemsMarkdown: String,
        modelID: String,
        generatedAt: Date
    ) {
        self.summaryMarkdown = summaryMarkdown
        self.actionItemsMarkdown = actionItemsMarkdown
        self.modelID = modelID
        self.generatedAt = generatedAt
    }

    /// Returns nil when any of `summaryMarkdown`, `actionItemsMarkdown`,
    /// `summaryModelID`, or `summaryGeneratedAt` is missing. The fifth
    /// column (`summarySourceWordCount`) is not required here — the prompt
    /// export doesn't surface word count.
    public static func make(from recording: Recording) -> PromptSummaryBlock? {
        guard let summary = recording.summaryMarkdown,
              let items = recording.actionItemsMarkdown,
              let modelID = recording.summaryModelID,
              let generatedAt = recording.summaryGeneratedAt else {
            return nil
        }
        return PromptSummaryBlock(
            summaryMarkdown: summary,
            actionItemsMarkdown: items,
            modelID: modelID,
            generatedAt: generatedAt
        )
    }
}
```

### Step 1.4 — Run tests to verify they pass

Run: `swift test --filter PromptSummaryBlockTests`
Expected: PASS — three tests green.

### Step 1.5 — Commit

```bash
git add Sources/HarcExport/PromptSummaryBlock.swift Tests/HarcExportTests/PromptSummaryBlockTests.swift
git commit -m "feat(export): PromptSummaryBlock value type + make(from:) factory"
```

### Step 1.6 — Write failing test for `PromptFrontMatter.render` overload

- [ ] Append test cases to `Tests/HarcExportTests/PromptFrontMatterTests.swift`.

```swift
    @Test("render without summary is byte-identical to the legacy single-arg render")
    func renderNoSummaryByteIdentical() {
        let input = ExportInput(
            title: "Q3 planning",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            durationSeconds: 3600,
            tags: ["team"],
            speakerNames: [0: "Amy", 1: "Jason"],
            segments: [
                .init(speaker: 0, text: "We should…"),
                .init(speaker: 1, text: "Agreed."),
            ]
        )
        let tz = TimeZone(identifier: "UTC")!
        let legacy = PromptFrontMatter.render(input, timeZone: tz)
        let overloaded = PromptFrontMatter.render(input, summary: nil, timeZone: tz)
        #expect(legacy == overloaded)
    }

    @Test("render with summary emits summary_model and summarized_at before closing ---")
    func renderWithSummaryEmitsNewKeys() {
        let input = ExportInput(
            title: "Q3 planning",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            durationSeconds: 3600,
            segments: [.init(speaker: nil, text: "hi")]
        )
        let summary = PromptSummaryBlock(
            summaryMarkdown: "s",
            actionItemsMarkdown: "a",
            modelID: "gemma-4-e2b-it-4bit",
            generatedAt: Date(timeIntervalSince1970: 1_714_003_800)
        )
        let tz = TimeZone(identifier: "UTC")!
        let out = PromptFrontMatter.render(input, summary: summary, timeZone: tz)

        #expect(out.contains("summary_model: gemma-4-e2b-it-4bit"))
        #expect(out.contains("summarized_at: 2024-04-25T01:30:00+00:00"))

        // Keys must appear INSIDE the front-matter block, before the closing ---.
        let lines = out.components(separatedBy: "\n")
        guard let openIdx = lines.firstIndex(of: "---"),
              let closeIdx = lines.lastIndex(of: "---") else {
            Issue.record("front-matter fences missing"); return
        }
        let modelLineIdx = lines.firstIndex(where: { $0.hasPrefix("summary_model:") })
        let dateLineIdx = lines.firstIndex(where: { $0.hasPrefix("summarized_at:") })
        #expect(modelLineIdx.map { openIdx < $0 && $0 < closeIdx } == true)
        #expect(dateLineIdx.map { openIdx < $0 && $0 < closeIdx } == true)
    }

    @Test("render with summary escapes modelID via yamlScalar when it contains reserved chars")
    func renderSummaryModelYamlEscape() {
        let input = ExportInput(
            title: "x",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            durationSeconds: nil,
            segments: [.init(speaker: nil, text: "hi")]
        )
        let summary = PromptSummaryBlock(
            summaryMarkdown: "s",
            actionItemsMarkdown: "a",
            modelID: "has: colon",   // must be quoted
            generatedAt: Date(timeIntervalSince1970: 1_714_003_800)
        )
        let out = PromptFrontMatter.render(input, summary: summary, timeZone: TimeZone(identifier: "UTC")!)
        #expect(out.contains("summary_model: \"has: colon\""))
    }
```

**Note on the timestamp in the second test:** `1_714_003_800` is `1_714_000_000 + 3800`, so the formatted date depends only on the epoch arithmetic and the `UTC` zone. Compute the expected string from `formatRecorded` if the assertion above looks wrong in practice; the point is that `summarized_at:` appears as an ISO-8601 line.

### Step 1.7 — Run tests to verify they fail

Run: `swift test --filter PromptFrontMatterTests`
Expected: FAIL — `render(_:summary:timeZone:)` does not exist.

### Step 1.8 — Implement the `PromptFrontMatter` overload

- [ ] Modify `Sources/HarcExport/PromptFrontMatter.swift`. Refactor the existing `render(_:timeZone:)` to delegate to a new summary-aware overload.

```swift
    /// Legacy / default form — no summary block. Preserved for callers that
    /// pre-date Stage 4.
    static func render(_ input: ExportInput, timeZone: TimeZone = .current) -> String {
        return render(input, summary: nil, timeZone: timeZone)
    }

    /// Summary-aware form. When `summary != nil`, emits `summary_model:` and
    /// `summarized_at:` after the `speakers:` key and before the closing `---`.
    static func render(_ input: ExportInput, summary: PromptSummaryBlock?, timeZone: TimeZone = .current) -> String {
        var lines: [String] = ["---"]

        let trimmedTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            lines.append("title: \(yamlScalar(trimmedTitle))")
        }

        lines.append("recorded: \(formatRecorded(input.startedAt, timeZone: timeZone))")

        if let secs = input.durationSeconds {
            lines.append("duration: \(formatDuration(secs))")
        }

        if !input.tags.isEmpty {
            let joined = input.tags.joined(separator: ", ")
            lines.append("tags: \(yamlScalar(joined))")
        }

        let speakers = speakerCount(in: input.segments)
        if speakers >= 2, hasAnyOverride(input: input) {
            let joined = (0..<speakers).map { i -> String in
                if let raw = input.speakerNames[i] {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                return "Speaker \(i + 1)"
            }.joined(separator: ", ")
            lines.append("participants: \(yamlScalar(joined))")
        }
        if speakers >= 2 {
            lines.append("speakers: \(speakers)")
        }

        if let summary {
            lines.append("summary_model: \(yamlScalar(summary.modelID))")
            lines.append("summarized_at: \(formatRecorded(summary.generatedAt, timeZone: timeZone))")
        }

        lines.append("---")
        return lines.joined(separator: "\n")
    }
```

### Step 1.9 — Run tests to verify they pass

Run: `swift test --filter PromptFrontMatterTests`
Expected: PASS — all (pre-existing + new) tests green.

### Step 1.10 — Commit

```bash
git add Sources/HarcExport/PromptFrontMatter.swift Tests/HarcExportTests/PromptFrontMatterTests.swift
git commit -m "feat(export): PromptFrontMatter.render overload with summary_model + summarized_at keys"
```

### Step 1.11 — Write failing tests for `ExportService.promptString(for:includeSummary:)`

- [ ] Append test cases to `Tests/HarcExportTests/ExportServiceTests.swift`.

```swift
    @Test("promptString with includeSummary=true and summary present inserts summary + action items + ## Transcript before body")
    func promptStringSummaryPresent() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: date,
            transcriptText: "Hello world",
            summaryMarkdown: "The team agreed.",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 2
        )
        let out = ExportService.promptString(for: rec, includeSummary: true)

        // Front-matter has the new keys.
        #expect(out.contains("summary_model: gemma-4-e2b-it-4bit"))
        #expect(out.contains("summarized_at:"))

        // Body composition in order: ## Summary, ## Action Items, ## Transcript, body.
        guard let summaryIdx = out.range(of: "## Summary"),
              let actionIdx = out.range(of: "## Action Items"),
              let transcriptIdx = out.range(of: "## Transcript"),
              let bodyIdx = out.range(of: "Hello world") else {
            Issue.record("expected headings + body"); return
        }
        #expect(summaryIdx.lowerBound < actionIdx.lowerBound)
        #expect(actionIdx.lowerBound < transcriptIdx.lowerBound)
        #expect(transcriptIdx.lowerBound < bodyIdx.lowerBound)

        // Summary and action items content is verbatim.
        #expect(out.contains("The team agreed."))
        #expect(out.contains("- [ ] Jason: ship it"))
    }

    @Test("promptString with includeSummary=false drops summary block even when columns are present")
    func promptStringSummaryExcluded() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: date,
            transcriptText: "Hello world",
            summaryMarkdown: "The team agreed.",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 2
        )
        let out = ExportService.promptString(for: rec, includeSummary: false)
        #expect(!out.contains("## Summary"))
        #expect(!out.contains("## Action Items"))
        #expect(!out.contains("## Transcript"))
        #expect(!out.contains("summary_model:"))
        #expect(!out.contains("summarized_at:"))
        #expect(out.contains("Hello world"))
    }

    @Test("promptString with summary absent is byte-identical regardless of includeSummary flag")
    func promptStringSummaryAbsentIdempotent() {
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            transcriptText: "Hello"
        )
        let withFlag = ExportService.promptString(for: rec, includeSummary: true)
        let withoutFlag = ExportService.promptString(for: rec, includeSummary: false)
        let legacy = ExportService.promptString(for: rec)
        #expect(withFlag == withoutFlag)
        #expect(withFlag == legacy)
        #expect(!withFlag.contains("## Summary"))
        #expect(!withFlag.contains("## Transcript"))
    }
```

### Step 1.12 — Run tests to verify they fail

Run: `swift test --filter ExportServiceTests`
Expected: FAIL — `promptString(for:includeSummary:)` does not exist.

### Step 1.13 — Implement `ExportService.promptString(for:includeSummary:)` + `compose`

- [ ] Modify `Sources/HarcExport/ExportService.swift`. Keep the zero-arg form as a default-parameter forwarder.

```swift
    /// Render the prompt-formatted blob. When `includeSummary` is true AND the
    /// recording has a complete summary (all four required columns populated),
    /// prepends `## Summary` + `## Action Items` above a `## Transcript` heading
    /// and the body. Falls back to today's byte-identical output when summary
    /// is absent or excluded. Pure.
    public static func promptString(for recording: Recording, includeSummary: Bool = true) -> String {
        let input = ExportInputBuilder.build(from: recording)
        let summary = includeSummary ? PromptSummaryBlock.make(from: recording) : nil
        let header = PromptFrontMatter.render(input, summary: summary)
        let body = MarkdownExporter.render(input)
        let summaryBlock = summary.map(Self.renderSummaryBlock) ?? ""
        return Self.compose(header: header, summaryBlock: summaryBlock, body: body)
    }

    private static func renderSummaryBlock(_ s: PromptSummaryBlock) -> String {
        """
        ## Summary
        \(s.summaryMarkdown)

        ## Action Items
        \(s.actionItemsMarkdown)
        """
    }

    /// Joins the three composed pieces. Inserts `## Transcript\n` between the
    /// summary block and the body only when both are present — today's
    /// summary-less prompt output stays byte-identical (no new headings).
    private static func compose(header: String, summaryBlock: String, body: String) -> String {
        switch (body.isEmpty, summaryBlock.isEmpty) {
        case (true, true):
            return header + "\n"
        case (true, false):
            return header + "\n\n" + summaryBlock
        case (false, true):
            return header + "\n\n" + body
        case (false, false):
            return header + "\n\n" + summaryBlock + "\n\n## Transcript\n" + body
        }
    }
```

- [ ] Update `write(recording:format:to:)` to forward `includeSummary`:

```swift
    public static func write(
        recording: Recording,
        format: ExportFormat,
        to url: URL,
        includeSummary: Bool = true
    ) throws {
        let input = ExportInputBuilder.build(from: recording)
        let data: Data
        switch format {
        case .markdown:
            data = Data(MarkdownExporter.render(input).utf8)
        case .docx:
            data = try DocxExporter.render(input)
        case .prompt:
            data = Data(ExportService.promptString(for: recording, includeSummary: includeSummary).utf8)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileWriteOutOfSpaceError:
                    throw ExportError.diskFull
                case NSFileWriteNoPermissionError:
                    throw ExportError.permissionDenied(url: url)
                default:
                    break
                }
            }
            throw ExportError.writeFailed(url: url, underlying: error.localizedDescription)
        }
    }
```

### Step 1.14 — Run tests to verify they pass

Run: `swift test --filter ExportServiceTests`
Expected: PASS — all new + pre-existing tests green.

### Step 1.15 — Commit

```bash
git add Sources/HarcExport/ExportService.swift Tests/HarcExportTests/ExportServiceTests.swift
git commit -m "feat(export): includeSummary flag on promptString/write; compose summary above ## Transcript"
```

### Step 1.16 — Thread `includeSummary` at the non-Detail UI call sites

`TranscriptionDetailView` already has `prefs` injected via `@EnvironmentObject` (added in Task 4 / Step 4.5), so its threading happens there. `LibraryWindowRootView` and `TranscriptEditorView` don't currently observe `HarcPreferences`; rather than expanding their environment surface for one boolean, read the pref inline via the `HarcPreferences.shared` singleton — same pattern used elsewhere in the codebase for read-only pref lookups outside SwiftUI views' direct observation graph.

- [ ] Modify `Sources/HarcUI/LibraryWindowRootView.swift` around line 807:

```swift
let s = ExportService.promptString(for: rec, includeSummary: HarcPreferences.shared.includeSummaryInPrompt)
```

- [ ] Modify `Sources/HarcUI/LibraryWindowRootView.swift` around line 836:

```swift
try ExportService.write(
    recording: rec,
    format: format,
    to: url,
    includeSummary: HarcPreferences.shared.includeSummaryInPrompt
)
```

- [ ] Modify `Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift` around line 294:

```swift
let s = ExportService.promptString(for: vm.recording, includeSummary: HarcPreferences.shared.includeSummaryInPrompt)
```

- [ ] Modify `Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift` around line 313:

```swift
try ExportService.write(
    recording: vm.recording,
    format: format,
    to: url,
    includeSummary: HarcPreferences.shared.includeSummaryInPrompt
)
```

- [ ] Leave `HarcApp/AppDelegate.swift:778` (auto-paste) unchanged — it fires before summarization runs, so `PromptSummaryBlock.make(from:)` returns nil regardless of the flag. Threading the pref here is cosmetic noise.

**Note for Detail view:** `Sources/HarcUI/TranscriptionDetailView.swift` lines 116 and 143 also need threading, but `prefs` arrives via `@EnvironmentObject` only in Task 4 (Step 4.5). Defer that pair to Task 4; the unchanged call sites use `promptString(for:)` (default `includeSummary: true`) until then, which gives existing manual QA the summary-included default.

### Step 1.17 — Verify build

Run: `swift build`
Expected: no errors.

### Step 1.18 — Commit

```bash
git add Sources/HarcUI/LibraryWindowRootView.swift Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift
git commit -m "chore(ui): thread includeSummaryInPrompt through library + editor promptString/write"
```

---

## Task 2 — `SummarizationQueueStore.lastFailures` + `dismissFailure`

**Files:**
- Modify: `Sources/HarcSummarize/SummarizationQueueStore.swift`
- Modify: `Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift`

### Step 2.1 — Write failing test for failure capture

- [ ] Append test cases to `Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift`.

```swift
    @Test("store captures non-cancellation .finished(.failure) into lastFailures keyed by id")
    @MainActor
    func capturesNonCancellationFailures() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            throw Boom()
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(42)
        await expectEventually {
            await MainActor.run { store.lastFailures[42] == "boom" }
        }
    }

    @Test("store swallows CancellationError — lastFailures stays nil when cancellation lands")
    @MainActor
    func swallowsCancellationError() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            // Cooperate with cancellation.
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(77)
        // Wait for it to become current, then cancel.
        await expectEventually { await MainActor.run { store.current == 77 } }
        await queue.cancel(77)
        await expectEventually { await MainActor.run { store.current == nil } }

        // Give the event-apply loop one more hop.
        try await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            #expect(store.lastFailures[77] == nil)
        }
    }

    @Test("enqueue clears a prior failure entry for the same id")
    @MainActor
    func enqueueClearsPriorFailure() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        var firstRun = true
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            if firstRun {
                firstRun = false
                throw Boom()
            }
            // Second run succeeds.
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(5)
        await expectEventually { await MainActor.run { store.lastFailures[5] == "boom" } }

        await queue.enqueue(5)
        // On enqueue, the failure should be cleared immediately (before the next run).
        await expectEventually { await MainActor.run { store.lastFailures[5] == nil } }
    }

    @Test("dismissFailure(id) removes the entry")
    @MainActor
    func dismissFailure() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in throw Boom() }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(8)
        await expectEventually { await MainActor.run { store.lastFailures[8] == "boom" } }

        store.dismissFailure(8)
        #expect(store.lastFailures[8] == nil)
    }
```

### Step 2.2 — Run tests to verify they fail

Run: `swift test --filter SummarizationQueueStoreTests`
Expected: FAIL — `lastFailures` and `dismissFailure` are undefined; compile errors.

### Step 2.3 — Extend `SummarizationQueueStore`

- [ ] Modify `Sources/HarcSummarize/SummarizationQueueStore.swift`.

Add the `@Published` property and `dismissFailure` method, and extend `apply(_:)` to handle failure events and clear on enqueue.

```swift
    @Published public private(set) var lastFailures: [Int64: String] = [:]

    // ... existing init / isQueued / position / totalInFlight unchanged ...

    /// Remove a failure entry — the UI's Dismiss action on the `.failed`
    /// card state calls this to clear the banner without re-enqueuing.
    public func dismissFailure(_ id: Int64) {
        lastFailures.removeValue(forKey: id)
    }

    // MARK: - Internals

    private func apply(_ event: SummarizationQueueEvent) {
        switch event {
        case .enqueued(let id):
            // Retrying (re-enqueuing an id with a prior failure) clears the
            // banner so the card shows .queued / .inFlight instead of stale
            // .failed. Also handles the plain "first enqueue" case where
            // lastFailures[id] is already nil.
            lastFailures.removeValue(forKey: id)
            if current != id, !pending.contains(id) {
                pending.append(id)
            }
        case .started(let id):
            if let idx = pending.firstIndex(of: id) { pending.remove(at: idx) }
            current = id
        case .finished(let id, let result):
            if current == id { current = nil }
            if case .failure(let error) = result {
                // CancellationError is user-initiated — don't surface as a
                // failure in the UI; the card returns to .empty / .summary
                // based on summaryMarkdown presence.
                if !(error is CancellationError) {
                    lastFailures[id] = error.localizedDescription
                }
            }
        case .queueDrained:
            current = nil
            pending.removeAll()
        }
    }
```

### Step 2.4 — Run tests to verify they pass

Run: `swift test --filter SummarizationQueueStoreTests`
Expected: PASS — old + four new tests green.

### Step 2.5 — Commit

```bash
git add Sources/HarcSummarize/SummarizationQueueStore.swift Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift
git commit -m "feat(summarize): SummarizationQueueStore captures non-cancellation failures + dismissFailure"
```

---

## Task 3 — `SummaryCardState` pure helper + tests

**Files:**
- Create: `Sources/HarcUI/SummaryCardState.swift`
- Create: `Tests/HarcUITests/SummaryCardStateTests.swift`

### Step 3.1 — Write the `.empty` test

- [ ] Create `Tests/HarcUITests/SummaryCardStateTests.swift`.

```swift
import Testing
import Foundation
import HarcStore
import HarcModels
@testable import HarcSummarize
@testable import HarcUI

@MainActor
@Suite("SummaryCardState.resolve")
struct SummaryCardStateTests {

    private func makeStore(current: Int64? = nil, pending: [Int64] = [], failures: [Int64: String] = [:]) async -> SummarizationQueueStore {
        // Queue with a no-op perform — we set state directly via enqueue where needed.
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let store = await SummarizationQueueStore(queue: queue)
        // Directly stub internal state for tests by bypassing the event stream.
        // If setters aren't publicly available, the resolve(...) signature
        // should accept primitives (current: Int64?, isQueued: Bool, lastFailure: String?)
        // to keep the helper pure. See resolution signature below.
        return store
    }

    @Test("empty when summary nil, not queued, installed, no failure")
    func empty() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false,
            isQueued: false,
            position: nil,
            totalInFlight: 0,
            isSummarizerInstalled: true,
            lastFailure: nil
        )
        #expect(state == .empty)
    }
}
```

**Decision made in this step:** `SummaryCardState.resolve` takes primitive state parameters — not references to the store/modelStore — so the helper stays fully pure and testable without store stubs. The view translates its observed state into primitives at render time.

### Step 3.2 — Run to verify failure

Run: `swift test --filter SummaryCardStateTests`
Expected: FAIL — `SummaryCardState` undefined.

### Step 3.3 — Scaffold `SummaryCardState.swift`

- [ ] Create `Sources/HarcUI/SummaryCardState.swift`.

```swift
import Foundation
import HarcStore

/// The one-of-six state a `SummaryCardView` renders. Computed by the pure
/// `resolve(...)` helper so precedence logic is testable without SwiftUI.
public enum SummaryCardState: Equatable {
    /// No summary, no queued work, summarizer installed — user gets the
    /// "Generate" CTA.
    case empty
    /// No summary, summarizer not installed — renders `ModelRequirementView`.
    case installRequired
    /// Queued behind at least one other job (`position` is 1-based).
    case queued(position: Int, totalInFlight: Int)
    /// Currently generating.
    case inFlight
    /// Last run for this id failed; shows `message` + Retry + Dismiss.
    case failed(message: String)
    /// Summary persisted — the rich card.
    case summary

    public static func resolve(
        recording: Recording,
        isInFlight: Bool,
        isQueued: Bool,
        position: Int?,
        totalInFlight: Int,
        isSummarizerInstalled: Bool,
        lastFailure: String?
    ) -> SummaryCardState {
        // Precedence (top wins): inFlight > queued > summary > failed > installRequired > empty.
        if isInFlight { return .inFlight }
        if isQueued, let pos = position { return .queued(position: pos, totalInFlight: totalInFlight) }
        if recording.summaryMarkdown != nil { return .summary }
        if let msg = lastFailure { return .failed(message: msg) }
        if !isSummarizerInstalled { return .installRequired }
        return .empty
    }

    /// True when the current transcript word count differs from the persisted
    /// `summary_source_word_count` by more than 5 %. Shown as a nudge banner
    /// above the `.summary` card. False when either field is missing.
    public static func isStale(recording: Recording) -> Bool {
        guard let source = recording.summarySourceWordCount, source > 0 else { return false }
        let current = recording.transcriptText?
            .split(whereSeparator: { $0.isWhitespace })
            .count ?? 0
        let diff = abs(current - source)
        return Double(diff) / Double(source) > 0.05
    }
}
```

### Step 3.4 — Run test to verify pass

Run: `swift test --filter SummaryCardStateTests`
Expected: PASS — one test green.

### Step 3.5 — Commit

```bash
git add Sources/HarcUI/SummaryCardState.swift Tests/HarcUITests/SummaryCardStateTests.swift
git commit -m "feat(ui): SummaryCardState enum + pure resolve helper"
```

### Step 3.6 — Write the full state-precedence tests

- [ ] Append to `Tests/HarcUITests/SummaryCardStateTests.swift`:

```swift
    @Test("installRequired when summarizer not installed and nothing else qualifies")
    func installRequired() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: false, lastFailure: nil
        )
        #expect(state == .installRequired)
    }

    @Test("summary when summaryMarkdown is present")
    func summaryPresent() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: true, lastFailure: nil
        )
        #expect(state == .summary)
    }

    @Test("failed when lastFailure is non-nil and no summary / queue state")
    func failed() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: true, lastFailure: "boom"
        )
        #expect(state == .failed(message: "boom"))
    }

    @Test("queued with position + totalInFlight when isQueued is true")
    func queued() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: true, position: 2, totalInFlight: 3,
            isSummarizerInstalled: true, lastFailure: nil
        )
        #expect(state == .queued(position: 2, totalInFlight: 3))
    }

    @Test("inFlight beats queued / summary / failed / installRequired / empty")
    func inFlightBeatsEverything() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: true, isQueued: true, position: 1, totalInFlight: 1,
            isSummarizerInstalled: false, lastFailure: "boom"
        )
        #expect(state == .inFlight)
    }

    @Test("summary beats failed when both are present (regenerate-failed doesn't hide existing summary)")
    func summaryBeatsFailed() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: true, lastFailure: "boom"
        )
        #expect(state == .summary)
    }

    @Test("summary beats installRequired (keep showing existing summary even if active tier changes to uninstalled one)")
    func summaryBeatsInstallRequired() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: false, lastFailure: nil
        )
        #expect(state == .summary)
    }

    @Test("failed beats installRequired")
    func failedBeatsInstallRequired() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: false, lastFailure: "boom"
        )
        #expect(state == .failed(message: "boom"))
    }
```

### Step 3.7 — Run tests to verify they pass

Run: `swift test --filter SummaryCardStateTests`
Expected: PASS — all precedence tests green.

### Step 3.8 — Commit

```bash
git add Tests/HarcUITests/SummaryCardStateTests.swift
git commit -m "test(ui): SummaryCardState.resolve precedence matrix"
```

### Step 3.9 — Write `isStale` tests

- [ ] Append to `Tests/HarcUITests/SummaryCardStateTests.swift`:

```swift
    @Test("isStale false when summarySourceWordCount is nil")
    func isStaleNilSource() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date(), transcriptText: "hello world")
        rec.summarySourceWordCount = nil
        #expect(SummaryCardState.isStale(recording: rec) == false)
    }

    @Test("isStale false when transcriptText is nil")
    func isStaleNilTranscript() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summarySourceWordCount = 100
        rec.transcriptText = nil
        #expect(SummaryCardState.isStale(recording: rec) == false)
    }

    @Test("isStale false when word count delta is 5% or less")
    func isStaleWithinTolerance() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summarySourceWordCount = 100
        // 100 words exactly — no drift
        rec.transcriptText = Array(repeating: "word", count: 100).joined(separator: " ")
        #expect(SummaryCardState.isStale(recording: rec) == false)
        // 105 words — 5 % drift, not stale
        rec.transcriptText = Array(repeating: "word", count: 105).joined(separator: " ")
        #expect(SummaryCardState.isStale(recording: rec) == false)
    }

    @Test("isStale true when word count delta exceeds 5%")
    func isStaleBeyondTolerance() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summarySourceWordCount = 100
        rec.transcriptText = Array(repeating: "word", count: 110).joined(separator: " ")   // 10 %
        #expect(SummaryCardState.isStale(recording: rec) == true)
        rec.transcriptText = Array(repeating: "word", count: 80).joined(separator: " ")    // 20 %
        #expect(SummaryCardState.isStale(recording: rec) == true)
    }
```

### Step 3.10 — Run tests to verify they pass

Run: `swift test --filter SummaryCardStateTests`
Expected: PASS — precedence + staleness tests all green.

### Step 3.11 — Commit

```bash
git add Tests/HarcUITests/SummaryCardStateTests.swift
git commit -m "test(ui): SummaryCardState.isStale 5% drift tolerance"
```

---

## Task 4 — `SummaryCardView` + mount in `TranscriptionDetailView`

**Files:**
- Create: `Sources/HarcUI/SummaryCardView.swift`
- Modify: `Sources/HarcUI/TranscriptionDetailView.swift`
- Modify: `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`
- Modify: `HarcApp/AppDelegate.swift` (`openDetail`)

This task has no isolated TDD beyond what Tasks 2 + 3 covered — the view is a thin switch on `SummaryCardState` and the environment objects. It ends with a manual build + launch to verify render across states.

### Step 4.1 — Create `SummaryCardView.swift`

- [ ] Create `Sources/HarcUI/SummaryCardView.swift`.

```swift
import SwiftUI
import HarcStore
import HarcModels
import HarcSummarize

/// Renders one of six states above the transcript in `TranscriptionDetailView`.
/// All state resolution lives in the pure `SummaryCardState.resolve(...)` helper;
/// this view's only job is to translate its observed environment into that
/// helper's primitive inputs and lay out each case.
public struct SummaryCardView: View {
    let recording: Recording
    let activeSummarizerID: String
    let onClearSummary: (Int64) -> Void

    @EnvironmentObject private var queueStore: SummarizationQueueStore
    @EnvironmentObject private var modelStore: ModelManagerStore

    public init(
        recording: Recording,
        activeSummarizerID: String,
        onClearSummary: @escaping (Int64) -> Void
    ) {
        self.recording = recording
        self.activeSummarizerID = activeSummarizerID
        self.onClearSummary = onClearSummary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            if case .summary = state, SummaryCardState.isStale(recording: recording) {
                stalenessBanner
            }
            card
        }
    }

    private var state: SummaryCardState {
        SummaryCardState.resolve(
            recording: recording,
            isInFlight: queueStore.current == recording.id,
            isQueued: recording.id.map { queueStore.isQueued($0) && queueStore.current != $0 } ?? false,
            position: recording.id.flatMap { queueStore.position($0) },
            totalInFlight: queueStore.totalInFlight,
            isSummarizerInstalled: modelStore.state(of: activeSummarizerID).isInstalled,
            lastFailure: recording.id.flatMap { queueStore.lastFailures[$0] }
        )
    }

    @ViewBuilder private var card: some View {
        switch state {
        case .empty:
            emptyCard
        case .installRequired:
            installRequiredCard
        case .queued(let position, let totalInFlight):
            queuedCard(position: position, totalInFlight: totalInFlight)
        case .inFlight:
            inFlightCard
        case .failed(let message):
            failedCard(message: message)
        case .summary:
            summaryCard
        }
    }

    // MARK: - Cards

    private var emptyCard: some View {
        tintedContainer {
            HStack(spacing: HarcDesign.Space.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.harcAccent)
                Text("No summary yet.")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkSecondary)
                Spacer()
                Button("Generate") { enqueueSelf() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var installRequiredCard: some View {
        Group {
            if let descriptor = ModelCatalog.descriptor(for: activeSummarizerID) {
                ModelRequirementView(
                    descriptor: descriptor,
                    reason: "Generate summaries and action items from your meeting transcripts."
                )
            } else {
                // Catalog doesn't know this id — render a degraded empty card
                // rather than crashing. Unlikely in practice unless the user
                // edited UserDefaults by hand.
                tintedContainer {
                    Text("Active summarizer model is unknown.")
                        .font(HarcDesign.Font.body)
                        .foregroundStyle(Color.harcError)
                }
            }
        }
    }

    private func queuedCard(position: Int, totalInFlight: Int) -> some View {
        tintedContainer {
            HStack(spacing: HarcDesign.Space.sm) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.harcInkSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summarization queued")
                        .font(HarcDesign.Font.body)
                        .foregroundStyle(Color.harcInkPrimary)
                    Text("Queued · #\(position) of \(totalInFlight)")
                        .font(HarcDesign.Font.meta)
                        .foregroundStyle(Color.harcInkTertiary)
                }
                Spacer()
                Button("Cancel") { cancelSelf() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var inFlightCard: some View {
        tintedContainer {
            HStack(spacing: HarcDesign.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Summarizing with \(currentTierDisplay)…")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkPrimary)
                Spacer()
                Button("Cancel") { cancelSelf() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func failedCard(message: String) -> some View {
        tintedContainer {
            VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                HStack(spacing: HarcDesign.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.harcWarning)
                    Text("Summarization failed")
                        .font(HarcDesign.Font.body)
                        .foregroundStyle(Color.harcInkPrimary)
                    Spacer()
                }
                Text(message)
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HarcDesign.Space.xs) {
                    Button("Retry") { enqueueSelf() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Dismiss") { dismissFailureOnSelf() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var summaryCard: some View {
        tintedContainer {
            VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
                summaryHeader
                Text(markdown: recording.summaryMarkdown ?? "")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let items = parsedActionItems, !items.isEmpty {
                    actionItemsLabel
                    actionItemsList(items)
                } else if recording.actionItemsMarkdown?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "_none identified._" {
                    actionItemsLabel
                    Text("No action items identified.")
                        .font(HarcDesign.Font.bodySm)
                        .italic()
                        .foregroundStyle(Color.harcInkTertiary)
                }
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.harcAccent)
            Text("Summary")
                .font(HarcDesign.Font.subtitle)
                .foregroundStyle(Color.harcInkPrimary)
            Text("· generated with \(persistedTierDisplay)")
                .font(HarcDesign.Font.meta)
                .foregroundStyle(Color.harcInkTertiary)
            if let when = recording.summaryGeneratedAt {
                Text("· \(when, format: .relative(presentation: .named))")
                    .font(HarcDesign.Font.meta)
                    .foregroundStyle(Color.harcInkTertiary)
            }
            Spacer()
            Button(action: enqueueSelf) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Regenerate with the active summarizer")

            Menu {
                Button("Copy summary") {
                    if let s = recording.summaryMarkdown { copyToPasteboard(s) }
                }
                Button("Copy action items") {
                    if let a = recording.actionItemsMarkdown { copyToPasteboard(a) }
                }
                Divider()
                Button("Clear summary", role: .destructive) {
                    if let id = recording.id { onClearSummary(id) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var actionItemsLabel: some View {
        Text("ACTION ITEMS")
            .font(HarcDesign.Font.label)
            .foregroundStyle(Color.harcInkSecondary)
    }

    private func actionItemsList(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                actionItemRow(item)
            }
        }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcDesign.Space.xs) {
            Text("•").foregroundStyle(Color.harcInkTertiary)
            HStack(spacing: 0) {
                if let actor = item.actor {
                    Text("\(actor): ").bold().foregroundStyle(Color.harcInkPrimary)
                }
                Text(item.text).foregroundStyle(Color.harcInkPrimary)
                if let due = item.due {
                    Text(" (\(due))").italic().foregroundStyle(Color.harcInkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(HarcDesign.Font.body)
    }

    private var stalenessBanner: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harcWarning)
            Text("Summary is based on an older transcript.")
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcWarning)
            Spacer(minLength: 0)
            Button("Regenerate") { enqueueSelf() }
                .buttonStyle(.plain)
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcWarning)
        }
        .padding(.horizontal, HarcDesign.Space.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                .fill(Color.harcWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                .strokeBorder(Color.harcWarning.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func tintedContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, HarcDesign.Space.md)
            .padding(.vertical, HarcDesign.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                    .fill(Color.harcAccent.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                    .strokeBorder(Color.harcAccent.opacity(0.3), lineWidth: 1)
            )
    }

    private var parsedActionItems: [ActionItem]? {
        guard let body = recording.actionItemsMarkdown else { return nil }
        return SummaryParser.parseActionItems(body)
    }

    private var persistedTierDisplay: String {
        guard let id = recording.summaryModelID,
              let d = ModelCatalog.descriptor(for: id) else {
            return recording.summaryModelID ?? "unknown"
        }
        return tierName(d.tier, fallback: d.displayName)
    }

    private var currentTierDisplay: String {
        guard let d = ModelCatalog.descriptor(for: activeSummarizerID) else {
            return activeSummarizerID
        }
        return tierName(d.tier, fallback: d.displayName)
    }

    private func tierName(_ tier: ModelTier, fallback: String) -> String {
        switch tier {
        case .standard: return "Standard"
        case .quality:  return "Quality"
        case .max:      return "Max"
        case .singleton: return fallback
        }
    }

    private func enqueueSelf() {
        guard let id = recording.id else { return }
        Task { await queueStore.queue.enqueue(id) }
    }

    private func cancelSelf() {
        guard let id = recording.id else { return }
        Task { await queueStore.queue.cancel(id) }
    }

    private func dismissFailureOnSelf() {
        guard let id = recording.id else { return }
        queueStore.dismissFailure(id)
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

// Tiny helper so `Text(markdown:)` reads clearly at call site.
private extension Text {
    init(markdown: String) {
        self.init(LocalizedStringKey(markdown))
    }
}
```

**Import note on `SummaryParser.parseActionItems` access.** That function is declared `static` but without `public` on `SummaryParser` in Stage 1's implementation — verify. If it's `internal`, either make it public in `HarcSummarize` as part of this task, OR re-parse via a public helper. Running the Tests section will flag this at compile time; add `public` if needed and commit separately.

### Step 4.2 — Verify `SummaryParser.parseActionItems` is accessible

Run: `swift build`
Expected: Either success (if already `public`), or a compile error pointing at `parseActionItems`. If the error fires, proceed to Step 4.3; otherwise skip to 4.4.

### Step 4.3 — Make `parseActionItems` public (if needed)

- [ ] Modify `Sources/HarcSummarize/SummaryParser.swift` — change:

```swift
    static func parseActionItems(_ body: String) -> [ActionItem] {
```
to:
```swift
    public static func parseActionItems(_ body: String) -> [ActionItem] {
```

Run: `swift build`
Expected: success.

### Step 4.4 — Commit `SummaryCardView`

```bash
git add Sources/HarcUI/SummaryCardView.swift Sources/HarcSummarize/SummaryParser.swift
git commit -m "feat(ui): SummaryCardView renders six states + staleness banner"
```

(Omit `SummaryParser.swift` from the `git add` if Step 4.3 was skipped.)

### Step 4.5 — Modify `TranscriptionDetailView` — new init param + prefs + mount point

- [ ] Edit `Sources/HarcUI/TranscriptionDetailView.swift`.

Insert `@EnvironmentObject private var prefs: HarcPreferences` and a new init param:

```swift
public struct TranscriptionDetailView: View {
    let recording: Recording
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onRename: (String?) -> Void
    let onSpeakerNamesChanged: ([Int: String]) -> Void
    let onClearSummary: (Int64) -> Void
    let suggestionsProvider: SpeakerNameEditor.SuggestionsProvider?

    @EnvironmentObject private var prefs: HarcPreferences
    // ... existing @State fields unchanged ...

    public init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void,
        onClearSummary: @escaping (Int64) -> Void,
        suggestionsProvider: SpeakerNameEditor.SuggestionsProvider? = nil
    ) {
        self.recording = recording
        self.onReveal = onReveal
        self.onDelete = onDelete
        self.onRename = onRename
        self.onSpeakerNamesChanged = onSpeakerNamesChanged
        self.onClearSummary = onClearSummary
        self.suggestionsProvider = suggestionsProvider
        self._renameDraft = State(initialValue: recording.title ?? "")
    }
```

Mount the card in the body's main `VStack`, between the title block HStack (ends at current line 69) and the `SpeakerNameEditor` (current line 71):

```swift
            HStack(alignment: .firstTextBaseline) {
                // ... existing title block unchanged ...
            }

            SummaryCardView(
                recording: recording,
                activeSummarizerID: prefs.activeSummarizerID,
                onClearSummary: onClearSummary
            )

            SpeakerNameEditor(
                // ... existing unchanged ...
            )
```

Thread the pref through Copy/Paste — update lines 116 and 143:

```swift
            Button {
                let s = ExportService.promptString(for: recording, includeSummary: prefs.includeSummaryInPrompt)
                try? FrontmostAppPaster.copyAndPaste(s)
            } label: {
```

```swift
    private func copyPromptString() {
        let s = ExportService.promptString(for: recording, includeSummary: prefs.includeSummaryInPrompt)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
```

### Step 4.6 — Modify `TranscriptionDetailWindowController` — accept + inject env objects + onClearSummary

- [ ] Edit `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`.

```swift
import AppKit
import SwiftUI
import HarcUI
import HarcStore
import HarcModels
import HarcSummarize

@MainActor
final class TranscriptionDetailWindowController: NSWindowController {
    convenience init(
        recording: Recording,
        prefs: HarcPreferences,
        queueStore: SummarizationQueueStore,
        modelStore: ModelManagerStore,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void,
        onClearSummary: @escaping (Int64) -> Void,
        suggestionsProvider: SpeakerNameEditor.SuggestionsProvider? = nil
    ) {
        let root = TranscriptionDetailView(
            recording: recording,
            onReveal: onReveal,
            onDelete: onDelete,
            onRename: onRename,
            onSpeakerNamesChanged: onSpeakerNamesChanged,
            onClearSummary: onClearSummary,
            suggestionsProvider: suggestionsProvider
        )
        .environmentObject(prefs)
        .environmentObject(queueStore)
        .environmentObject(modelStore)

        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc — \(recording.displayTitle)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        self.init(window: window)
    }
}
```

### Step 4.7 — Modify `AppDelegate.openDetail` — pass env objects + onClearSummary

- [ ] Edit `HarcApp/AppDelegate.swift` — the `openDetail(for:)` function (around line 697).

```swift
    private func openDetail(for recording: Recording) {
        if let existing = detailWindows[recording.wavPath] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let queueStore = summarizationQueueStore else {
            // Safety: bootstrap hasn't completed; retry after graph exists.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.openDetail(for: recording)
            }
            return
        }
        let controller = TranscriptionDetailWindowController(
            recording: recording,
            prefs: prefs,
            queueStore: queueStore,
            modelStore: modelStore,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(recording: recording)
            },
            onRename: { [weak self] newTitle in
                guard let id = recording.id else { return }
                Task { try? await self?.store?.rename(id: id, title: newTitle) }
            },
            onSpeakerNamesChanged: { [weak self] names in
                guard let id = recording.id else { return }
                Task { try? await self?.store?.updateSpeakerNames(id: id, names: names) }
            },
            onClearSummary: { [weak self] id in
                Task { try? await self?.store?.clearSummary(id: id) }
            },
            suggestionsProvider: reIDSuggestionsProvider(for: recording)
        )
        detailWindows[recording.wavPath] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        trackManagedWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }
```

### Step 4.8 — Run tests + build

Run: `swift test` then `swift build`
Expected: all tests pass (no new unit tests here; existing ones don't break); build succeeds.

### Step 4.9 — Commit

```bash
git add Sources/HarcUI/TranscriptionDetailView.swift HarcApp/WindowControllers/TranscriptionDetailWindowController.swift HarcApp/AppDelegate.swift
git commit -m "feat(ui): mount SummaryCardView in TranscriptionDetailView; thread env objects through detail window"
```

### Step 4.10 — Manual smoke

- [ ] Build the app via Xcode (`open Harc.xcodeproj`, Cmd-R) or `xcodebuild` equivalent.
- [ ] Launch, open a previously-recorded meeting in the library detail pane.
  - Expected: if the recording has a summary, the card renders in `.summary` state with the mockup shape.
  - Expected: if not, card renders in `.empty` (if summarizer installed) or `.installRequired` (if not).
- [ ] Record a short meeting → open its detail → watch the card flip `.inFlight` → `.summary`.
- [ ] Click `↻` on a summarized recording → watch the card flip to `.inFlight`.
- [ ] Click overflow · Clear summary → card returns to `.empty`.

No commit — manual verification only.

---

## Task 5 — Summarization Settings tab

**Files:**
- Create: `Sources/HarcUI/Settings/SummarizationSettingsView.swift`
- Modify: `Sources/HarcUI/SettingsView.swift`

### Step 5.1 — Add tab-selection binding to `SettingsView`

- [ ] Replace the contents of `Sources/HarcUI/SettingsView.swift`:

```swift
import SwiftUI

public struct SettingsView: View {

    /// Identifies each tab so the "Open Models" link in
    /// `SummarizationSettingsView` can switch programmatically.
    public enum Tab: Hashable {
        case general, recording, library, processing, summarization, models
    }

    @State private var selectedTab: Tab = .general

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "mic") }
                .tag(Tab.recording)
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "tray.full") }
                .tag(Tab.library)
            ProcessingSettingsView()
                .tabItem { Label("Processing", systemImage: "wand.and.rays") }
                .tag(Tab.processing)
            SummarizationSettingsView(onOpenModels: { selectedTab = .models })
                .tabItem { Label("Summarization", systemImage: "sparkles") }
                .tag(Tab.summarization)
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "brain") }
                .tag(Tab.models)
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 560, minHeight: 440)
    }
}
```

### Step 5.2 — Create `SummarizationSettingsView`

- [ ] Create `Sources/HarcUI/Settings/SummarizationSettingsView.swift`.

```swift
import SwiftUI
import HarcModels

/// Settings → Summarization tab. Auto-summarize + prompt-copy knobs, plus
/// a mirrored tier picker bound to the same `activeSummarizerID` key used
/// on the Models tab. `onOpenModels` is invoked by the "Open Models" link
/// so users install or remove tiers in the canonical place.
public struct SummarizationSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var models: ModelManagerStore

    public let onOpenModels: () -> Void

    public init(onOpenModels: @escaping () -> Void) {
        self.onOpenModels = onOpenModels
    }

    public var body: some View {
        Form {
            header

            Section {
                activeTierPicker
            } header: {
                Text("Model")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Install or remove tiers from the")
                        Button("Models tab") { onOpenModels() }
                            .buttonStyle(.link)
                    }
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcInkSecondary)

                    if !models.state(of: prefs.activeSummarizerID).isInstalled {
                        Text("The active summarizer is not installed. Auto-summarize and the Generate button will have no effect.")
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcWarning)
                    }
                }
            }

            Section {
                Toggle("Automatically summarize after recording", isOn: $prefs.autoSummarizeEnabled)
                Toggle("Also when on battery", isOn: $prefs.autoSummarizeOnBatteryEnabled)
                    .disabled(!prefs.autoSummarizeEnabled)
                    .padding(.leading, HarcDesign.Space.md)
                Toggle("Include summary in Copy for Prompt", isOn: $prefs.includeSummaryInPrompt)
            } header: {
                Text("Behavior")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemma 4 is multi-GB resident and uses power. The battery toggle is off by default.")
                    Text("“Include summary in Copy for Prompt” prepends ## Summary and ## Action Items above the transcript when copying.")
                }
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcInkSecondary)
            }
        }
        .formStyle(.grouped)
        .task { await models.bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summarization")
                .font(HarcDesign.Font.title)
            Text("Harc summarizes finished recordings locally using Gemma 4.")
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcInkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    private var activeTierPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active model")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcInkSecondary)
            Picker("", selection: $prefs.activeSummarizerID) {
                ForEach(summarizers) { d in
                    Text(tierName(d)).tag(d.id)
                        .disabled(!models.state(of: d.id).isInstalled)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var summarizers: [ModelDescriptor] {
        ModelCatalog.descriptors(for: .summarizer)
    }

    private func tierName(_ d: ModelDescriptor) -> String {
        switch d.tier {
        case .standard: return "Standard"
        case .quality:  return "Quality"
        case .max:      return "Max"
        case .singleton: return d.displayName
        }
    }
}
```

### Step 5.3 — Run build

Run: `swift build`
Expected: success. (No unit tests added for the view; the Form contents are pass-through bindings and visually verified during manual QA.)

### Step 5.4 — Commit

```bash
git add Sources/HarcUI/Settings/SummarizationSettingsView.swift Sources/HarcUI/SettingsView.swift
git commit -m "feat(ui): Summarization settings tab + SettingsView tab-selection binding"
```

### Step 5.5 — Manual smoke

- [ ] Build + launch the app, open Settings via the menu.
- [ ] Verify the Summarization tab appears between Processing and Models with the `sparkles` icon.
- [ ] Toggle "Automatically summarize" off → verify the "Also when on battery" sub-toggle disables.
- [ ] Click the "Models tab" link in the footer → verify it switches to the Models tab.
- [ ] With an uninstalled active summarizer (pick a tier that isn't installed), verify the amber warning line appears below the picker footer.

No commit — manual verification only.

---

## Task 6 — AppDelegate cleanup

**Files:**
- Modify: `HarcApp/AppDelegate.swift`

### Step 6.1 — Remove the Stage 3 stderr-log task

- [ ] Find the block in `AppDelegate.swift` (around lines 915–930) that attaches a `Task` to `queue.events()` and prints `.finished(.failure)` to stderr.

```swift
            // Log summarization failures to stderr so Stage 3 QA can
            // diagnose problems ahead of the Stage 4 UI that will surface
            // them. CancellationError is expected (user cancel) and skipped.
            // The task's lifetime is tied to the events stream — it ends
            // when the queue actor is deallocated, not to `self`.
            let events = await queue.events()
            Task {
                for await event in events {
                    if case .finished(let id, .failure(let error)) = event,
                       !(error is CancellationError) {
                        FileHandle.standardError.write(Data(
                            "harc: summarization failed for recording \(id): \(error.localizedDescription)\n".utf8
                        ))
                    }
                }
            }
```

- [ ] Delete the entire block. Replace with a one-line comment so the history stays readable:

```swift
            // Failure surfaces now live on `summarizationQueueStore.lastFailures`
            // (Stage 4) — consumed by `SummaryCardView.failed` state.
```

### Step 6.2 — Run tests + build

Run: `swift test && swift build`
Expected: success.

### Step 6.3 — Commit

```bash
git add HarcApp/AppDelegate.swift
git commit -m "chore(app): drop Stage 3 stderr-log task — failures now in queueStore.lastFailures"
```

### Step 6.4 — Move sidecar JSON decode off MainActor in `performSummarization`

- [ ] Find `AppDelegate.performSummarization(id:)` (around line 985). Identify the synchronous decode (lines 997–1000):

```swift
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(SessionTranscript.self, from: data)
```

Replace with a detached decode that blocks only on `.value`:

```swift
        let session: SessionTranscript = try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(SessionTranscript.self, from: data)
        }.value
```

The `session` variable name is preserved so downstream lines (`session.joinedText`, `session.words`, `session.speakers`) need no further changes. `PromptTranscriptAdapter.make(...)` stays on MainActor (it's a pure static function), and the subsequent `service.summarize(...)` / `store.updateSummary(...)` calls already hop actors and are unchanged.

### Step 6.5 — Run tests + build

Run: `swift test && swift build`
Expected: success.

### Step 6.6 — Commit

```bash
git add HarcApp/AppDelegate.swift
git commit -m "perf(app): decode SessionTranscript sidecar off MainActor in performSummarization"
```

### Step 6.7 — Manual smoke for hour-long decode

- [ ] Record a short meeting (or pick a historical one with a large `.json` sidecar — >1 MB).
- [ ] Trigger summarization by clicking Generate.
- [ ] Observe no UI hitch in the moment the card flips to `.inFlight`. (Pre-fix: a ~100–300 ms stutter is visible; post-fix: smooth.)

No commit — manual verification only.

---

## Self-review

(Performed during plan authoring; fixes applied inline.)

- **Spec coverage:** Section 1 scope → Task 6 (cleanup, edge cases), Section 2 card → Tasks 3 + 4, Section 3 mount → Task 4, Section 4 Copy-for-Prompt → Task 1, Section 5 Settings tab → Task 5, Section 6 AppDelegate cleanup → Task 6, Section 7 edge cases → tests in Tasks 2–4, Section 8 test plan → Tasks 1, 2, 3 (Task 4 covers manual QA for view rendering, Task 5 covers manual QA for Settings tab). Every enumerated spec section has at least one task.
- **Placeholder scan:** No `TBD` / `TODO` / `fill in`. Steps 1.16 and 4.3 have branching notes that fall back to explicit actions rather than hand-waving.
- **Type consistency:** `SummarizationQueueStore.lastFailures` and `dismissFailure(_:)` declared in Task 2, consumed in Tasks 3 + 4. `PromptSummaryBlock.make(from:)` declared in Task 1, used in Step 1.13. `SummaryCardState.resolve` signature fixed in Task 3, consumed in Task 4's `SummaryCardView.state` property. No drifting identifiers.
- **Scope check:** Single-PR sized. Six tasks, all additive, revertable independently of Stages 1–3. No migration, no new actor, no behavior change to the recording pipeline.

---

## What ships after this plan

The user-visible flip. After merge:

- Detail pane shows a six-state summary card for every recording.
- Copy-for-Prompt (Paste button, Copy for Prompt menu, library copy, editor copy, library export, editor export) prepends `## Summary` / `## Action Items` / `## Transcript` above the transcript when a summary exists and the pref is on.
- Settings → Summarization exposes the tier picker + three behavioral toggles.
- Stage 3's stderr log is gone; failures render in the card's `.failed` state.
- The hour-long MainActor decode hitch on summary start is gone.
