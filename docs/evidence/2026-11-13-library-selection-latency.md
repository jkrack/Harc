# Library selection loading follow-up

## Scope and source identity

Isolated branch based on `0b33255` (the preview/meter fixes), not the dirty production checkout. Installed MacBook version 0.14.20 source `a5a60ff` contains synchronous transcript-loading paths. Current source already has the asynchronous loader from `8896117`; this follow-up does not replace it or change editing/autosave behavior.

Remaining source-confirmed work: `speakerIndices(for:)` reopened and decoded JSON in SwiftUI rendering; waveform tasks were unstructured and could publish after selection changes. These are likely contributors, not a measured reproduction against the owner's recordings.

## Changes

- Speaker-count and inspector rendering use a background-loaded metadata snapshot keyed to the full Recording value. Same-selection processing updates invalidate metadata independently of dirty editor text. Async consumers can obtain metadata off-main before the cache is populated.
- Waveform work belongs to the recording's SwiftUI task. Detached decoding receives cancellation and checks between bins. Cancelled or superseded tasks cannot clear/publish another recording's waveform.
- Metadata cancellation is forwarded around sidecar projection. An in-progress synchronous read/projection cannot be interrupted internally, but cancelled results are not published.
- No app installation, restart, recording-content inspection, release or push performed.

## Verification

- `git diff --check` and `xcodegen generate`: passed.
- Standalone executable compiled the actual modified AmplitudeEnvelopeLoader source and checked fixture sample count/range, cache identity, cancellation of a cached read, and cancellation of an active detached decoder: passed. Observed cancellation response was 1.56 ms on this run; this is not click-to-ready latency.
- Focused SwiftPM suite: 9 tests passed, zero failures/skips. Covers active/cached cancellation, same-path JSON replacement from speaker 1 to speaker 7, and synthetic metadata lookup reuse after deleting the sidecar.
- Synthetic debug diagnostic (8,000 words, 1,000 speaker turns): a legacy single sidecar-backed speaker lookup took 604.03 ms; background metadata preparation took 347.45 ms; 1,000 cached array accesses took 0.099 ms. These are diagnostic timings, not real-recording click-to-ready performance or a production speedup ratio.
- Adjacent regression run passed all 41 tests across waveform/metadata, TranscriptDocument, WordIndex, TranscriptSpeakerLabelRewriter and ExportInputBuilder, with zero failures/skips. Repeat synthetic run measured 254.35 ms legacy lookup and 252.66 ms metadata preparation, illustrating run variability.
- HarcUI sources compiled. Initial build planning predated the new metadata file and a test-only missing import was corrected before the successful final run. Real app interaction, rapid selection UI tests and full Xcode build remain separate qualification gates.

## Active-search review follow-up

A release review found that search hits retained their original Recording rows while the full-list observation advanced. Because detail selection prefers search hits, metadata task identity did not change for an observed same-path transcript replacement during search.

Observation now reconciles existing hit Recording values while retaining query snippets, relevance scores and ordering. A pending search that completes after a newer list observation also reconciles its result rows before publication. The scoped recordings list retains its existing search-time behavior so unrelated observations cannot invalidate selection through filtered navigation. No editor text or autosave path is modified.

The regression keeps an active `pricing` search selected, replaces same-path JSON speaker 1 with speaker 7, and verifies new selected source identity, refreshed speaker indices, unchanged search rank/snippet and stale-result reconciliation. Focused LibraryRefreshPublication and AmplitudeEnvelopeLoader suites passed all 12 tests with zero failures/skips. Full app/UI release qualification remains separate.
