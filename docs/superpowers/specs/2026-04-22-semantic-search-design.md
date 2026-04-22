# Semantic Search Over Transcripts Design Doc

**Feature:** Add embedding-based semantic search to the Library alongside the existing SQLite full-text index. A query like "pricing concerns" retrieves meetings where speakers said "we're worried about cost" — matches meaning, not just tokens. Indexes automatically per recording after transcription; backfills existing recordings once on upgrade.
**Date:** 2026-04-22
**Status:** draft — ready for implementation
**Depends on:** `2026-04-22-model-manager-design.md` (embedding model install UX)

---

## 1. Problem & user story

The Library search today is `LibrarySearchField.swift` over SQLite FTS5 (per `2026-04-19-fts-search-plan.md`). It's fast and correct for keyword match, and it's the right default. It misses everything FTS misses:

- Synonyms — "budget" ↔ "spend" ↔ "finances" ↔ "quarterly costs".
- Paraphrase — "we should push the launch" ↔ "delay the release".
- Intent — "what about the legal concerns?" ↔ "is this compliant?".

For a growing personal library, the difference between a keyword-only and a semantic index is the difference between "Harc is a filing cabinet" and "Harc is memory."

**User story (semantic hit).** "I type *pricing concerns* in the library search. The top tab shows keyword hits (2 recordings). A second tab, *Related*, shows 4 more recordings where someone talked about cost, margin pressure, or tier pricing — none of which contain the word 'pricing.'"

**User story (exact match preserved).** "I type *PO-4482* (a specific PO number). The keyword tab has the one recording that mentioned it exactly. The Related tab is empty because there's no paraphrase for a PO number. I'm not confused; keyword is the right tool and it's still there."

**User story (nothing indexed yet).** "I open search before I've downloaded the embedding model. I see the keyword results plus a small banner: *Install the English embedder (130 MB) to enable related-meaning search.* I install it; indexing runs in the background. The banner flips to a progress bar; Related results show up for my next query."

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- A new `HarcSemanticSearch` target with:
  - `TextEmbedder` actor — wraps the installed BGE-small model (via `ModelManager.requireInstalled("bge-small-en-v1.5")`), produces 384-dim L2-normalized Float32 embeddings from English text.
  - `TranscriptChunker` — splits a recording's transcript into coherent chunks (utterance-aligned, targeting 200–400 tokens, see §4.2).
  - `SemanticIndex` — per-recording write path (overwrite on transcript change) and cross-library search path.
- New DB table `transcript_chunks`:
  - `id INTEGER PRIMARY KEY AUTOINCREMENT`
  - `recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE`
  - `ordinal INTEGER NOT NULL` (0-based position within the recording)
  - `start_ms INTEGER NOT NULL` — start of the first utterance in the chunk
  - `end_ms INTEGER NOT NULL` — end of the last utterance
  - `text TEXT NOT NULL` — the chunk text as-used (speaker-prefixed)
  - `embedding BLOB NOT NULL` (384 × Float32 = 1 536 bytes)
  - UNIQUE on `(recording_id, ordinal)`
- Migration `v8_semantic_chunks`.
- Automatic indexing trigger on `ChunkedTranscriber.finalize` — after transcript writer + speaker embedding extraction, generate chunk embeddings and upsert.
- One-time backfill on launch for already-transcribed recordings (resumable, one-at-a-time).
- Extension to `LibrarySearchField` to add a second **Related** tab next to the existing keyword results. Activated by the same Cmd+F that opens search today.
- `HarcPreferences.semanticSearchEnabled` (default `true`).
- Tests: chunker splits, embedder shape, cosine search correctness, migration, backfill resumability.

**Out of scope / non-goals (v1):**

- **Hybrid ranking algorithms** (reciprocal rank fusion, BM25 + cosine). The UI keeps the two result streams separate — keyword and related — so the user reads both; no need to fuse scores for a single ranked list in v1.
- **Query rewriting / expansion.** The query is embedded as-is, no LLM rewrite, no pseudo-relevance feedback.
- **ANN index structures.** Linear scan, same reasoning as speaker re-ID (§4.4).
- **Multi-lingual embeddings.** Transcripts are English; the BGE-small English model is enough.
- **Indexing titles, tags, front-matter separately.** Only the transcript body is embedded in v1. Tag + title search stays in the FTS path.
- **Search across summaries.** Summaries (see local-summarization-design.md) are separate artifacts. Embedding them is a trivial v2 add.
- **User-visible similarity scores.** The Related tab doesn't show percentages — results are already ranked; numeric scores add noise.
- **Saved / canned queries, filters.** Existing Library filtering (date range, tag) stays keyword-only in v1; Related results respect the same filters (applied after retrieval).
- **On-demand "find more like this chunk" UI.** Inside a recording, no "find related moments" affordance in v1. Easy to add later.

---

## 3. Dependencies

### 3.1 Embedding model

`bge-small-en-v1.5` — `mlx-community/bge-small-en-v1.5` (or Core ML port; we pick at impl time based on performance vs disk):

- 384-dim output.
- Max input 512 tokens (≈ 400 words).
- ~100–130 MB on disk.
- Routed through Model Manager as a `singleton` tier (one-of per task).

### 3.2 Package

```swift
.target(
    name: "HarcSemanticSearch",
    dependencies: [
        "HarcCore",
        "HarcStore",
        "HarcModels",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXEmbedders", package: "mlx-swift-examples"),
    ]
),
```

`HarcUI` gains dep on `HarcSemanticSearch` for the Related tab.

If MLX embedders prove too heavy or unstable, fall back to the sentence-transformers Core ML export. Decision at implementation time; the `TextEmbedder` actor surface is identical.

---

## 4. Indexing pipeline

### 4.1 Trigger

At the tail of `ChunkedTranscriber.finalize(startedAt:endedAt:)`, after the transcript is persisted and speaker embeddings are written (per speaker re-ID spec):

```swift
if prefs.semanticSearchEnabled,
   ModelManager.shared.state(of: "bge-small-en-v1.5") == .installed,
   let id = rec.id {
    Task.detached { await semanticIndexer.index(recordingID: id) }
}
```

Detached Task, not awaited — the recording UI must not wait on embeddings. Index state is tracked via a lightweight `chunks_indexed_at` column on `recordings` (see §4.5).

### 4.2 Chunking

`TranscriptChunker.split(segments:)` turns `[TranscriptSegment]` (utterance-level with speaker + word timings) into `[Chunk]` where each chunk:

- Starts at an utterance boundary.
- Targets ~300 words (≈ 400 tokens for English, safely under BGE's 512 ceiling).
- Prefers speaker-homogeneous chunks: if adding the next utterance would change speakers AND we're already at ≥ 150 words, finalize the current chunk.
- Never smaller than ~50 words unless it's the last chunk of a recording.

Chunk text is the speaker-prefixed rendering (via the existing `SpeakerLabel.displayLabel`), e.g.:

```
Jason: So on the roadmap side — I think we're in a decent place.
Amy: Agreed. The pricing workstream is where I'm nervous.
Jason: Say more on that.
Amy: The enterprise tier is still priced against last year's COGS…
```

Rationale for speaker-prefix: it's the same text the user would paste into an LLM; embeddings trained on dialog will pick up on the structure.

### 4.3 Embedding

`TextEmbedder.embed([text])` batches 1–N strings (up to 16 per batch; batched throughput is meaningfully higher than one-at-a-time). Returns aligned `[[Float]]` of 384-dim vectors, L2-normalized.

Text preprocessing:

- Strip trailing whitespace.
- Truncate at 512 tokens via the tokenizer — defensive; chunker shouldn't produce oversize chunks, but external text (e.g. imported transcripts) might.

### 4.4 Write

`SemanticIndex.upsert(recordingID:, chunks:)`:

1. Transaction.
2. Delete existing `transcript_chunks WHERE recording_id = ?`.
3. Insert new rows in ordinal order.
4. `UPDATE recordings SET chunks_indexed_at = ? WHERE id = ?`.
5. Commit.

### 4.5 Indexing state

One new column on `recordings`:

- `chunks_indexed_at INTEGER NULL` (Unix ms). `NULL` = "not indexed or stale."

Any write that changes `transcript_text` in `recordings` clears this column in the same transaction (existing `RecordingStore.upsert` and transcript-editor save paths). So:

- Fresh recording → `NULL` until the indexer finishes.
- User edits the transcript → back to `NULL`; backfill re-indexes it.
- Beam-search refinement (separate spec) produces a new transcript → back to `NULL`.

### 4.6 Backfill

A `SemanticBackfill` runner, started once on launch if `semanticSearchEnabled && embedder installed`:

1. Queries `SELECT id FROM recordings WHERE chunks_indexed_at IS NULL AND transcript_text IS NOT NULL ORDER BY started_at DESC LIMIT 1`.
2. Indexes it.
3. Loops.
4. Exits when the query is empty.

Running one at a time keeps RAM flat. The runner cooperates with `SummarizationQueue` (§10 — they're separate queues but both respect a shared throttle).

Status exposed via a simple `SemanticBackfill.progress: (done: Int, total: Int)?` observed by the Library UI to render a subtle "Indexing N of M meetings" footer while active. Clears when done.

---

## 5. Search pipeline

### 5.1 Query path

```swift
public struct SemanticHit: Sendable {
    public let recordingID: Int64
    public let chunkID: Int64
    public let ordinal: Int
    public let startMs: Int
    public let endMs: Int
    public let snippet: String        // ~180 char preview
    public let similarity: Float      // 0..1
}

public actor SemanticSearchService {
    public func search(
        query: String,
        k: Int = 20,
        minSimilarity: Float = 0.35
    ) async throws -> [SemanticHit]
}
```

- `query` is trimmed; empty → no search.
- Query embedded with the same `TextEmbedder` as the index.
- Full scan of `transcript_chunks` joining `recordings`, cosine similarity, filter by `minSimilarity`, sort by sim desc, take top `k`.
- Group hits per recording after ranking: return at most 2 chunks per recording in the top-level array so the UI doesn't show "same recording five times."

### 5.2 Performance

Per §4.4 of the re-ID spec, linear scans remain fine at realistic scale:

| Library size | Chunks per recording (avg) | Rows | Dot time (384-dim) | Scan |
|---|---|---|---|---|
| 100 meetings | 15 | 1 500 | 1 µs | 1.5 ms |
| 1 000 meetings | 15 | 15 000 | 1 µs | 15 ms |
| 10 000 meetings | 15 | 150 000 | 1 µs | 150 ms |

At 10k we'd want a proper index; we cross that bridge later.

### 5.3 Snippet generation

For each hit, compute a snippet from `text`:

- Find the single sentence with max cosine to the query (cheap — tokenize on `.`/`!`/`?` with simple heuristics, embed each candidate, pick max).
- Or, if the sentence split produces weird fragments on all-caps / dictation audio, fall back to the first 180 chars with a "…" suffix.

Skip the per-sentence embedding if its cost is meaningful (likely fine: 3–8 sentences × 384-dim embed ≈ 5 ms per hit; at top-20 = 100 ms).

Pragmatic alternative if 100 ms feels slow: pre-compute a single-sentence or centered-sentence snippet at index time, store it alongside the chunk. Add `snippet TEXT NOT NULL` to `transcript_chunks`. Decision deferred to implementation; either is easy.

---

## 6. UI integration

### 6.1 Tab shape

`LibrarySearchField` + results pane extends from:

```
[Search bar]
Keyword · 3 results
  ▪ Apr 17 — 1:1 with Rachel · …pricing concerns…
  ▪ Apr 12 — Team standup · …pricing discussion…
  ▪ Apr 8  — Strategy offsite · …pricing strategy…
```

to:

```
[Search bar]
[Keyword · 3]  [Related · 7]          ← tabs

(Related tab selected:)
  ▪ Apr 15 — Product sync · "…we should think about margin pressure before…"
  ▪ Apr 10 — Customer call · "…they were worried about the total cost…"
  ▪ Apr 5  — Finance planning · "…budget is the gate on shipping this…"
  …
```

### 6.2 Tab behavior

- Tabs show live counts. Counts update as the user types (debounced 180 ms).
- Empty-state for Related tab: if `semanticSearchEnabled` but embedder not installed → `ModelRequirementView`.
- If installed but backfill still running → "Indexing N of M meetings — some matches may be missing" banner at the top of the Related results list.
- Keyboard: `Tab` / `Shift+Tab` toggles tabs; `↑ / ↓` navigates results within the active tab.

### 6.3 Hit rows

Same row shape as keyword hits (date, title, snippet), replacing the match highlighting — Related hits highlight the best-matching *sentence*, not specific tokens. Clicking opens the recording detail view and scrolls to `startMs` (same behavior as keyword hits have today).

---

## 7. Test plan

### 7.1 Unit tests (HarcSemanticSearchTests)

- `TranscriptChunker`:
  - A simple 1 000-word diarized transcript splits into 3–4 chunks, all speaker-homogeneous where possible.
  - A single 50-word recording yields exactly one chunk.
  - An all-solo 5 000-word dictation splits into ~15 chunks averaging 300 words.
- `TextEmbedder` (mocked model output): batch of 3 inputs → 3 L2-normalized 384-dim vectors.
- `EmbeddingBlob` encode/decode for 384 floats (parallel shape to speaker re-ID).

### 7.2 Store tests (HarcStoreTests)

- Migration `v8_semantic_chunks` on a seeded v7 DB preserves existing data.
- `ON DELETE CASCADE` removes chunks when a recording is deleted.
- `chunks_indexed_at` column flips to `NULL` when `transcript_text` is updated, via the existing update path.

### 7.3 Service tests

- `SemanticSearchService.search`:
  - Seeded DB of 10 chunks across 3 recordings, with known query ("budget pressure") and fixed mocked embeddings → returns 2 chunks from 2 recordings in the expected order.
  - `k` cap honored.
  - `minSimilarity` filter drops near-orthogonal noise.
  - Per-recording grouping: top-20 requests don't return 5 chunks from the same recording.

### 7.4 Backfill tests

- Start backfill on DB of 5 un-indexed recordings; after completion every row has `chunks_indexed_at` set.
- Kill (cancel) mid-backfill; restart; it picks up where it left off (no re-indexing of completed rows).
- Transcript edit during backfill: the edited recording's `chunks_indexed_at` flips to `NULL`; backfill eventually re-indexes it.

### 7.5 Integration (manual QA)

- Paraphrase test: index a recording containing "we need to slow down the launch," search "delay release," confirm the recording is in Related but not Keyword.
- Exact-ID test: index a recording with "PO-4482," search "PO-4482" — confirm Keyword has it and Related is silent.
- Model uninstalled mid-session: install the embedder, index 10 recordings, uninstall it → Related tab shows install prompt again; already-indexed chunks stay in the DB (they re-become queryable if the user reinstalls).

---

## 8. Performance + memory

- `TextEmbedder` keeps the model resident once loaded. Small (~130 MB on disk, ~250 MB resident).
- Query: ~10–30 ms including embedding + scan + snippet generation at 1k-chunk scale. Fits the debounced-keystroke budget.
- Indexing one hour-long recording: ~5–8 s at 15 chunks × 40 ms per batch embed — detached Task, invisible.
- RAM pressure during backfill: bounded by `one at a time`, ~250 MB above baseline. Coexists with the summarization queue (which can hit 1.5–2 GB); concurrent backfill + summarize should be OK on 16 GB Macs, but §10 below introduces a small coordinator.

---

## 9. Preferences

Two added to `HarcPreferences`:

```swift
@Published public var semanticSearchEnabled: Bool           // default true
@Published public var indexTranscriptChanges: Bool          // default true; when false, edits don't re-embed
```

`indexTranscriptChanges = false` is an escape hatch for users with very large libraries who want edits to stay local without kicking off re-indexing. Rare enough to live in a sub-disclosure.

---

## 10. Queue coordination with summarization

Summarization and semantic indexing are both heavy background jobs. Both respect a shared serial coordinator so they don't trample each other:

```swift
public actor BackgroundWorkCoordinator {
    private var running: Int = 0
    public func performOne<T>(_ op: () async throws -> T) async rethrows -> T {
        // serialize: max 1 active job across all producers
    }
}
```

- `SummarizationQueue` wraps each summary job in `coordinator.performOne { … }`.
- `SemanticBackfill` does the same for each recording.
- Trigger-time indexing (§4.1) and user-triggered summarization skip the coordinator — UX affordance beats perfect RAM hygiene.

This isn't a full priority system; it's a mutex. The UX consequence: if a user is auto-summarizing and a backfill is running, they alternate one-for-one. Simple and predictable.

---

## 11. Rollout

- v1 ships with `semanticSearchEnabled = true`.
- Zero user-visible change until the embedder is installed.
- Once installed, the Related tab quietly populates as new recordings come in; backfill works through the library over the first hour or two of app use post-install.
- We don't send a notification when backfill completes — it's a background promise, not an event.

---

## 12. Open questions

- **Pre-compute snippets at index time?** Lean yes — 180 bytes × 15 chunks × 1 000 recordings ≈ 2.7 MB extra in the DB, in exchange for removing 100 ms from queries. Probably worth it.
- **Decay / recency?** Do we bias recent chunks higher? Not in v1; the library is personal, a 2-year-old meeting is still a legitimate answer. Easy to add `score = cosine + 0.02 * recencyBonus` later.
- **Embedder swap cost.** If we upgrade the embedding model, the full library needs re-indexing. Make that path explicit: `SemanticIndex.rebuildAll(newModelID:)` with UI in Settings. Out of scope for v1 since we're only shipping one model.
