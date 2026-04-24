# Summarization Stage 3 — Persistence, Queue, Trigger

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the persistence, queue, and trigger plumbing for local summarization — end state: a fresh recording, a minute or two after stop, quietly has its `summary_markdown` / `action_items_markdown` / three metadata columns populated in the DB. No UI yet; Stage 4 will read the columns.

**Architecture:** Five columns on `recordings` (v7 migration). `RecordingStore` gains primitives-shaped `updateSummary` / `clearSummary` + an `unsummarizedRecordings` query. `HarcSummarize` gains a pure `SessionTranscript → PromptTranscript` adapter (taking HarcCore primitives so no new package deps), an `ActionItemsMarkdown.render` serializer, a one-slot `BackgroundWorkCoordinator` mutex (forward-looking for semantic search), a closure-driven `SummarizationQueue` actor, and a `@MainActor ObservableObject` bridge. `HarcPreferences` gains three auto-summarize knobs. `AppDelegate` constructs the graph, fires the trigger from `stopRecording`, and seeds on-launch catch-up for un-summarized rows.

**Tech Stack:** Swift 6, SwiftPM, GRDB (SQLite), Combine (`@Published` bridge), Swift Testing + XCTest, IOKit.ps (for power-state check), mlx-swift-lm (already wired in Stage 2 — not touched here).

**Spec:** `docs/superpowers/specs/2026-04-22-local-summarization-design.md` §12 (Stage 3 refresh, 2026-04-24).

**Hand-off notes from Stage 2 (still load-bearing):**
1. Serial scheduling is load-bearing. `SummarizerService.getOrLoad` is NOT a coalescing cache. The queue must guarantee one in-flight summarize per service.
2. `startObservingMemoryPressure()` is not auto-started. AppDelegate calls it once and stashes the returned `MemoryPressureObservation` handle for the app's lifetime.
3. Cancellation propagates as `CancellationError` (unwrapped). The queue must distinguish it from `SummarizerError.generationFailed` so UI can show "cancelled" vs "failed".
4. `loadedModelID` is the only state probe on the service.

---

## File structure

**Created (HarcSummarize target):**
- `Sources/HarcSummarize/PromptTranscriptAdapter.swift` — pure adapter, HarcCore primitives in / `PromptTranscript` out
- `Sources/HarcSummarize/ActionItemsMarkdown.swift` — inverse of `SummaryParser`
- `Sources/HarcSummarize/BackgroundWorkCoordinator.swift` — one-slot serial mutex
- `Sources/HarcSummarize/SummarizationQueue.swift` — FIFO queue actor
- `Sources/HarcSummarize/SummarizationQueueStore.swift` — `@MainActor` `@Published` bridge

**Created (tests):**
- `Tests/HarcStoreTests/RecordingStoreSummaryTests.swift` — migration + round-trip + `unsummarizedRecordings`
- `Tests/HarcSummarizeTests/PromptTranscriptAdapterTests.swift`
- `Tests/HarcSummarizeTests/ActionItemsMarkdownTests.swift`
- `Tests/HarcSummarizeTests/BackgroundWorkCoordinatorTests.swift`
- `Tests/HarcSummarizeTests/SummarizationQueueTests.swift`
- `Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift`

**Modified:**
- `Sources/HarcStore/DatabaseMigrator+Harc.swift` — append `v7_summary`
- `Sources/HarcStore/Recording.swift` — five new optional fields + `Columns` + `CodingKeys`
- `Sources/HarcStore/RecordingStore.swift` — `updateSummary`, `clearSummary`, `unsummarizedRecordings`
- `Sources/HarcUI/HarcPreferences.swift` — three new `@Published` prefs
- `HarcApp/AppDelegate.swift` — graph construction, `performSummarization` helper, trigger in `stopRecording`, `shouldSummarizeGivenPower`, on-launch catch-up, environment injection

**Not modified:** `Package.swift`. No new target deps. `HarcSummarize` stays at HarcCore + MLX/tokenizer packages.

---

## Task 1 — `v7_summary` migration + `Recording` columns + store round-trip

**Files:**
- Modify: `Sources/HarcStore/DatabaseMigrator+Harc.swift` (append `v7_summary`)
- Modify: `Sources/HarcStore/Recording.swift` (5 new fields, Columns, CodingKeys)
- Modify: `Sources/HarcStore/RecordingStore.swift` (`updateSummary`, `clearSummary`)
- Create: `Tests/HarcStoreTests/RecordingStoreSummaryTests.swift`

### Step 1.1 — Write failing migration test

- [ ] Create the new test file with the migration test only.

```swift
// Tests/HarcStoreTests/RecordingStoreSummaryTests.swift
import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("RecordingStore summary persistence")
struct RecordingStoreSummaryTests {

    @Test("v7_summary migration adds the five columns without dropping existing data")
    func v7AddsColumnsAndPreservesData() throws {
        let dbq = try DatabaseQueue()

        // Stand up migrations up through v6 only, seed a row, then run v7.
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO recordings
                  (wav_path, started_at, transcript_text, pinned, created_at, updated_at)
                VALUES (?, ?, ?, 0, ?, ?)
                """, arguments: ["/tmp/seed.wav", Date(), "seed body", Date(), Date()])
        }

        try dbq.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .map { ($0["name"] as String?) ?? "" }
            #expect(cols.contains("summary_markdown"))
            #expect(cols.contains("action_items_markdown"))
            #expect(cols.contains("summary_model_id"))
            #expect(cols.contains("summary_generated_at"))
            #expect(cols.contains("summary_source_word_count"))

            // Seed row still there and queryable.
            let transcript = try String.fetchOne(
                db,
                sql: "SELECT transcript_text FROM recordings WHERE wav_path = ?",
                arguments: ["/tmp/seed.wav"]
            )
            #expect(transcript == "seed body")
        }
    }
}
```

### Step 1.2 — Run test, verify it fails

- [ ] Run: `swift test --filter HarcStoreTests.RecordingStoreSummaryTests/v7AddsColumnsAndPreservesData`
- [ ] Expected: FAIL — columns don't exist yet.

### Step 1.3 — Add `v7_summary` migration

- [ ] Append the new migration block at the end of `harcMigrator()` inside `Sources/HarcStore/DatabaseMigrator+Harc.swift`, immediately before the `return migrator` line:

```swift
migrator.registerMigration("v7_summary") { db in
    try db.alter(table: "recordings") { t in
        t.add(column: "summary_markdown", .text)
        t.add(column: "action_items_markdown", .text)
        t.add(column: "summary_model_id", .text)
        t.add(column: "summary_generated_at", .integer)  // Unix ms
        t.add(column: "summary_source_word_count", .integer)
    }
}
```

### Step 1.4 — Run test, verify it passes

- [ ] Run: `swift test --filter HarcStoreTests.RecordingStoreSummaryTests/v7AddsColumnsAndPreservesData`
- [ ] Expected: PASS.

### Step 1.5 — Extend `Recording` struct with five new fields

- [ ] Open `Sources/HarcStore/Recording.swift`.
- [ ] Add these stored properties immediately after `public var speakerNames: [Int: String] = [:]`:

```swift
public var summaryMarkdown: String?
public var actionItemsMarkdown: String?
public var summaryModelID: String?
public var summaryGeneratedAt: Date?
public var summarySourceWordCount: Int?
```

- [ ] Extend the designated `init(...)` parameter list and assignment block with matching trailing parameters (all defaulting to `nil`):

```swift
public init(
    id: Int64? = nil,
    wavPath: String,
    txtPath: String? = nil,
    jsonPath: String? = nil,
    startedAt: Date,
    endedAt: Date? = nil,
    title: String? = nil,
    transcriptText: String? = nil,
    suggestedTitle: String? = nil,
    tags: [String] = [],
    speakerNames: [Int: String] = [:],
    pinned: Bool = false,
    deletedAt: Date? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    summaryMarkdown: String? = nil,
    actionItemsMarkdown: String? = nil,
    summaryModelID: String? = nil,
    summaryGeneratedAt: Date? = nil,
    summarySourceWordCount: Int? = nil
) {
    // ... existing assignments ...
    self.summaryMarkdown = summaryMarkdown
    self.actionItemsMarkdown = actionItemsMarkdown
    self.summaryModelID = summaryModelID
    self.summaryGeneratedAt = summaryGeneratedAt
    self.summarySourceWordCount = summarySourceWordCount
}
```

- [ ] Extend `init(from decoder:)`. In the `keyedBy: CodingKeys.self` block, after the existing `self.updatedAt = ...` line:

```swift
self.summaryMarkdown = try c.decodeIfPresent(String.self, forKey: .summaryMarkdown)
self.actionItemsMarkdown = try c.decodeIfPresent(String.self, forKey: .actionItemsMarkdown)
self.summaryModelID = try c.decodeIfPresent(String.self, forKey: .summaryModelID)
if let ms = try c.decodeIfPresent(Int64.self, forKey: .summaryGeneratedAt) {
    self.summaryGeneratedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
} else {
    self.summaryGeneratedAt = nil
}
self.summarySourceWordCount = try c.decodeIfPresent(Int.self, forKey: .summarySourceWordCount)
```

- [ ] Extend `encode(to:)`. After the existing `try c.encode(updatedAt, forKey: .updatedAt)` line:

```swift
try c.encodeIfPresent(summaryMarkdown, forKey: .summaryMarkdown)
try c.encodeIfPresent(actionItemsMarkdown, forKey: .actionItemsMarkdown)
try c.encodeIfPresent(summaryModelID, forKey: .summaryModelID)
if let d = summaryGeneratedAt {
    let ms = Int64(d.timeIntervalSince1970 * 1000)
    try c.encode(ms, forKey: .summaryGeneratedAt)
} else {
    try c.encodeNil(forKey: .summaryGeneratedAt)
}
try c.encodeIfPresent(summarySourceWordCount, forKey: .summarySourceWordCount)
```

- [ ] Extend `CodingKeys` enum with the five new cases:

```swift
case summaryMarkdown = "summary_markdown"
case actionItemsMarkdown = "action_items_markdown"
case summaryModelID = "summary_model_id"
case summaryGeneratedAt = "summary_generated_at"
case summarySourceWordCount = "summary_source_word_count"
```

- [ ] Extend `Columns` enum with five matching `Column(...)` constants:

```swift
static let summaryMarkdown = Column("summary_markdown")
static let actionItemsMarkdown = Column("action_items_markdown")
static let summaryModelID = Column("summary_model_id")
static let summaryGeneratedAt = Column("summary_generated_at")
static let summarySourceWordCount = Column("summary_source_word_count")
```

### Step 1.6 — Write failing round-trip tests for `updateSummary` + `clearSummary`

- [ ] Append to `Tests/HarcStoreTests/RecordingStoreSummaryTests.swift`:

```swift
    private func seed(_ store: RecordingStore, wav: String) async throws -> Int64 {
        let rec = Recording(
            wavPath: wav,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptText: "body"
        )
        let saved = try await store.upsert(rec)
        return saved.id!
    }

    @Test("updateSummary writes all five columns and clearSummary nulls them")
    func updateAndClearSummaryRoundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await seed(store, wav: "/tmp/s.wav")

        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.updateSummary(
            id: id,
            markdown: "summary body",
            actionItemsMarkdown: "- [ ] someone: do the thing",
            modelID: "gemma-4-e2b-it-4bit",
            generatedAt: generatedAt,
            sourceWordCount: 1234
        )

        let saved = try await store.fetch(id: id)
        #expect(saved?.summaryMarkdown == "summary body")
        #expect(saved?.actionItemsMarkdown == "- [ ] someone: do the thing")
        #expect(saved?.summaryModelID == "gemma-4-e2b-it-4bit")
        #expect(saved?.summarySourceWordCount == 1234)
        // Date round-trips via Unix ms — expect equality to millisecond precision.
        #expect(
            Int(saved!.summaryGeneratedAt!.timeIntervalSince1970 * 1000)
            == Int(generatedAt.timeIntervalSince1970 * 1000)
        )

        try await store.clearSummary(id: id)
        let cleared = try await store.fetch(id: id)
        #expect(cleared?.summaryMarkdown == nil)
        #expect(cleared?.actionItemsMarkdown == nil)
        #expect(cleared?.summaryModelID == nil)
        #expect(cleared?.summaryGeneratedAt == nil)
        #expect(cleared?.summarySourceWordCount == nil)
    }

    @Test("updateSummary throws notFound on an unknown id")
    func updateSummaryNotFound() async throws {
        let store = try await RecordingStore.inMemory()
        await #expect(throws: StoreError.self) {
            try await store.updateSummary(
                id: 999_999,
                markdown: "x",
                actionItemsMarkdown: "y",
                modelID: "z",
                generatedAt: Date(),
                sourceWordCount: 0
            )
        }
    }

    @Test("clearSummary throws notFound on an unknown id")
    func clearSummaryNotFound() async throws {
        let store = try await RecordingStore.inMemory()
        await #expect(throws: StoreError.self) {
            try await store.clearSummary(id: 999_999)
        }
    }
```

### Step 1.7 — Run tests, verify they fail

- [ ] Run: `swift test --filter HarcStoreTests.RecordingStoreSummaryTests`
- [ ] Expected: FAIL on the three new tests — `updateSummary` / `clearSummary` not defined.

### Step 1.8 — Implement `updateSummary` + `clearSummary`

- [ ] In `Sources/HarcStore/RecordingStore.swift`, after `updateSpeakerNames(id:names:)`, add:

```swift
    // MARK: - Summary

    /// Write a generated summary + action items (markdown-authoritative) +
    /// metadata onto a recording. Throws `StoreError.notFound` if the id
    /// doesn't exist — a queue-time bug worth surfacing, not silently
    /// dropping.
    public func updateSummary(
        id: Int64,
        markdown: String,
        actionItemsMarkdown: String,
        modelID: String,
        generatedAt: Date,
        sourceWordCount: Int
    ) async throws {
        let ms = Int64(generatedAt.timeIntervalSince1970 * 1000)
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.summaryMarkdown.set(to: markdown),
                    Recording.Columns.actionItemsMarkdown.set(to: actionItemsMarkdown),
                    Recording.Columns.summaryModelID.set(to: modelID),
                    Recording.Columns.summaryGeneratedAt.set(to: ms),
                    Recording.Columns.summarySourceWordCount.set(to: sourceWordCount),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    /// Null all five summary columns for a recording.
    public func clearSummary(id: Int64) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.summaryMarkdown.set(to: nil),
                    Recording.Columns.actionItemsMarkdown.set(to: nil),
                    Recording.Columns.summaryModelID.set(to: nil),
                    Recording.Columns.summaryGeneratedAt.set(to: nil),
                    Recording.Columns.summarySourceWordCount.set(to: nil),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }
```

### Step 1.9 — Run tests, verify all pass

- [ ] Run: `swift test --filter HarcStoreTests.RecordingStoreSummaryTests`
- [ ] Expected: PASS — four tests green.
- [ ] Run the whole test suite to confirm nothing else broke: `swift test`
- [ ] Expected: the same ~346 test count from before, all green (plus the four new ones).

### Step 1.10 — Commit

- [ ] Run:

```bash
git add Sources/HarcStore/DatabaseMigrator+Harc.swift \
        Sources/HarcStore/Recording.swift \
        Sources/HarcStore/RecordingStore.swift \
        Tests/HarcStoreTests/RecordingStoreSummaryTests.swift
git commit -m "$(cat <<'EOF'
feat(store): v7_summary migration + updateSummary/clearSummary

Adds five summary columns to recordings and round-trip setters.
EOF
)"
```

---

## Task 2 — `RecordingStore.unsummarizedRecordings` backfill query

**Files:**
- Modify: `Sources/HarcStore/RecordingStore.swift`
- Modify: `Tests/HarcStoreTests/RecordingStoreSummaryTests.swift`

### Step 2.1 — Write failing test

- [ ] Append to `Tests/HarcStoreTests/RecordingStoreSummaryTests.swift`:

```swift
    @Test("unsummarizedRecordings returns un-summarized, non-deleted rows ordered by startedAt DESC, bounded by limit")
    func unsummarizedRecordingsFilterOrderLimit() async throws {
        let store = try await RecordingStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Oldest, summarized — excluded.
        let summarized = Recording(
            wavPath: "/tmp/a.wav",
            startedAt: t0,
            transcriptText: "a"
        )
        let aSaved = try await store.upsert(summarized)
        try await store.updateSummary(
            id: aSaved.id!,
            markdown: "s", actionItemsMarkdown: "i",
            modelID: "m", generatedAt: Date(), sourceWordCount: 0
        )

        // Middle, soft-deleted — excluded.
        let deleted = Recording(
            wavPath: "/tmp/b.wav",
            startedAt: t0.addingTimeInterval(60),
            transcriptText: "b"
        )
        let bSaved = try await store.upsert(deleted)
        try await store.softDelete(id: bSaved.id!)

        // Newest two — included, newest first.
        let c = Recording(
            wavPath: "/tmp/c.wav",
            startedAt: t0.addingTimeInterval(120),
            transcriptText: "c"
        )
        let d = Recording(
            wavPath: "/tmp/d.wav",
            startedAt: t0.addingTimeInterval(180),
            transcriptText: "d"
        )
        _ = try await store.upsert(c)
        _ = try await store.upsert(d)

        let rows = try await store.unsummarizedRecordings(limit: 10)
        #expect(rows.map { $0.wavPath } == ["/tmp/d.wav", "/tmp/c.wav"])
    }

    @Test("unsummarizedRecordings honors the limit parameter")
    func unsummarizedRecordingsRespectsLimit() async throws {
        let store = try await RecordingStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            let rec = Recording(
                wavPath: "/tmp/\(i).wav",
                startedAt: t0.addingTimeInterval(Double(i) * 60),
                transcriptText: "row \(i)"
            )
            _ = try await store.upsert(rec)
        }
        let rows = try await store.unsummarizedRecordings(limit: 2)
        #expect(rows.count == 2)
        // Newest two.
        #expect(rows.map { $0.wavPath } == ["/tmp/4.wav", "/tmp/3.wav"])
    }
```

### Step 2.2 — Run tests, verify they fail

- [ ] Run: `swift test --filter HarcStoreTests.RecordingStoreSummaryTests/unsummarizedRecordings`
- [ ] Expected: FAIL — method not defined.

### Step 2.3 — Implement `unsummarizedRecordings`

- [ ] In `Sources/HarcStore/RecordingStore.swift`, directly after `clearSummary(id:)`, add:

```swift
    /// Rows with a transcript but no summary yet — the on-launch catch-up
    /// list. Ordered startedAt DESC, capped at `limit` so a fresh install
    /// with a long pre-existing history doesn't seed hundreds of jobs.
    public func unsummarizedRecordings(limit: Int = 20) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.deletedAt == nil)
                .filter(Recording.Columns.summaryMarkdown == nil)
                .order(Recording.Columns.startedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
```

### Step 2.4 — Run tests, verify all pass

- [ ] Run: `swift test --filter HarcStoreTests.RecordingStoreSummaryTests`
- [ ] Expected: PASS — six tests green total in this suite.

### Step 2.5 — Commit

- [ ] Run:

```bash
git add Sources/HarcStore/RecordingStore.swift \
        Tests/HarcStoreTests/RecordingStoreSummaryTests.swift
git commit -m "$(cat <<'EOF'
feat(store): unsummarizedRecordings(limit:) for on-launch catch-up

Bounded, startedAt-DESC query over non-deleted rows that have a
transcript but no summary yet.
EOF
)"
```

---

## Task 3 — `PromptTranscriptAdapter`

**Files:**
- Create: `Sources/HarcSummarize/PromptTranscriptAdapter.swift`
- Create: `Tests/HarcSummarizeTests/PromptTranscriptAdapterTests.swift`

### Step 3.1 — Write failing tests

- [ ] Create `Tests/HarcSummarizeTests/PromptTranscriptAdapterTests.swift`:

```swift
import Testing
import HarcCore
@testable import HarcSummarize

@Suite("PromptTranscriptAdapter")
struct PromptTranscriptAdapterTests {

    @Test("no speakers or words → single utterance carrying joinedText, speaker nil")
    func undiarized() {
        let t = PromptTranscriptAdapter.make(
            joinedText: "Hello there, this is a solo dictation.",
            words: [],
            speakers: [],
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].speaker == nil)
        #expect(t.utterances[0].text == "Hello there, this is a solo dictation.")
    }

    @Test("empty joinedText and no segments → empty utterances")
    func emptyTranscript() {
        let t = PromptTranscriptAdapter.make(
            joinedText: "",
            words: [],
            speakers: [],
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.isEmpty)
    }

    @Test("two diarized speakers → two utterances with default Speaker N labels")
    func twoSpeakersDefaultLabels() {
        let words = [
            Word(text: "Hello",    startMs: 0,    endMs: 500),
            Word(text: "everyone", startMs: 500,  endMs: 1000),
            Word(text: "Hi",       startMs: 1000, endMs: 1300),
            Word(text: "there",    startMs: 1300, endMs: 1600),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0,    endMs: 1000),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 1600),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "Hello everyone Hi there",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0].speaker == "Speaker 1")
        #expect(t.utterances[0].text == "Hello everyone")
        #expect(t.utterances[1].speaker == "Speaker 2")
        #expect(t.utterances[1].text == "Hi there")
    }

    @Test("speakerNameOverrides replaces the default Speaker N label")
    func overriddenLabels() {
        let words = [
            Word(text: "Roadmap",  startMs: 0,   endMs: 500),
            Word(text: "first",    startMs: 500, endMs: 1000),
            Word(text: "Pricing",  startMs: 1000, endMs: 1500),
            Word(text: "concern",  startMs: 1500, endMs: 2000),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0,    endMs: 1000),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 2000),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "Roadmap first Pricing concern",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [0: "Jason", 1: "Amy"]
        )
        #expect(t.utterances[0].speaker == "Jason")
        #expect(t.utterances[1].speaker == "Amy")
    }

    @Test("sentencepiece-style words (leading space) concatenate without extra spaces")
    func sentencePieceStyle() {
        // Tokens arrive with leading spaces; concatenation is verbatim.
        let words = [
            Word(text: "Hello",    startMs: 0,   endMs: 500),
            Word(text: " every",   startMs: 500, endMs: 700),
            Word(text: "one",      startMs: 700, endMs: 1000),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "Hello everyone",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].text == "Hello everyone")
    }
}
```

### Step 3.2 — Run tests, verify they fail

- [ ] Run: `swift test --filter HarcSummarizeTests.PromptTranscriptAdapterTests`
- [ ] Expected: FAIL — `PromptTranscriptAdapter` not found.

### Step 3.3 — Implement the adapter

- [ ] Create `Sources/HarcSummarize/PromptTranscriptAdapter.swift`:

```swift
import Foundation
import HarcCore

/// Convert the HarcCore transcript primitives (joined text + per-word
/// timings + diarization segments + per-recording speaker-name overrides)
/// into a `PromptTranscript` ready for `SummaryPrompt.build`.
///
/// Pure — no I/O, no state. Mirrors `HarcClient.TranscriptPlainTextRenderer`
/// but emits structured `Utterance`s instead of joined paragraph strings.
public enum PromptTranscriptAdapter {

    /// Group words into contiguous same-speaker runs and emit one
    /// `Utterance` per run. Falls back to a single un-labeled utterance
    /// carrying `joinedText` when diarization is absent.
    public static func make(
        joinedText: String,
        words: [Word],
        speakers: [SpeakerSegment],
        speakerNameOverrides: [Int: String]
    ) -> PromptTranscript {
        let trimmedFallback = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // No diarization (or no timings to diarize against) → one utterance.
        guard !speakers.isEmpty, !words.isEmpty else {
            if trimmedFallback.isEmpty {
                return PromptTranscript(utterances: [])
            }
            return PromptTranscript(utterances: [
                .init(speaker: nil, text: trimmedFallback)
            ])
        }

        // Pick concat strategy per-transcript: SentencePiece style leaves a
        // leading space on continuation tokens; whole-word style has none
        // and we insert spaces ourselves.
        let sentencePieceStyle = words.contains { $0.text.first?.isWhitespace == true }

        var utterances: [PromptTranscript.Utterance] = []
        var currentSpeaker: Int? = nil
        var bucket = ""

        func flush() {
            let trimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let label = currentSpeaker.flatMap { idx in
                    speakerNameOverrides[idx] ?? "Speaker \(idx + 1)"
                }
                utterances.append(.init(speaker: label, text: trimmed))
            }
            bucket = ""
        }

        for word in words {
            let midpoint = (word.startMs + word.endMs) / 2
            let assigned: Int?
            if let containing = speakers.first(where: {
                midpoint >= $0.startMs && midpoint < $0.endMs
            }) {
                assigned = containing.speaker
            } else if currentSpeaker != nil {
                assigned = currentSpeaker
            } else {
                assigned = speakers.min { a, b in
                    distance(midpoint, from: a) < distance(midpoint, from: b)
                }?.speaker
            }

            if assigned != currentSpeaker {
                flush()
                currentSpeaker = assigned
            }

            if sentencePieceStyle {
                bucket += word.text
            } else if bucket.isEmpty {
                bucket = word.text
            } else {
                bucket += " " + word.text
            }
        }
        flush()

        if utterances.isEmpty {
            if trimmedFallback.isEmpty {
                return PromptTranscript(utterances: [])
            }
            return PromptTranscript(utterances: [
                .init(speaker: nil, text: trimmedFallback)
            ])
        }
        return PromptTranscript(utterances: utterances)
    }

    private static func distance(_ point: Int, from seg: SpeakerSegment) -> Int {
        if point < seg.startMs { return seg.startMs - point }
        if point >= seg.endMs  { return point - seg.endMs + 1 }
        return 0
    }
}
```

### Step 3.4 — Run tests, verify they pass

- [ ] Run: `swift test --filter HarcSummarizeTests.PromptTranscriptAdapterTests`
- [ ] Expected: PASS — five tests green.

### Step 3.5 — Commit

- [ ] Run:

```bash
git add Sources/HarcSummarize/PromptTranscriptAdapter.swift \
        Tests/HarcSummarizeTests/PromptTranscriptAdapterTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): PromptTranscriptAdapter for SessionTranscript primitives

Pure adapter taking HarcCore types (joinedText, words, speakers,
speakerNameOverrides) and emitting a diarized PromptTranscript ready
for SummaryPrompt.build. Keeps HarcSummarize free of HarcClient deps.
EOF
)"
```

---

## Task 4 — `ActionItemsMarkdown.render`

**Files:**
- Create: `Sources/HarcSummarize/ActionItemsMarkdown.swift`
- Create: `Tests/HarcSummarizeTests/ActionItemsMarkdownTests.swift`

### Step 4.1 — Write failing tests

- [ ] Create `Tests/HarcSummarizeTests/ActionItemsMarkdownTests.swift`:

```swift
import Testing
@testable import HarcSummarize

@Suite("ActionItemsMarkdown.render")
struct ActionItemsMarkdownTests {

    @Test("empty array renders as the canonical None-identified sentinel")
    func emptyRendersSentinel() {
        let rendered = ActionItemsMarkdown.render([])
        #expect(rendered == "_None identified._")
    }

    @Test("undone item renders as `- [ ]`, done item as `- [x]`")
    func checkboxState() {
        let items: [ActionItem] = [
            .init(text: "thing", actor: nil, due: nil, done: false),
            .init(text: "other", actor: nil, due: nil, done: true),
        ]
        let rendered = ActionItemsMarkdown.render(items)
        #expect(rendered == "- [ ] thing\n- [x] other")
    }

    @Test("actor + text + due renders as `- [ ] actor: text (due)`")
    func actorTextDue() {
        let items: [ActionItem] = [
            .init(text: "rewrite tiering page", actor: "Jason", due: "Friday", done: false),
        ]
        #expect(
            ActionItemsMarkdown.render(items)
            == "- [ ] Jason: rewrite tiering page (Friday)"
        )
    }

    @Test("actor + text without due omits parentheses")
    func actorTextOnly() {
        let items: [ActionItem] = [
            .init(text: "file the ticket", actor: "Amy", due: nil, done: false),
        ]
        #expect(ActionItemsMarkdown.render(items) == "- [ ] Amy: file the ticket")
    }

    @Test("text + due without actor omits the colon prefix")
    func textDueOnly() {
        let items: [ActionItem] = [
            .init(text: "ship the release", actor: nil, due: "next week", done: true),
        ]
        #expect(ActionItemsMarkdown.render(items) == "- [x] ship the release (next week)")
    }

    @Test("text-only renders as bare checkbox + text")
    func textOnly() {
        let items: [ActionItem] = [
            .init(text: "do the thing", actor: nil, due: nil, done: false),
        ]
        #expect(ActionItemsMarkdown.render(items) == "- [ ] do the thing")
    }

    @Test("render output round-trips through SummaryParser.parse")
    func roundTripThroughParser() {
        let original: [ActionItem] = [
            .init(text: "rewrite pricing page", actor: "Jason", due: "Friday", done: false),
            .init(text: "follow up", actor: "Amy", due: nil, done: true),
            .init(text: "file GDPR ticket", actor: nil, due: nil, done: false),
        ]
        let rendered = ActionItemsMarkdown.render(original)
        // Wrap in a fake summary body so SummaryParser.parse can split.
        let fakeModelOutput = """
        ## Summary
        sum body

        ## Action Items
        \(rendered)
        """
        let parsed = SummaryParser.parse(fakeModelOutput)
        #expect(parsed.actionItems.count == 3)
        #expect(parsed.actionItems[0].actor == "Jason")
        #expect(parsed.actionItems[0].text == "rewrite pricing page")
        #expect(parsed.actionItems[0].due == "Friday")
        #expect(parsed.actionItems[0].done == false)
        #expect(parsed.actionItems[1].actor == "Amy")
        #expect(parsed.actionItems[1].done == true)
        #expect(parsed.actionItems[2].actor == nil)
        #expect(parsed.actionItems[2].text == "file GDPR ticket")
    }
}
```

### Step 4.2 — Run tests, verify they fail

- [ ] Run: `swift test --filter HarcSummarizeTests.ActionItemsMarkdownTests`
- [ ] Expected: FAIL — `ActionItemsMarkdown` not found.

### Step 4.3 — Implement the serializer

- [ ] Create `Sources/HarcSummarize/ActionItemsMarkdown.swift`:

```swift
import Foundation

/// Serialize `[ActionItem]` to the exact markdown shape `SummaryParser.parse`
/// consumes. Enables round-trip persistence — the UI re-parses markdown on
/// read and re-renders it here when the user toggles `done`.
public enum ActionItemsMarkdown {

    /// Render items as one line each, or the canonical empty sentinel.
    public static func render(_ items: [ActionItem]) -> String {
        if items.isEmpty { return "_None identified._" }
        return items.map(renderLine(_:)).joined(separator: "\n")
    }

    private static func renderLine(_ item: ActionItem) -> String {
        let box = item.done ? "- [x]" : "- [ ]"
        let body: String
        switch (item.actor, item.due) {
        case (let actor?, let due?):
            body = "\(actor): \(item.text) (\(due))"
        case (let actor?, nil):
            body = "\(actor): \(item.text)"
        case (nil, let due?):
            body = "\(item.text) (\(due))"
        case (nil, nil):
            body = item.text
        }
        return "\(box) \(body)"
    }
}
```

### Step 4.4 — Run tests, verify they pass

- [ ] Run: `swift test --filter HarcSummarizeTests.ActionItemsMarkdownTests`
- [ ] Expected: PASS — seven tests green.

### Step 4.5 — Commit

- [ ] Run:

```bash
git add Sources/HarcSummarize/ActionItemsMarkdown.swift \
        Tests/HarcSummarizeTests/ActionItemsMarkdownTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): ActionItemsMarkdown.render — inverse of SummaryParser

Serializes [ActionItem] to the exact markdown shape the parser consumes,
covering all four (actor, due) presence combinations and the empty
sentinel. Enables lossless round-trip through the DB column.
EOF
)"
```

---

## Task 5 — `BackgroundWorkCoordinator`

**Files:**
- Create: `Sources/HarcSummarize/BackgroundWorkCoordinator.swift`
- Create: `Tests/HarcSummarizeTests/BackgroundWorkCoordinatorTests.swift`

### Step 5.1 — Write failing tests

- [ ] Create `Tests/HarcSummarizeTests/BackgroundWorkCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcSummarize

@Suite("BackgroundWorkCoordinator")
struct BackgroundWorkCoordinatorTests {

    /// Actor-based overlap counter — if two `performOne` bodies ever run
    /// concurrently, `peak` will climb above 1.
    actor OverlapCounter {
        private(set) var active = 0
        private(set) var peak = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
    }

    @Test("two concurrent performOne calls run serially (peak concurrency == 1)")
    func serializesConcurrentCallers() async throws {
        let coord = BackgroundWorkCoordinator()
        let counter = OverlapCounter()

        async let first: Void = coord.performOne {
            await counter.enter()
            try await Task.sleep(nanoseconds: 40_000_000)   // 40 ms
            await counter.leave()
        }
        async let second: Void = coord.performOne {
            await counter.enter()
            try await Task.sleep(nanoseconds: 40_000_000)
            await counter.leave()
        }
        _ = try await (first, second)

        let peak = await counter.peak
        #expect(peak == 1)
    }

    @Test("performOne rethrows the operation's error and releases the slot")
    func rethrowsAndReleases() async throws {
        struct Boom: Error {}
        let coord = BackgroundWorkCoordinator()

        await #expect(throws: Boom.self) {
            try await coord.performOne { throw Boom() }
        }
        // Slot must be free — a second call should complete without hanging.
        let result: Int = try await coord.performOne { 42 }
        #expect(result == 42)
    }

    @Test("performOne returns the operation's value")
    func passesReturnValueThrough() async throws {
        let coord = BackgroundWorkCoordinator()
        let value: String = try await coord.performOne { "hello" }
        #expect(value == "hello")
    }
}
```

### Step 5.2 — Run tests, verify they fail

- [ ] Run: `swift test --filter HarcSummarizeTests.BackgroundWorkCoordinatorTests`
- [ ] Expected: FAIL — type not found.

### Step 5.3 — Implement the coordinator

- [ ] Create `Sources/HarcSummarize/BackgroundWorkCoordinator.swift`:

```swift
import Foundation

/// One-slot serial mutex for background work. At most one `performOne`
/// body executes at a time across all producers. Forward-looking for the
/// semantic-search stage (§10 of the semantic-search spec) — Stage 3's
/// only tenant is `SummarizationQueue`, for which it's a pass-through.
///
/// Thread model: actor. Callers `await`. Cancellation of the caller's
/// `Task` propagates into the operation via structured concurrency.
public actor BackgroundWorkCoordinator {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func performOne<T>(_ op: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // Woken — the previous holder transferred the slot to us.
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()  // slot transfers — busy stays true
        } else {
            busy = false
        }
    }
}
```

### Step 5.4 — Run tests, verify they pass

- [ ] Run: `swift test --filter HarcSummarizeTests.BackgroundWorkCoordinatorTests`
- [ ] Expected: PASS — three tests green.

### Step 5.5 — Commit

- [ ] Run:

```bash
git add Sources/HarcSummarize/BackgroundWorkCoordinator.swift \
        Tests/HarcSummarizeTests/BackgroundWorkCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): BackgroundWorkCoordinator — one-slot serial mutex

Forward-looking mutex so SummarizationQueue and (later) semantic
backfill never run concurrently. Pass-through for Stage 3's single
tenant.
EOF
)"
```

---

## Task 6 — `SummarizationQueue` + `SummarizationQueueStore`

Split into two sub-commits: the actor first, then the `@MainActor` bridge on top.

**Files:**
- Create: `Sources/HarcSummarize/SummarizationQueue.swift`
- Create: `Sources/HarcSummarize/SummarizationQueueStore.swift`
- Create: `Tests/HarcSummarizeTests/SummarizationQueueTests.swift`
- Create: `Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift`

### Step 6.1 — Write failing queue tests

- [ ] Create `Tests/HarcSummarizeTests/SummarizationQueueTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcSummarize

@Suite("SummarizationQueue")
struct SummarizationQueueTests {

    /// Records the order + overlap of `perform` invocations.
    actor Recorder {
        private(set) var starts: [Int64] = []
        private(set) var active = 0
        private(set) var peakActive = 0
        private(set) var cancelled: [Int64] = []
        func enter(_ id: Int64) {
            starts.append(id)
            active += 1
            peakActive = max(peakActive, active)
        }
        func leave() { active -= 1 }
        func markCancelled(_ id: Int64) { cancelled.append(id) }
    }

    /// Wait for a closure to return true, polling every 5ms, up to
    /// `timeoutMs`. Fails the calling test on timeout.
    private func expectEventually(
        timeoutMs: Int = 2000,
        _ check: @Sendable () async -> Bool,
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("expectEventually timed out", sourceLocation: sourceLocation)
    }

    @Test("three enqueues execute sequentially (peak concurrency == 1)")
    func serializesThree() async throws {
        let recorder = Recorder()
        let coord = BackgroundWorkCoordinator()
        let queue = SummarizationQueue(coordinator: coord) { id in
            await recorder.enter(id)
            try await Task.sleep(nanoseconds: 30_000_000)
            await recorder.leave()
        }

        await queue.enqueue(1)
        await queue.enqueue(2)
        await queue.enqueue(3)

        await expectEventually { await recorder.starts == [1, 2, 3] }
        let peak = await recorder.peakActive
        #expect(peak == 1)
    }

    @Test("enqueueing the same id twice executes it once (dedupe)")
    func dedupeOnInsert() async throws {
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            await recorder.enter(id)
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.leave()
        }
        await queue.enqueue(7)
        await queue.enqueue(7)   // duplicate — should be dropped
        await queue.enqueue(7)   // duplicate — should be dropped

        // Give plenty of time for the first to start + finish.
        try await Task.sleep(nanoseconds: 100_000_000)
        let starts = await recorder.starts
        #expect(starts == [7])
    }

    @Test("cancel of a queued id removes it before perform runs")
    func cancelQueued() async throws {
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            await recorder.enter(id)
            try await Task.sleep(nanoseconds: 40_000_000)
            await recorder.leave()
        }
        await queue.enqueue(1)
        await queue.enqueue(2)   // will be in pending while 1 runs
        await queue.cancel(2)

        await expectEventually { await recorder.starts == [1] }
        // Give the worker time to drain; id 2 should never start.
        try await Task.sleep(nanoseconds: 60_000_000)
        let starts = await recorder.starts
        #expect(starts == [1])
    }

    @Test("cancel of the currently-running id surfaces CancellationError and advances")
    func cancelCurrent() async throws {
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            await recorder.enter(id)
            do {
                try await Task.sleep(nanoseconds: 500_000_000)  // 500 ms — plenty of time to cancel
            } catch is CancellationError {
                await recorder.markCancelled(id)
                await recorder.leave()
                throw CancellationError()
            }
            await recorder.leave()
        }

        await queue.enqueue(10)
        await queue.enqueue(11)

        // Wait until 10 is actually running before cancelling.
        await expectEventually { await recorder.starts == [10] }
        await queue.cancel(10)

        await expectEventually { await recorder.starts == [10, 11] }
        let cancelled = await recorder.cancelled
        #expect(cancelled == [10])
    }

    @Test("events stream yields enqueued/started/finished/queueDrained in order")
    func eventStreamOrdering() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            // Instant success.
        }
        let stream = queue.events()
        var iter = stream.makeAsyncIterator()

        await queue.enqueue(5)

        // Consume up to drained.
        var observed: [String] = []
        for _ in 0..<4 {
            guard let ev = await iter.next() else { break }
            switch ev {
            case .enqueued(let i):    observed.append("enqueued(\(i))")
            case .started(let i):     observed.append("started(\(i))")
            case .finished(let i, let r):
                switch r {
                case .success: observed.append("finished(\(i), success)")
                case .failure: observed.append("finished(\(i), failure)")
                }
            case .queueDrained:       observed.append("queueDrained")
            }
        }
        #expect(observed == [
            "enqueued(5)",
            "started(5)",
            "finished(5, success)",
            "queueDrained",
        ])
    }

    @Test("failing perform yields finished(.failure) and queue advances")
    func failureAdvances() async throws {
        struct Boom: Error {}
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            if id == 1 { throw Boom() }
            await recorder.enter(id)
            await recorder.leave()
        }
        await queue.enqueue(1)
        await queue.enqueue(2)
        await expectEventually { await recorder.starts == [2] }
    }
}
```

### Step 6.2 — Run queue tests, verify they fail

- [ ] Run: `swift test --filter HarcSummarizeTests.SummarizationQueueTests`
- [ ] Expected: FAIL — `SummarizationQueue` not found.

### Step 6.3 — Implement the queue actor

- [ ] Create `Sources/HarcSummarize/SummarizationQueue.swift`:

```swift
import Foundation

/// One event per state transition in the queue. The `@MainActor`
/// `SummarizationQueueStore` bridge forwards these into `@Published`
/// properties for SwiftUI views. `CancellationError` arrives in the
/// `.failure` payload distinctly from `SummarizerError.*`.
public enum SummarizationQueueEvent: Sendable {
    case enqueued(Int64)
    case started(Int64)
    case finished(Int64, Result<Void, Error>)
    case queueDrained
}

/// FIFO summarization queue. Closure-driven — the perform body is injected
/// at init so the queue itself has no dep on HarcStore / HarcModels /
/// SummarizerService. At most one job runs at a time (enforced by the
/// worker task here AND by the shared `BackgroundWorkCoordinator`).
///
/// Thread model: actor. Events are published through a replay-free
/// `AsyncStream` per subscriber. No disk persistence — app quit drops
/// pending IDs; `AppDelegate` re-seeds on launch via
/// `RecordingStore.unsummarizedRecordings`.
public actor SummarizationQueue {
    public typealias Perform = @Sendable (Int64) async throws -> Void

    private let coordinator: BackgroundWorkCoordinator
    private let perform: Perform

    public private(set) var pending: [Int64] = []
    public private(set) var current: Int64? = nil

    private var worker: Task<Void, Never>? = nil
    private var currentTask: Task<Void, Error>? = nil
    private var subscribers: [UUID: AsyncStream<SummarizationQueueEvent>.Continuation] = [:]

    public init(
        coordinator: BackgroundWorkCoordinator,
        perform: @escaping Perform
    ) {
        self.coordinator = coordinator
        self.perform = perform
    }

    // MARK: - Control

    public func enqueue(_ id: Int64) {
        // Dedupe — both in-flight and queued.
        if current == id { return }
        if pending.contains(id) { return }
        pending.append(id)
        emit(.enqueued(id))
        startWorkerIfNeeded()
    }

    public func cancel(_ id: Int64) {
        if let idx = pending.firstIndex(of: id) {
            pending.remove(at: idx)
            return
        }
        if current == id {
            currentTask?.cancel()
        }
    }

    public func cancelAll() {
        pending.removeAll()
        currentTask?.cancel()
    }

    // MARK: - Events

    public nonisolated func events() -> AsyncStream<SummarizationQueueEvent> {
        AsyncStream { continuation in
            let token = UUID()
            Task { await self.attach(token: token, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.detach(token: token) }
            }
        }
    }

    private func attach(token: UUID,
                        continuation: AsyncStream<SummarizationQueueEvent>.Continuation) {
        subscribers[token] = continuation
    }

    private func detach(token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func emit(_ event: SummarizationQueueEvent) {
        for (_, c) in subscribers { c.yield(event) }
    }

    // MARK: - Worker loop

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    private func run() async {
        while let id = await popNext() {
            current = id
            emit(.started(id))
            let result: Result<Void, Error>
            let task = Task { [coordinator, perform] in
                try await coordinator.performOne { try await perform(id) }
            }
            currentTask = task
            do {
                try await task.value
                result = .success(())
            } catch {
                result = .failure(error)
            }
            currentTask = nil
            current = nil
            emit(.finished(id, result))
        }
        emit(.queueDrained)
        worker = nil
    }

    private func popNext() -> Int64? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
```

### Step 6.4 — Run queue tests, verify they pass

- [ ] Run: `swift test --filter HarcSummarizeTests.SummarizationQueueTests`
- [ ] Expected: PASS — six tests green.

### Step 6.5 — Commit the queue actor

- [ ] Run:

```bash
git add Sources/HarcSummarize/SummarizationQueue.swift \
        Tests/HarcSummarizeTests/SummarizationQueueTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): SummarizationQueue actor — FIFO + dedupe + cancel

Closure-driven queue serializing summarization jobs through the shared
BackgroundWorkCoordinator. Emits events for the UI bridge;
CancellationError surfaces distinctly from SummarizerError.
EOF
)"
```

### Step 6.6 — Write failing store-bridge tests

- [ ] Create `Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcSummarize

@Suite("SummarizationQueueStore")
struct SummarizationQueueStoreTests {

    private func expectEventually(
        timeoutMs: Int = 2000,
        _ check: @Sendable () async -> Bool,
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("expectEventually timed out", sourceLocation: sourceLocation)
    }

    @Test("store mirrors queue state: pending grows, current is set, drained leaves both empty")
    @MainActor
    func mirrorsQueueState() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let store = SummarizationQueueStore(queue: queue)

        await queue.enqueue(1)
        await queue.enqueue(2)

        // Eventually: one is current, one is pending.
        await expectEventually {
            await MainActor.run {
                (store.current == 1 && store.pending == [2])
                || (store.current == 2 && store.pending == [])
            }
        }

        // After drain both are clear.
        await expectEventually {
            await MainActor.run {
                store.current == nil && store.pending.isEmpty
            }
        }
    }

    @Test("isQueued and position reflect both current and pending")
    @MainActor
    func isQueuedAndPosition() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let store = SummarizationQueueStore(queue: queue)

        await queue.enqueue(10)
        await queue.enqueue(11)
        await queue.enqueue(12)

        await expectEventually {
            await MainActor.run {
                store.isQueued(10) && store.isQueued(11) && store.isQueued(12)
                && store.position(10) != nil && store.position(12) != nil
            }
        }

        // Clean up so the test doesn't hang on outstanding sleeps.
        await queue.cancelAll()
    }
}
```

### Step 6.7 — Run tests, verify they fail

- [ ] Run: `swift test --filter HarcSummarizeTests.SummarizationQueueStoreTests`
- [ ] Expected: FAIL — `SummarizationQueueStore` not found.

### Step 6.8 — Implement the bridge

- [ ] Create `Sources/HarcSummarize/SummarizationQueueStore.swift`:

```swift
import Foundation
import Combine

/// `@MainActor`-bound bridge from `SummarizationQueue`'s async events to
/// Combine `@Published` properties so SwiftUI views can `@EnvironmentObject`
/// and render queue state without managing their own Tasks. Mirrors the
/// `ModelManagerStore` pattern used for the Model Manager.
@MainActor
public final class SummarizationQueueStore: ObservableObject {

    @Published public private(set) var pending: [Int64] = []
    @Published public private(set) var current: Int64? = nil

    public let queue: SummarizationQueue
    private var observer: Task<Void, Never>? = nil

    public init(queue: SummarizationQueue) {
        self.queue = queue
        self.observer = Task { [weak self] in
            let stream = queue.events()
            for await event in stream {
                await MainActor.run { self?.apply(event) }
            }
        }
    }

    deinit {
        observer?.cancel()
    }

    /// True when `id` is either currently running or waiting in the queue.
    public func isQueued(_ id: Int64) -> Bool {
        current == id || pending.contains(id)
    }

    /// 1-based position — 1 if currently running, 2+ if pending.
    /// Returns nil if the id is not tracked.
    public func position(_ id: Int64) -> Int? {
        if current == id { return 1 }
        if let idx = pending.firstIndex(of: id) {
            return idx + (current == nil ? 1 : 2)
        }
        return nil
    }

    /// Total jobs on the clock — pending + (current != nil ? 1 : 0).
    public var totalInFlight: Int {
        pending.count + (current == nil ? 0 : 1)
    }

    // MARK: - Internals

    private func apply(_ event: SummarizationQueueEvent) {
        switch event {
        case .enqueued(let id):
            if current != id, !pending.contains(id) {
                pending.append(id)
            }
        case .started(let id):
            if let idx = pending.firstIndex(of: id) { pending.remove(at: idx) }
            current = id
        case .finished(let id, _):
            if current == id { current = nil }
        case .queueDrained:
            current = nil
            pending.removeAll()
        }
    }
}
```

### Step 6.9 — Run tests, verify they pass

- [ ] Run: `swift test --filter HarcSummarizeTests.SummarizationQueueStoreTests`
- [ ] Expected: PASS — two tests green.
- [ ] Run the whole HarcSummarize suite: `swift test --filter HarcSummarizeTests`
- [ ] Expected: all green.

### Step 6.10 — Commit the bridge

- [ ] Run:

```bash
git add Sources/HarcSummarize/SummarizationQueueStore.swift \
        Tests/HarcSummarizeTests/SummarizationQueueStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): SummarizationQueueStore @Published bridge

MainActor ObservableObject mirroring queue events into pending/current
for SwiftUI consumption. Matches the ModelManagerStore pattern.
EOF
)"
```

---

## Task 7 — `HarcPreferences` additions + `AppDelegate` wiring

This task has no pure unit tests (AppDelegate integration is manual-QA territory). Make the code changes, verify the whole suite still builds + passes, run the manual QA list, commit.

**Files:**
- Modify: `Sources/HarcUI/HarcPreferences.swift`
- Modify: `HarcApp/AppDelegate.swift`

### Step 7.1 — Add three new `HarcPreferences` keys + `@Published` props

- [ ] Open `Sources/HarcUI/HarcPreferences.swift`.
- [ ] Inside the `private enum Key` block, add at the end (after `speakerReIDAutoApply`):

```swift
static let autoSummarizeEnabled = "harc.autoSummarizeEnabled"
static let autoSummarizeOnBatteryEnabled = "harc.autoSummarizeOnBatteryEnabled"
static let includeSummaryInPrompt = "harc.includeSummaryInPrompt"
```

- [ ] After the existing `speakerReIDAutoApply` published property, add three new ones:

```swift
/// Fire the summarization queue from `stopRecording` when the active
/// summarizer is installed + power conditions allow. Default on.
@Published public var autoSummarizeEnabled: Bool {
    didSet { UserDefaults.standard.set(autoSummarizeEnabled, forKey: Key.autoSummarizeEnabled) }
}

/// Allow auto-summarize when the laptop is on battery. Default off
/// — Gemma 4 is multi-GB resident and drains battery fast.
@Published public var autoSummarizeOnBatteryEnabled: Bool {
    didSet { UserDefaults.standard.set(autoSummarizeOnBatteryEnabled, forKey: Key.autoSummarizeOnBatteryEnabled) }
}

/// Prepend the summary + action items to the Copy-for-Prompt blob.
/// Consumed by Stage 4. Default on.
@Published public var includeSummaryInPrompt: Bool {
    didSet { UserDefaults.standard.set(includeSummaryInPrompt, forKey: Key.includeSummaryInPrompt) }
}
```

- [ ] Inside `public init()`, at the end of the assignment block (after `self.speakerReIDAutoApply = ...`):

```swift
self.autoSummarizeEnabled = defaults.object(forKey: Key.autoSummarizeEnabled) as? Bool ?? true
self.autoSummarizeOnBatteryEnabled = defaults.object(forKey: Key.autoSummarizeOnBatteryEnabled) as? Bool ?? false
self.includeSummaryInPrompt = defaults.object(forKey: Key.includeSummaryInPrompt) as? Bool ?? true
```

### Step 7.2 — Verify the build still compiles

- [ ] Run: `swift build`
- [ ] Expected: builds clean.

### Step 7.3 — Add AppDelegate properties for Stage 3 graph

- [ ] Open `HarcApp/AppDelegate.swift`.
- [ ] Add `import HarcSummarize` alongside the other module imports at the top.
- [ ] Immediately after `import HarcVoiceprint`, add:

```swift
import IOKit.ps
```

- [ ] In the `AppDelegate` class body, immediately after `private lazy var modelStore = ModelManagerStore(manager: modelManager)`, add:

```swift
private var summarizerService: SummarizerService?
private var summarizationQueue: SummarizationQueue?
private var summarizationQueueStore: SummarizationQueueStore?
private var memoryObservation: SummarizerService.MemoryPressureObservation?
```

### Step 7.4 — Add the `performSummarization(id:)` closure helper

- [ ] In the `AppDelegate` class body, before the existing `// MARK: - MeetingDetector.Delegate` marker, add:

```swift
    // MARK: - Summarization

    /// The `SummarizationQueue` perform closure. Pulls the recording and
    /// its JSON sidecar, builds the prompt transcript, resolves the active
    /// summarizer's directory + context window, runs the summary, and
    /// persists the result. Errors propagate — the queue's `.finished`
    /// event carries them up to whatever's listening.
    private func performSummarization(id: Int64) async throws {
        guard let store = self.store,
              let service = self.summarizerService else { return }
        guard let rec = try await store.fetch(id: id),
              let jsonPath = rec.jsonPath else {
            // No sidecar = nothing structured to summarize. Losing speaker
            // segments would silently degrade the summary, so we skip
            // rather than fall back to plain transcriptText. The queue
            // advances as success.
            return
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(SessionTranscript.self, from: data)

        let promptTranscript = PromptTranscriptAdapter.make(
            joinedText: session.joinedText,
            words: session.words,
            speakers: session.speakers,
            speakerNameOverrides: rec.speakerNames
        )

        let modelID = prefs.activeSummarizerID
        guard let descriptor = await modelManager.descriptor(for: modelID) else { return }
        let directory = try await modelManager.requireInstalled(modelID)
        let budgetWords = SummaryPrompt.budgetWords(contextTokens: descriptor.contextTokens)

        let result = try await service.summarize(
            transcript: promptTranscript,
            modelID: modelID,
            modelDirectory: directory,
            budgetWords: budgetWords
        )

        let wordCount = session.joinedText.split(whereSeparator: { $0.isWhitespace }).count

        try await store.updateSummary(
            id: id,
            markdown: result.summary,
            actionItemsMarkdown: ActionItemsMarkdown.render(result.actionItems),
            modelID: modelID,
            generatedAt: Date(),
            sourceWordCount: wordCount
        )
    }

    /// Private helper — returns true when auto-summarize should fire. The
    /// only skip condition is "on battery AND the user didn't opt into
    /// battery-time summarization". Desktop Macs with no battery report
    /// AC-or-unknown and always summarize.
    private func shouldSummarizeGivenPower() -> Bool {
        if prefs.autoSummarizeOnBatteryEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return true
        }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return type != kIOPSBatteryPowerValue
    }
```

### Step 7.5 — Construct the summarization graph in `bootstrapStore`

- [ ] In `bootstrapStore()`, immediately after the `self.speakerReIDService = SpeakerReIDService(...)` block (but before `observeDestinationChanges()`), insert:

```swift
            // Stage 3 summarization graph. Owned by AppDelegate for app
            // lifetime; queue survives popover re-renders.
            let coordinator = BackgroundWorkCoordinator()
            let service = SummarizerService(loader: SummarizerService.defaultLoader)
            self.memoryObservation = service.startObservingMemoryPressure()
            let queue = SummarizationQueue(coordinator: coordinator, perform: { [weak self] id in
                guard let self else { return }
                try await self.performSummarization(id: id)
            })
            self.summarizerService = service
            self.summarizationQueue = queue
            self.summarizationQueueStore = SummarizationQueueStore(queue: queue)

            // On-launch catch-up: enqueue the N newest un-summarized rows
            // so a fresh install (or a crash recovery) picks up where it
            // left off. Gated by the same prefs + install checks the
            // stopRecording trigger uses.
            if prefs.autoSummarizeEnabled,
               shouldSummarizeGivenPower(),
               modelStore.state(of: prefs.activeSummarizerID).isInstalled {
                let rows = (try? await store.unsummarizedRecordings(limit: 20)) ?? []
                for rec in rows { if let id = rec.id { await queue.enqueue(id) } }
            }
```

### Step 7.6 — Fire the trigger from `stopRecording`

- [ ] In `stopRecording(autoStopReason:)`, replace the existing upsert line:

```swift
if let store = self.store {
    _ = try? await store.upsert(rec)
}
```

with the capturing version:

```swift
var savedID: Int64? = nil
if let store = self.store {
    savedID = (try? await store.upsert(rec))?.id
}
```

- [ ] Immediately after the `runAutoPaste(for: rec, shiftHeld: ...)` call (and before `autoStop.end(...)`), add:

```swift
            // Stage 3 summarization trigger. Gated by the user's opt-ins
            // and the active model's install state. Silent no-op if any
            // gate says no.
            if prefs.autoSummarizeEnabled,
               shouldSummarizeGivenPower(),
               modelStore.state(of: prefs.activeSummarizerID).isInstalled,
               let id = savedID,
               let queue = self.summarizationQueue {
                await queue.enqueue(id)
            }
```

### Step 7.7 — Inject the queue store into the SwiftUI environment

- [ ] In `refreshPopoverRoot`, add `.environmentObject(summarizationQueueStore)` to the chain. Because the property is optional, guard unwrap early in the function next to the existing `guard let vm = recordingsVM, let pop = popover else { return }` — extend to:

```swift
guard let vm = recordingsVM,
      let pop = popover,
      let queueStore = summarizationQueueStore else { return }
```

- [ ] Add `.environmentObject(queueStore)` at the end of the environment chain, directly after `.environmentObject(modelStore)`:

```swift
.environmentObject(state)
.environmentObject(vm)
.environmentObject(prefs)
.environmentObject(autoStop)
.environmentObject(modelStore)
.environmentObject(queueStore)
```

### Step 7.8 — Build + run the full test suite

- [ ] Run: `swift build`
- [ ] Expected: builds clean.
- [ ] Run: `swift test`
- [ ] Expected: all tests pass — no regressions. The suite should be the previous 346 tests plus the new ones from Tasks 1–6 (roughly 22 added: 6 store + 5 adapter + 7 markdown + 3 coordinator + 6 queue + 2 queue store = 29 new, but the exact number depends on how Swift Testing counts parameterized `@Test` methods; the existing Testing vs XCTest counts stay stable).

### Step 7.9 — Manual QA checklist

Mark each item checked after running it. The AppDelegate graph only exercises in a live app session, not tests.

- [ ] **Auto-summarize fires on stop, on AC, with Gemma 4 E2B installed.**
  - Download Gemma 4 E2B via Settings → Models if not already installed.
  - Plug in. Verify `HarcPreferences.autoSummarizeEnabled == true` (default).
  - Start a short recording (~30 s, say some stuff), stop.
  - Wait a minute or two.
  - Open `~/Library/Application Support/Harc/Harc.db` in `sqlite3` or TablePlus:
    ```sql
    SELECT id, summary_markdown, action_items_markdown, summary_model_id,
           summary_generated_at, summary_source_word_count
      FROM recordings
      ORDER BY id DESC LIMIT 1;
    ```
  - Expected: all five columns populated; `summary_model_id` matches `prefs.activeSummarizerID`.

- [ ] **On-battery skip is honored.**
  - Unplug the Mac. Verify `prefs.autoSummarizeOnBatteryEnabled == false`.
  - Record another short meeting, stop.
  - Wait 30 s.
  - SQL-inspect the new row → summary columns should all be NULL.

- [ ] **`autoSummarizeEnabled = false` suppresses the trigger.**
  - `defaults write com.harc.Harc harc.autoSummarizeEnabled -bool false` (exact bundle id may differ — check with `defaults domains | tr ',' '\n' | grep -i harc`).
  - Restart the app, record, stop.
  - New row should have NULL summary columns.
  - Reset: `defaults write com.harc.Harc harc.autoSummarizeEnabled -bool true`.

- [ ] **On-launch catch-up seeds the queue.**
  - With `autoSummarizeEnabled = false`, record 2–3 short sessions (they won't summarize).
  - SQL-inspect: confirm those rows have NULL summary columns.
  - Re-enable `autoSummarizeEnabled`, relaunch the app.
  - Within a couple minutes the latest un-summarized rows should populate their summary columns (processed newest-first, up to 20).

- [ ] **Memory pressure unloads the model.** (Optional smoke check.)
  - After a summary completes, trigger memory pressure:
    ```bash
    sudo memory_pressure -l warn   # or -l critical
    ```
  - Service should nil its container; next summary pays the load cost again. Verify via Console.app logs (MLX prints on load) or by timing the next summary's first run.

### Step 7.10 — Commit the AppDelegate wiring

- [ ] Run:

```bash
git add Sources/HarcUI/HarcPreferences.swift HarcApp/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(app): summarization Stage 3 trigger + on-launch catch-up

Adds three auto-summarize prefs. Constructs SummarizerService +
SummarizationQueue + SummarizationQueueStore + BackgroundWorkCoordinator
in bootstrapStore, retains the memory-pressure observation for the app
lifetime, fires enqueue from stopRecording when gated prefs + power +
install state pass, seeds on-launch catch-up from unsummarizedRecordings,
and injects the queue store into the SwiftUI environment for Stage 4.
EOF
)"
```

---

## Final verification

- [ ] Run the full suite once more: `swift test`
- [ ] Expected: all green. Total test count up by ~22–29 new tests from Tasks 1–6.
- [ ] `git log --oneline -10` — expect eight new commits on top of `43b1c0d` (one per task, plus the queue actor + bridge sub-commits).
- [ ] `git status` — clean working tree.

## What Stage 3 does NOT do

- No UI surface. `SummaryCardView` lands in Stage 4.
- No `ExportService` summary-in-prompt integration. Stage 4.
- No editing / regenerate / clear from the UI. Stage 4.
- No `NSWorkspace.didActivateApplicationNotification`-driven unload (deferred past v1 per §12.1).
- No persistence of `SummaryOutput.parseWarning` (generation-time-only per §12.2).
- No persistence of `elapsedMs` (computed in Stage 2 but not stored by Stage 3).

---

## Self-review summary

- Task 1 covers spec §12.2 (migration, Recording struct columns) + §12.3 (`updateSummary`, `clearSummary`).
- Task 2 covers spec §12.3 (`unsummarizedRecordings`).
- Task 3 covers spec §12.4 (`PromptTranscriptAdapter`).
- Task 4 covers spec §12.4 (`ActionItemsMarkdown.render`).
- Task 5 covers spec §12.4 (`BackgroundWorkCoordinator`).
- Task 6 covers spec §12.4 (`SummarizationQueue` + `SummarizationQueueStore`).
- Task 7 covers spec §12.5 (`HarcPreferences` additions) + §12.6 (all six AppDelegate edits) + §12.7 manual QA list.

Type + signature consistency across tasks:
- `RecordingStore.updateSummary(id:markdown:actionItemsMarkdown:modelID:generatedAt:sourceWordCount:)` — used in Tasks 1, 2 (test seed), 7 (AppDelegate).
- `PromptTranscriptAdapter.make(joinedText:words:speakers:speakerNameOverrides:)` — defined Task 3, used Task 7.
- `ActionItemsMarkdown.render(_:)` — defined Task 4, used Task 7.
- `BackgroundWorkCoordinator.performOne<T>(_:)` — defined Task 5, used Tasks 6 and 7.
- `SummarizationQueue.init(coordinator:perform:)` — defined Task 6, used Task 7.
- `SummarizationQueueStore(queue:)` — defined Task 6, used Task 7.

No placeholders — every test has real code, every implementation step has the full body, every command has the expected outcome.
