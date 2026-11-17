# Frozen local semantic evidence evaluation, 2026-11-17

Implementation tested: PR221 `ac11ce8`. Independent methodology review cleared the run. Development ran first, then untouched holdout with the identical prompt, model, labels and quote rubric. No prompt/label/quote tuning occurred between runs. All sources and briefs are authored synthetic fixtures, not owner recordings. No app activation.

Corpus SHA256: `bf60329f9eaf6e1c493ce5be33e7aeee4ad620ae16bef93aef8a48bf80d757f4`
Prompt: `selected-source-evidence-v1`, SHA256 `b209aba461496f1ad137872b5d14c2b96c9b2c06a052cfdf2e62ae083e472d54`
Model: `gemma-4-e2b-it-4bit`, revision `99d9a53ff828d365a8ecae538e45f80a08d612cd`
Manifest SHA256: `00bb57f120877ad82ff41dc0711f6479ffa657bf593c2751a4957c092cef6b03`

## Results

| Split | Cases | Quote-aware TP / FP / FN | Precision / recall | Literal precision / recall | Nonliteral recall: model / literal |
|---|---:|---|---|---|---|
| development | 12 | 4 / 2 / 2 | 66.7% / 66.7% | 66.7% / 66.7% | 50.0% / 0.0% |
| holdout | 20 | 7 / 3 / 3 | 70.0% / 70.0% | 50.0% / 60.0% | 75.0% / 0.0% |

These are conservative **quote-aware** scores, not pure semantic-classification precision. Every model suggestion was source-valid and on a positive-labeled case, but 2 development and 3 holdout quotes did not byte-match the frozen acceptable quote. Those count as FP and FN by the predetermined rubric. We did not inspect/relabel them as equivalent after seeing holdout. Thus they are not evidence of 3 wrong-project suggestions. Conversely, mere source validity is not proof those alternate quotes adequately support the relationship.

The model abstained on every negative/ambiguous case (6 development, 10 holdout). Literal matching suggested 2 development and 6 holdout nonpositive cases. Valid-suggestion coverage was 50% on each split. Across all 32 model responses: zero invalid responses, ambiguous quotes, unsupported quotes or runtime errors; exactly one authoritative normal-stop completion per case. No pending review cards were written.

## Timing and resource evidence

- development: median 14.48s, max 19.00s, total 180.42s across cases. Prepared input tokens 194–215; generated tokens 6–24. Observed cumulative process peak MLX allocation 3,000,910,800 bytes.
- holdout: median 14.31s, max 16.55s, total 287.89s across cases. Prepared input tokens 196–223; generated tokens 6–25. Observed cumulative process peak MLX allocation 3,022,929,484 bytes.

Timing includes full verified bundle copy, load, token preparation, inference, producer join, unload and cleanup for each case; inference-only latency is not instrumented. Repeated copies are experimental qualification overhead, not an optimized app UX. MLX peak is process-cumulative, not isolated operation peak or total RSS. Mac mini had 16GiB RAM and ~1.4TiB SSD headroom; observed memory-free percentage stayed at least31% during checks and returned to70%. Snapshot scratch ended at0 bytes after both runs, and every case asserted no resident model remained. No downloads or existing app termination; preflight and subsequent checks found no writable Host audio handles.

## Complete outcomes

`quoteOK` means exact frozen acceptable quote, not a model confidence score. `abstain` has quoteOK false by definition.

| ID | Label | Category | Literal suggests | Model outcome | quoteOK |
|---|---|---|---|---|---|
| d01 | positive | literal | True | suggest | True |
| d02 | positive | nonliteral | False | suggest | False |
| d03 | positive | literal | True | suggest | True |
| d04 | positive | nonliteral | False | suggest | True |
| d05 | positive | negated-decision | True | suggest | True |
| d06 | positive | unicode | True | suggest | False |
| d07 | negative | homonym | True | abstain | False |
| d08 | negative | unrelated | False | abstain | False |
| d09 | negative | explicit-other-project | True | abstain | False |
| d10 | negative | injection | False | abstain | False |
| d11 | ambiguous | underspecified | False | abstain | False |
| d12 | ambiguous | hypothetical | False | abstain | False |
| h01 | positive | literal | True | suggest | True |
| h02 | positive | nonliteral | False | suggest | True |
| h03 | positive | nonliteral | False | suggest | True |
| h04 | positive | literal | True | suggest | True |
| h05 | positive | nonliteral | False | suggest | False |
| h06 | positive | literal | True | suggest | True |
| h07 | positive | nonliteral | False | suggest | True |
| h08 | positive | negated-decision | True | suggest | True |
| h09 | positive | unicode | True | suggest | False |
| h10 | positive | source-repetition | True | suggest | False |
| h11 | negative | homonym | True | abstain | False |
| h12 | negative | homonym | True | abstain | False |
| h13 | negative | unrelated | False | abstain | False |
| h14 | negative | explicit-other-project | True | abstain | False |
| h15 | negative | injection | True | abstain | False |
| h16 | negative | quoted-irrelevant-name | True | abstain | False |
| h17 | negative | substring | False | abstain | False |
| h18 | ambiguous | underspecified | False | abstain | False |
| h19 | ambiguous | hypothetical | False | abstain | False |
| h20 | ambiguous | competing-context | True | abstain | False |

## Limits and next gate

This small hand-authored, same-project holdout is illustrative, not unseen-project or real-transcript generalization. Exact quote scoring intentionally penalizes alternate wording/spans and may undercount useful evidence; it was not relaxed post hoc. No statistical confidence or production precision claim is warranted. Additional disjoint cases should cover unseen projects, noisy/long transcripts and confusable decisions. Real model cancellation and long-running resource behavior remain unqualified.

The results support continuing local evidence-backed suggestion work, but not auto-assignment or automatic UI rollout. Keep explicit selected-source consent, source/version/Host revalidation, abstention and human review. Optimize snapshot/model lifecycle only after preserving these guarantees. Raw reports preserve all numeric outcomes and fingerprints; prompts/responses are not logged.
