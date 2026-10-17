# Refusal publication guard, 2026-09-06

Implemented: new summary results containing an explicit opening refusal such as
“I will not book a venue” are rejected as generation failures before publication.
This applies to the short path and final long-summary reconciliation. The shared
parser remains unchanged, so existing stored/manual action text is not rewritten.
The guard preserves accepted removal/cancellation work and negation later in a
task. It is deliberately narrow and does not prove that other tasks are supported.

Validation: 37 XCTest and 21 Swift Testing tests passed without failures/skips in
the focused exact-source summary package. Tests include both service paths and
legitimate tasks that must remain allowed. The diagnostic macOS Xcode app build
succeeded with two workers. It uses the existing helper snapshot and is not a
release qualification or a complete UI workflow test.

The built app's actual service and installed Qwen model reproduced the erroneous
Ari refusal action. The service now throws the specific generation failure instead
of returning that action. This remains a failed summary generation, not an accuracy
pass. On the same service, the next three cases successfully retained a conditional
purchase, cancellation-notice email and obsolete-account removal. Conditions and
deadlines remained in those tasks. Prose still invents or broadens facts, including
cancellation of a reservation that was only promised; those outputs do not qualify
factual accuracy.

Evidence: `build/qualification/production-hardening-2026-09-05/summary-refusal-guard/`
contains exact source/app hashes, raw model passes, service results, build/test logs,
runner source and an explicitly scoped guard verdict. The separate structured
source-grounding experiments are rejected; see
[grounding evidence](2026-09-06-summary-grounding.md).

The overall accuracy and production-readiness goal remains open. The guard prevents
one known class of misinformation from being published; generating a correct,
complete replacement summary and validating real recordings remain required.
