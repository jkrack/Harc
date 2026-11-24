# V2 frozen unseen-project evaluation results

Executed db0d466 unchanged after independent review, development first then
holdout, once each. No prompt/label/anchor tuning or reruns. Original v1 results
remain untouched. Corpus/prompt/catalog hashes and all synthetic raw responses
are retained in the JSON reports. Label-masked packets omit expected labels,
anchors and automatic scores for a fresh independent reviewer.

| Frozen metric | Development (8) | Holdout (20) |
| --- | ---: | ---: |
| Positive labels | 4 | 10 |
| Relation TP / FP / FN | 4 / 0 / 0 | 9 / 3 / 1 |
| Relation precision / recall | 100% / 100% | 75% / 90% |
| Source-valid suggestions | 4 | 12 |
| Abstentions | 4 | 8 |
| Evidence-anchor-qualified TP | 4 | 5 |
| Evidence-qualified precision / recall | 100% / 100% | 41.7% / 50% |
| Positive suggestions missing required anchors | 0 | 4 |
| Literal TP / FP / FN | 1 / 3 / 3 | 3 / 7 / 7 |
| Literal relation precision / recall | 25% / 25% | 30% / 30% |

All 28 responses passed the strict production parser/source contract, with one
normal stop completion each. No invented/ambiguous-source quote or runtime error
was observed. This **does not** mean the claims were correct: holdout false
positive cases h06, h10 and h12 are respectively hypothetical podcast work,
source instruction injection, and explicitly different-project work. Positive
h17 was missed. Independent adjudication is pending; frozen scores will not be
rewritten if a reviewer disagrees with the anchor proxy.

These results block automatic assignment or semantic UI activation. Exact source
quotes are insufficient to establish relevance. The drop from development to
holdout also demonstrates why the eight development successes alone would have
been misleading. This small authored, short English set is not population
accuracy or unseen-concept generalization.

## Runtime

- Development XCTest passed in 113.838 s; holdout passed in 291.278 s. Passing
  runtime tests means completion/cleanup, not that semantic quality passed.
- Per-case copy/load/inference/cleanup median: 14.096 s development,
  14.375 s holdout; maxima 14.605 s and 15.575 s. Inference-only timing unavailable.
- Observed cumulative process peak MLX allocation: 3,006,880,804 bytes development,
  3,025,962,840 bytes holdout. Not total RSS or per-operation isolated peaks.
- Mini headroom: 72% memory free initially, 65% between runs, lowest observed
  sample 31%, 71% after; SSD 1.4 TiB free. No thermal warning in monitored samples.
- Initial installed Harc had zero writable audio handles/no STT daemon and low
  resident memory. No user apps stopped, no private recordings or Library read
  by tests, no model download. Synthetic fixtures remained outside real data.
- Every case asserted resident nil, empty snapshot scratch and no review cards.
  Scratch 0 B after both runs. Three non-model checks passed before review;
  required hosted CI remains separate, not asserted green here.

## Next decision

First independently adjudicate retained outputs against the source and brief,
without seeing expected labels or scores. Preserve disagreements as a separate
artifact. Any prompt/rubric change needs a new predeclared protocol and untouched
holdout. Prioritize the actual false-positive failure modes over polishing the
anchor metric. Long-source, real-model cancellation/endurance, and explicit
Host-bound semantic candidate commit/review remain unqualified. No app activation.
