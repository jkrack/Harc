# Attribution and refusal candidate, 2026-09-06

Decision: reject this prompt candidate. It improved several Gemma outputs but
regressed Qwen's factual account of the cancelled booking. The prior production
prompt is retained; the expanded regression coverage and diagnostic evidence remain.

The candidate added refusal/withdrawal examples and asked for independent sentences
with explicit speaker attribution, original statement scope, and no inferred causal
links. The evaluation froze the previous 19 cases plus eight fresh cases before
running either local model. The fresh cases cover individual refusals, unrelated
statements, missing receipt confirmation, withdrawn/replacement tasks, reported
speech, legitimate removal work, explicit causal conditions and completed work.
Those eight cases are now also in the repository's opt-in attribution test with
selected action-content assertions. These checks do not prove semantic correctness.

Gemma passed 27/27 owner/count/format checks and all selected lexical checks on the
prior 19 cases. Manual review confirmed that the individual deployment refusal and
invented refusal/ownership causal link improved. It also found omission of Rita's
request, ambiguous timing of reported grant approval, redundant attribution of a
reported promise and unsupported gendered pronouns. No general accuracy pass.

Qwen passed 26/27 owner/count/format checks and 17/19 selected lexical checks
on the prior set. Qwen continued listing Ari's refusal as a booking action. Its new prose additionally
said Ari booked the venue yesterday, which is not in the transcript. This regression
is enough to reject the candidate regardless of aggregate checkbox counts.

37 XCTest and 18 Swift Testing tests passed in the focused exact-source summary
package; the diagnostic macOS app build succeeded. The expanded contrast method,
wrapper and directory helper were type-checked against production modules; the
whole quality test file was syntax-checked. The full quality target and user workflow
were not executed. The real app-backed probes retain raw responses and assembled
results under `build/qualification/production-hardening-2026-09-05/summary-attribution-scope/`.
Candidate source and binary hashes identify the evaluated version, not the restored
production prompt. Model hashes remain in sibling `summary-short-accuracy/`.

Next correction needs stronger grounding of claims in source statements. More
instruction examples alone have not reliably prevented paraphrases from changing
scope, attribution or completed-versus-proposed work. Preserve the full production
accuracy objective, including real recordings and complete workflow qualification.
