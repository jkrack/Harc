# Untrusted project-link preview boundary (proposal, not implemented)

Status: design for independent review before code. No UI activation, inference
scheduler, new Store mutation, model change or prompt retuning is authorized by
this document. Frozen v1/v2/v3/challenge results remain unchanged.

## Why the product boundary must not depend on model correctness

Strict parsing establishes that a quote exists, not that it supports the project.
Role-separated prompting still produced a source-directive false positive on
independently authored inputs. A second pass by the same model is not independent
confidence. Regex detection cannot cover paraphrases, obfuscation or all benign
instruction discussions. A model may offer a useful hypothesis, but it must not
change user data, assert a commitment, or hide counterevidence on that basis.

## Smallest useful next slice

An **in-memory, untrusted project-link preview** for one explicitly selected
canonical source and one versioned project brief. It is not a verified connection,
a task, a speaker identity, a commitment or an automatic graph edge. Creation has
no Store writes. It has no action/tool capability and cannot broaden source scope.
The initial implementation remains inert and synthetic-tested, with no UI caller.

Proposed preview payload:

- Opaque Store-bound snapshot identity: canonical recording, transcript digest,
  project ID/version and exact resident Host authority/state/library tuple.
- Model label is explicitly caller-supplied/unverified in the first inert slice.
  Do not fabricate catalog/load attestation from a string; a future opaque scoped
  generation receipt is a separate prerequisite for authenticated provenance.
- Exact source-bound quote byte range (existing strict parser), NOT timestamps or
  reconstructed words. The type/name must not imply semantic verification.
- The entire already-bounded selected transcript and project brief as the review
  context, plus highlight range. No newly summarized claim or inferred action.
  No truncation silently drops earlier correction, negation, owner or conditions.
- State `untrustedSuggestion`, never accepted, confidence percentage or accuracy.
  User-facing wording: “Possible connection. Review the source before linking.”

Keep full context available in the preview contract, even if later UI starts at
the highlight. Later rendering must visibly disclose collapsed context and allow
immediate expansion. A highlight never changes source text. When critical context
is outside the quote, do not make the standalone quote into a factual title.

## Explicit review and atomic confirmation (separate implementation gate)

The classifier cannot call the review/confirmation API. Only the trusted local
review controller may pass a user action tied to this exact preview. Do not use
model-produced `confirm`, `approve`, booleans, tool calls or JSON fields as user
intent. No 'accept all' or background auto-accept in this slice.

At confirmation, the Store must revalidate Host writer authority, active canonical
source, unchanged transcript digest, project version/brief and expected decision
version in ONE transaction. A mismatch means reload and review again, never rebind
the old choice to new content. Persist a user-authored relation through existing
answer-event/idempotency/undo mechanisms, not a second assignment table. Preserve
model hypothesis provenance separately; it cannot become training truth simply
because it existed. Respect existing accepted/rejected/unsure human decisions.

Confirmation says only “link this recording to this project.” It does not verify
every sentence, approve a project plan, create a task, identify a speaker or grant
permission to share the recording. Undo removes only the relation/event it owns
and refuses to overwrite later decisions. Re-transcription freshness remains
separate from an enduring user-authored relationship.

## Defense-in-depth quarantine, not a detector guarantee

Before inference, an optional conservative admission check may notice explicit
source control directives or role-control delimiters and route to manual review.
It must have an enumerated reason, no 'safe' verdict, and a visible explanation:
“Automatic suggestions unavailable for this source. You can review it manually.”
Do not call the source malicious or imply a successful attack detection.

- No-match does NOT establish absence of injection and never permits auto-write.
- Match may be benign discussion of prompts/code. Manual review remains available
  with unchanged source; no silent data deletion, edit or permanent suppression.
- Do not hard-code challenge strings or IDs, rescore old reports, or claim coverage
  from the cases used to design the check. Any filter needs a fresh independently
  authored challenge with both adversarial variants and benign controls.
- Source quarantine, model unavailable, invalid output, abstention and stale
  snapshot are distinct outcomes. None silently means 'no relation exists'.

Prefer shipping the authority/context boundary before a broad keyword filter.
Quarantine is optional defense in depth, not the core permission boundary.

## Tests required before code may be activated

1. Preview construction performs zero Store writes, even for a source-valid
   injected directive; no callback or tool action is available to the model.
2. Full original source/brief survive round trip byte-for-byte, with Unicode
   ranges; corrections, conditionals, unrelated-project disclaimers and prior
   utterance antecedents are retained outside the highlight.
3. Invalid, repeated, fabricated, over-limit or blank quotes cannot create a
   preview. Source selection is opaque and captured; model label remains explicitly
   unverified until an authenticated generation receipt is implemented.
4. No conversion to accepted relation without explicit controller user action;
   cancellation/dismissal/abstention/quarantine leaves assignments unchanged.
5. Confirmation races: transcript/canonical/project/Host changes, trash, repeat
   click/replayed operation and later decision; atomic refusal and safe reload.
6. Existing human decisions survive; exact undo is idempotent and does not erase
   newer state. No inferred facts/commitments appear in side effects.
7. If admission heuristics are added: fresh development tests and independently
   frozen blind challenge, false-positive/false-negative counts separate, manual
   escape available. No role-separation or heuristic immunity claims.

## Evaluation and release boundary

Independent second review assesses full-source relation support separately from
standalone quote sufficiency, including disputed antecedents/omitted conditions.
Report disagreements instead of rewriting frozen labels or scores. Small synthetic
samples and explicit human review do not prove real-world reliability; long-source,
noise, resource/cancellation and device UI/accessibility tests remain outstanding.

No automatic graph changes, background scans, cloud fallback, production Library
experimentation or release activation is part of this proposal. The first code PR
should only add an inert preview contract plus synthetic tests, reviewed separately
before any confirmation path or UI is implemented.

## Reviewed implementation constraints

The first slice is a memory-only session and immutable full-context payload, no
confirmation API, model calls, Store writes, heuristic detector or UI. Selection
keys bind captured canonical/transcript/project/Host identity, but are not live DB
freshness proofs. The future controller must invalidate on every selection/Host
change and release its own preview copies on dismissal. Session dismissal drops
its references only; it cannot securely erase Swift Strings or invalidate copies
held elsewhere. No persistence, logs or background cache. Full context being
available is not evidence that a person reviewed it. No model-generated title,
markdown or action rendering is supplied by this contract.

## Inert contract validation

Implemented on the isolated `feat/inert-project-link-preview-20261117` branch:
`UntrustedProjectPreviewSession` has no Store reference or mutation/model API;
only begin, finish, captured-selection comparison and dismissal/invalidation.
`UntrustedProjectLinkPreview` retains all source/brief text and exact byte highlight,
with caller-provided model label explicitly unverified. No UI/controller or
confirmation path is installed, so automatic observation of live Store changes
is NOT claimed. Future controller wiring and transactional confirmation remain
unimplemented qualification gates.

Twelve synthetic tests passed across new preview and existing evidence-contract
suites. They verify full context/Unicode, no pending/confirmed relations even for
an injected quote, superseded/duplicate/late completion refusal, malformed output,
source/project selection changes, explicit Host-loss invalidation and dismissal.
An initial test incorrectly attempted a new Host authority on a retained library
and was correctly rejected by existing tuple invariants. It was replaced with
an actual Host-loss/invalidate test, not an authority bypass. No real recordings,
model evaluation, confirmation API, heuristics or app activation was involved.
