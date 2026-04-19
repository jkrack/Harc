# Full-Text Search Design Doc

**Status:** Draft · 2026-04-19
**Author:** Harc
**Scope:** macOS menu bar app · Library window · fully local

---

## 1. Problem & User Story

A Harc user accumulates hundreds of hour-long meeting transcripts over time. Every transcript is thousands of words. The user remembers a phrase ("the bit where Sarah talked about Q3 renewals") but not which meeting it came from and definitely not the date.

**User story.** *As a Harc user, I open the Library window, type a phrase into a search box, and within ~100ms see a ranked list of recordings whose transcripts contain that phrase, with the matched text highlighted in a snippet preview, so I can find the meeting and paste the relevant section into my LLM.*

The existing Library already has a `LibrarySearchField` wired to `LibraryViewModel.searchText` and `RecordingStore.search(query:)` — but that implementation is a first pass: it matches against titles AND transcripts, orders by `pinned DESC, started_at DESC` (ignoring relevance), returns whole-row `[Recording]` (no snippets / no match spans), and has no BM25 ranking. This spec upgrades it to a real FTS experience.

## 2. Scope (v1)

**In scope:**

- FTS5 search restricted to the **transcript body** (`transcript_text` column only).
- BM25-ranked results with title/preview snippets that include highlighted hit terms (`<mark>…</mark>` spans).
- Retroactive indexing for the existing library so the feature works immediately on first launch of the new build — no "reindex later" toggle.
- Live search with 200ms debounce (already in the VM).
- Empty-query behaviour unchanged: show the existing list / filter.
- Matches work across both the recording's `displayTitle` row and a transcript snippet — the title stays visible as context, the snippet is the hit evidence.

**Non-goals (v1):**

- Filter combinators (date ranges, tag filters, speaker filters) layered on the FTS query.
- Searching across titles, tags, or speaker labels — user decision, transcript body only.
- Within-transcript navigation ("jump to 12:34 in the WAV from a hit") — that's a TranscriptionDetailView concern, not the library list.
- Saved searches, search history, fuzzy typo tolerance, synonyms, stemming beyond what Porter gives us.
- Phrase boosting, field weights, per-user tuning.
- Search across soft-deleted rows.

## 3. Architecture: FTS5 Virtual Table Design

### 3.1 Current state

`DatabaseMigrator+Harc.swift` already creates `recordings_fts` as an FTS5 content-synced virtual table with columns `title` and `transcript_text`, tokenized via `porter(wrapping: unicode61())`, in the `v1_recordings_and_fts` migration. `t.synchronize(withTable: "recordings")` installs triggers that mirror inserts/updates/deletes.

### 3.2 Target state

Per user decision "transcript body ONLY", we drop `title` from the FTS index. The table becomes:

```swift
try db.create(virtualTable: "recordings_fts", using: FTS5()) { t in
    t.synchronize(withTable: "recordings")
    t.column("transcript_text")
    t.tokenizer = .porter(wrapping: .unicode61(removeDiacritics: .d2))
}
```

**Tokenizer choice — `porter(wrapping: unicode61)`:**

- `unicode61` is FTS5's default — Unicode-aware word splitting, case folding, optional diacritic folding. Correct foundation for anything beyond ASCII.
- `porter` wraps the base tokenizer to add English stemming: "renewing", "renewals", "renewed" → all match "renew". Harc is English-first per CLAUDE.md constraints, so Porter is a pure win.
- `removeDiacritics: .d2` (the modern variant) — folds "café" → "cafe" so users don't have to type accents. Safe for English. Note the existing migration uses the default; we'll align to d2 on the *new* table definition.
- `trigram` was considered and rejected — it would give us substring ("finding `plan` inside `implementation`") at the cost of index size (~3-4× larger) and rank quality. BM25 on stemmed tokens is a better fit for meeting transcripts where users search for real words, not code identifiers.

**Content-synced vs. external-content vs. contentless:**

We stay with **content-synced** (`t.synchronize(withTable:)`): FTS5 owns a shadow table automatically kept in lockstep with `recordings` via SQL triggers. This is the lowest-maintenance option and already in use. External-content would save ~20% disk (no duplicate text) at the cost of running our own triggers — not worth it at expected data volumes (hundreds of transcripts, each a few KB of compressed text after tokenization).

### 3.3 Rebuild strategy on content updates

Triggers installed by `synchronize` fire on every `INSERT`/`UPDATE`/`DELETE` to `recordings`. Our hot paths already update `transcript_text` through GRDB record APIs or explicit `UPDATE` statements, so the index stays current for free. Two callouts:

- Soft-delete (`deleted_at IS NOT NULL`) does **not** remove a row from `recordings`, so the FTS index still contains deleted rows. The `search(query:)` SQL filters on `recordings.deleted_at IS NULL` at the JOIN boundary. This is intentional — a restore is just clearing the timestamp, no reindex needed.
- Hard delete (which we don't currently expose) would remove the row; triggers handle the cascade.

## 4. Schema Migration & Retroactive Indexing

The existing `recordings_fts` table indexes `title + transcript_text`. We need to (a) narrow the index to `transcript_text` only, and (b) guarantee every existing row's transcript is in the new index on first launch of the build that ships this feature.

### 4.1 Migration `v4_fts_transcript_only`

GRDB's `DatabaseMigrator` runs registered migrations in order on store open. We add:

```swift
migrator.registerMigration("v4_fts_transcript_only") { db in
    // Drop the old combined-column FTS table + its triggers.
    try db.execute(sql: "DROP TABLE IF EXISTS recordings_fts")

    // Recreate with transcript_text only, Porter over unicode61, diacritic-folded.
    try db.create(virtualTable: "recordings_fts", using: FTS5()) { t in
        t.synchronize(withTable: "recordings")
        t.column("transcript_text")
        t.tokenizer = .porter(wrapping: .unicode61(removeDiacritics: .d2))
    }

    // Backfill: synchronize creates triggers for future writes, but does not
    // populate from existing rows. Issue the FTS5 'rebuild' command which reads
    // every row in `recordings` and repopulates `recordings_fts`.
    try db.execute(sql: "INSERT INTO recordings_fts(recordings_fts) VALUES('rebuild')")
}
```

**Why `rebuild` and not a manual `INSERT ... SELECT`:** FTS5 exposes a `'rebuild'` command that uses the synchronize triggers' definition to backfill. It's atomic, idempotent, and is the officially documented path for this exact use case. Since `synchronize` was just set up on this table, `rebuild` knows which columns to project.

**Cost.** One-time, runs inside the migration transaction. For a user with a few hundred hour-long transcripts (say 400 × ~40KB of text each = 16MB), tokenization completes in well under a second on Apple Silicon. This is a first-launch one-time hit — acceptable.

**Safety.** `DROP TABLE recordings_fts` drops only the virtual table and its shadow rows; it does not touch `recordings`. If migration aborts mid-flight, GRDB rolls the transaction back and the old `recordings_fts` remains (migrations run atomically per-migration).

### 4.2 Alternative considered: `ALTER TABLE … DROP COLUMN`

FTS5 does not support `DROP COLUMN`. Drop + recreate + rebuild is the supported path.

### 4.3 No separate reindex UI needed

Because the migration runs on store open (`RecordingStore.onDisk(url:)` → `DatabaseMigrator.harcMigrator().migrate(dbq)`), every existing user is reindexed exactly once on the first launch of this build. No settings toggle, no progress bar, no background job — all existing acceptance paths for migrations work.

If in the future we discover the rebuild is slow enough to worry about (say, multi-second UI stall on very large libraries), we can move it into a post-migration background `ValueObservation` trigger. Not needed for v1.

## 5. Query Layer

### 5.1 Swift API

Replace the current `RecordingStore.search(query:includeDeleted:) -> [Recording]` with a richer return type and leave the old signature as a deprecated thin wrapper (so the existing `LibraryViewModel` doesn't break on the same commit).

```swift
public struct TranscriptHit: Sendable, Equatable, Identifiable {
    public var recording: Recording
    /// Pre-highlighted snippet — contains literal `<mark>` / `</mark>` spans
    /// around matched tokens. Up to ~200 chars, ellipsised with `…` on either
    /// side if trimmed.
    public var snippet: String
    /// BM25 score. Lower is better (SQLite's bm25() returns negative numbers;
    /// we negate so "higher is better" downstream).
    public var score: Double
    public var id: String { recording.wavPath }
}

extension RecordingStore {
    /// Full-text search over transcript bodies. Empty/whitespace query returns
    /// `[]` — the view model handles "show everything" itself.
    public func search(query: String) async throws -> [TranscriptHit]
}
```

### 5.2 SQL

```sql
SELECT
    recordings.*,
    snippet(recordings_fts, 0, '<mark>', '</mark>', '…', 24) AS hit_snippet,
    bm25(recordings_fts)                                    AS hit_rank
FROM recordings
JOIN recordings_fts ON recordings_fts.rowid = recordings.id
WHERE recordings_fts MATCH ?
  AND recordings.deleted_at IS NULL
ORDER BY hit_rank ASC               -- bm25() ascending = best first
LIMIT 200;
```

- `snippet(fts_table, col_index, open, close, ellipsis, token_count)` — FTS5 built-in. Col index `0` is `transcript_text`. 24-token window = ~15 words around the strongest hit, enough for context in a two-line row.
- `bm25()` returns negative floats — smaller is better. The Swift layer negates to `Double` where higher is better for intuitive sorting / debugging.
- `LIMIT 200` caps worst-case work; a user searching for "the" in a 400-transcript library gets the top 200 by BM25, not 400 rows of unranked dross. We never expect a user to *scroll* 200 hits — they refine the query.

### 5.3 Query string assembly

The current code naively appends `*` to every whitespace-split token for prefix matching. That approach breaks the moment a user's query contains FTS syntax characters (`"`, `(`, `)`, `AND`, `OR`, `NOT`, `-`, `:`). Malformed FTS queries raise SQLite errors.

We sanitize explicitly:

```swift
// Split on whitespace, strip everything that isn't alphanumeric or '-',
// drop empties, suffix with `*` for prefix matching, join with space.
// FTS5's default operator between bare terms is AND.
func ftsPattern(from raw: String) -> String {
    raw.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
        .map { String($0) + "*" }
        .joined(separator: " ")
}
```

- All input becomes bare prefix-match terms separated by AND. No operator injection possible.
- Query `""` (empty after sanitization) → empty `[]` result, caller handles.
- Quoted phrase search is a v2 concern; if we want it later, we add a branch that detects paired `"` and emits a phrase expression instead.

### 5.4 Observation

The current `LibraryViewModel.performSearch` returns `[Recording]`. It becomes `[TranscriptHit]`. The VM keeps its 200ms debounce, keeps writing to `@Published var recordings`, and gains `@Published var hits: [TranscriptHit]` used only when `searchText` is non-empty. When empty, `hits = []` and the existing `recordings` list (from `observeAll`) is rendered as before.

## 6. Result Ranking & Snippet Generation

**Ranking — BM25 (FTS5 default).** Chosen per user decision. BM25 is:
- Relevance-aware (rare terms weighted more).
- Length-aware (a 3-hour transcript with one hit isn't favoured over a 20-minute one with four hits).
- Free — SQLite ships it as `bm25(fts_table)`.

We do **not** layer a secondary `started_at DESC` tiebreaker by default — users told us they're searching for content, not chronology. If ties matter at the very tail, the LIMIT 200 cutoff hides them anyway. (Legacy `pinned DESC, started_at DESC` ordering from the current search is explicitly dropped for the relevance-ranked query.)

**Snippet generation.** FTS5's `snippet()` gives us pre-highlighted HTML-ish text. We render it in SwiftUI via `AttributedString(markdown:)` for the trivial case (`<mark>foo</mark>` doesn't actually parse as markdown), so we do a one-pass tokeniser:

```swift
// Converts "before <mark>hit</mark> after …" into an AttributedString with
// the hit span coloured `HarcDesign.primary` at 140% weight on a translucent
// primary background. Pure string walk — cheap enough per row.
static func highlight(_ snippet: String) -> AttributedString { … }
```

This keeps the rendering layer pure SwiftUI — no WebKit, no HTML parser, no new deps. The `<mark>` sentinel is a FTS5 convention and stays internal; callers of `TranscriptHit` see the raw string.

## 7. UI Sketch

Search bar already lives in `LibraryWindowRootView.main`. No placement change needed. What changes is the **list rendering** when a query is active.

### 7.1 Behaviour

- `searchText == ""` — existing `Table` (Name & Date / Duration / Tags / Actions) renders as today. No change.
- `searchText != ""` — switch to a results `List` of `TranscriptHitRow` views, ranked by BM25, showing title + snippet + date + duration. `Table` is the wrong container here: we want a single dominant column (the snippet) with rich per-row layout and the four-column table clashes with snippets that wrap to 2–3 lines.

### 7.2 `TranscriptHitRow` sketch

```swift
struct TranscriptHitRow: View {
    let hit: TranscriptHit
    let onOpen: () -> Void

    var body: some View {
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

    /// Converts "<mark>…</mark>" spans to AttributedString with primary-tinted
    /// highlights. Pure walk over the string.
    static func highlight(_ raw: String) -> AttributedString { … }
}
```

All tokens are `HarcDesign.*`. No new design primitives needed.

### 7.3 Layout in `LibraryWindowRootView.main`

```swift
private var main: some View {
    VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
        LibrarySearchField(text: $vm.searchText)
        if vm.searchText.isEmpty {
            list                  // existing Table
        } else {
            searchResultsList     // new: List of TranscriptHitRow
        }
        statusStrip
    }
    .padding(HarcDesign.Space.lg)
}
```

Selection in search mode uses the same `selectedWavPath` state so the detail pane stays populated on single-click.

### 7.4 Empty / no-matches states

- `searchText != ""` and `vm.hits.isEmpty` → centered VStack with `magnifyingglass` glyph and "No matches for \(vm.searchText)" in `Color.harcOnSurfaceVariant`.
- Unchanged: empty library → "No recordings." (only visible when searchText is empty).

## 8. Debounce & Performance

- 200ms debounce on `searchText` — already in `LibraryViewModel`, kept.
- Cancellation: `performSearch` cancels in-flight `searchTask` before starting a new one — already in place.
- Actor hop: `RecordingStore.search` runs inside the actor on a GRDB read transaction. No worker-thread jump needed; GRDB's read pool is already concurrent.
- BM25 evaluation over ~hundreds of rows × a dozen indexed terms is microseconds on Apple Silicon; the dominant cost is the `snippet()` text assembly per row, which is linear in LIMIT (200). Measured worst case we expect <20ms end-to-end.
- The results list uses `LazyVStack` inside a `ScrollView` (or SwiftUI `List`), so rendering cost is windowed.

If a pathological query (a user pastes a 10KB transcript snippet into the search bar) happens, the sanitiser already truncates per-token at whitespace boundaries — the resulting MATCH string is still bounded by the number of distinct tokens, and FTS5 handles hundreds of ANDed prefixes fine.

## 9. Error Handling

- **Malformed queries.** Impossible after sanitisation — every `?` arg is pure `alnum*` terms joined by space. If a future change introduces quote-phrase support we'll need a syntax-error catch that falls back to sanitised bare-prefix mode.
- **Empty results.** Not an error. VM sets `hits = []` and the UI shows the "No matches" state.
- **Empty query.** VM short-circuits — no DB hit.
- **Large libraries.** LIMIT 200 bounds result size. Index size scales linearly with transcript text; an hour of speech is ~7k words / ~50KB text, so 1000 meetings ≈ 50MB of index — well within SQLite's comfort zone and still local-disk fast.
- **DB errors.** The current pattern "keep previous list on error" in `LibraryViewModel.performSearch` is kept — search is idempotent and a transient lock or IO hiccup shouldn't nuke the rendered list.
- **Migration failure.** Existing `RecordingStore.onDisk` throws `StoreError.migrationFailed`. AppDelegate already handles that (fatal error path — we refuse to launch with a half-migrated DB rather than silently show an empty or corrupt library).

## 10. Testing

### 10.1 Store layer (`HarcStoreTests`)

New `FTSSearchTests` suite, all using `RecordingStore.inMemory()`:

- `search returns only transcript-body matches, not title matches` — regression guard for the narrowing decision.
- `search ranks by BM25 — rarer term wins` — fixture: two transcripts, one has "budget" once, the other has "the" 200 times and "budget" once; query "budget" returns the shorter one first.
- `search stems via Porter — "renewals" matches "renewing"`.
- `search excludes soft-deleted recordings`.
- `search returns empty on whitespace-only query`.
- `search sanitises FTS5 operators — MATCH operator, quote, colon do not raise`.
- `search snippet wraps matched term in <mark> tags`.
- `search respects LIMIT 200`.
- `migration v4 reindexes existing rows — pre-v4 recordings are searchable after migration`. Fixture: write a v3-schema DB with a row, run migrator, query FTS.

### 10.2 UI layer (`HarcUITests`, where practical)

SwiftUI is hostile to headless rendering, but the `TranscriptHitRow.highlight(_:)` string-to-AttributedString function is pure and unit-testable:

- `highlight emits AttributedString with mark spans styled in HarcDesign.primary`.
- `highlight handles snippets without marks as plain text`.
- `highlight is idempotent on repeated `<mark>` tags`.

View-model glue:

- `LibraryViewModel updates hits on searchText change after debounce`.
- `LibraryViewModel.hits is empty when searchText is empty`.

### 10.3 Manual smoke

- Open Library → type "roadmap" → see ranked matches with highlighted snippet inline.
- Clear search → list restores to the default Table view and the date filter / calendar state is preserved.
- Type nonsense → "No matches for \(query)".
- Re-launch with a pre-existing library → first-launch migration populates FTS, search works on the *old* recordings without any explicit user action.

## 11. Future Work

Explicitly deferred from v1:

- **Filters.** Date range + tag + pinned combinators on the FTS query. Straightforward once desired: add `AND` predicates to the SQL alongside the MATCH.
- **Jump-to-timestamp from a hit.** Use `word_timestamps` in `HH-mm-ss.json` to map the snippet back to an audio offset and seek the player.
- **Speaker-scoped search.** "Find everything Sarah said about budget" — requires indexing segmented speaker-tagged text; likely a separate FTS table keyed by (recording_id, speaker).
- **Phrase / quoted search.** Extend the sanitiser to emit FTS5 phrase expressions.
- **Saved searches.** Persist (query, filter-state) tuples in `UserDefaults` or a new `saved_searches` table.
- **Cross-field weighting.** If we ever re-include title/tags, FTS5's `bm25(fts, w1, w2, ...)` accepts per-column weights.
- **Synonyms / custom vocabulary.** A user dictionary ("MRR" → "monthly recurring revenue") would extend the tokenizer pipeline. Open question in CLAUDE.md (custom vocabulary), naturally dovetails with this.

---

## Appendix A: Why not OS-level Core Spotlight?

macOS has `CSSearchableIndex`. We do not use it:

- Privacy posture — Spotlight's index lives in `~/Library/Metadata` and is accessible to any app and to Spotlight's global UI. Meeting transcripts are sensitive; keeping the index in Harc's own SQLite (sandboxed to our app support dir) is a cleaner boundary.
- Determinism — Spotlight indexes on its own schedule; we'd have no "guaranteed searchable within N seconds of transcribe" contract.
- Ranking — Spotlight's ranker is opaque; BM25 is tunable and testable.
- Offline — no dependency on Spotlight daemon state.

## Appendix B: Files touched (preview)

- `Sources/HarcStore/DatabaseMigrator+Harc.swift` — add `v4_fts_transcript_only` migration.
- `Sources/HarcStore/RecordingStore.swift` — replace `search` implementation; add `TranscriptHit`.
- `Sources/HarcStore/TranscriptHit.swift` *(new)* — the result struct.
- `Sources/HarcUI/LibraryViewModel.swift` — add `hits` state, swap VM → store call.
- `Sources/HarcUI/TranscriptHitRow.swift` *(new)* — row view + highlighter.
- `Sources/HarcUI/LibraryWindowRootView.swift` — branch `main` on `searchText.isEmpty`.
- `Tests/HarcStoreTests/FTSSearchTests.swift` *(new)* — store-layer coverage.
- `Tests/HarcStoreTests/MigrationTests.swift` — add v4 reindex test.
- `Tests/HarcUITests/TranscriptHitHighlightTests.swift` *(new)* — highlighter unit tests.
