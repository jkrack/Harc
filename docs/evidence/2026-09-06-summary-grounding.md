# Source-grounding evaluation, 2026-09-06

Decision: do not integrate the evaluated structured-output candidate. Exact
quotation checks are useful evidence validation, but are not an entailment test.

A local probe used the production model adapter, temperature zero, reasoning off
and a 2,048-token cap. The frozen 27-case set was identical to the attribution
candidate set. Each fact/action had to carry an exact source quotation and utterance
number; owners had to appear in their cited source. The strict checker rejects
unknown/missing fields, duplicate keys, nonexistent/altered quotations, ambiguous
reasoning boundaries, incomplete generation and empty/mismatched inventories.

| Model | Valid format and source evidence | Evidence plus owner/count |
| --- | --- | --- |
| Gemma | 3/27 | 3/27 |
| Qwen | 21/27 | 20/27 |

Manual review found false claims even with valid quotes: Qwen invents a causal
relationship in a refusal, reattaches reported-speech time and omits an accepted
cancellation-notice task. Gemma can cite a refusal as evidence for its opposite;
one otherwise valid conditional task loses its condition. Source citation is not
proof that the paraphrase is supported or that all substantive facts are retained.
The checker explicitly tests this limitation instead of labeling it accuracy.

A six-case Qwen reasoning-on comparison used a 4,096-token cap and greedy decoding.
The first case reported runtime `cancelled` after 123.85 seconds without a final
answer boundary. Its final token count was not retained, so exact exhaustion of
the cap is not proved. The remaining cases were deliberately stopped; the child
and supervisor are terminal. This is a failed partial diagnostic, not six results.

The [official Qwen model guidance](https://huggingface.co/Qwen/Qwen3.5-4B#best-practices)
was checked on 2026-09-06. Its general non-thinking profile uses temperature 0.7,
top-p 0.8 and top-k 20, plus a presence penalty. A separate six-case sampling-only
probe tested the first three settings, keeping reasoning and penalties off. This
isolates sampling from MLX's prompt-inclusive penalty window and is not the full
author profile. It obtained 5/6 valid evidence and 4/6 matching ownership counts,
but still invented who cancelled an event and missed a real task. A single unfixed
random seed run does not establish a stable improvement. Neither configuration
is promoted to production.

Added reusable diagnostic sources under `scripts/quality/`: the Swift probe,
JSON prompt and exact-source checker. Seven Python tests passed. The retained
probe now records final token counts for future runs; earlier immutable probe
sources and results retain their original schema. No production inference
settings were changed by these experiments. All generation stayed local.

Evidence: `build/qualification/production-hardening-2026-09-05/summary-grounding/`,
including raw responses, checker reports, manual findings, runner/probe sources,
source/binary hashes, sampling settings and deliberate-stop decision. Installed
model hashes are retained in sibling `summary-short-accuracy/model-sha256.json`.

The production refusal guard is documented separately. It prevents a specific
known false action from being published; it does not qualify summary accuracy.
