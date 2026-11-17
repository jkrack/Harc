# Literal project-name proposal producer

Separate graph stack above PR211; not included in the release candidate.

This slice adds an opt-in Store API for one existing project and at most 25
explicitly selected recording IDs. Matching is literal, case-sensitive and
Unicode word-boundary-aware; it is not an LLM or semantic relevance classifier.
Names must contain 3–120 characters; transcripts larger than 256 KB are skipped.
Evidence is verbatim and includes up to 160 characters on either side.

Store constructs an immutable batch binding the Host library/authority/state,
canonical recording identity, whole-transcript SHA256 and project version.
Commit revalidates these in the writer transaction. Stale/missing evidence is
skipped; existing decisions are preserved. Results report actual inserted,
existing and stale candidate counts, never estimated precision or assignments.

No background producer, real-Library scan, UI consent surface, new-project UI,
remote inference, automatic assignment, alias promotion or speaker enrollment is
introduced. UI source/project selection and permission-to-scan wording remain
next integration work. Pending hypotheses still require human review.

Validation: focused SwiftPM execution passed 24 tests in two suites (18 existing
ProjectRefinement Store tests plus six producer test functions, with rejected/
unsure parameter cases). Coverage includes Unicode near-substrings, retained
negation context, idempotency, rejected/unsure preservation, stale full-transcript
hash despite unchanged excerpt, Host revocation, bounds, trash and pre-cancelled
commit. No app UI, performance benchmark or physical behavior is claimed.

Hardening follow-up: SQL checks transcript byte length before fetching the
Recording into Swift. Batch statistics expose selected, oversized, unavailable
and no-match counts. Mid-transaction cancellation is bridged through a locked
flag and rolls back earlier inserts. Cancellation after the final check/commit
boundary can still race a completed commit; callers must reload rather than
asserting that cancellation means nothing was saved.

Latest focused run: 27 tests passed, including canonical-identity and project-
version races, rejected/unsure/accepted preservation, oversized input, duplicate
IDs, invalid name bounds and cancellation after the first insertion. The source
identity test uses direct mutation of its synthetic database because normal
upsert correctly preserves canonical identity.
