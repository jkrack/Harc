# Short-summary accuracy correction, 2026-09-06

Status: implemented candidate; accuracy goal remains open. This is a dirty-tree
local diagnostic, not release or end-to-end user-workflow qualification.

Short summaries now extract confirmed commitments and factual prose independently
from the same transcript. The service combines the parsed actions from the first
pass with the second pass's prose. Invalid factual output fails the job. Summary
generation uses temperature zero through a dedicated container method, while Q&A
and transforms retain their prior profile. The parser accepts the confirmed
commitments heading and bracketed owners without silently accepting malformed rows.

The real-model test wrapper forwards the dedicated method, retains all raw passes,
and scores the assembled service result. The wrapper was separately type-checked;
the full quality target was syntax-checked, not executed in this validation.

## Measured local development cases

The frozen set contains 15 previously used development cases and four additional
cases. Prompt changes were made after seeing results; these are not held-out tests.

| Model/candidate | Owner, count and format | Selected lexical content |
| --- | --- | --- |
| Gemma original one-pass service | 5/19 | 5/19 |
| Gemma final two-pass service | 19/19 | 19/19 |
| Qwen final two-pass service | 18/19 | 16/19 |

Qwen's cancelled venue booking remains an erroneous action item. Its two additional
lexical flags use synonymous wording (unresolved/open and no one/nobody); those
flags are not proof of factual errors. Manual reading found errors that lexical
checks missed in both models: a speaker's refusal to deploy becomes a claim that
the service will not be deployed, and an unsupported causal link joins refusal
with unassigned ownership. Gemma also loosely attributes a cancellation statement;
Qwen invents receipt acknowledgement in completed work. Therefore even Gemma's
19/19 is not a factual-accuracy pass.

Median generation time in this small run: original Gemma 1.27 seconds, two-pass
Gemma 2.85 seconds, two-pass Qwen 4.42 seconds. These diagnostic times exclude initial
model load and are not a repeated performance benchmark.

## Validation and provenance

37 XCTest tests and 18 Swift Testing tests passed with no failures or skips in
the isolated exact-source summary package. The package excludes the real MLX
adapter; the macOS diagnostic Xcode app build and real model probes cover that
boundary separately. The app build succeeded with two workers. Its existing helper
snapshot is not an exact current release helper qualification.

The long-summary probe was rerun through the new deterministic method: three
section passes plus one reconciliation, zero omitted utterances, no cancelled
booking action, and explicit meeting cancellation, unchanged budget and required
accessibility retained. Generation took 6.98 seconds excluding model load. This
previously tuned fixture is narrow evidence, not general long-input accuracy.

Raw passes, assembled results, frozen rubric, manual findings, runner source,
source/app hashes, tests and build log are retained under
`build/qualification/production-hardening-2026-09-05/summary-short-accuracy/`.
The long probe is retained under sibling `summary-full-coverage/` with the
`deterministic-service-` prefix. Initial baseline raw output and later assembled
Markdown differ in representation; later runs also retain every original response.
The disk supervisor did not trigger; minimum free space stayed above 12.7 GiB.

Next work: preserve statement scope and attribution in factual summaries, reject
withdrawn/noncommitment actions reliably across installed models, then freeze a
new evaluation set before changing prompts again. Real recording, diarization,
long-form capture, full user workflow and release qualification remain open.
