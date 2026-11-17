# Role-separated evidence development v3

Status: frozen development run completed once; raw outputs and the remaining
injection false positive are preserved in `docs/evidence/role-separated-development-v3-20261117/`.
Independent challenge inputs released after policy freeze; gold withheld until output lock.
Not UI activation, assignment automation or a claim that role separation guarantees
prompt-injection resistance. V1 and v2 reports/scorers remain unchanged.

## Concrete change

Prior evidence calls placed instructions and JSON in one user turn. The installed,
catalog-pinned Gemma template explicitly supports a leading system turn. This
experiment places fixed classifier policy in that turn and only selected-source
JSON in the user turn. JSON strings cannot become new message dictionaries. This
does not prove the tokenizer/model treats embedded special tokens or adversarial
text safely; independently authored challenge evaluation remains mandatory.

New ContainerLike capability fails unsupported by default rather than silently
concatenating roles or invoking the old method. Legacy calls retain their exact
single-user behavior. Scoped service dispatch selects the new capability only
with explicit systemPrompt; no app caller exists. Both roles are prepared once,
full templated tokens counted together, and the same LMInput is generated under
the existing context/output bounds, authoritative stop and producer-join lifecycle.
The operation gate and snapshot receipt/cleanup remain unchanged.

## Frozen protocol

- Policy: `EvidenceV3Prompt.instructions` in
  `Tests/HarcSummarizeTests/RoleSeparatedEvidenceDevelopmentTests.swift`.
- Policy version `role-separated-policy-v3`, SHA256
  `38e499ce710ee345fc8e6511f79de5052c0472b3790831ea3e6c827d7495d310`.
- Eight fresh development fixtures, four new projects, corpus SHA256
  `ae69c41a8d497bd46774ff80493ea590fc730894fb1b3047c06e161c31fc9cfd`.
- Require an actual action/decision/commitment with attributable project context;
  preserve real conditional commitments and cancellation decisions. Mere fiction,
  speculative overlap, explicit other-project attribution, source directives and
  unresolved ambiguity should abstain. This is policy, not a measured guarantee.
- Frozen after v2 failure-category analysis but BEFORE any v3 development output
  or access to independently authored hidden challenge. Do not claim this design
  was uninformed by the earlier failure classes. Never rerate or tune on v2.
- Model output contract unchanged: abstain or one exact source quote. Source
  integrity and project relevance remain separate from quote/claim sufficiency.
  No same-model agreement is described as independent confidence.
- Existing independent challenge manifest was frozen by another worker and is
  withheld until this policy/code review completes. Any label-policy ambiguity
  discovered after disclosure is documented, not retroactively altered.

## Verification and next step

Boundary tests cover separate message dictionaries, exact content preservation,
combined UTF8 bounds, no legacy fallback, scoped dispatch/unload and existing
cleanup/serialization/token boundaries. Fake tests do not prove real template
rendering, semantic safety or actual model token accounting; the opt-in runtime
logs full prepared token counts and normal completion when authorized.

The v3 development harness is opt-in `HARC_EVIDENCE_ROLE_DEVELOPMENT=1` with split
`development` only. It uses existing installed catalog-verified model, isolated
Store fixtures, no downloads/private recordings, retained synthetic raw outputs
and separate adjudication packet. Independent review before model execution.
Then run frozen development once and the separately frozen unseen challenge,
without changing policy/model settings. Results, failures and adjudicator
interpretations stay distinct. No user-facing semantic activation follows merely
from a small synthetic success.

## Independent challenge release

Inputs only: `Fixtures/evidence-independent-challenge-v1.json`, 8725 bytes,
SHA256 `a2a870aaa54476c6199676d6a9930bc30f553fe13314aa14d7b3ad9029816338`.
Authored independently before release, author freeze commit
`a0221ef0c2afb6104bb11ae84004de6ddb0f940d`. Input-only runner records raw
outputs, strict source validation, tokens/timing and literal baseline without
labels or semantic scores. It asserts policy hash unchanged. Freeze output bytes
and publish hash BEFORE requesting gold/rationale. No policy changes based on
released inputs or development results. The project name Lumen overlaps v1;
independent authorship/new transcripts do not mean every name is unseen.

Post-run hardening: both opt-in loaders now check the frozen policy hash directly
alongside corpus/input hash before model service creation, rather than relying
on a preceding non-model assertion. This changes no policy/output or score; four
non-model XCTest checks passed and both model opt-ins skipped. Original challenge
run remains attributed to56664b4, not this later guard change.
