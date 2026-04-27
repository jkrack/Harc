# Speaker Re-ID Across Recordings Design Doc

> **Superseded by [2026-04-26-speaker-identity-design.md](2026-04-26-speaker-identity-design.md).**
> The 2026-04-26 design subsumes this one and broadens scope to cover within-recording diarization correctness alongside across-recording identity. It also retires the bundled-ECAPA model plan in favor of FluidAudio's already-bundled WeSpeaker v2 embedder. The shipped commit `d9e78e2` (schema, EmbeddingBlob, SpeakerExtractor, StubSpeakerEmbedder, suggestion chips) implements parts of this older design; what remained un-shipped is now redesigned from scratch in the 2026-04-26 doc. This document is preserved as historical context — do not implement against it.

**Feature:** Extract a short voice fingerprint per diarized speaker segment, cluster fingerprints across the user's library, and surface "this speaker sounds like <Name> — used in N other recordings" suggestions in the existing `SpeakerNameEditor`. Naming one speaker automatically propagates across their recent recordings, fixing the "Speaker 1 is a different person in every meeting" problem.
**Date:** 2026-04-22
**Status:** superseded by 2026-04-26-speaker-identity-design.md
**Depends on:** `2026-04-20-speaker-renaming-design.md` (the per-recording rename feature; this extends it, not replaces it)

---

## 1. Problem & user story

The speaker-rename feature delivered last week lets users type `Jason` and `Amy` into a recording's speaker slots. The limitation, deliberately kicked down the road in that design: speaker IDs are per-recording — `Speaker 1` on Monday is a different person from `Speaker 1` on Tuesday, because FluidAudio's diarizer clusters voices within a recording, not across. A user with 20 meetings with the same 3 people ends up typing "Jason, Amy, Sam" 20 times.

**User story (first suggestion).** "I just recorded today's standup. I open the recording; `SpeakerNameEditor` shows two rows. Next to Speaker 1 there's a subtle chip: *Sounds like Jason · 3 prior recordings*. I click it — the field fills with `Jason` and his name also gets applied to Speaker 1 in the 3 other recordings that matched."

**User story (manual override).** "The suggestion says *Sounds like Amy*, but it's actually her new colleague Chris who sounds similar. I ignore the chip, type `Chris` myself. Next time I record with Chris, his own fingerprint is now in the library and he gets suggested for his own voice — not Amy's."

**User story (wrong suggestion).** "The chip says *Sounds like Jason (67 % match)*. The match percentage is right there; I know it's actually Jason's brother. I hit the `×` on the chip to dismiss just this one. The chip stays dismissed on this recording but keeps suggesting elsewhere."

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- A new `SpeakerEmbedder` in `HarcSTT` (or a new `HarcVoiceprint` target — see §3.1) that consumes a mono 16 kHz Float32 audio segment and returns a 192-dim L2-normalized `[Float]` embedding. Bundled ECAPA-TDNN or WavLM-base Core ML model, ~20–30 MB, shipped inside `Harc.app/Contents/Resources`.
- Integration in the daemon's existing transcription pipeline: for each `SpeakerSegment` the diarizer returns, run the embedder on that segment's audio region and attach the resulting vector to the IPC response.
- New DB table `speaker_embeddings`:
  - `recording_id INTEGER NOT NULL` (FK → recordings.id)
  - `speaker_index INTEGER NOT NULL` (matches the per-recording 0-based speaker index)
  - `embedding BLOB NOT NULL` (192 Float32 = 768 bytes)
  - `segment_count INTEGER NOT NULL` (how many diarized segments were averaged)
  - `total_ms INTEGER NOT NULL` (total speech duration averaged)
  - PK on `(recording_id, speaker_index)`.
- Added via `DatabaseMigrator` migration `v7_speaker_embeddings`.
- `SpeakerReIDService` actor: given a new embedding, searches the table for cosine-similar vectors above a threshold; returns top-K matches with their recording IDs + speaker indices + the names (from the existing `speaker_names` column) that the user has assigned to those speakers.
- `SpeakerSuggestionChip` SwiftUI view in `SpeakerNameEditor` — one chip per suggested match; clicking applies the name to this speaker AND optionally propagates it back to the unnamed / mismatched prior speakers (see §5.3).
- `HarcPreferences.speakerReIDEnabled` (default `true`).
- `HarcPreferences.speakerReIDAutoApply` (default `false`) — when true, single-match suggestions apply silently. Default is "suggest but don't write."
- Unit tests for: embedding-distance math (cosine, thresholding), averaging multiple segments, the SQL-level kNN query, the propagation logic.

**Out of scope / non-goals (v1):**

- **A standalone "People" directory.** No list of known voices with names and avatars. The library of embeddings is a derived index, not a user-facing entity. (A future Tier 2 may surface it.)
- **Cross-device sync of the voice library.** Everything is local. The embedding is a derived artifact per-recording, regenerated cheaply if the DB is ever wiped.
- **Real-time re-ID during recording.** Embeddings are computed at the end of a recording alongside the transcript; not surfaced live.
- **Automatic silent name assignment.** `speakerReIDAutoApply` is off by default. Suggestions are one click to accept — never invisible.
- **Biometric lock-in.** Voice matching is a convenience, not an auth factor. We deliberately under-claim accuracy.
- **Embedding updates from user corrections.** We don't train or fine-tune anything. If the user contradicts a suggestion, we respect the edit per-recording but don't mutate embeddings.
- **Speaker re-ID across DIFFERENT diarizer runs on the same recording.** If the diarizer ever re-runs and produces different speaker indices, this table's rows become stale for that recording. We treat that as a delete-on-rewrite: a new transcription for the same recording_id deletes the old embedding rows first.
- **Embedding model swapping.** One model, one embedding shape (192-dim). If we ever swap it, we migrate by re-running the embedder on existing WAVs in a one-time backfill — not something v1 designs for.
- **Handling a 200+-recording library scaling.** Linear cosine scan across a few thousand vectors is fine for the realistic user base (see §4.4). No ANN / HNSW indexing in v1.

---

## 3. Model choice + integration

### 3.1 Model

**ECAPA-TDNN (English-trained, ~20 MB as Core ML)** or **WavLM-Base speaker embedding (~95 MB)**. We pick **ECAPA** as the v1 default:

- Compact enough to bundle (doesn't need Model Manager).
- Well-studied for speaker verification on English meeting audio.
- Stable 192-dim embedding; cosine similarity has a well-understood threshold range (~0.6–0.7 for "likely same person" on 10 s+ of audio).

The Core ML `.mlpackage` lives at `HarcApp/Resources/SpeakerEmbedder.mlpackage` and is included in the app target. A small adapter in `Sources/HarcVoiceprint/` loads + runs it.

**Why not the pyannote embedder that FluidAudio's diarizer already uses internally?** It's not exposed through FluidAudio's public API; we'd be reaching into private surfaces. Using a second model is one-time cost we pay for decoupling.

### 3.2 Targets

New library target:

```swift
.target(
    name: "HarcVoiceprint",
    dependencies: ["HarcCore"],
    resources: [.copy("Resources/SpeakerEmbedder.mlpackage")]
)
```

`HarcSTT` does NOT depend on `HarcVoiceprint` directly — the daemon stays model-small. Instead:

- The daemon emits speaker segments and their `startMs`/`endMs` as before.
- `HarcClient.ChunkedTranscriber.finalize(...)` picks up the final `SessionTranscript` + the cached audio path, and runs `HarcVoiceprint` against the WAV to extract per-speaker embeddings, which are then passed to the store writer.

This keeps the daemon stateless of voiceprints and lets us run the embedder against the final mixed WAV (not the daemon's short-lived chunks).

### 3.3 Extraction

Per recording, for each distinct speaker index:

1. Gather all segments `[(startMs, endMs)]` for that speaker from `TranscribeResult.speakers`.
2. For each segment, load the corresponding samples from the 16 kHz mono WAV (re-reusing `AudioConverter` / direct `AVAudioFile` reads).
3. Concatenate (with small silence padding to avoid boundary artifacts), cap at 60 s total per speaker (more than that is diminishing returns).
4. Run `SpeakerEmbedder.embed(samples:)` → 192-dim Float32.
5. L2-normalize; store.

Segments shorter than 1 s total are skipped — the embedder doesn't produce useful fingerprints on tiny samples. A speaker with under 1 s in a recording gets NO row in `speaker_embeddings`; the chip won't suggest for them and no matches will be found.

---

## 4. Data + retrieval

### 4.1 Schema

```sql
CREATE TABLE speaker_embeddings (
    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    speaker_index INTEGER NOT NULL,
    embedding BLOB NOT NULL,
    segment_count INTEGER NOT NULL,
    total_ms INTEGER NOT NULL,
    PRIMARY KEY (recording_id, speaker_index)
);

CREATE INDEX idx_speaker_embeddings_recording ON speaker_embeddings(recording_id);
```

No index on the BLOB — we scan linearly (see §4.4).

### 4.2 Blob layout

`BLOB` is the concatenation of 192 × 4-byte little-endian Float32, 768 bytes total. Encoded/decoded via a tiny helper:

```swift
public enum EmbeddingBlob {
    public static func encode(_ vec: [Float]) -> Data   // precondition: vec.count == 192
    public static func decode(_ data: Data) -> [Float]  // returns [] on wrong length
}
```

### 4.3 Search

```swift
public struct SpeakerMatch: Sendable {
    public let recordingID: Int64
    public let speakerIndex: Int
    public let name: String?        // from recordings.speaker_names, or nil
    public let similarity: Float    // cosine, 0..1
    public let recordingStartedAt: Date
    public let recordingTitle: String
}

public actor SpeakerReIDService {
    /// Top-K candidates above `threshold`, ordered by similarity desc.
    public func suggestMatches(
        for embedding: [Float],
        excludingRecording: Int64,
        threshold: Float = 0.62,
        k: Int = 5
    ) async throws -> [SpeakerMatch]
}
```

- Cosine similarity is a dot product of two L2-normalized vectors; no normalization at search time.
- Only considers embeddings with `total_ms >= 5000` and where the target recording has a non-empty `speaker_names` override for that speaker (see §4.5 about unnamed candidates).
- Returns at most `k` matches.
- The `excludingRecording` param keeps a recording from matching itself.

### 4.4 Performance

A linear scan over `speaker_embeddings` is the v1 plan. Cost per query, with a 192-dim dot product ≈ 500 ns on Apple Silicon:

| Library size | Rows (est.) | Scan time |
|---|---|---|
| Light user (50 meetings, 3 speakers avg) | 150 | 75 µs |
| Heavy user (1,000 meetings, 4 speakers avg) | 4,000 | 2 ms |
| Power user (10,000 meetings) | 40,000 | 20 ms |

Well under user-perceivable. We revisit if anyone hits 50k+ (at which point a stored HNSW graph becomes worth it).

### 4.5 Grouping by identity

Two embeddings with the same `name` in different recordings are treated as the same person for suggestion purposes. When we build the match list, we:

1. Find all rows above threshold.
2. Group by `recordings.speaker_names[speakerIndex]` — matches where the user named the speaker the same thing coalesce into one suggestion with `N prior recordings` count.
3. Matches with `name = nil` (unnamed in their source recording) are still returned but at a lower priority — shown as "Sounds like a speaker from <date>" rather than a name suggestion. Clicking them offers to propagate an anchor.

---

## 5. UI — integration with `SpeakerNameEditor`

### 5.1 When suggestions are computed

Per the existing editor, on first appearance for a recording we already call `ExportInputBuilder.build(from:)` to discover speaker indices. We extend that path: after the editor mounts, fire a detached Task per speaker:

```swift
for speakerIndex in discoveredSpeakers {
    Task { [weak self] in
        guard let embedding = try? await self?.store.embedding(for: recordingID, speakerIndex: speakerIndex) else { return }
        let matches = try await reIDService.suggestMatches(for: embedding, excludingRecording: recordingID)
        await MainActor.run { self?.suggestions[speakerIndex] = matches }
    }
}
```

Each row renders zero or more chips based on `suggestions[speakerIndex]`.

### 5.2 Chip shape

```
┌──────────────────────────────────────────────────────────────┐
│ Speaker 1                 [_Jason__________________________] │
│                                                              │
│   ◉ Sounds like Jason (3 prior recordings, 84 %)   ✕         │
│   ◉ Sounds like Amy (1 prior recording, 63 %)       ✕         │
└──────────────────────────────────────────────────────────────┘
```

- Ordered by similarity desc.
- Clicking the main chip body populates the field with the suggested name (committing just like a typed edit), and triggers §5.3 propagation.
- `✕` dismisses the chip for this speaker on this recording only (stored in local view state, not persisted).
- Chips with `name == nil` show "Sounds like a speaker from Apr 12 · 67 %" and clicking offers a native sheet: "This speaker appears in 2 earlier recordings. Name them all?"

### 5.3 Propagation

When user accepts a suggestion "Sounds like Jason · 3 prior recordings":

1. The name is written to this recording's `speaker_names[speakerIndex]`.
2. A modal or inline confirmation (design choice: inline, as a banner just below the editor) lists the 3 prior recordings with a checkbox each; Harc proposes applying the same name to all of them. Default: all boxes checked.
3. On confirm, a single async pass writes `speaker_names[priorSpeakerIndex] = "Jason"` to each checked recording.
4. No writes are retroactive to exports / pasted blobs — just the DB. The next time a user opens / exports those recordings, the new name shows up.

**When `HarcPreferences.speakerReIDAutoApply == true`:** step 2's UI is skipped for matches with similarity ≥ 0.78 AND where every prior recording agrees on the name. Lower-confidence or conflicting matches always show the confirm UI.

### 5.4 Visibility rule

The chip row is hidden entirely if:

- `HarcPreferences.speakerReIDEnabled == false`
- OR the speaker has no embedding row (`total_ms < 1 s`)
- OR no matches above threshold

A speaker with the chip row but no matches shows a muted "No matches yet — record more meetings to build your voice library" hint the first 3 times the editor opens; dismissed forever after.

---

## 6. Feedback loop (deliberately minimal)

- **Accepting a suggestion** just writes a name. No quality signal fed back.
- **Dismissing a chip** is view-state only — the suggestion returns next time.
- **Typing a different name** than the chip suggested is the product's implicit "wrong" signal, but we don't store or learn from it.

This is deliberate. Learning from user edits would require a trust model (which person is Jason's real voice — the one in recording A or B?), and that's a v2 rabbit hole. v1 stays stateless on the feedback side.

---

## 7. Test plan

### 7.1 Unit tests (HarcVoiceprintTests)

- `EmbeddingBlob.encode/decode` round-trip: 192 floats in, equal floats out.
- Cosine similarity helpers: identical vector → 1.0; orthogonal → 0.0; antipodal → −1.0.
- Averaging: 3 segments of a speaker collapsed into a single 192-vector matches a direct concat-then-embed baseline within ε on a fixture WAV.

### 7.2 Store tests (HarcStoreTests)

- `v7_speaker_embeddings` migration creates the table on a fresh DB and preserves existing rows when applied to a fixture from v6.
- `ON DELETE CASCADE` works: deleting a recording removes its embedding rows.
- `RecordingStore.upsertEmbeddings(recordingID:, rows:)` overwrites prior rows for the same recording (v1 guarantees one embedding per (rec, speaker)).

### 7.3 Service tests

- `SpeakerReIDService.suggestMatches` on a seeded DB of 5 recordings with 2 known voices:
  - High-similarity match surfaces first.
  - Threshold of 0.62 filters out noise.
  - `excludingRecording` keeps the current recording out of its own results.
  - Name-coalescing: 3 recordings where user named the speaker "Jason" → one match entry with `priorRecordings = 3`.

### 7.4 Integration (manual QA list)

- Record 3 meetings with the same two voices (synthetic TTS samples are fine for the test fixture). Name speakers in meeting 1. Open meeting 2 and 3; confirm chips appear and accepting one propagates.
- Use two different-sounding voices in a 4th recording — confirm NO chip appears for them.
- Dismiss a chip; reopen the editor — chip should still NOT be present in this session, but SHOULD reappear on app relaunch (view-state dismissal is not persistent).

---

## 8. Rollout

- v1 ships with `speakerReIDEnabled = true` by default. Zero user-visible change until:
  1. The user has ≥ 2 recordings with the same person, AND
  2. The user has named that person at least once.
- A one-time backfill runs on first launch post-upgrade to populate `speaker_embeddings` for existing recordings. Runs in a detached Task, no UI, bounded by one WAV at a time. The migration marks it in a `speaker_embeddings_backfill_state` row in a tiny `app_state` key/value table; if interrupted (app quit) it resumes on next launch.
- Suggestion chips arrive after backfill completes for the prior-recording universe. The banner "Your voice library is still building (N/M recordings)" shows in `SpeakerNameEditor` during the backfill window.

---

## 9. Open questions

- **Threshold tuning.** 0.62 is a defensible default from ECAPA papers. We should plan to revisit after real-world use — it may be slightly too low on noisy meeting audio. Keep the constant co-located in `SpeakerReIDService` for easy knob-turning.
- **Per-user threshold?** A user's specific microphone + mic-placement consistency may let us raise or lower it. Out of scope for v1; log similarity scores of accepted matches to a local analytics file for self-debugging in the future.
- **Model choice revisit.** If WavLM-base gives meaningfully better accuracy on meeting audio (not podcast audio), it's worth the extra 75 MB. Decide after a small blind test post-v1.
