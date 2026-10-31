# Summary completeness and cancellation boundaries

This change fixes three application-level failures. It does not qualify the
models' factual accuracy or promote the experimental two-pass prompt.

- When the input budget removes earlier utterances, `SummaryPrompt` now reports
  the exact number removed. `SummarizerService` carries that count separately
  from parser validity. `markdownForStorage` persists a partial-summary notice
  alongside the text, including the possibility of missing earlier commitments.
  Both resident-app summary save paths already use this storage representation.
  The original transcript is unchanged; this does not restore omitted context.
- An empty summary with otherwise valid action headings no longer counts as a
  complete response. The parser retains the raw response and requires review.
- Summary generation checks cancellation and its load-generation identity after
  the model returns. A cancellation or unload cannot publish a late successful
  result, even if the underlying generator ignored cancellation. The next queued
  operation can proceed normally.

Focused validation uses exact repository source/test files in a small isolated
Swift package, substituting only the production `ContainerLike` protocol and
convenience methods for the MLX implementation. It ran 35 XCTest tests and seven
Swift Testing tests with no failures or skips. Parameterized tests exercise both
cancellation and unload while a deliberately noncooperative generator is paused.
Tests also verify suffix-only coverage, complete input, the retained single
oversized utterance, combined review notices, and raw empty-summary preservation.
This is focused boundary evidence, not the full Harc package suite or real-model
accuracy qualification. Source hashes and harness scope are recorded under
`build/qualification/production-hardening-2026-09-05/summary-boundaries/`.

The macOS diagnostic Xcode app build succeeded with two workers. It compiled
the changed package and real app consumers; helper phases use the existing
isolated helper snapshot. The log and artifact hash are retained.
No new on-screen UI exercise, release, installation, or device qualification is
claimed. Earlier inference probes must be recompiled before reuse after this
build: they linked against the previous diagnostic app dylib and module layout.

Remaining accuracy work: restore full long-transcript coverage rather than merely
labeling its absence, preserve deadlines and conditions semantically, prevent
unsupported model-generated commitments, and validate complete user workflows.
The earlier narrow synthetic scores do not close those requirements.
