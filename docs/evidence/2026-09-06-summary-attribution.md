# Summary attribution investigation — 2026-09-06

**Not qualified. Production SummaryPrompt is unchanged.** A disposable local
probe reused the current diagnostic app's summary/model implementation and
matched Metal library. No recordings were used, no preferences changed, and
inference ran against the installed default Gemma model with offline mode.
Initial runs used unchanged generation settings; later diagnostic runs used
temperature 0 and a 128 MiB unused MLX buffer-cache limit. Candidate templates were external inputs
only; none was installed into the application.

| Template | Cases completed | Actor/count plus format passes | Disposition |
| --- | --- | --- | --- |
| Unchanged production | 15 | 3 | Complete diagnostic; fails quality |
| Longer evidence rules | 7 | 3 | Rejected |
| Shorter, single format example | 7, then 15 | 7, then 13 | Completed work and unanswered request still become tasks |
| Shorter plus explicit exclusions | 15 | 13 | Same two failures |
| Shorter plus generic worked examples | 11 of 15 | 11 | Disk guard interrupted; four cases remain untested |

These are synthetic single-run results unless the row explicitly lists both
runs. The additional eight cases were new when the first shorter candidate was
measured; later candidates were tuned after seeing those results. They are no
longer independent holdouts. The continuation below includes a second-model comparison; no general accuracy
claim is supported. Passing actor/count checks cannot establish correct task
wording, preserved conditions, or factual summary prose.

The first shorter template's renewal output preserved Jason's commitment,
Priya's legal-review constraint and Amy's unaccepted request without assigning
work to Priya or Amy. The expanded output still listed a completed contract as
an unchecked task and an unanswered request as unassigned work. Those are model
errors, not only parser disagreements.

The repository's opt-in attribution test now has 14 contrast cases (the renewal
sample remains its own existing test). Added short acceptance, completed work,
mixed positive/negative future work, two owners, a conditional commitment,
revocation, a fictional quote and an unanswered request. Selected positive cases
also require task/deadline/condition terms in the parsed action. This is a lexical
check and does not prove semantic entailment. The exact changed method and its
helper dependencies passed a standalone type check against the current modules;
the full package test target and live expanded XCTest remain unrun.

Evidence is retained under
`build/qualification/production-hardening-2026-09-05/summary-commitment-probe/`:
raw outputs, templates, case inputs, probe sources, execution records and hashes.
The probe process returning zero means generation completed, not quality passed.
Earlier runs were interrupted by the disk guard and are not complete results.
Temporary Metal files were removed after each run.

## Continued local experiments

The shorter worked-example prompt subsequently completed 14/15 cases with Gemma,
missing the conditional commitment. A temperature-0 repeat also scored 14/15;
Qwen scored 13/15. Adding conditional-promise wording fixed that case but brought
back false tasks from unanswered requests, so those variants were not adopted.

A candidate using `## Confirmed Commitments` instead of `## Action Items`, with
explicit coverage instructions, passed all 15 development cases and six fresh
cases on Gemma at temperature 0. This is **actor/count plus diagnostic format
acceptance**, not a production parser pass. The probe normalizes that heading and
`- [Owner]: task` into the existing checkbox format before invoking the production
parser. The unmodified production parser does not accept these new forms.

The six fresh cases were created before measuring the commitment-heading variant.
They cover conditional promises/speculation, a refused request plus an accepted
different task, completed work plus remaining work, cancellation/replacement, and
quoted training instructions. They are small synthetic examples, not real meetings.
The coverage-wording variant was measured after the earlier heading variant's
fresh-case results were available, so this is not a wholly unseen final evaluation.

Manual review of the latest Gemma output confirms the conditional promises retain
their conditions and the two-owner dependency is preserved. However, the renewal
summary omits the customer's **healthy** status. It retains the open pricing risk,
Friday plan, legal restriction and Michelle request. That omission fails the
existing golden sample's required summary facts despite a correct Jason-only task.
The same candidate scored 14/15 on Qwen: it emitted the cancelled venue work as
`Ari: I will not book a venue`. Its renewal summary contained all five lexical
fact groups but called Jason's promise a request, showing that lexical coverage
also needs semantic review. Results are retained in
`complete-commitments-content-review.json`.

The candidate is therefore **not ready to promote**. Production prompt, parser,
model preferences and generation settings remain unchanged.

Current probe sources and settings are archived as `capped-Probe.swift`,
`capped-compile.py`, `capped-run.py` and `capped-provenance.json`. Per-run execution
records bind the probe binary and minimum free space. The original provenance
record describes the original uncapped probe and is retained separately.

## Disk guard and cleanup

The repository's 5 GiB free-space floor protects this constrained development Mac;
it is an operational rule, not a Harc application requirement. The model-run
supervisor now terminates its owned process below 6 GiB to leave a buffer. This
samples free space and cannot guarantee against another process consuming disk.
A 128 MiB MLX cache limit applies only to unused buffers, not model weights or all
process memory. Capped runs reported approximately 3.2 GiB peak MLX allocations;
that is not process RSS or a whole-system memory qualification.

After verifying builds/tests were idle, removed only the regenerable
`swiftpm-testing-helper/com.apple.e5rt.e5bundlecache` and the diagnostic app's
`DerivedData/ModuleCache.noindex`. Measured recovery: 1,928,957,952 bytes (about
1.8 GiB), recorded in `cache-cleanup-20260906.json`. Existing diagnostic products,
current helper cache, source dependencies, models, recordings and Guppy were kept.
An earlier idle 789 MiB original helper build cache had also been removed.

After explicit user approval, deleted only the shut-down iPhone 17 Pro simulator
`C67B4630-E386-48CF-B661-7F4B43DF97F8` through `simctl`. Verified the device and
its directory are absent and all other registered simulators remain. The first
post-deletion recheck showed about 1.8 GiB more free space (10.1 GiB available);
the prior 3.7 GiB directory size is not a guarantee of uniquely reclaimable bytes.
Evidence: `simulator-cleanup-20260906.json`.

Next: require factual coverage alongside ownership in candidate comparisons,
resolve the omission without regressing commitment eligibility, then validate any
production change through focused tests and an Xcode build. The expanded XCTest
has only been typechecked, not executed in the full test target. Real recordings
and long-form accuracy remain separate qualification gates.

## Follow-up: coverage and separate passes

With approximately 13 GiB free after Simulator cleanup settled, continued at two
workers maximum and the existing 6 GiB inference stop threshold. No additional
user data was deleted.

- `status-commitments` restored the healthy-renewal fact but omitted Felix's
  dependent task: 14/15 development cases. Rejected.
- A separate `facts-only` pass retained the five renewal fact groups. A separate
  `tasks-only` pass reintroduced unsupported Amy/Leah tasks and omitted Noor:
  combined result 12/15. Rejected.
- Retrospectively combining commitments from the earlier `complete-commitments`
  run with prose from `facts-only` passed 15/15 development checks. These checks
  now include exact owner/count, selected task/deadline/condition terms and all
  five renewal summary fact groups, using a diagnostic Markdown grammar.
  This **does not execute the production parser**. Other cases' prose does not
  have exhaustive automated fact coverage.
- Applied the same assembly to the six additional cases. Manual review retained
  conditional promises, refusals, completed versus remaining work, and cancelled
  versus replacement work. The final prose sometimes omits names that remain in
  the task list. These examples are now development material, not fresh holdouts.

The promising combination is full-summary reasoning for commitments plus an
independent facts pass, not task-only extraction. It adds a model call and has
not been implemented or measured end-to-end. Separate retained runs are not a
repeatability, latency, cancellation, memory, or long-form qualification.
Production prompt/parser/generation behavior remains unchanged.

Added `missingStatusFailsDespiteCorrectAction` to the repository golden tests.
A compiled replay of the exact repository fixture/evaluator accepted the complete
reference and rejected the missing status with correct action ownership. The
full XCTest target and Xcode build were not run for this test-only addition.
The diagnostic scorer also rejected injected missing-case, missing-status and
missing-condition outputs. Raw results, rubric, scorer, source hashes and replay
sources are retained in `continuation-provenance.json` and adjacent files.

Next implementation decision requires a repeated end-to-end diagnostic of the
full-plus-facts combination, with untouched examples and both installed models.
Only then consider production integration, strict parsing of each response,
cancellation/failure behavior and the extra-call latency. Do not infer general
accuracy from these short, tuned synthetic examples.

## End-to-end diagnostic — fresh cases and model comparison

Implemented the candidate only in disposable `TwoPass.swift`: the same loaded
container generates the full response and then independent factual prose,
sequentially for each case. It retains both outputs, assembles their selected
sections, and invokes the existing production parser after the explicitly
reported diagnostic heading/owner normalization. This is now a real sequential
probe, not a retrospective join. It is still not application integration.

Froze eight new cases and `fresh2-rubric.json` before inference. No prompt or rubric
was changed after seeing those results. Cases cover status/risk contrasts,
unaccepted requests, dependent owners, reassignment, conditional work, completed
work, pronoun acceptance and cancellation after a promise.

| Diagnostic run | Selected lexical content/owner/format checks |
| --- | --- |
| Gemma, temperature 0, development set | 15/15 |
| Gemma, temperature 0, fresh set | 8/8 |
| Gemma, production-default temperature 0.6, same fresh set | 8/8 |
| Qwen, temperature 0, same fresh set | 6/8 |

Qwen's Nell condition is preserved in parentheses without the literal word `if`;
that flag is a lexical false positive. Its Tariq output actually converts the
cancelled reservation into an assigned negative task, so the model still fails.
Gemma's Nell prose uses `following day` at temperature 0, with possible temporal
ambiguity, and omits the deadline at default sampling while the action retains
`tomorrow`. The frozen prose rubric did not cover that deadline. These passes do
not establish complete prose coverage or semantic correctness. Manual findings
are retained separately in `two-pass-manual-review.json` without rewriting scores.

Median generation plus assembly for these tiny warm examples was 2.8 seconds
for Gemma development, 2.9 seconds for Gemma fresh and 4.5 seconds for Qwen fresh.
Model loading is excluded. There is no matched single-pass latency measurement
on this fresh set, so these figures do not establish the incremental cost.
Long-form input/output timing and completeness remain untested.

The actual assembly helper passed a valid case and eight empty/malformed response
cases, preserving the first response and setting an error for invalid assembly.
This does not test a thrown generation error or cancellation. The diagnostic
executable aborts on generation exceptions; its first response is not checkpointed
until the second succeeds. The wrapper records the child's exit status but itself
returns zero, so execution records and complete case inventory must be checked.
These are reasons to keep this probe separate from application implementation.

Evidence includes both raw responses per case, execution/disk records, source and
binary hashes (`two-pass-provenance.json`), frozen input/rubric, timing, assembly
checks and manual review. Production behavior is unchanged. No package or Xcode
build was necessary for these diagnostic-only changes and none is claimed.

Next: address deadline fidelity with stronger untouched prose checks; cover
cancellation and second-pass failures in a reusable generator before considering
Gemma integration. Qwen remains no-go for the candidate. Full package/app tests,
real recordings and long-form qualification are still required.
