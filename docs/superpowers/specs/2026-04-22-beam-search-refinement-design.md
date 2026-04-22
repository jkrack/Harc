# Beam Search Transcript Refinement Design Doc

**Feature:** Add a deferred "refine this transcript" pass that re-transcribes a recording with beam search instead of the live pipeline's greedy decode. User-triggered from the transcript editor; future v2 adds idle/AC-powered auto-refinement. Zero latency for the first pass (greedy stays as the default), quality upgrade available on demand, never clobbers user edits.
**Date:** 2026-04-22
**Status:** draft — ready for implementation

---

## 1. Problem & user story

Live transcription uses FluidAudio's default greedy decode. It's fast, good enough, and matches the "never lose context" reliability bar in `CLAUDE.md`. It also has a quality ceiling: in low-SNR stretches, overlapping speech, or near acronyms, greedy flips a token that a wider beam would have gotten right. The pattern "ship fast draft, refine later" matches how we already think about the app — heavy work goes to down moments.

**User story (user-triggered).** "I'm reviewing an important recording in the transcript editor. I see a mangled bit — Parakeet got confused around the phrase 'parakeet-tdt-0-point-6'. I hit **Refine with beam search** in the toolbar. A progress bar at the top of the editor; ~40 s later, the transcript has been rewritten. The mangled phrase is now right. My 3 hand edits from earlier are preserved."

**User story (can't refine over edits).** "I refined a transcript yesterday, made 2 hand edits this morning, and now want to refine again after uploading a bigger model. The Refine button is disabled with a tooltip: *Transcript has been edited. Discard edits to refine?* — the only way forward is to explicitly accept a blow-away."

**User story (don't-bother cases).** "For a 5-minute dictation that transcribed perfectly, I don't see the Refine button take any special prominence. It's a quiet toolbar item I'll ignore."

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- Extended daemon protocol: the existing `transcribe` request gets optional `beamSize: Int` field (default `1` = greedy; `2..16` allowed). `harc-stt` passes this through to FluidAudio's `AsrManager`. (See §3 for the "Does FluidAudio support this?" gating.)
- Transcript lifecycle column on `recordings`:
  - `transcript_quality TEXT NOT NULL DEFAULT 'draft'` — values: `'draft'`, `'refined'`, `'edited'`.
  - Set to `'draft'` on initial pipeline output.
  - Set to `'refined'` after a successful beam pass completes.
  - Set to `'edited'` the first time the user edits a `'draft'` or `'refined'` transcript.
  - Migration `v9_transcript_quality`.
- A `TranscriptRefinementService` actor in `HarcClient` that:
  - Takes a recording ID.
  - Reads the WAV path, sends a `transcribe` IPC request to `harc-stt` with `beamSize: <configured>`.
  - Runs the same post-processing the normal path runs (VAD already-applied, diarizer, vocabulary replacement).
  - Writes the result back via `RecordingStore.replaceTranscript(id:, result:)` in a single transaction, sets `transcript_quality = 'refined'`.
- Guard rail: refusal to refine a recording with `transcript_quality = 'edited'` without explicit user confirm that their edits will be dropped.
- `HarcPreferences.refineBeamSize` (Int, default `4`, range `1..16`).
- UI surface in `TranscriptEditorView`:
  - Toolbar button **Refine with beam search** (with variant state: `ready`, `running(progress)`, `disabled(reason)`).
  - A modal confirm when the current transcript is `'edited'`.
  - Progress bar + cancel affordance during refinement.
- Invalidation: after a successful refinement, the summary (if any) is flagged stale (see `2026-04-22-local-summarization-design.md` §10), the semantic index is re-run via the existing `chunks_indexed_at = NULL` trigger (see `2026-04-22-semantic-search-design.md` §4.5), and word-level edit mappings are discarded.
- Tests for the state machine, the protocol extension, the idempotent replace path, and the "edited → blocked" guard.

**Out of scope / non-goals (v1):**

- **Automatic / background refinement.** v1 is entirely user-triggered. A future v2 adds "refine all drafts on AC power when idle" gated by a preference; the spec here leaves room for it without implementing it.
- **Per-segment selective refinement.** Can't re-run the decoder on half a recording cheaply; it's the whole file or nothing.
- **N-best rescoring with an external LM.** A proper rescore step (the cheap kind, not a full decoder re-run) would need Parakeet to emit n-best, which FluidAudio doesn't surface. Not a v1 option.
- **Comparing greedy vs beam outputs in UI.** We don't diff. Refined output replaces draft output wholesale. No side-by-side.
- **Variable beam size per recording.** One preference, applied to every refinement. No "try with beam 2, then retry with beam 8" UX.
- **GPU-aware scheduling.** The daemon takes what it gets; OS scheduling is fine.
- **Refining while a live recording is in progress.** The daemon serializes transcribe requests today; new refinements queue behind in-flight transcripts.
- **Offline queueing across app quits.** If the user quits with a refinement pending, it's cancelled. Next launch shows the transcript in its pre-refinement state.

---

## 3. Capability gating — does FluidAudio expose beam?

**Unknown at spec time.** `Sources/HarcSTT/Transcriber.swift` calls `manager.transcribe(samples)` — no beam parameter in the current code. FluidAudio's `AsrManager.config` may expose one, or may not. **Implementation step one is a capability check.**

Three resolutions:

1. **FluidAudio exposes a beam-size knob** (e.g. `DecodingConfig(beamSize: 4)` or a method param) → wire it through the daemon protocol and we're done.
2. **FluidAudio has the decoder abstraction but beam isn't public yet** → file a PR against FluidAudio. Until it lands, ship the rest (DB columns, UI, state machine) behind a `transcriptRefinementEnabled` feature flag; button renders disabled with a tooltip explaining "coming soon."
3. **FluidAudio's Parakeet decoder is greedy-only and not easily extensible** → the feature as specified doesn't ship. Fall back to a different quality lever (e.g. re-run with a different model variant, or wait for upstream). No silent partial ship — we pull the feature entirely from the release rather than shipping a dead button.

The plan doc accompanying this spec opens with the capability check as Task 1 and gates the rest on it.

---

## 4. Protocol + daemon

### 4.1 IPC request

`harc-stt` currently accepts (from `2026-04-17-harc-daemon-core.md`):

```json
{"type":"transcribe","audioPath":"/…wav","vad":true}
```

Extended to:

```json
{"type":"transcribe","audioPath":"/…wav","vad":true,"beamSize":4}
```

- `beamSize` optional. Absent or `1` → greedy (today's behavior).
- Values outside `1..16` → daemon returns `error` with `code: "invalid_beam"`.
- Values > 1 on a daemon/FluidAudio that doesn't support beam → `error` with `code: "beam_unsupported"`. Client surfaces this as a clear UI error, not a silent fallback.

### 4.2 Transcriber changes

```swift
public func transcribe(audioPath: String, vad: Bool, beamSize: Int = 1) async throws -> TranscribeResult {
    // identical preamble: load model, resample, (optionally) VAD-gate
    // then:
    let asrConfig = beamSize > 1
        ? AsrManager.DecodingConfig(beamSize: beamSize)  // placeholder API, per §3
        : AsrManager.DecodingConfig.greedy
    let result = try await manager.transcribe(samples, config: asrConfig)
    // identical postamble: VAD timestamp remap, word conversion, etc.
}
```

(API names subject to what FluidAudio exposes — fix at impl time.)

### 4.3 No other protocol touches

The `result`, `status`, and `shutdown` messages are unchanged. Beam is an input parameter; the output shape is identical.

---

## 5. Client: `TranscriptRefinementService`

### 5.1 API

```swift
public actor TranscriptRefinementService {
    public enum Phase: Equatable, Sendable {
        case idle
        case queued
        case running(progress: Double?)        // progress optional; daemon may not report
        case completed
        case failed(String)
    }

    public func refine(recordingID: Int64, allowOverwriteEdited: Bool = false) async throws
    public func cancel(recordingID: Int64)
    public nonisolated func phase(of id: Int64) -> AsyncStream<Phase>
}
```

### 5.2 Flow

1. Load the recording from `RecordingStore`; fetch `transcript_quality`.
2. If `'edited'` and `allowOverwriteEdited == false`, throw `.editedWithoutConfirm` — the UI catches this and shows the modal.
3. Emit `.queued`.
4. Acquire the daemon via the existing `HarcSTTClient`.
5. Send `transcribe` with `beamSize = prefs.refineBeamSize`, audioPath = the stored WAV.
6. On result:
   - Construct a new `SessionTranscript` following the same path `ChunkedTranscriber.finalize` does (speaker segments merged in, vocabulary replaced, timestamps remapped).
   - Call `RecordingStore.replaceTranscript(id:, result:)` which:
     - Transaction-wraps: update `transcript_text`, rewrite sibling `.txt` + `.json` next to the WAV, set `transcript_quality = 'refined'`, null `chunks_indexed_at` so semantic search re-indexes, and null any `summary_markdown` if `refinementInvalidatesSummary == true` (preference, default `true`).
     - Emits the usual store change notification so the UI refreshes.
   - Re-kicks the semantic backfill and the summarization trigger (same as they fire on a fresh recording), so downstream artifacts catch up automatically.
7. Emit `.completed`; 1.5 s later revert to `.idle`.
8. On failure: emit `.failed(reason)`; DB untouched.

### 5.3 Cancellation

- Client-side cancel: cancel the Task that's awaiting the daemon response. The daemon keeps processing (no cancellation over the protocol in v1) but the client drops the result. Next launch the daemon is idle-shutdown anyway.
- A future v2 adds an `abort` IPC message. Out of scope here.

---

## 6. DB / store changes

### 6.1 Migration `v9_transcript_quality`

```sql
ALTER TABLE recordings
ADD COLUMN transcript_quality TEXT NOT NULL DEFAULT 'draft';

UPDATE recordings SET transcript_quality = 'draft' WHERE transcript_text IS NOT NULL;
```

No data loss. Existing recordings all enter the `'draft'` state — they haven't been refined and we can't infer prior edits retroactively (the `'edited'` state is set prospectively by the editor going forward).

### 6.2 Swift shape

```swift
// HarcStore/Recording.swift
public enum TranscriptQuality: String, Codable, Equatable, Sendable {
    case draft
    case refined
    case edited
}

public var transcriptQuality: TranscriptQuality = .draft
```

### 6.3 Store methods

```swift
public func replaceTranscript(id: Int64, result: SessionTranscript) async throws
public func markTranscriptEdited(id: Int64) async throws
```

- `replaceTranscript` sets `.refined`.
- `markTranscriptEdited` sets `.edited`, called from `TranscriptEditorViewModel` on first dirty-state transition.

---

## 7. UI — transcript editor toolbar

### 7.1 Button states

Rendered in `TranscriptEditorTransportView` (existing toolbar):

| State | Label | Enabled? | Tooltip |
|---|---|---|---|
| `.idle`, quality `draft` | Refine with beam search | yes | "Re-transcribe at higher quality" |
| `.idle`, quality `refined` | Refine with beam search | yes | "Already refined. Re-running will replace." |
| `.idle`, quality `edited` | Refine with beam search | disabled | "You've edited this transcript. Click to discard edits and refine." — clicking opens the confirm. |
| `.queued` / `.running` | Refining… | disabled (shows spinner) | "In progress" |
| `.failed(reason)` | Refine with beam search | yes, with small ⚠︎ | reason |

### 7.2 Confirm modal (quality == edited)

Native macOS `NSAlert`:

```
Refine this transcript?
Refining replaces the current transcript — your hand edits will be lost.
                        [Cancel]  [Discard edits & refine]
```

Accept → calls `refine(recordingID:, allowOverwriteEdited: true)`.

### 7.3 Progress

During `.running`, a thin progress bar sits at the top of the editor pane. No ETA (daemon doesn't report progress in v1); we just render an indeterminate animation.

### 7.4 Post-completion feedback

A toast in the bottom-right of the editor:
```
Refined with beam 4 · 42 s
```
Auto-dismisses after 4 s.

### 7.5 Stale-summary indicator

After refinement, if the recording had a summary, the `SummaryCardView` (see summarization spec) shows its `summary is based on an older transcript` nudge per that spec's §10. We don't auto-regenerate — too heavy without user consent.

---

## 8. Preferences

```swift
@Published public var transcriptRefinementEnabled: Bool    // default true
@Published public var refineBeamSize: Int                  // default 4, range 1...16
@Published public var refinementInvalidatesSummary: Bool   // default true
```

`transcriptRefinementEnabled = false` hides the toolbar button entirely. `refineBeamSize` is exposed in Settings → Transcription under an "Advanced" disclosure. `refinementInvalidatesSummary` is not exposed — a legacy-safety knob for internal testing; could be promoted if users push back.

---

## 9. Test plan

### 9.1 Unit tests

- `TranscriptQuality` round-trips through `Codable` and the GRDB column.
- `RecordingStore.replaceTranscript` rewrites text, sibling files, and sets `quality = .refined` atomically; partial failure rolls back.
- `RecordingStore.markTranscriptEdited` transitions draft → edited and refined → edited; no-op if already edited.
- `TranscriptRefinementService.refine` with a mock daemon:
  - Success path updates store.
  - `allowOverwriteEdited: false` on an `.edited` recording throws `.editedWithoutConfirm`.
  - `allowOverwriteEdited: true` on `.edited` runs.
  - Beam-unsupported response surfaces as `.failed("beam_unsupported")`.

### 9.2 Daemon tests (HarcSTTTests)

- `transcribe` request with `beamSize = 1` → greedy (matches today's behavior exactly).
- `beamSize = 0` or `17` → error `invalid_beam`.
- `beamSize = 4` on a compiled-without-beam FluidAudio (mocked) → error `beam_unsupported`.
- `beamSize = 4` on a compiled-with-beam FluidAudio (real, behind a `HARC_TEST_BEAM` env flag since it needs real model weights) → produces a transcribe result that differs measurably from greedy on a fixture WAV.

### 9.3 Integration (manual QA)

- Record a meeting; stop; observe `draft` quality.
- Click Refine; confirm transcript updates, quality flips to `refined`, a toast appears.
- Edit the transcript; quality flips to `edited`.
- Click Refine; confirm modal; accept; confirm quality flips back to `refined` and edits are gone.
- Kick off refinement, quit the app mid-way; relaunch; confirm the transcript is in its pre-refinement state (no partial writes).

---

## 10. Rollout

- v1 ships the toolbar button and the full state machine.
- `transcriptRefinementEnabled` defaults to the value of the capability check (§3): `true` if FluidAudio exposes a beam knob, `false` otherwise. On `false`, the button is hidden and Settings → Transcription shows a small "Transcript refinement is not yet available in this build."
- Once the capability lands upstream, we ship a patch release that flips the default.

---

## 11. Relationship to other specs

- **Summarization** — Refinement invalidates summaries per the summarization spec's §10 semantics. Keep the pref `refinementInvalidatesSummary` visible-to-us so we can flip behavior if this turns out to annoy users.
- **Semantic search** — Refinement nulls `chunks_indexed_at` so the semantic indexer repopulates the chunks automatically. No new logic required here.
- **Speaker re-ID** — Refinement does NOT invalidate speaker embeddings. Speaker segments may shift slightly across greedy → beam, but the embedding per-speaker is stable enough to survive minor segment boundary drift. If a future run of the diarizer produces radically different speaker counts, we re-extract embeddings (already handled by the re-ID spec's delete-on-rewrite).

---

## 12. Open questions

- **Quality measurement.** Can we ship a small internal test suite of voice clips with ground-truth transcripts so we actually know beam-4 is better than greedy on our target audio? The FluidAudio project might already have one; otherwise a handful of user-contributed recordings (opt-in) would work.
- **Beam search speed on ANE.** We're quoting "1.3–1.5× greedy" from general ASR folklore; Parakeet TDT on Core ML may be closer to 1.1× or to 2× depending on how FluidAudio exposes the decode loop. Confirm empirically after the capability check.
- **Should refinement preserve user-corrected vocabulary terms?** The existing vocabulary pass (`VocabularyReplacer`) runs post-transcribe. Refinement re-runs it. Good — the user's corrections persist.
