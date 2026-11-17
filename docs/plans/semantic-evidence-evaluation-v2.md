# Frozen unseen-project semantic evaluation v2

Status: independently reviewed db0d466 ran development then unchanged holdout
on 2026-11-17. Reports and label-masked packets are in
`docs/evidence/semantic-evaluation-v2-20261117/`; independent output adjudication
is pending. The holdout exposed false positives, so no activation is justified.
No v1 score or output is modified. This is evaluation, not training/fine-tuning.

## Freeze and generalization scope

- Corpus: `Tests/HarcSummarizeTests/Fixtures/evidence-evaluation-v2.json`.
- SHA256: `66b1ff0daa13ea5ddaa93f9f2cc74654391da41fc4788364bc542b7b5112be2c`.
- Eight development cases covering four projects; 20 holdout cases covering ten
  completely different project names/briefs/domains. Names also exclude all v1
  projects. Each project has a positive and a negative or ambiguous case.
- Holdout: ten positives, seven negatives, three ambiguous. Development: four
  positives, three negatives, one ambiguous. Ambiguity requires abstention.
- Corpus/labels/briefs and evidence rubric are assistant-authored synthetic data.
  Unseen means unseen in these evaluation development/v1 sets, not proof a model
  never encountered similar concepts in pretraining. Cases are short, stylized
  and English; this does not establish population or real-recording accuracy.
- Prompt is the unchanged `selected-source-evidence-v1`, SHA256
  `b209aba461496f1ad137872b5d14c2b96c9b2c06a052cfdf2e62ae083e472d54`.
  No labels, split, anchor rubric or example quote is supplied to the model.
- Never tune prompt, label, rubric or model settings against v2 holdout. If a
  defect changes scoring, preserve raw results and version the protocol rather
  than silently rescoring. Development is not used for tuning in this run.

## Three distinct questions

1. **Relation classification:** among strictly valid suggestions, does the
   frozen label say this recording relates to the project? TP/FP/FN and
   precision/recall are separate from quote sufficiency. Invalid responses do
   not earn positive credit; positive invalid/abstain cases count FN. This is
   end-to-end valid-output relation performance, not an estimate of a hidden
   decision inside an invalid response. Ambiguous is nonpositive for scoring.
2. **Source integrity:** every raw response goes through the unchanged production
   duplicate-key/size/unique-exact-UTF8-span validator. Report valid suggestions,
   strict-decision coverage, malformed/ambiguous quotes and runtime failures.
   A permissive parse only flags visibly unsupported quotes diagnostically;
   duplicate keys or other malformed outputs can never receive credit that way.
3. **Evidence sufficiency:** frozen alternatives require all semantic anchors
   in one exact source-valid quote. Anchors include action/object and identifying
   project context, not a generic sentence fragment. Punctuation at quote
   boundaries is naturally optional; source text itself is never normalized.
   Report qualified TP/precision/recall and insufficient-anchor positives
   separately. This deterministic anchor proxy is not final semantic judgment.

For every denominator-zero metric, report null/N/A. The literal baseline invokes
actual `prepareProjectMentionProposals` on the same isolated fixture; it has no
semantic evidence qualifier. Do not present its relation precision as directly
identical to the stricter evidence-qualified precision.

## Independent adjudication (separate, no automated score overwrite)

Retain all synthetic raw outputs, including invalid outputs, in reports. A
separate `.adjudication.json` packet contains ID, brief, transcript and raw output,
without expected label, anchors or automatic scores. The adjudicator records:

- relation supported / unsupported / ambiguous;
- source quote exact / invented / repeated / not applicable;
- evidence sufficient / insufficient / not applicable;
- short rationale, noting whether necessary identifying context is only outside
  the quote or actually inside it.

Judge actual action/object and project attribution, not punctuation or whether
wording matches a preferred quote. When several projects could share the action,
require identifying context in the quote; otherwise mark insufficient. A generic
fragment such as 'we approved it' is insufficient even inside a relevant source.
Record disagreement with frozen labels/anchor proxy as disagreement, never
retroactively change the original results. Review is independent but merely
label-masked if the reviewer previously saw this corpus; do not call that a
fully blinded human study. Request a fresh reviewer where available.

## Runtime and gates

`UnseenProjectEvidenceEvaluationTests` has non-model freeze/separation, strict
source-fixture, generic-fragment, punctuation and metric-denominator checks.
Opt-in requires `HARC_EVIDENCE_EVAL_V2=1`, `HARC_EVIDENCE_EVAL_SPLIT`, installed
source/scratch paths and `HARC_EVIDENCE_EVAL_REPORT`. Both runs enforce corpus
hash before service/model creation. Only the installed catalog-pinned E2B model
via the scoped qualified load is permitted; no downloads, user recordings,
production Library, background scans or UI activation. Preflight Host activity,
resource headroom and worker coordination. Save partial results on runtime error,
stop rather than silently retry. Each case verifies empty scratch, no resident
model and no review assignments. Copy/load/inference/cleanup latency, real token
counts/stop, catalog/config/manifest hashes and cumulative process MLX peak are
reported. Inference-only latency and operation-specific/total-RSS memory are not
instrumented, and must not be inferred.

Small synthetic success alone does not qualify broad application activation.
Real-model cancellation, long sources, thermal/endurance and explicit Host-bound
candidate commit/review integration remain separate gates.
