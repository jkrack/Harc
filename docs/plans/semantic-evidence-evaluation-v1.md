# Frozen semantic evidence evaluation v1

Status: frozen development and holdout evaluations completed on 2026-11-17 after
independent review, using ac11ce8 unchanged. Immutable results and a separately
labeled fresh diagnostic reproduction are in `docs/evidence/semantic-evaluation-20261117/`.
Original scores are not rerated by that diagnostic. No owner data, production
Library, training or fine-tuning was involved; no semantic UI is activated.

## Freeze

- Corpus: `Tests/HarcSummarizeTests/Fixtures/evidence-evaluation-v1.json`
- SHA256: `bf60329f9eaf6e1c493ce5be33e7aeee4ad620ae16bef93aef8a48bf80d757f4`
- 12 development + 20 disjoint holdout transcripts. IDs and source text unique.
- Development labels: 6 positive, 4 negative, 2 ambiguous.
- Holdout labels: 10 positive, 7 negative, 3 ambiguous.
- Authored synthetic project brief per case, explicit label rationale and
  explicit acceptable verbatim quote strings. Ambiguous means expected abstention.
- Cases cover literal and nonliteral relevance, homonyms/substrings, unrelated
  topics, explicit other-project statements, negated actual decisions, hypothetical
  work, source instruction injection, repeated text and Unicode.
- Prompt `selected-source-evidence-v1` frozen in harness. Labels, rationale,
  split and acceptable quotes NEVER enter the model prompt.

Do not tune prompt, thresholds, labels or acceptable quotes against holdout results.
Any future revision must be a new corpus/prompt version and new untouched holdout.
The small authored sample does not establish population accuracy.

## Execution

`SemanticEvidenceEvaluationTests.testFrozenCorpusAndStrictValidatorWithoutModel`
checks all fixtures against the real Host-bound Store snapshot and strict parser;
it does not run inference. A separate scorer test rejects rewarding wrong-quote
positives and reports zero-denominator precision as null/N/A.

Opt-in model harness requires `HARC_EVIDENCE_EVAL=1`, a split (`development` or
`holdout`), explicit installed source/scratch paths and report path. Use only the
already-installed fixed catalog E2B model and scoped verified-copy entry. No
network/download fallback. Stop at the first runtime error, save partial report,
and mark the test incomplete rather than retrying or filling results.

Every generated response passes the production duplicate-key/size/unique exact
UTF8 span validator. A valid suggestion counts TP only on a positive label AND
when its quote exactly matches an acceptable quote byte-for-byte. Label-positive wrong-quote suggestions are
separate errors AND count FP/FN rather than receiving credit. Invalid/ambiguous
quotes, unsupported quotes, runtime failures and abstentions are separate counts.
The literal baseline is the actual bounded project-name Store producer on the
same source, not an approximate substring implementation. Nothing is committed
to review queues or assignments.

## Report

Per split: TP/FP/FN, precision, recall, valid-suggestion coverage, abstention,
label-positive wrong-quote suggestions, invalid/ambiguous/unsupported quotes, runtime errors,
literal baseline metrics and nonliteral recall. Null denominators mean N/A.
Per-case output includes ID/label/category and metrics, never model response or
transcript text. Record corpus/prompt hashes, catalog revision/config hash/full
manifest fingerprint, actual prepared/generated token counts and completion
reason. Latency explicitly includes snapshot copy/load/inference/cleanup;
inference-only latency is null (not instrumented). MLX peak is cumulative process
peak, not operation-isolated or total RSS. Recheck resource state before runs.

No app/UI activation or broad accuracy claim follows from passing this sample.

Review correction before any model run: broad region containment was replaced
with frozen exact acceptable quotes. A source-valid generic fragment receives no
semantic credit. This conservative rubric can reject reasonable alternate quotes;
report that limitation, do not expand acceptable quotes after seeing holdout. The
opt-in run itself checks the corpus hash. Briefs/labels are assistant-authored
synthetic fixtures, not James-authored or user recordings. Holdout shares project
themes with development and does not test unseen-project generalization.
