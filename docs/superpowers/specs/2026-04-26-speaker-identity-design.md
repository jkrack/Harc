# Speaker Identity Design Doc

**Feature:** Make speaker labels correct *within* a recording and *across* the user's library, in a single coherent design. Replaces the partially-shipped placeholder pipeline with one that uses FluidAudio's already-bundled WeSpeaker v2 embedder for both within-recording diarization clustering and cross-recording cosine search.

**Date:** 2026-04-26
**Status:** draft — ready for implementation
**Supersedes:** [2026-04-22-speaker-reid-design.md](2026-04-22-speaker-reid-design.md)
**Depends on:** [2026-04-20-speaker-renaming-design.md](2026-04-20-speaker-renaming-design.md) (per-recording rename feature; this builds on it)

---

## 1. Problem & user story

Two related problems, one design.

**Problem A — within-recording label flip.** During a recording, every 60s chunk is sent to the daemon for `transcribe(diarize: true)`. Each chunk's diarizer output uses an *independent* per-chunk speaker-index space, and `TranscriptAssembler.finalize` simply concatenates those per-chunk segments after rebasing their start times. There's no cross-chunk linking, so chunk 1's "Speaker 0" and chunk 2's "Speaker 0" end up sharing a label without being the same person. Concretely: a two-person conversation between the user and their wife shows up with `Speaker 1` flipping between them mid-conversation.

**Problem B — across-recording identity.** A user with 20 recurring meetings ends up typing `Jason, Amy, Sam` 20 times. The 2026-04-22 design specced cross-recording suggestion chips ("Sounds like Jason · 3 prior recordings") and that surface is shipped (commit `d9e78e2`), but the embedder behind it is `StubSpeakerEmbedder` — log-mel band statistics, deterministic and L2-normalized but **not a real speaker fingerprint**. The feature is gated `speakerReIDEnabled = false` until a real model lands.

**The unifying insight.** FluidAudio (already a dependency, pinned at 0.13.5) bundles `wespeaker_v2.mlmodelc` — a production-grade WeSpeaker v2 speaker embedder, 256-dim L2-normalized — and exposes it through public API: `DiarizerManager.extractSpeakerEmbedding(from:)`, `DiarizerManager.embeddingExtractor`, and per-segment `embedding: [Float]` on the `TimedSpeakerSegment` that `performCompleteDiarization` already returns. The embedding is *already computed* during diarization; today's `Sources/HarcSTT/Diarizer.swift` simply discards it.

So the long-term-correct architecture is one we can ship today:

1. **One diarization pass per recording**, performed on the *full* WAV at end-of-recording. Globally consistent speaker labels by construction. Solves Problem A.
2. **Per-speaker WeSpeaker v2 embeddings come back from that same pass.** Stored in `speaker_embeddings` and used by the existing cross-recording cosine-search service. Solves Problem B.
3. **No bundled or downloaded model to add.** WeSpeaker v2 is already in the FluidAudio model package the user fetches the first time they record.

**User story (within-recording).** "I record a 45-minute conversation with my wife. The transcript text appears correctly during recording, as it does today. After I hit stop, the popover shows 'Identifying speakers…' for ~5 seconds, then 'Speakers identified · 2 speakers' briefly, then collapses. When I open the recording in detail view, Speaker 1 is consistently me throughout and Speaker 2 is consistently her — no mid-conversation flips."

**User story (across-recording).** "I just recorded today's standup. I open the recording; `SpeakerNameEditor` shows two rows. Next to Speaker 1 there's a chip: *Sounds like Jason · 3 prior recordings · 84%*. I click it — Jason's name fills the field and propagates to the three matching prior recordings."

**User story (post-stop crash).** "Mid-recording I closed my laptop and the app died. I relaunch, find my recording in the library — text is there but no speaker labels. I open it; there's an 'Identify speakers' button instead of the speaker editor. I click; ~5s later the speaker rows appear and chips populate."

---

## 2. Scope (v1) and non-goals

**In scope:**

- A single `daemon.diarize(audioPath:)` IPC verb that runs FluidAudio's full diarization pipeline on the final mixed WAV and returns both `[SpeakerSegment]` and per-speaker WeSpeaker embeddings.
- `ChunkedTranscriber` calls `transcribe(diarize: false)` per chunk during recording, then calls `client.diarize(...)` once after stop. The diarize result is the source of truth for speaker labels and embeddings.
- Schema migration `v9_speaker_embeddings_wespeaker`: wipe the existing 192-dim stub rows; add `embedder_kind TEXT` column.
- Removal of `StubSpeakerEmbedder`, `SpeakerEmbedder` protocol, `SpeakerEmbedderError`, and `SpeakerExtractor`. The embedder lives inside FluidAudio; we just plumb its output.
- Post-stop UX: a small `RecordingPostProcessingState` `ObservableObject` drives a menu-bar spinner, a popover inline status row, and a detail-view skeleton state during the 3–10 s diarization window. Failure surfaces a retry affordance.
- `HarcPreferences.speakerReIDEnabled` default flips from `false` to `true`. `speakerReIDAutoApply` stays `false`.
- Cosine threshold in `SpeakerReIDService` changes from `0.62` to `0.65` (WeSpeaker-tuned default; code constant only, not user-exposed).

**Out of scope / non-goals:**

- **Per-chunk live speaker labels.** Per-chunk diarization is dropped (β path from brainstorm). Speaker labels appear once, after stop. This avoids "live but wrong" label states and saves daemon work during recording. A future "live speaker pill in the popover" feature would need this back; it's not on the roadmap.
- **Cross-chunk embedding stitching during recording (A2 path).** The path of running ECAPA/WeSpeaker per chunk and maintaining a session-scope centroid table was deliberately rejected. The single full-WAV pass produces strictly better per-speaker embeddings (FluidAudio's diarizer makes better global clustering decisions on the full WAV) and is simpler.
- **Backfill of existing recordings.** Existing recordings stay as-is. Their speaker labels (per-chunk-flipped) are preserved; their stub embeddings are wiped by the v9 migration. Users wanting to fix a specific old recording can click "Identify speakers" in the detail view (the same handler that powers the failure-retry path).
- **Bundling our own ECAPA-TDNN.** The 2026-04-22 plan to bundle a 20 MB ECAPA `.mlpackage` is dropped — FluidAudio's WeSpeaker v2 supplies a strictly better, already-shipped equivalent.
- **A standalone "People" directory.** Same non-goal as the 2026-04-22 spec.
- **Cross-device sync of voice library.** Same non-goal as the 2026-04-22 spec.
- **Real-time re-ID during recording.** Same non-goal as the 2026-04-22 spec.
- **Silent auto-application of speaker names.** `speakerReIDAutoApply` stays false by default.
- **Embedding model swapping logic at runtime.** `embedder_kind` is a tag, not a dispatch key. If we ever swap embedders, we change the constant and rows tagged with the previous kind become invisible to the cosine scan. No fallback to old-kind rows.
- **Per-segment storage of embeddings.** We store one embedding per `(recording_id, speaker_index)`. The per-segment vectors FluidAudio computes internally are averaged into per-speaker centroids by FluidAudio (`speakerDatabase`) or by us (fallback path), then stored once.
- **Tunable threshold setting.** The 0.65 constant is co-located in `SpeakerReIDService` for easy adjustment, but not surfaced in Settings. A debug log of accepted-vs-typed similarities is captured for future tuning.

---

## 3. What's shipped today vs. what changes

The 2026-04-22 design shipped partially in commit `d9e78e2`. Net inventory before this design:

**Shipped and unchanged by this design:**

- `Sources/HarcVoiceprint/EmbeddingBlob.swift` — packed Float32 BLOB encode/decode. Already dim-agnostic.
- `Sources/HarcVoiceprint/SpeakerEmbedder.swift`'s `CosineSimilarity` and `l2Normalize` helpers (still used by daemon-side fallback averaging).
- `Sources/HarcVoiceprint/SpeakerEmbedding` struct (still useful as a domain type).
- `Sources/HarcStore/RecordingStore.swift`'s embedding upsert and query methods (signature widened, behavior preserved).
- `SpeakerReIDService` (in `HarcUI`) — actor + suggestion-grouping logic.
- `StoreSpeakerNameResolver`, `SpeakerSuggestionChip`, `SpeakerNameEditor`'s suggestions-provider integration.
- `HarcPreferences.speakerReIDEnabled` and `speakerReIDAutoApply` keys.

**Shipped but wholesale replaced:**

- `Sources/HarcVoiceprint/StubSpeakerEmbedder.swift` — deleted.
- `Sources/HarcVoiceprint/SpeakerEmbedder` protocol — deleted (one-implementation protocol with no remaining call sites).
- `Sources/HarcVoiceprint/SpeakerEmbedderError` — deleted.
- `Sources/HarcVoiceprint/SpeakerExtractor.swift` — deleted (~140 lines). Replaced by FluidAudio computing embeddings inline during diarization.
- The detached extraction Task in `HarcApp/AppDelegate.swift` that ran `SpeakerExtractor.extract` on stop — deleted, replaced by the in-finalize diarize call inside `ChunkedTranscriber`.
- `Sources/HarcSTT/Diarizer.swift`'s `diarize(audioPath:) -> [SpeakerSegment]` — replaced by `diarizeWithEmbeddings(audioPath:) -> DiarizationOutput`.

**Net-new:**

- Within-recording diarization correctness (Problem A fix).
- IPC `diarize` verb + `DiarizeRequest` + `DiarizeResult` + `SpeakerEmbeddingRow` types.
- `RecordingPostProcessingState` UI state machine + popover/detail-view/menu-bar wiring.
- v9 schema migration with `embedder_kind` column.
- `EmbedderKind.wespeakerV2` constant.

---

## 4. End-of-recording data flow

**During recording (unchanged structurally, simpler):** `RecordingSession` writes the rolling 16 kHz mono WAV, `ChunkedTranscriber` polls the file every ~2 s and dispatches 60 s chunks to the daemon's `transcribe` IPC. Per-chunk diarization is now disabled — the per-chunk request specifies `diarize: false`. The daemon skips the `Diarizer` step for those chunks and returns text + word timings only.

**At stop:**

```
chunks N: text only (diarize=false) ─┐
                                     ├─→ TranscriptAssembler.finalize ─→ joinedText + words
chunks N+1: tail flush               ┘   (no speaker output)
                                                       │
                                  daemon.diarize(audioPath: finalWAV)   ← new IPC verb
                                                       │
                                  Per speaker: { startMs, endMs }[] + embedding[256]
                                                       │
                                       ┌───────────────┴───────────────┐
                                       ▼                               ▼
                              SessionTranscript                speaker_embeddings rows
                              (text + speakers + words)        (real WeSpeaker vectors)
```

`SessionTranscript.speakers` is the diarize-pass output directly — no per-chunk concatenation, no splicing onto words. Existing renderers and exporters in `HarcExport` continue to attribute words to speakers via time-range overlap, exactly as they do today; only the `speakers` array source changes.

**Embedding sourcing inside `Diarizer.diarizeWithEmbeddings`:**

1. Load samples via the existing `AudioConverter.resampleAudioFile`.
2. Call `manager.performCompleteDiarization(samples)`.
3. Map `result.segments` (`[TimedSpeakerSegment]`) to `[SpeakerSegment]` using the existing `String → Int` insertion-order mapping.
4. Build `[SpeakerEmbeddingRow]`:
   - **Preferred:** if `result.speakerDatabase` (`[String: [Float]]?`) is non-nil, use those vectors directly. They are FluidAudio's authoritative averaged centroids per clustered speaker.
   - **Fallback:** if `speakerDatabase` is nil, weighted-average the per-segment `embedding` vectors (weights = segment durations) per speaker, then `l2Normalize` in place.
   - Compute `totalMs` = sum of segment durations per speaker; `segmentCount` = number of segments per speaker.

**Persistence:** the caller (the post-finalize hand-off in `AppDelegate`) writes the embedding rows alongside the recording row via the existing `RecordingIngestor` transactional path. Both succeed or neither does.

**Latency budget.** On Apple Silicon, FluidAudio's pyannote-segmentation + WeSpeaker pipeline runs at ≈ 300×–600× realtime: roughly 6 s for a 1-hour 16 kHz mono WAV; longer for very-many-speaker audio. The user sees a brief "Identifying speakers…" indicator (section 7) during this window. The transcript text is already complete from the chunked pass; speaker labels patch in when the diarize call returns.

---

## 5. IPC

The IPC surface gains one new verb. Existing `transcribe` keeps its shape; the chunked path passes `diarize: false`.

### 5.1 New request

```swift
// HarcCore/IPCRequest.swift

public enum IPCRequest: Codable, Equatable, Sendable {
    case transcribe(TranscribeRequest)
    case diarize(DiarizeRequest)        // NEW
    case status
    case shutdown
}

public struct DiarizeRequest: Codable, Equatable, Sendable {
    public var audioPath: String
}
```

### 5.2 New response variant

```swift
// HarcCore/IPCResponse.swift

public enum IPCResponse: Codable, Equatable, Sendable {
    case result(TranscribeResult)
    case diarization(DiarizeResult)     // NEW
    case status(DaemonStatus)
    case error(IPCError)
}

public struct DiarizeResult: Codable, Equatable, Sendable {
    public var segments: [SpeakerSegment]            // existing type
    public var speakers: [SpeakerEmbeddingRow]       // NEW
    public var processingMs: Int
}

public struct SpeakerEmbeddingRow: Codable, Equatable, Sendable {
    public var speakerIndex: Int
    public var vector: [Float]      // 256, L2-normalized
    public var totalMs: Int         // sum of segment durations
    public var segmentCount: Int
}
```

`SpeakerSegment`, `Word`, `TranscribeResult` are unchanged.

### 5.3 Daemon handler outline

```swift
// Sources/HarcSTT/Daemon.swift

case .diarize(let req):
    let output = try await diarizer.diarizeWithEmbeddings(audioPath: req.audioPath)
    return .diarization(DiarizeResult(
        segments: output.segments,
        speakers: output.speakers,
        processingMs: Int(processingTimer.elapsedMs)
    ))

case .transcribe(let req):
    // Existing path, but skip the diarizer call when req.diarize == false.
```

### 5.4 Wire compatibility

Pure-additive shape. The app and daemon are versioned together (the daemon is rebuilt and re-signed into the app bundle on every Xcode build via `scripts/build-daemon.sh`), so cross-version IPC isn't a real production concern. The additive shape is still the right invariant: a stale binary on either end fails the unknown variant cleanly via Codable rather than corrupting state.

---

## 6. Schema migration v9

```swift
migrator.registerMigration("v9_speaker_embeddings_wespeaker") { db in
    // The stub-embedder rows from v6 are 192-dim mel statistics — wrong
    // shape and wrong semantics for the WeSpeaker v2 vectors that replace
    // them. New recordings repopulate; pre-existing recordings stay
    // un-fingerprinted (no automatic backfill).
    try db.execute(sql: "DELETE FROM speaker_embeddings")

    try db.alter(table: "speaker_embeddings") { t in
        // Versioned embedder identity. NULL means "unknown / pre-v9";
        // SpeakerReIDService filters to the current kind only, so old
        // rows are effectively invisible. New writes always set this.
        t.add(column: "embedder_kind", .text)
    }
}
```

No new index; the existing composite PK and `idx_speaker_embeddings_recording` cover all queries.

### 6.1 `EmbedderKind` constants

```swift
// Sources/HarcVoiceprint/EmbedderKind.swift  (NEW)

public enum EmbedderKind {
    /// FluidAudio's WeSpeaker v2 — 256-dim, L2-normalized.
    /// Bumped if FluidAudio ships a breaking change to the model
    /// or its output layout.
    public static let wespeakerV2: String = "wespeaker_v2"
}
```

### 6.2 `RecordingStore` surface deltas

Two additive changes in `Sources/HarcStore/RecordingStore.swift`:

```swift
public func upsertSpeakerEmbeddings(
    recordingID: Int64,
    rows: [SpeakerEmbeddingRow],
    embedderKind: String = EmbedderKind.wespeakerV2     // NEW
) throws

public func allSpeakerEmbeddings(
    excludingRecording: Int64,
    embedderKind: String = EmbedderKind.wespeakerV2      // NEW
) throws -> [PersistedSpeakerEmbedding]
```

The upsert writes the column. The query filters: `WHERE embedder_kind = ? AND recording_id != ?`.

`SpeakerReIDService.suggestMatches` passes `embedderKind: EmbedderKind.wespeakerV2` through to the store query. Pre-v9 rows with NULL kind are silently invisible, which is the desired behavior — they were stub vectors and aren't comparable to WeSpeaker output anyway.

### 6.3 `EmbeddingBlob` change

None to the file. `EmbeddingBlob.encode/decode` is already dim-agnostic. Call sites pass `expectedDim: 256` instead of `192`. Tests update accordingly.

---

## 7. Post-stop UX

A 3–10 s window between stop and labels-available. Surfaces it in three places.

### 7.1 `RecordingPostProcessingState`

```swift
// Sources/HarcUI/RecordingPostProcessingState.swift  (NEW)

public enum DiarizationPhase: Equatable {
    case idle
    case identifying(startedAt: Date)
    case done(speakerCount: Int)
    case failed(message: String)
}

@MainActor
public final class RecordingPostProcessingState: ObservableObject {
    @Published public private(set) var current: (recordingID: Int64, phase: DiarizationPhase)?

    public func begin(recordingID: Int64) { ... }
    public func succeed(recordingID: Int64, speakerCount: Int) { ... }
    public func fail(recordingID: Int64, message: String) { ... }
    public func clear(recordingID: Int64) { ... }
}
```

Owned by `AppDelegate`, injected as `@EnvironmentObject` to popover, detail view, and observed by the status-item glue. Only one recording is ever post-processing at a time, so the published optional pair is sufficient — no per-ID dictionary.

### 7.2 Menu bar status item

When `current.phase == .identifying`, replace the idle glyph with a pulsing/spinning indicator; tooltip "Identifying speakers… (Ns)" using the elapsed time from `startedAt`. Reverts on `.done` or `.failed`. Implementation: a `Combine.sink` on the published property updates `NSStatusItem.button.image`.

### 7.3 Popover post-stop tray

| Phase | Inline row | Copy plain text | Copy for prompt | Open |
|---|---|---|---|---|
| `.idle` | (none) | enabled | enabled | enabled |
| `.identifying` | `⟳ Identifying speakers…` | enabled | disabled + spinner | enabled |
| `.done(N)` | `✓ N speakers identified` (auto-collapses ~1.5 s) | enabled | enabled | enabled |
| `.failed(msg)` | `⚠ Couldn't identify speakers — Retry` | enabled | enabled (no labels) | enabled |

**Auto-paste** (existing plain-text-on-stop behavior) fires immediately on stop, unchanged. It does not wait on diarization.

### 7.4 `TranscriptionDetailView`

- If `RecordingPostProcessingState.current` references this recording's ID with `phase == .identifying`, render `SpeakerNameEditor` placeholder: one skeleton row + spinner + tooltip "Identifying speakers…".
- If `RecordingPostProcessingState.current` references this recording's ID with `phase == .failed`, **or** the recording has no `speaker_embeddings` rows and is not currently being processed: render an "Identify speakers" button instead of the editor. Click runs the same `client.diarize(...)` → upsert path the post-stop flow uses; while that's running, the in-memory state transitions to `.identifying` and the view switches to the skeleton state.
- On `.done`, render `SpeakerNameEditor` normally with populated speaker rows + cross-recording suggestion chips.

### 7.5 Failure semantics

If `daemon.diarize` errors or times out (default ceiling: 60 s — generous enough that we don't kill a slow legitimate run):

- Status item drops the spinner.
- Popover row becomes the failure variant with retry.
- Detail view, if open, switches to the "Identify speakers" button.
- The transcript text is **never lost** — it was complete the moment the chunked path finished. Only speaker labels and embeddings are deferred.

### 7.6 Settings

No new toggle. `speakerReIDEnabled` already exists in Settings; only the default value flips. The 0.65 threshold is a code constant, not user-exposed.

---

## 8. Code surface — what changes by module

### `HarcCore`

- **Add:** `DiarizeRequest`, `DiarizeResult`, `SpeakerEmbeddingRow`, the new `IPCRequest.diarize` case, the new `IPCResponse.diarization` case (with Codable plumbing).

### `HarcSTT` (daemon)

- **Modify:** `Diarizer.swift` — replace `diarize(audioPath:) -> [SpeakerSegment]` with `diarizeWithEmbeddings(audioPath:) -> DiarizationOutput`. Pull `result.speakerDatabase` if non-nil; fallback weighted-average of per-segment embeddings + L2-normalize.
- **Modify:** `Daemon.swift` — handle the new `IPCRequest.diarize`. Honor `transcribe.diarize: false` by skipping the diarizer call.
- **Modify:** `SocketServer.swift` — route the new request variant.
- **Add:** internal `DiarizationOutput` struct in `Diarizer.swift`.
- **Delete:** the old `diarize(audioPath:) -> [SpeakerSegment]` method (no remaining callers after `ChunkedTranscriber` switches off per-chunk diarization).

### `HarcClient`

- **Modify:** `HarcSTTClient.swift` — add `func diarize(audioPath: String) async throws -> DiarizeResult`. Mirror the existing `transcribe(...)` connect/send/recv/close pattern.
- **Modify:** `ChunkedTranscriber.swift` — default `diarize: false` on per-chunk transcribe call. After tail flush, call `client.diarize(audioPath:)` on the final WAV. `finalize(...)` returns a tuple `(SessionTranscript, [SpeakerEmbeddingRow])`. On diarize error, returns the SessionTranscript with empty `speakers` and `[]` embeddings — does not throw.
- **Modify:** `TranscriptAssembler.swift` — `finalize` no longer concatenates per-chunk speaker segments (the per-chunk path returns empty arrays). Drop the loop or leave it as harmless dead code; preference is drop.
- **Add:** a `DiarizingClient` protocol alongside `TranscribingClient`, for test seam clarity. Both protocols are conformed by `HarcSTTClient`.

### `HarcVoiceprint`

The module shrinks substantially.

- **Keep:** `EmbeddingBlob.swift`. `CosineSimilarity` and `l2Normalize` helpers (used by daemon fallback averaging). `SpeakerEmbedding` domain type.
- **Add:** `EmbedderKind.swift`.
- **Delete:** `StubSpeakerEmbedder.swift`, `SpeakerEmbedder` protocol, `SpeakerEmbedderError` enum, `SpeakerExtractor.swift`.

The module ends up at ~80 lines. Folding it into `HarcCore` is a possible follow-up but out of scope for this design — keep it as a thin shared module to avoid touch surface beyond what's needed.

### `HarcStore`

- **Modify:** `DatabaseMigrator+Harc.swift` — add `v9_speaker_embeddings_wespeaker` migration.
- **Modify:** `RecordingStore.swift` — `upsertSpeakerEmbeddings` and `allSpeakerEmbeddings` gain a defaulted `embedderKind: String` parameter.

### `HarcUI`

- **Modify:** `HarcPreferences.swift` — flip `speakerReIDEnabled` default `false → true`.
- **Modify:** `SpeakerReIDService.swift` — threshold `0.62 → 0.65`. Pass `embedderKind` to the store query. Add a debug-pref-gated log of accepted-vs-typed similarities (file at `~/Library/Application Support/Harc/reid-similarity.log`, append-only) to inform future tuning.
- **Modify:** post-stop popover tray — render the inline status row from `RecordingPostProcessingState`. Disable Copy-for-prompt during `.identifying`. Show retry on `.failed`.
- **Modify:** `TranscriptionDetailView.swift` and its window controller — gate `SpeakerNameEditor` behind `phase == .done`; render skeleton during `.identifying`; render "Identify speakers" button on `.failed` or recordings with no embeddings.
- **Add:** `RecordingPostProcessingState.swift`.

### `HarcApp`

- **Modify:** `AppDelegate.swift` — remove `StubSpeakerEmbedder()` instantiation and the detached `SpeakerExtractor.extract` job spawned on stop. Wire the `RecordingPostProcessingState` lifecycle: `.begin` when `ChunkedTranscriber.finalize` enters its diarize call, `.succeed` after `RecordingStore.upsertSpeakerEmbeddings` returns, `.fail` on error.
- **Modify:** the menu-bar status-item glue to bind to `RecordingPostProcessingState.current.phase`.

---

## 9. Tests

### 9.1 Unit

- `HarcCoreTests` — Codable round-trip for `DiarizeRequest`, `DiarizeResult`, `SpeakerEmbeddingRow`, and the new IPC enum cases.
- `HarcSTTTests` — `Diarizer.diarizeWithEmbeddings`:
  - Happy path with `speakerDatabase` set: returned vectors match the database entries by speakerId, lengths == 256, L2-norm ≈ 1.
  - Fallback path with `speakerDatabase` nil: weighted average across segments matches a hand-computed reference within ε; L2-normalized.
  - `transcribe` with `diarize: false` returns empty `speakers: []` and skips diarizer init (mocked).
- `HarcVoiceprintTests` — drop stub-embedder and extractor tests. Keep `EmbeddingBlob` round-trip at 256 dims; cosine identity / orthogonality / antipodal cases; `l2Normalize` invariants.
- `HarcStoreTests` — v9 migration on a v8 fixture: existing rows deleted, `embedder_kind` column added, idempotent re-runs. `RecordingStore.upsertSpeakerEmbeddings` writes the kind column. `allSpeakerEmbeddings(excludingRecording:embedderKind:)` filters cross-kind rows when two kinds coexist.

### 9.2 Service / integration

- `HarcClientTests` — `ChunkedTranscriber` against a stub `TranscribingClient` + `DiarizingClient`:
  - Per-chunk transcribe calls all use `diarize: false`.
  - `finalize` calls `diarize` exactly once with the audio URL it was given.
  - Returned `SessionTranscript.speakers` matches the stub's diarize response.
  - On diarize error, `SessionTranscript` returns with text + words intact, empty `speakers`, no thrown error.
- `SpeakerReIDService` tests (existing) — updated for threshold 0.65; embedder-kind filter.

### 9.3 Manual QA

- **Within-recording fix.** Record a 5-minute conversation with two voices (the user + one other person). Verify Speaker 1 is consistent throughout — no mid-conversation flips. Verify the post-stop "Identifying speakers…" indicator appears and resolves in ≤ 15 s for a 5-minute recording.
- **Force-quit recovery.** Force-quit the app immediately after stopping a recording (during the post-processing window). Relaunch. Open the recording — "Identify speakers" button appears; click; embeddings populate within ~10 s; Speaker 1 / Speaker 2 are consistent.
- **Cross-recording suggestion.** Record three short meetings with the same second voice. Name "Speaker 1" as e.g. "Maria" in the first recording. Open the second recording — suggestion chip "Sounds like Maria · 1 prior recording · NN%" appears. Click it; name fills; propagation banner offers to apply to the third recording.
- **Failure path.** Kill the daemon mid-diarize (e.g., via `kill <pid>` from the daemon log). Verify popover surfaces "Couldn't identify speakers — Retry"; retry succeeds.
- **Long meeting.** Record a 60-minute meeting with two speakers. Verify diarization completes in ≤ 30 s post-stop and speaker labels are correct end-to-end.

---

## 10. Rollout

- **Single migration** (v9) applied at first launch on the new build. No data movement beyond the DELETE.
- **No backfill.** Existing recordings keep their current per-chunk-flipped speaker labels and have zero embeddings. Users wanting to fix any specific old recording use the "Identify speakers" button in detail view (the same handler that powers the failure-retry path). This is documented in the user-visible release note.
- **Default flips visible to existing users.** Anyone who manually enabled `speakerReIDEnabled = true` on the prior build was getting stub-vector matches (effectively random). Their suggestion chips will become accurate. Worth a one-line note in the changelog: "Speaker matching now uses a real voiceprint model — your suggestions will be much more accurate."
- **No feature flag.** The whole point is unifying the within-recording fix and the cross-recording feature; there is no useful midpoint to ship.

---

## 11. Risk inventory

| Risk | Mitigation |
|---|---|
| FluidAudio model load time on first run with new diarizer-call paths. | Already paid today (the diarizer is pre-loaded on daemon start). No regression. |
| `result.speakerDatabase` is nil in some FluidAudio versions or edge cases. | Fallback path averages per-segment embeddings + L2-normalizes. Both paths covered by tests. |
| Diarizer crashes or hangs on long meetings. | 60 s timeout on the IPC call. Failure surfaces a retry affordance. Transcript text is never lost. |
| `wespeaker_v2.mlmodelc` shape changes in a future FluidAudio release. | `embedder_kind` column lets us bump the constant; old rows become invisible to suggestion queries. No migration logic needed for the swap. |
| Cosine threshold 0.65 turns out to be too loose or too tight on real meeting audio. | Code constant, easily adjusted. Hidden-pref-gated similarity log captures real numbers for tuning. |
| Force-quit-during-post-processing leaves recording in inconsistent state. | "Identify speakers" affordance in detail view recovers cleanly. Same handler as failure-retry. |

---

## 12. Open questions

- **Threshold tuning.** 0.65 is a defensible WeSpeaker default; revisit after a few weeks of dogfood data from the similarity log. Constant lives in `SpeakerReIDService`.
- **Folding `HarcVoiceprint` into `HarcCore`.** The module ends up small enough that it's arguably not worth its own target. Out of scope for this design — flag for a future cleanup PR.
- **Live speaker pill in popover.** If we ever want live (during-recording) speaker labels in the popover, per-chunk diarization needs to come back. Not on the roadmap; design left open.
