# Full-Text Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship BM25-ranked, snippet-highlighted, transcript-body-only full-text search in the Library window. Reindex the existing library on first launch. Spec: `docs/superpowers/specs/2026-04-19-fts-search-design.md`.

**Tech stack:** Swift 6, GRDB, SQLite FTS5 (Porter over unicode61), SwiftUI, HarcDesign tokens.

**Architecture summary:**
- Schema: migration `v4_fts_transcript_only` drops the combined FTS table and recreates it with only `transcript_text`, then issues FTS5 `'rebuild'` to backfill from existing rows.
- Store: `RecordingStore.search(query:) -> [TranscriptHit]` replaces `[Recording]`. Result bundles `recording + snippet (with <mark>…</mark>) + BM25 score`.
- UI: `LibraryViewModel` gains `@Published var hits`. `LibraryWindowRootView.main` switches from the default `Table` to a `TranscriptHitRow` list when a query is active.

---

## Task dependency graph

```
  T1 (migration + reindex)
        │
        ▼
  T2 (TranscriptHit + store API)  ──► T3 (VM wires in hits)
                                              │
                                              ▼
                                      T4 (Hit row + highlighter)  ──► T5 (Root view switch)
                                                                              │
                                                                              ▼
                                                                      T6 (Full build + smoke)
```

T7 (store-layer tests) can start after T2, in parallel with T3–T5.
T8 (highlighter tests) can start after T4, in parallel with T5.

---

## Task 1 — Schema migration `v4_fts_transcript_only` (**S**)

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcStore/DatabaseMigrator+Harc.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/MigrationTests.swift`

- [ ] **Step 1: Append the migration**

At the bottom of `harcMigrator()`, just before `return migrator`, add:

```swift
migrator.registerMigration("v4_fts_transcript_only") { db in
    // Drop the v1 combined-column FTS table + its synchronize triggers.
    try db.execute(sql: "DROP TABLE IF EXISTS recordings_fts")

    // Recreate with transcript_text only, Porter over unicode61, diacritic-folded.
    try db.create(virtualTable: "recordings_fts", using: FTS5()) { t in
        t.synchronize(withTable: "recordings")
        t.column("transcript_text")
        t.tokenizer = .porter(wrapping: .unicode61(removeDiacritics: .d2))
    }

    // Backfill existing rows. `synchronize` only installs triggers for future
    // writes; `rebuild` reads every row in `recordings` and repopulates the FTS
    // index using those same trigger projections.
    try db.execute(sql: "INSERT INTO recordings_fts(recordings_fts) VALUES('rebuild')")
}
```

- [ ] **Step 2: Add migration test**

In `Tests/HarcStoreTests/MigrationTests.swift`, add a test that:
1. Opens a fresh in-memory DB and applies *only* migrations v1–v3 (simulate a pre-v4 user).
2. Inserts a row with `transcript_text = "quarterly planning renewals"` via direct SQL.
3. Runs the full migrator (which applies v4).
4. Asserts the row is findable via `MATCH 'quarterly'` against `recordings_fts`.

Sketch:

```swift
@Test("v4 migration reindexes pre-existing rows into the new FTS table")
func v4ReindexesExistingRows() async throws {
    let dbq = try DatabaseQueue()

    // Stand up a v1–v3 migrator so we can seed a row before v4 runs.
    var preV4 = DatabaseMigrator()
    preV4.registerMigration("v1_recordings_and_fts") { db in
        try db.create(table: "recordings") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("wav_path", .text).notNull().unique()
            t.column("txt_path", .text)
            t.column("json_path", .text)
            t.column("started_at", .datetime).notNull()
            t.column("ended_at", .datetime)
            t.column("title", .text)
            t.column("transcript_text", .text)
            t.column("pinned", .boolean).notNull().defaults(to: false)
            t.column("deleted_at", .datetime)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(virtualTable: "recordings_fts", using: FTS5()) { t in
            t.synchronize(withTable: "recordings")
            t.column("title")
            t.column("transcript_text")
            t.tokenizer = .porter(wrapping: .unicode61())
        }
    }
    preV4.registerMigration("v2_suggested_title") { db in
        try db.alter(table: "recordings") { t in t.add(column: "suggested_title", .text) }
    }
    preV4.registerMigration("v3_tags") { db in
        try db.alter(table: "recordings") { t in t.add(column: "tags", .text) }
    }
    try preV4.migrate(dbq)

    try await dbq.write { db in
        try db.execute(sql: """
            INSERT INTO recordings
              (wav_path, started_at, transcript_text, pinned, created_at, updated_at)
            VALUES (?, ?, ?, 0, ?, ?)
            """, arguments: ["/tmp/x.wav", Date(), "quarterly planning renewals", Date(), Date()])
    }

    // Now apply the full migrator (will run v4 on top).
    try DatabaseMigrator.harcMigrator().migrate(dbq)

    let hit = try await dbq.read { db in
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM recordings_fts WHERE recordings_fts MATCH 'quarterly'
            """)
    }
    #expect(hit == 1)
}
```

- [ ] **Step 3: Run migration tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter MigrationTests 2>&1 | tail -20
```

Expected: all green, including new test.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcStore/DatabaseMigrator+Harc.swift Tests/HarcStoreTests/MigrationTests.swift
git commit -m "feat(store): v4 FTS migration — transcript-only index with rebuild"
```

---

## Task 2 — `TranscriptHit` + new `search` API (**M**)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcStore/TranscriptHit.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcStore/RecordingStore.swift`

- [ ] **Step 1: Create `TranscriptHit.swift`**

```swift
import Foundation

/// A single search hit. Bundles the matching recording, a pre-highlighted
/// snippet (with literal `<mark>…</mark>` sentinels around matched tokens),
/// and the BM25 relevance score (higher = more relevant — we negate SQLite's
/// lower-is-better bm25() so the UI layer can sort naturally).
public struct TranscriptHit: Sendable, Equatable, Identifiable {
    public var recording: Recording
    public var snippet: String
    public var score: Double

    public var id: String { recording.wavPath }

    public init(recording: Recording, snippet: String, score: Double) {
        self.recording = recording
        self.snippet = snippet
        self.score = score
    }
}
```

- [ ] **Step 2: Replace the `search` method on `RecordingStore`**

In `Sources/HarcStore/RecordingStore.swift`, in the `// MARK: - Search (FTS5)` block, replace the existing `search(query:includeDeleted:)` with:

```swift
/// Full-text search over transcript bodies. Returns BM25-ranked hits with
/// pre-highlighted snippets (matched tokens wrapped in `<mark>…</mark>`).
/// Empty/whitespace query → [].
public func search(query: String) async throws -> [TranscriptHit] {
    let pattern = Self.ftsPattern(from: query)
    guard !pattern.isEmpty else { return [] }

    return try await dbQueue.read { db in
        let sql = """
            SELECT
                recordings.*,
                snippet(recordings_fts, 0, '<mark>', '</mark>', '…', 24) AS hit_snippet,
                bm25(recordings_fts)                                    AS hit_rank
            FROM recordings
            JOIN recordings_fts ON recordings_fts.rowid = recordings.id
            WHERE recordings_fts MATCH ?
              AND recordings.deleted_at IS NULL
            ORDER BY hit_rank ASC
            LIMIT 200
            """

        let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern])
        return rows.map { row in
            let rec = Recording(row: row)
            let snippet: String = row["hit_snippet"] ?? ""
            let rank: Double = row["hit_rank"] ?? 0
            return TranscriptHit(recording: rec, snippet: snippet, score: -rank)
        }
    }
}

/// Sanitise a user query into a safe FTS5 MATCH expression.  Splits on any
/// non-alphanumeric boundary (keeping `-`), prefix-stars every token,
/// joins with spaces (FTS5's implicit AND).  Guarantees no operator injection.
static func ftsPattern(from raw: String) -> String {
    raw.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
        .map { "\($0)*" }
        .joined(separator: " ")
}
```

- [ ] **Step 3: Update call sites**

The only existing caller is `LibraryViewModel.performSearch`. Do not touch it yet — Task 3 rewrites it. For now, the VM won't compile until T3 is done, which is fine because T3 is the next task in a single branch.

- [ ] **Step 4: Build**

```bash
cd /Users/jlane/GitHub/Harc
swift build --target HarcStore 2>&1 | tail -10
```

Expected: HarcStore target builds clean. HarcUI will be broken (VM still calls old signature) — intentional, fixed in T3.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcStore/TranscriptHit.swift Sources/HarcStore/RecordingStore.swift
git commit -m "feat(store): TranscriptHit struct + BM25-ranked FTS search"
```

---

## Task 3 — Wire `hits` into `LibraryViewModel` (**S**)

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryViewModel.swift`

- [ ] **Step 1: Add `hits` state**

Add alongside `@Published public private(set) var recordings`:

```swift
/// Populated only when `searchText` is non-empty. Ranked by BM25.
@Published public private(set) var hits: [TranscriptHit] = []
```

- [ ] **Step 2: Rewrite `performSearch(_:)`**

Replace the existing `performSearch` body with:

```swift
private func performSearch(_ query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    searchTask = Task { [weak self, store, filter] in
        guard let self else { return }
        do {
            if trimmed.isEmpty {
                let all = try await store.fetchAll()
                await MainActor.run {
                    self.fullList = all
                    self.recordings = self.apply(filter: filter, to: all)
                    self.hits = []
                }
            } else {
                let results = try await store.search(query: trimmed)
                await MainActor.run {
                    self.hits = results
                    // `recordings` stays populated with the unfiltered list so
                    // the detail pane can still look up full Recording data by
                    // wavPath.  The main view branches on `searchText.isEmpty`
                    // to pick which list to render.
                }
            }
        } catch {
            // Keep previous state on error.
        }
    }
}
```

- [ ] **Step 3: Build + unit test sweep**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -10
swift test --filter HarcUITests 2>&1 | tail -10
```

Expected: clean build, existing UITests still pass (we only *added* a published property).

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/LibraryViewModel.swift
git commit -m "feat(ui): LibraryViewModel.hits — BM25 results alongside recordings list"
```

---

## Task 4 — `TranscriptHitRow` + highlighter (**M**)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptHitRow.swift`

- [ ] **Step 1: Write the row view + highlighter**

```swift
import SwiftUI
import HarcStore

/// Single search-results row — recording header + highlighted transcript
/// snippet. Double-tap opens the detail window (parent passes `onOpen`).
public struct TranscriptHitRow: View {
    public let hit: TranscriptHit
    public let onOpen: () -> Void

    public init(hit: TranscriptHit, onOpen: @escaping () -> Void) {
        self.hit = hit
        self.onOpen = onOpen
    }

    public var body: some View {
        HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
            RecordingIconTile(
                systemImage: hit.recording.pinned ? "pin.fill" : "waveform",
                accent: hit.recording.pinned ? .harcTertiary : .harcPrimary,
                size: 32
            )
            VStack(alignment: .leading, spacing: HarcDesign.Space.xxs) {
                HStack(spacing: HarcDesign.Space.xs) {
                    Text(hit.recording.displayTitle)
                        .font(HarcDesign.Font.titleSm)
                        .foregroundStyle(Color.harcOnSurface)
                        .lineLimit(1)
                    Spacer()
                    Text(RelativeTimeFormatter.format(hit.recording.startedAt))
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Text(TranscriptHitRow.highlight(hit.snippet))
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, HarcDesign.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }

    /// Convert a snippet containing literal "<mark>…</mark>" spans into an
    /// `AttributedString` where the marked tokens are tinted with
    /// `HarcDesign.primary` on a translucent primary-container background.
    /// Pure string walk — no HTML parser.
    public static func highlight(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(snippet)
        let open: Substring = "<mark>"
        let close: Substring = "</mark>"

        while let openRange = rest.range(of: open) {
            // Everything before the opening <mark> is plain.
            var plain = AttributedString(String(rest[..<openRange.lowerBound]))
            plain.foregroundColor = .harcOnSurfaceVariant
            out += plain

            let afterOpen = rest[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else {
                // Malformed — no closing tag. Emit remaining as plain and stop.
                var tail = AttributedString(String(afterOpen))
                tail.foregroundColor = .harcOnSurfaceVariant
                out += tail
                return out
            }

            var hit = AttributedString(String(afterOpen[..<closeRange.lowerBound]))
            hit.foregroundColor = .harcPrimary
            hit.backgroundColor = Color.harcPrimary.opacity(0.14)
            out += hit

            rest = afterOpen[closeRange.upperBound...]
        }

        var tail = AttributedString(String(rest))
        tail.foregroundColor = .harcOnSurfaceVariant
        out += tail
        return out
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -10
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcUI/TranscriptHitRow.swift
git commit -m "feat(ui): TranscriptHitRow — highlighted snippet row for search results"
```

---

## Task 5 — Branch `LibraryWindowRootView.main` on query state (**M**)

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryWindowRootView.swift`

- [ ] **Step 1: Add `searchResultsList` computed property**

Somewhere below the existing `list` var, add:

```swift
@ViewBuilder
private var searchResultsList: some View {
    if vm.hits.isEmpty {
        VStack {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.4))
            Text("No matches for \u{201C}\(vm.searchText)\u{201D}")
                .font(HarcDesign.Font.bodyMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .padding(.top, HarcDesign.Space.xs)
            Spacer()
        }
    } else {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.hits) { hit in
                    TranscriptHitRow(hit: hit) { onOpen(hit.recording) }
                        .background(
                            selectedWavPath == hit.recording.wavPath
                                ? Color.harcPrimary.opacity(0.08)
                                : Color.clear
                        )
                        .onTapGesture {
                            selectedWavPath = hit.recording.wavPath
                        }
                    Divider().background(Color.harcOutlineVariant.opacity(0.2))
                }
            }
        }
    }
}
```

- [ ] **Step 2: Branch `main`**

Change `main` from:

```swift
private var main: some View {
    VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
        LibrarySearchField(text: $vm.searchText)
        list
        statusStrip
    }
    .padding(HarcDesign.Space.lg)
}
```

to:

```swift
private var main: some View {
    VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
        LibrarySearchField(text: $vm.searchText)
        if vm.searchText.isEmpty {
            list
        } else {
            searchResultsList
        }
        statusStrip
    }
    .padding(HarcDesign.Space.lg)
}
```

- [ ] **Step 3: Update `statusStrip` copy for search mode**

Let the file-count line reflect hits when searching. Replace the start of `statusStrip` with:

```swift
private var statusStrip: some View {
    HStack {
        Text(vm.searchText.isEmpty
             ? "\(vm.recordings.count) files"
             : "\(vm.hits.count) match\(vm.hits.count == 1 ? "" : "es")")
            .font(HarcDesign.Font.labelMd)
            .foregroundStyle(Color.harcOnSurfaceVariant)
        Text("·")
            .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.5))
        Text(storageUsed)
            .font(HarcDesign.Font.labelMd)
            .foregroundStyle(Color.harcOnSurfaceVariant)
        Spacer()
        Text("LOCAL")
            .font(HarcDesign.Font.labelMd)
            .foregroundStyle(Color.harcPrimary)
            .tracking(1.2)
    }
}
```

- [ ] **Step 4: Verify the detail pane still works under search**

The detail pane uses `selectedRecording`, which looks up `vm.recordings` by `wavPath`. Since `vm.recordings` is still populated during search (we don't empty it in T3), this keeps working. If `TranscriptHitRow` selects a `wavPath` not in `vm.recordings` (edge case: list diverged), the detail falls back to `detailEmpty`. Acceptable.

- [ ] **Step 5: Build + full test sweep**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -10
swift test 2>&1 | tail -10
```

Expected: everything green.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcUI/LibraryWindowRootView.swift
git commit -m "feat(ui): Library results list switches to hit rows when searching"
```

---

## Task 6 — Full build + xcodebuild + manual smoke (**S**)

**Files:** (none modified, verification only)

- [ ] **Step 1: Full swift build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tail -10
swift test 2>&1 | tail -10
```

Expected: no warnings, all tests pass.

- [ ] **Step 2: Regenerate Xcode project + build the app**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke**

Launch the app with an existing `~/Library/Application Support/Harc/Harc.db` that has at least one real recording.

1. Open Library window. Verify no hang on launch (migration + rebuild must be sub-second).
2. Type a word you know is in a transcript. Verify: ranked list appears; matched word appears in a coloured span inline in each row.
3. Clear the search. Verify: default Table returns, calendar/filter state preserved.
4. Type garbage ("xyzzqq"). Verify: "No matches" state.
5. Type a phrase with punctuation ("why, you know"). Verify: no crash, sane results.
6. Double-click a hit. Verify: opens the TranscriptionDetailView for the right recording.

---

## Task 7 — Store-layer tests (**M**)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/FTSSearchTests.swift`

Can run in parallel with Tasks 3–5.

- [ ] **Step 1: Write the suite**

```swift
import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("FTS search")
struct FTSSearchTests {
    private func sample(wav: String, transcript: String?, title: String? = nil) -> Recording {
        Recording(
            wavPath: wav,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: title,
            transcriptText: transcript
        )
    }

    @Test("search returns only transcript-body matches — title-only matches are filtered out")
    func onlyTranscriptBody() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "hello world", title: "Unrelated"))
        _ = try await store.upsert(sample(wav: "/tmp/b.wav", transcript: "completely different", title: "hello"))
        let hits = try await store.search(query: "hello")
        #expect(hits.map { $0.recording.wavPath } == ["/tmp/a.wav"])
    }

    @Test("search ranks rarer term hits above common-term noise (BM25)")
    func bm25Ranking() async throws {
        let store = try await RecordingStore.inMemory()
        let long = String(repeating: "the quick brown fox jumped over the lazy dog ", count: 50) + " budget"
        _ = try await store.upsert(sample(wav: "/tmp/long.wav", transcript: long))
        _ = try await store.upsert(sample(wav: "/tmp/short.wav", transcript: "the annual budget meeting"))
        let hits = try await store.search(query: "budget")
        #expect(hits.count == 2)
        // Shorter doc with same hit count should outrank the long, noisy one.
        #expect(hits[0].recording.wavPath == "/tmp/short.wav")
    }

    @Test("Porter stemmer matches across English inflections")
    func porterStem() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "we are renewing the contract"))
        let hits = try await store.search(query: "renewals")
        #expect(hits.count == 1)
    }

    @Test("search excludes soft-deleted recordings")
    func excludesDeleted() async throws {
        let store = try await RecordingStore.inMemory()
        let r = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "budget"))
        try await store.softDelete(id: r.id!)
        let hits = try await store.search(query: "budget")
        #expect(hits.isEmpty)
    }

    @Test("whitespace-only query returns empty")
    func emptyQuery() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "hello"))
        #expect(try await store.search(query: "   ").isEmpty)
        #expect(try await store.search(query: "").isEmpty)
    }

    @Test("FTS5 operator characters in user input do not raise")
    func sanitisesOperators() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "the annual budget"))
        // None of these should throw; they should all degrade to safe prefix searches.
        _ = try await store.search(query: "\"budget\"")
        _ = try await store.search(query: "budget AND meeting")
        _ = try await store.search(query: "budget NOT meeting")
        _ = try await store.search(query: "(budget)")
        _ = try await store.search(query: "field:budget")
    }

    @Test("snippet wraps matched term in <mark> sentinels")
    func snippetMarks() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "quarterly planning for the budget review"))
        let hits = try await store.search(query: "budget")
        let hit = try #require(hits.first)
        #expect(hit.snippet.contains("<mark>"))
        #expect(hit.snippet.contains("</mark>"))
    }

    @Test("search results are capped at 200")
    func resultsCapped() async throws {
        let store = try await RecordingStore.inMemory()
        for i in 0..<250 {
            _ = try await store.upsert(sample(wav: "/tmp/\(i).wav", transcript: "budget line item \(i)"))
        }
        let hits = try await store.search(query: "budget")
        #expect(hits.count == 200)
    }
}
```

- [ ] **Step 2: Run the suite**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter FTSSearchTests 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/HarcStoreTests/FTSSearchTests.swift
git commit -m "test(store): FTS search coverage — BM25, stemming, sanitisation, snippets"
```

---

## Task 8 — Highlighter unit tests (**S**)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/TranscriptHitHighlightTests.swift`

Can run in parallel with Task 5.

- [ ] **Step 1: Write tests**

```swift
import Testing
import SwiftUI
@testable import HarcUI

@Suite("TranscriptHitRow.highlight")
struct TranscriptHitHighlightTests {
    @Test("plain text without marks round-trips as plain AttributedString")
    func plainText() {
        let out = TranscriptHitRow.highlight("just some words here")
        #expect(String(out.characters) == "just some words here")
    }

    @Test("mark spans produce a run tinted with HarcDesign.primary")
    func singleMark() {
        let out = TranscriptHitRow.highlight("before <mark>hit</mark> after")
        #expect(String(out.characters) == "before hit after")
        // Locate the "hit" run and assert its foreground matches primary.
        var sawPrimary = false
        for run in out.runs {
            if String(out.characters[run.range]) == "hit",
               run.foregroundColor == Color.harcPrimary {
                sawPrimary = true
            }
        }
        #expect(sawPrimary)
    }

    @Test("multiple mark spans are all highlighted")
    func multipleMarks() {
        let out = TranscriptHitRow.highlight("<mark>a</mark> b <mark>c</mark>")
        var primaryCount = 0
        for run in out.runs where run.foregroundColor == Color.harcPrimary {
            primaryCount += 1
        }
        #expect(primaryCount == 2)
    }

    @Test("unmatched opening <mark> degrades gracefully — remaining text is plain")
    func unmatchedOpen() {
        let out = TranscriptHitRow.highlight("before <mark>oops no close")
        #expect(String(out.characters) == "before oops no close")
    }
}
```

- [ ] **Step 2: Run**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter TranscriptHitHighlightTests 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Tests/HarcUITests/TranscriptHitHighlightTests.swift
git commit -m "test(ui): TranscriptHitRow.highlight — mark-span highlighting"
```

---

## Effort summary

| Task | Effort | Depends on |
|---|---|---|
| T1 — Migration + reindex | S | — |
| T2 — TranscriptHit + store API | M | T1 |
| T3 — VM wires in hits | S | T2 |
| T4 — Hit row + highlighter | M | — *(can start as soon as T2 is spec-stable)* |
| T5 — Root view switch | M | T3, T4 |
| T6 — Full build + smoke | S | T5 |
| T7 — Store-layer tests | M | T2 *(parallel with T3–T5)* |
| T8 — Highlighter tests | S | T4 *(parallel with T5)* |

**Total:** ~1 focused day (S≈1h, M≈2–3h).

---

## Acceptance Criteria

- `DatabaseMigrator.harcMigrator()` includes `v4_fts_transcript_only` migration that drops the old FTS table, recreates it on `transcript_text` only with `Porter / unicode61 / removeDiacritics: .d2`, and runs `'rebuild'` to backfill.
- `RecordingStore.search(query:) -> [TranscriptHit]` returns BM25-ranked hits with `<mark>`-wrapped snippets, caps at 200, excludes soft-deleted rows.
- `LibraryViewModel.hits` is populated on non-empty query, cleared on empty.
- Library main pane switches between the default `Table` (no query) and a hit-rows list (query active); status strip reflects match count.
- Existing library transcripts are searchable immediately after the new build launches — no manual reindex step.
- `swift build -Xswiftc -strict-concurrency=complete` clean. `swift test` green. `xcodebuild` green.
- Manual smoke (see T6 step 3) checks out.

## Out of Scope (deferred)

- Date-range / tag / speaker filters combined with text search.
- Title / tag / speaker-name indexing — transcript body only per user decision.
- Jump-to-timestamp from a hit.
- Quoted-phrase and boolean-operator syntax.
- Saved searches, search history, fuzzy / synonym support.
- Per-column BM25 weighting.

## Open Questions

- Do we want a visible "Indexing…" affordance on first launch if `rebuild` ever becomes slow? Not shipped in v1; revisit if telemetry from the field shows >500ms migrations on typical libraries.
- Should we preserve a legacy `search(query:includeDeleted:) -> [Recording]` shim for external callers? No external callers today; removed cleanly in T2.
