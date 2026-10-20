# Summary generation termination

The production MLX adapter previously discarded `GenerateCompletionInfo.stopReason`.
A capped or interrupted response could therefore be parsed and returned as if
its generation had finished. Valid Markdown is not completion evidence.

`GenerationStats` now carries optional final stop metadata. The adapter maps the
runtime's stop/length/cancelled states and refuses a stream with no completion
event. A shared summary-pass helper validates metadata for short summaries,
section extraction and final reconciliation. Explicit output limits fail the
summary job. Unexpected runtime cancellation is a visible generation failure;
actual caller cancellation or unload still propagates as cancellation, checked
before and after generation and on errors. This avoids suppressing a runtime
failure as though the user had cancelled the job.

Only final metadata decides completion. Approximate interim counts are ignored;
a normal completion at the numeric token ceiling is accepted. A later contradictory
success cannot erase a recorded final failure. Existing custom/test containers
without stop metadata retain compatibility; the production adapter requires a
final event and always supplies a reason.

Validation:

- 35 XCTest and 16 Swift Testing tests passed with no failures/skips in the
  focused exact-source package. Cases cover short, intermediate and final-pass
  exhaustion, unexpected cancellation, contradictory final metadata, misleading
  interim counts, normal completion at the ceiling, plus prior cancellation and
  full-coverage tests. This package excludes the MLX implementation.
- The actual diagnostic macOS Xcode app build succeeded. The first build caught
  an adapter syntax error absent from the isolated package; it was corrected
  before successful integration validation. Existing isolated helpers were used.
- The installed local Gemma runtime was forced to one and then eight output
  tokens. It reported **cancelled**, not **length**, for these caps. The initial
  service implementation surfaced CancellationError, which would suppress the
  unexpected failure. The corrected service raises a visible generation failure.
  A normal successor call on the same service returned, proving operation release.
  Its malformed action format required review; it is not an accuracy success.

Source/binary hashes, tests, builds, raw runtime metadata, earlier results and
probe sources are retained under
`build/qualification/production-hardening-2026-09-05/summary-termination/`.
The probe's eight-token clamp and 128 MiB cache cap are diagnostic only. No release,
UI exercise, physical-device validation or general model-accuracy claim is made.

Remaining: automatic bounded recovery from output exhaustion, broader factual
accuracy (especially the ordinary short-summary path), long-input qualification,
and full workflow validation. This change makes incomplete generation fail
visibly; it does not make an incorrect completed response factually correct.
