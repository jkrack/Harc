# Full transcript summary processing

Implemented in `LongSummary.swift` and `SummarizerService.swift`. Over-budget
transcripts now take a sequential extraction/reconciliation path instead of
silently discarding earlier utterances or returning a suffix-only summary.
Short transcripts retain the existing single-call path.

Each section fits the available word budget (capped at 2,000 for extraction).
Oversized utterances split into ordered word sequences with their speaker label.
Every non-whitespace input word is submitted. Distinct facts are extracted as
bullets, including conditions, restrictions and cancellations. Chronological
notes are grouped within budget and reconciled until one result remains; later
cancellations and ownership changes are explicitly considered. Non-shrinking
reduction or an oversized intermediate note fails instead of dropping content.
This guarantees input submission, not semantic completeness of generated notes.

Malformed or failed intermediate/final generations fail the entire job. Cancellation
or unload during a section cannot publish partial notes. Very small input budgets
fail with an actionable error rather than producing only the transcript's tail.
The existing partial-coverage metadata remains available, but this service path
no longer uses truncation as a successful fallback.

Validation:

- 35 XCTest tests and 13 Swift Testing tests passed, no failures/skips, in the
  exact-source focused package. Coverage includes complete word ordering and
  bounds, early/middle/late submission, chronological cancellation context,
  section and final-reconciliation failures, cancellation/unload during the
  second section, and a reduction that cannot make progress.
- The actual macOS diagnostic Xcode app build succeeded with two workers. It uses
  the existing isolated helper snapshot; this is not a release qualification.
- The production `SummarizerService`, loaded from that app, ran installed local
  Gemma at default sampling on a synthetic transcript with a forced 512-word
  budget. Three extraction calls plus one reconciliation call processed all input.
  The final result retained the cancelled meeting, withdrawn booking, unchanged
  travel budget and required accessibility, with no booking action. Generation
  and reconciliation took about 6.75 seconds excluding model load.

The first model run dropped budget/accessibility from intermediate prose. After
switching extraction to distinct facts, final prose still dropped explicit meeting
cancellation. Using distinct-fact bullets for reconciliation retained the required
facts. All three raw runs are retained; the successful fixture is therefore tuned
and cannot serve as an untouched general-accuracy benchmark.

Evidence and hashes:
`build/qualification/production-hardening-2026-09-05/summary-full-coverage/`.
The focused package excludes MLX implementation; the app build and model probe
provide separate integration evidence. Word comparisons normalize whitespace.
The model probe's unused-buffer cache cap is diagnostic, not a production setting.

Remaining: broader untouched cases, production-sized long inputs, repeated model
runs, Qwen validation, token-limit exhaustion detection, resumable progress, and
complete user workflow validation. Free model paraphrasing can still lose facts
or invent commitments; no general accuracy or production-readiness claim is made.
