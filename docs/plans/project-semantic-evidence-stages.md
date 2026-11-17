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
