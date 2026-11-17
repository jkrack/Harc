# Selected-source project evidence: staged local evolution

## Stage 1: inert contract (this branch)

- Owner-authored project brief, optional for old payloads; explicit edit uses
  expected project version and Host identity, then advances version.
- One explicitly selected canonical source and project version. Snapshot uses
  original transcript, not search index, embeddings or normalized chunks.
- Reject missing brief or sources over32KB; no silent truncation. Brief at most
  2048UTF-8 bytes. These caps do not establish model context-window compatibility.
- Strict response is either `{"decision":"abstain"}` or
  `{"decision":"suggest","quote":"verbatim original source"}`. No confidence,
  timestamps, tools or freeform rationale fields. Unknown/duplicate fields,
  malformed JSON, fabricated/short quotes and ambiguous repeated quotes fail.
- A unique exact UTF-8 quote is mapped to original byte offsets, not playback
  times. This proves presence in the snapshot, NOT relevance or factual truth.
- Validation creates an inert candidate only. No candidate persistence API,
  model invocation, UI integration, scan scheduling or assignment is added.

## Stage 2: separate local adapter and synthetic evaluation

Reuse the existing serialized SummarizerService operation gate/container lifecycle,
not a second MLX container or `semanticSearch`. The current TextEmbedder is
HashedLexicalEmbedder, not semantic; index search scans the library and lacks
snapshot transcript-hash binding. TranscriptChunker normalizes text/interpolates
times and is not exact-source evidence.

Adapter must enforce actual installed-model context limits before generation;
no download or cloud fallback. Require authoritative normal generation completion,
not parse success alone, and reject stale service generation/cancellation. Treat
brief/transcript as data, not instructions. Use synthetic relevant, irrelevant,
negated, quoted, adversarial, multilingual and ambiguous cases. Report observed
counts and failures, not fabricated precision. Quality remains unqualified until
actual local-model evaluation.

A later candidate commit must revalidate Host tuple, canonical identity, complete
transcript hash and project version transactionally, preserve all existing human
answers, and remain pending review. Snapshot validity alone cannot authorize a
write after inference.

## Stage 3: separately qualified explicit UI

Keep one-source consent scoped to source+Host+project brief/version and disclose
local model use. Changing source or project resets consent. Clearly separate
abstention from validation/inference failure. No inference of speaker identities,
no whole-library scan expansion, no auto assignment or accuracy gain claims.

## Validation recorded for stage 1

Final combined focused run:34 Store test functions across existing refinement,
mention producer and six evidence-contract tests passed. Contract coverage:
legacy decode, owner brief CAS/project-version invalidation, Unicode exact spans,
abstention, malformed/unknown/duplicate fields, hallucinated or short quotes,
ambiguous repeated quotes, missing brief and source-size rejection. No actual
model was loaded; this is not a semantic-quality or app-UI result.

### Adapter prerequisites from independent review

- Acquire/release the existing SummarizerService operation slot and reuse its
  loaded container; no parallel container, silent download or cloud fallback.
- Tokenize the full prompt and reserve output tokens against the actual selected
  model context limit. The32KB Store cap is not a token-budget guarantee.
- Require authoritative normal generation completion and unchanged loadGeneration
  before accepting output, even if the JSON parses. Cancellation/truncation fails.
- Never log brief/transcript/model content. Supplied modelID currently records
  caller input only; the adapter must bind it to the actual loaded model.
- Blank evidence is invalid, even when whitespace occurs uniquely in the source.
  Exact spans establish presence, not semantic relevance. Keep semantic UI/model
  availability disabled until actual local-model evaluation has passed.
The follow-up seven-test contract run passed, including whitespace-only evidence
and a duplicate JSON key expressed through a Unicode escape. No model invoked.

## Adapter feasibility checkpoint (implementation paused)

Read-only inspection of current code found the operation lifecycle is reusable,
but the strict token-budget prerequisite is not yet exposed:

- `ContainerLike` exposes generation methods, not a prepared-input token-count /
  context-capacity contract. The production wrapper prepares the full chat input
  internally immediately before generation.
- `ModelDescriptor.contextTokens` is documented as a prompt-context budget.
  Treating it as authoritative actual model capacity would be an assumption.
- The pinned MLX `ModelConfiguration` exposes model/tokenizer locations and EOS
  configuration, but no uniform context-limit property. Model-family-specific
  position limits exist elsewhere and cannot safely be generalized by guessing.
- `generateSummaryPass` accepts a nil completion reason for legacy/test adapters;
  the project verifier must instead require explicit final normal completion.
  Production stream validation alone is not a complete injected-adapter contract.

No local verifier adapter/model invocation was added at this checkpoint. Safe
next implementation is a narrowly typed bounded prepared-input capability on the
existing container: measure the actual chat-template token count, reserve output,
validate against verified model-specific capacity, then generate that same input
within the existing operation slot. Unsupported metadata must fail closed. Add
fake-container tests for over-budget, missing metadata, nonfinal/nil completion,
output limit, cancellation, unload generation changes and operation serialization.
Only after that seam is qualified should actual local synthetic-model evaluation
begin. Do not substitute the32KB cap, approximate word counts, catalog budget or
parseable JSON for these prerequisites. No model, downloads, external service,
content logging, UI activation or production-source test was used in this check.

### Prepare-once capability groundwork (not activated)

The stacked bounded-evidence branch adds a separate `generateEvidence` capability.
The production container prepares the full chat template once, measures
`prepared.text.tokens.size`, rejects input plus reserved output over the limit,
and passes that same prepared input to generation. It accepts exactly one normal
completion, rejects tool calls, output-limit/cancel termination, missing/duplicate
completion and content after completion. Responses have a 4096-byte cap.
Existing summary/answer/transform behavior is unchanged; other container adapters
fail unsupported by default.

The service entry is internal, resident-only and shares the existing operation
lock. It cannot load/download a model and rejects unload/cancellation after a
noncooperative response. `EvidenceGenerationBudget` has no public constructor:
its 32768-token ceiling is an operational ceiling, NOT model qualification.
This change deliberately does not provide the installed-config resolver or a
public adapter. Before exposing it, bind a known schema's explicit context limit
to a SHA-verified installed config and model identity, revalidate config around
loading, and test unsupported/missing/ambiguous metadata. Never substitute SDK
default limits or descriptor prompt budgets for that evidence.

Synthetic tests exercise boundary/completion/serialization/unload behavior only.
They do not establish Metal inference, semantic relevance, accurate extraction,
Store proposal persistence or app accessibility. Actual local synthetic model
evaluation and strict Store snapshot validation remain separate gates.
