# Speaker evidence binding

## Review execution validated — 2026-09-26 evening

After user-approved removal of the duplicate Qwen download cache restored 6.35 GiB
free, the current execution candidate compiled and passed all 48 selected XCTest
cases plus 10 Swift Testing cases, with no skips or failures. The actual recovery
fixture reached the injected post-decision/pre-completion failure, retained exactly
one matched decision, reopened the Store, and completed using the same operation.
Confirmed target enrollment did not advance its recognition revision during review
or retry. Source hashes, log and results are retained under
`build/qualification/host-review-execution-20260927/` (directory label uses UTC date).
This supersedes the interrupted validation status below for those exact sources.
Runtime inventory/scheduling, recurring deadlines, installed-app behavior and real
client convergence remain open.

## Review execution candidate — 2026-09-26, validation interrupted

Follow-up source inspection found that evaluating an already-confirmed speaker
called the ordinary enrollment revision bump even during a review of unchanged
retained evidence. That can change the revision underneath subsequent clusters or
an interrupted retry. Review-only admission now skips that enrollment bump; other
observation paths retain their existing behavior. The recovery fixture confirms
the target through the actual Host review API, retains independent matching evidence,
and requires the injected completion error, exactly one newly persisted matched
decision, stable recognition revision, and the same operation after reopen.
Swift syntax parsing passed, but typechecking and execution remain unverified at
3.3 GiB free. Current hashes and limitations are in
`build/qualification/host-review-execution-20260926/confirmed-review-followup.json`.

Added `performHostSpeakerReview` to reconstruct observations from retained evidence
without STT or new inference. Operation IDs bind persisted job UUID, evidence digest
and recognition revision so a retry can replay a committed decision. Naming admission
also checks that revision transactionally; final outcome replacement checks the exact
job snapshot. Missing evidence stays missing, and enqueue excludes outcomes with no
usable embeddings. Cancellation is checked between clusters and before publication.

Expanded the on-disk test to add independent confirmed enrollment, inject failure
after decision persistence but before outcome completion, reopen and retry, and
require unchanged decision count plus a matched refreshed outcome. This test has
NOT passed yet: the build was deliberately interrupted with exit 130 when free
space fell from 6.0 to 3.8 GiB. Evidence and edited-source hashes:
build/qualification/host-review-execution-20260926/status.json. Runtime scheduling,
recurring deadlines and end-to-end validation remain open. Do not treat earlier
focused passes as validating this subsequent execution change.

## Review naming admission — 2026-09-26

`submitHostSpeakerReviewObservation` now rechecks the full persisted job snapshot,
deadline, selected outcome and exact evidence inside the naming transaction, before
operation replay or assignment. Outcome compare-and-swap alone would reject stale
completion too late to protect the displayed name. This local-only entry point
preserves ordinary immutable decision replay while refusing a superseded worker's
attempt to present replay as current review work.

Focused speaker Store/People/arbitration tests passed without skips, covering a
valid review, stale backoff snapshot, early deadline, cleared/replaced queue job,
and both new and replayed operations from a superseded worker. Evidence:
build/qualification/host-review-admission-20260926/. The execution loop still must
use this entry point; runtime scheduling and physical convergence remain open.

## Persisted Host review queue — 2026-09-26

Migration v33 adds a local queue bound by foreign key to the exact Host outcome.
Enqueue validates the selected generation and preserves the existing UUID/deadline
on exact retries. Due inventory is bounded, ordered and revalidates artifact and
decision provenance. Failure backoff persists (5 seconds through one hour, capped
at eight failures); a stale job snapshot cannot postpone a replacement or count
the same failure twice. Outcome replacement deletes its queue entry transactionally,
and outcome invalidation/deletion cascades to the queued job.

Focused Store/arbitration/migration checks passed without skips, including on-disk
reopen, preserved backoff on re-enqueue, injected write rollback preserving both
outcome and queue, successful replacement clearing the job, and actual row deletion
when reprocessing starts. Evidence: build/qualification/host-speaker-review-queue-20260926/.
This is persistence infrastructure only: runtime inventory seeding, recognition-pack
wake-up, review execution, recurring deadlines and app/end-to-end tests remain open.

## Recognition-only outcome replacement — 2026-09-26

`replaceHostSpeakerProcessingOutcome` now supplies a transactional compare-and-swap
boundary for an already-ready Host artifact. It preserves canonical audio, producer,
transcript digest, diarization state, cluster inventory and selected evidence. Both
old and replacement outcomes revalidate exact retained bytes and decision provenance;
new results must use the current recognition-pack revision. A stale expected outcome
or invalidated processing generation returns false. A successful replacement emits
a Library change without rewriting the transcript or historical decisions.

The focused Store/arbitration run passed, including on-disk reopen, stale pack and
competing writer rejection, producer substitution refusal, injected write failure
preserving the old outcome, unchanged transcript bytes and immutable original
decision. Evidence: build/qualification/host-speaker-reevaluation-20260926/.
This API is not yet called by a review scheduler. Durable scheduling, atomic review
job progression, restart/retry behavior and real client convergence remain open;
the Host does not automatically re-evaluate existing outcomes on this change alone.

## Host speaker completion gap verified 2026-09-07

Missing local master/sidecar recovery is now implemented for verified committed
outboxes. A shared gate checks the current adoption, receipt, origin, producer,
canonical audio hash and frame count. Coordinator inventory, pending counts and
review scheduling use that gate; a missing master alone no longer hides metadata
work. Recovery preserves a matching sidecar or reconstructs only capture metadata
from the immutable outbox when both local files are absent. It never creates an
audio file or a local transcription candidate in this path. Corrupt sidecars,
unverified receipts, other-Library receipts, and integrity blocks remain excluded.

The actual Debug app build and 15 Swift Testing cases passed with no skips (zero
XCTest cases selected). The real timer fixture deleted its disposable master,
then separately both master and sidecar, and retained speaker-review scheduling
after recovery. It also checked absent/wrong-Library trust and a corrupt sidecar.
Evidence: `build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-speaker-missing-master/`.
This is recovery/inventory evidence, not a complete network delivery or cleanup
qualification. Missing encoded chunks/batches can still carry integrity blocks;
the complete retention policy and Host re-evaluation remain open.

The desktop sender now consumes authenticated Host outcomes before requiring a
local embedding, speaker-write scope, or retained edge submission. It persists
the outcome in a separate optional marker field; Host indices are never copied
into local speaker decisions. Missing evidence and disabled diarization remain
attention concerns, while a missing outcome with no local embeddings returns a
deferred error instead of success. Valid Host outcomes schedule six-hour status
reviews, including when the local embedding list is empty. Marker saves finish
file/parent synchronization, and inventory repeats that barrier before allowing
an existing Host marker to suppress retry. Review counts require a matching
sidecar, so old local generations cannot contribute current concerns.

The actual Debug app build passed. Seven focused Swift Testing cases passed,
including the real inventory timer with no local embeddings. The actual sender
case passed on direct pinned TLS and the local encrypted-relay emulator: it
consumed missing-evidence and disabled outcomes without adding Host observations,
and preserved its prior marker while deferring on an absent Host outcome. No
selected tests skipped; these runs selected zero XCTest cases. Evidence:
`build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-speaker-client/`.

This qualifies the invoked sender and the bounded timer fixture, not the complete
outbox/route-discovery lifecycle. Missing local master and sidecar eligibility is
now addressed by verified-receipt recovery above. Host re-evaluation after recognition-pack
changes, detailed on-screen outcome presentation, marker/sidecar cleanup, and
physical/six-hour endurance remain open. Status refresh alone does not rerun
recognition or reduce false name assignments.

Authenticated status exposure is now implemented as additive field 8,
`ProcessingStatusV1.host_speaker_outcome`, for both origin and canonical lookups.
Evaluated clusters now retain disposition and recognition-pack revision alongside
their immutable decision/evidence link. The Store compares both fields with the
persisted decision; it rejects an attempted nonmatch-to-match upgrade or changed
revision. Missing evidence and disabled diarization remain separate outcomes.

The protocol conversion validates required fields, enums, complete evaluation
tuples, and duplicate clusters/operations. The status boundary additionally
checks the caller's recording, origin, canonical audio and Host producer identity,
requires both ready states, and rejects simultaneous edge selection. An absent
outcome remains unknown. This boundary requires an authenticated response; its
expected identities must come from adoption and the durable receipt.

The actual app build and schema guard passed (7 schemas, 6 services, 27 RPCs,
31 enums). Focused validation passed 17 XCTest and 13 Swift Testing cases, plus
one actual app transport case on direct pinned TLS and the same case on the
local encrypted-relay emulator, without skips. Both lookup routes carried the
exact Host outcome after edge-to-Host replacement. Evidence:
`build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-speaker-status/`.

Client completion consumption for retained outboxes is implemented above. Status
is fetched before requiring a local edge submission, Host outcomes stay separate
from local numeric mappings, and concerns remain pending attention. Remaining
eligibility, re-evaluation and full lifecycle gates are listed above. Do not turn
an absent outcome or generic ready state into completion.
Production feature advertisement and speaker-bearing edge acceptance remain off;
no new real-model accuracy or physical-network result is claimed.

Host persistence implementation now lands in `HostSpeakerProcessingOutcome`,
Store migration v32, and the actual Host worker. The worker inventories every
transcript cluster, marks missing embeddings explicitly, and records disabled
diarization separately. A usable embedding requires a persisted decision before
the outcome can publish atomically with the ready projection. No-match and
pending-review decisions still count as evaluated, not as identified people.

Host decisions now retain immutable evidence provenance in their insertion
transaction, and replay requires it. Worker operation generation advances to v3
so older decisions without provenance are not silently backfilled. Outcome reads
revalidate current artifact bytes, canonical audio, evidence inventory and the
exact decision binding. Reprocessing invalidates the receipt; restoring generic
readiness cannot recreate it. Earlier rows remain unknown.

The actual Debug app build passed. Store/domain/migration validation passed
18 XCTest and 25 Swift Testing cases with no skips, including an on-disk reopen,
missing decision refusal, damaged provenance, disabled diarization, incomplete
cluster coverage, changed artifact bytes, and reprocessing invalidation. An
additional 13 worker/identity Swift Testing cases passed with no skips. Evidence:
`build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-speaker-outcome/`.
Authenticated status serialization is now implemented as described above;
retained-outbox client reconciliation is implemented above. These changes do
not close the full lifecycle gate or measure real-model accuracy.

The client must not treat `ProcessingStatusV1.processing == ready`, projection
readiness, or an absent selected edge digest as a completed speaker receipt.
`readyHostTranscriptDoesNotProveSpeakerIdentificationCompleted` now exercises
the actual Store publication path with a transcript containing speaker 0 and no
voice embeddings: both ready states publish, while current speaker evidence and
the selected edge artifact remain absent. All seven processing-arbitration Swift
Testing cases passed with no skips (zero XCTest cases). Evidence is retained at
`build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-speaker-readiness/`.
This reused the prior Debug app library; only tests and documentation changed.

The worker can also transcribe with diarization disabled. Existing status fields
cannot distinguish that case from successful diarization without usable voice
evidence, pending recognition, or completed recognition decisions. A transcript
cluster is not proof of an identified person. This blocks using generic Host
readiness to terminate the client's bound-speaker retry loop.

The reconciliation requirements are listed below. Persistence and authenticated
status are implemented above; client consumption and the remaining qualification
cases are still open:

- Persist a Host speaker-processing outcome bound to the canonical audio and
  exact selected Host artifact, including whether diarization was requested,
  completed, disabled, or failed. Existing rows remain unknown unless proved.
- Account for every produced cluster: retained usable evidence and a completed
  decision, or an explicit missing-evidence/unresolved outcome. Zero embeddings
  must not silently mean zero work. A completed decision may still be unknown
  or pending review and must not be presented as a correct identity.
- Publish this outcome with the corresponding projection generation; reject a
  stale generation after replacement or retry. Expose it through authenticated
  own-recording status without filesystem paths or numeric-ID fallback.
- Let the client reconcile Host-owned processing using that bound outcome,
  preserve visible concerns, and recheck after selection/pack changes. Test
  disabled diarization, missing embeddings, partial decisions, restart, and
  replacement through the actual sender before enabling feature advertisement.

This regression proves a status-contract gap, not a new recognition-accuracy
result. Production activation, real-audio false-name reduction, and physical/UI
qualification remain open.

Status: immutable evidence, protocol validation primitives, Store selection and
current Host publication, and desktop review actions are implemented. The live
UI attempt failed during automation initialization. Standalone capture/import/
re-identification/reprocessing still replace mutable embeddings and are not
bound; a current diagnostic reproduces identity reassignment on replacement.
Negotiated transport/admission, split and legacy migration remain open. This
extends the approved Host/Client implementation contract without changing local
inference or Host authority boundaries.

## Reproduced defect

A disposable app-linked Store diagnostic submitted two orthogonal 256-dimensional
voice embeddings for the same canonical recording and speaker index, with separate
observation operations: an older 20-second voice and a newer six-second voice.
Neither was initially enrolled. After confirming that slot as Bob:

- The recognition pack selected the older, longer observation as Bob and did not
  recognize the newer voice.
- Host matching recognized both unrelated vectors as Bob.

One test failed three assertions. This is a deterministic data/authority defect,
not a model-quality measurement. Evidence and exact source/library hashes live in
`build/qualification/production-hardening-2026-09-05/speaker-accuracy/historical-enrollment/`.

`speakerRecognitionPack` joins every historical observation to the current
`person_speakers` slot, then picks by duration. `submitSpeakerObservation` uses all
those historical rows. `linkSpeaker` confirms only recording/index, so neither
query can establish which payload the user confirmed. Local embedding replacement
has the same conceptual risk when a confirmed slot acquires new evidence.

## Required identity model

An immutable diarization generation must identify the canonical audio, producing
authority, exact processing artifact/timeline and model provenance. A cluster is
identified within that generation, not by a recording-global integer. A separate
embedding evidence identity binds the model and exact quantized payload, duration
and segment count to that cluster. Repeated recognition-pack evaluation must reuse
the evidence identity while creating a distinct evaluation operation.

The Host must validate generation ownership and cluster membership before accepting
an observation for a displayed timeline. Client and Host cluster zero are distinct
unless an explicit validated mapping establishes otherwise. Model ID alone cannot
establish this mapping. Delayed delivery must not make an old artifact current.

Human confirmation must reference the exact displayed cluster generation and
specific eligible evidence. Preserve its immutable evidence snapshot. A later
processing pass cannot silently change that confirmed prototype; corrected person
assignment moves the selected evidence, not every historical payload at its index.

Recognition packs and Host matching must read one shared selection of eligible
confirmed evidence. Keep historical observations for provenance and exact replay,
but never turn historical membership in a recording/index into enrollment authority.

## Implementation sequence and affected surfaces

1. Add validated generation/cluster/evidence identifiers to `HarcDomain` and the
   protocol observation and processing schemas, including negotiated capability
   behavior and exact signed-byte codecs. Extend processing artifacts so the Host
   can validate the claimed cluster and its audio/timeline binding. Update generated
   fixtures through the repository's existing protocol generation workflow.
2. Add durable current-generation and immutable confirmed-evidence records in
   `DatabaseMigrator+Harc.swift`. Update local embedding replacement, confirmation,
   correction, merge, split and dismissal transactions. Keep user labels and
   historical assignments; ambiguous legacy evidence needs explicit re-confirmation
   before serving as enrollment. Do not guess authority from arrival time or duration.
3. Make Store pack construction and Host matching share the same confirmed-evidence
   selector. Bind observation replay to the exact evidence and evaluation revision.
   Old evaluations may return their historical decision but cannot mutate the
   current generation's name or enrollment.
4. Thread the binding through Host processing, desktop recovery/artifact submission,
   speaker synchronization markers, Library detail projection and person-review UI.
   A review opened for a replaced generation must fail stale confirmation rather
   than name the new index. Preserve retry and original audio durability behavior.
5. Implement safe direct adoption of Client speaker turns with that binding. Retain
   existing Host-processing fallback until the complete artifact is compatible.

## Required verification

- Turn the retained failing diagnostic into a passing Store regression: only the
  explicitly confirmed payload matches, identically in packs and Host evaluation.
- Reorder delivery of two generations and swap cluster indices. Neither ordering
  nor index reuse may transfer a confirmed name or evidence to another voice.
- Replace local embeddings after confirmation. The old confirmed snapshot remains
  exact; the replacement is not automatically enrolled. Cover same-model replacement.
- Exercise same-evidence reevaluation under a new pack revision, exact replay,
  conflicting operation bytes, delayed historical decisions, and stale UI actions.
- Test legacy migration, reopen, correction/unlink/merge/split, enrollment duration
  floor, ambiguous matches, custom labels and automatic nonmatch cleanup.
- Run actual Host worker replacement/restart and both pinned-TLS direct and local
  relay lifecycle paths with bound artifacts and observations, then the app build.
- Re-run the retained AMI evaluations through the production flow. Separate the
  repaired evidence binding from model diarization and voice-identification errors.

This work remains part of production readiness. A green ordinary suite or a new
random observation UUID does not close the reproduced defect.

## Implemented foundation — September 7

`HarcDomain.SpeakerEvidenceSnapshot` validates and retains canonical recording/audio
identity, producer DeviceID, exact processing-artifact SHA-256, cluster ID, model,
quantized embedding, speech duration and segment count. Its evidence digest uses
a domain-separated binary encoding with explicit string/data lengths and big-endian
integers, including exact Float scale bits. It excludes evaluation operations,
pack revisions and person names. JSON decoding runs validation, including nested
embedding dimensions/scale and nonzero voice evidence. Text identifiers must be
bounded canonical Unicode without control characters or outer whitespace.

Three new tests cover JSON round-trip and an independently computed digest fixture,
eleven authority/payload mutations, and eleven invalid persisted-input mutations.
Together with four existing matcher tests, seven tests passed without skips; the
full app build passed. Evidence lives under `speaker-accuracy/evidence-snapshot/`.

This type is not yet connected to observations, confirmation, Store selection or
wire negotiation. It identifies supplied evidence but cannot itself authenticate
the producer or verify that the cluster belongs to the claimed artifact. The
historical enrollment reproduction remains unfixed. Next, carry this value through
validated protocol conversion and durable evidence/confirmation records rather
than allowing existing unbound observations to imply an equivalent binding.

## Validated envelope — September 7

`BoundSpeakerEmbeddingObservation` pairs an evaluation with an immutable snapshot
and rejects mismatched canonical recording, embedding, model, duration or segment
count. JSON decoding repeats these checks. The separate protobuf snapshot/envelope
messages have validated conversions; absent or malformed evidence cannot fall back
to legacy semantics. Reevaluation may change operation and pack revision without
changing evidence identity. The speaker index remains a projection hint until the
Host validates its mapping to the bound artifact's cluster.

No existing RPC or negotiated feature is changed. In particular, the new envelope
cannot be sent through the old observation RPC by stripping its binding. This
preparation leaves the deployed legacy behavior unchanged and still defective.

The schema guard and app build passed, followed by 22 tests across bound conversion,
snapshot validation and existing domain conversions with no skips. Six observation
payload mutations and nine missing/malformed envelope mutations are exercised,
alongside persisted mismatch, wire/JSON round-trip and reevaluation cases. Exact
source/library hashes and logs are retained under `speaker-accuracy/evidence-binding/`.

## Immutable retention — September 7

Migration v21 adds `speaker_evidence_snapshots`, keyed by the complete evidence
digest and associated with its recording. A SQLite trigger rejects updates;
hard deletion of the recording cascades removal. No legacy observations are
backfilled because they lack a proved artifact/producer binding.

`retainSpeakerEvidence` requires a live known canonical recording and matching
audio hash. Exact repeats are idempotent; different artifact/payload identities
remain separate snapshots. `retainedSpeakerEvidence` validates stored JSON and
recomputes its digest on read. Payloads are bounded to 16 KiB. Neither method
authorizes a producer, selects a current timeline or adds enrollment evidence.
Those are still required before confirmation can consume a retained snapshot.

The app build and 32 XCTest tests passed without skips. New coverage exercises
two snapshots retained across file-backed reopen, exact replay, update refusal,
stored digest mismatch, wrong/unknown canonical audio, migration idempotence and
preservation of legacy labels without invented bindings. The fixture seeds
canonical metadata directly; ordinary file-backed upsert rehashes the WAV and
correctly refused to preserve a hash for an absent fixture file. This tests Store
durability and invariants, not physical capture, ingest or producer authentication.
Logs and source/app-library hashes are in `speaker-accuracy/evidence-store/`.

Next: add explicit confirmation against the validated current artifact/evidence,
then make all enrollment consumers use that immutable selection. The legacy
historical-enrollment diagnostic remains a known failure until callers and
recognition selection have moved to the bound path.

## Exact selection and recognition — September 7

Migration v22 records a selected snapshot digest, person, stable prototype UUID
and confirmation time. `confirmSpeakerEvidence` names that digest explicitly.
Correction requires the expected previous person; an old first-confirmation action
cannot overwrite a later correction. Exact repeat confirmation preserves pack
revision and prototype identity. Evidence JSON remains immutable.

Both recognition-pack construction and authoritative Host matching now consume the
same confirmed-snapshot selector. It validates snapshot hashes and filters by model,
dimension, enrollment duration and live recording. Host matching excludes the query
recording to prevent self-corroboration. Correcting the selected evidence updates
both affected profiles and pack revision.

The two-voice contamination case passes through this new explicit path: two
different snapshots are retained, only the chosen one is confirmed as Bob, the
older voice remains unmatched, and the selected voice matches Bob in both pack and
Host evaluation. Correcting it to Alice changes both consumers and stale Bob
confirmation is rejected. File-backed reopen preserves prototype and pack revision.
The app build passed; 33 XCTest plus four Swift Testing tests passed without skips.
Source/library hashes and logs are retained in `speaker-accuracy/evidence-confirmation/`.

This does not yet replace legacy `linkSpeaker`/`confirmSuggestion`, local suggestion
consumers, or their merge/split/unlink lifecycle. Legacy evidence queries still run
alongside the new selection, so the original legacy reproduction remains defective.
Current-artifact review validation and callers must be integrated before presenting
this as a production fix. Retained evidence alone does not authenticate a producer
or authorize its use; the explicit API contract requires validated artifact
membership and review of that exact evidence before confirmation.

## Confirmation tokens and lifecycle — September 7

The previous-person comparison above was insufficient for A-to-B-to-A changes.
Migration v23 gives each selection a confirmation UUID. Corrections now present
that token; reassignment rotates it while preserving the prototype UUID. Exact
same-person repeats return the current token without changing enrollment. Old
tokens cannot correct or withdraw a newer selection, even when it again names the
same person. `speakerEvidenceAssignment` exposes the person and token for review.

`unconfirmSpeakerEvidence` removes only the selected enrollment after token
validation and retains immutable evidence as history. Repeated removal is harmless;
removal using an old token after re-confirmation fails. Pack/profile revisions
advance with the selection change.

Existing person merge now transfers snapshot selections before deleting source
people, preserving prototype IDs and rotating review tokens. Rename reflects the
current person's name without rewriting evidence. Person deletion cascades removal
of confirmations while retaining snapshots. Soft deletion and restoration of source
recordings now advance affected bound-evidence profile/pack revisions; filtered
snapshots disappear/reappear without changing their identity. These changes apply
to snapshot selections, not a migration of legacy recording/index confirmations.

The app build passed. Thirty-six XCTest tests plus four Swift Testing tests passed
without skips, including token backfill on an existing v22 selection, A-B-A stale
actions, withdrawal/re-confirmation, rename/merge/person deletion, source deletion
and restore, and exact snapshot/prototype persistence. Evidence is retained under
`speaker-accuracy/evidence-lifecycle/`.

Remaining integration includes current-artifact membership/review, split and
recording-slot unlink semantics, local suggestion consumers, production UI callers
and negotiated transport. The legacy contamination reproduction remains open.

## Authenticated artifact membership — September 7

`HarcValidatedSpeakerEvidenceV1` now binds an observation/snapshot envelope to a
`HarcValidatedProcessingSubmissionV1`, using the existing signed-metadata and exact
bundle validation. Callers supply the Host-resolved canonical recording, origin,
audio hash and current artifact digest. The validator rejects mismatched canonical
identity/audio/origin, a producer differing from the authenticated producing device,
a stale or different artifact, and an absent cluster. Claimed speech duration may
not exceed the sum of that cluster's signed canonical frame ranges; integer division
at 16 kHz avoids duration-overflow and fractional-millisecond overclaiming.

The validator proves provenance and cluster membership, not model accuracy or
human confirmation. It does not map Client-local clusters to Host speaker indices.
The caller must obtain current-artifact and canonical-row values from authoritative
Host state rather than echoing the request. It is not yet wired into an RPC or a
Store admission/confirmation workflow, and local Host-derived artifacts need their
own corresponding validated publication path.

The app build and 14 Swift Testing tests passed without skips. The new signed
fixture uses a ten-second cluster, accepts six-second and exact ten-second evidence,
and rejects ten variants including wrong producer/audio/origin/recording, missing
cluster, wrong/current-artifact digest and excessive duration. Existing authenticated
submission tests still reject historical-authentication promotion and artifact,
coverage or length substitutions. Evidence is retained under
`speaker-accuracy/evidence-artifact/`.

## Live Host worker retention — September 7

The resident Host composition now supplies the worker with the DeviceID derived
from its existing authority public key. The worker retains each voice embedding
as a snapshot bound to that producer, canonical recording/audio, the exact
structured transcript JSON SHA-256, and a `host-speaker-N` local cluster. It rejects
negative/missing transcript clusters. Snapshot retention occurs after immutable
transcript staging and before the existing embedding/observation/publication steps;
it does not select enrollment or claim that this artifact won publication.

The app build passed and 13 focused tests passed (seven XCTest, six Swift Testing).
The actual worker source then ran real local inference on ES2002b's first 180 seconds
in a fresh disposable Library with an explicit diagnostic producer ID. It returned
627 timed tokens and 33 turns, persisted six voice snapshots, marked processing and
projection ready, and left no durable backlog. After the process exited zero, an
independent Python verifier recomputed every snapshot identity and checked each
against the exact saved JSON digest, canonical audio hash, producer, cluster,
embedding model/duration/count and database integrity. No snapshot confirmation
was created. The owned worker and daemon were confirmed stopped.

Evidence is retained under `speaker-accuracy/host-bound-evidence/`, including the
Library, transcript, source, probe/compiler, verifier, logs and input/source/binary
hashes. Production uses the actual Host public identity; the replay uses a labeled
fixture identity. This verifies the real worker's retention path, not captured
input, signed app startup, Client admission, name accuracy or UI confirmation.
Current-artifact review and migration of legacy enrollment selection remain open.

## Published slot mapping and stale review — September 7

Migration v24 adds the current Host speaker-slot to snapshot mapping. Host ready
publication installs it in the same transaction as projection/readiness, after
checking each retained digest against the staged artifact bytes, canonical audio,
recording and `host-speaker-N` cluster. New staging, edge adoption and canonical
JSON-path/audio/recording-identity changes invalidate old mappings. An edge winner
still prevents a late Host publication from installing its map.

`currentHostSpeakerEvidence` requires a live ready recording and verifies the
current sidecar digest using bounded one-MiB reads. `confirmCurrentHostSpeakerEvidence`
rechecks that mapping, artifact hash and expected evidence digest inside the
confirmation transaction. An open review cannot enroll another payload when the
same numeric speaker index is reused. This API selects enrollment; UI label and
person-link updates are not yet routed through it.

The app build and 16 tests passed (eight XCTest and eight Swift Testing). The new
replacement fixture covers unpublished evidence, work in progress, mismatched
publication, index reuse, stale confirmation, sidecar rewriting and same-path edge
takeover. Only the newly reviewed voice enrolls. A fresh real-model worker replay
also completed with 627 timed tokens, 33 turns, six snapshots and six current maps.
After zero-exit shutdown, independent SQLite/artifact verification matched every
map to its retained snapshot and published artifact. No enrollment confirmations
were created by processing. Evidence is in `speaker-accuracy/current-speaker-evidence/`.

The live worker now installs mappings, but production UI/legacy review callers do
not yet consume them. Client transport, artifact-to-Host cluster mapping, legacy
migration and speaker-management integration remain required before readiness.

## Mixed legacy/bound enrollment transition — September 7

Before UI integration, the clean-Library confirmation fixture was strengthened
with both legacy local embeddings and two historical remote observations, plus
an existing confirmed person link. It reproduced five failures: old-voice naming,
Host matching, conflicting correction, legacy resurrection after withdrawal, and
local-reference reuse. The prior explicit-snapshot test alone did not establish
safe transition of existing libraries.

Migration v25 records `bound_speaker_enrollment_sources` independently of current
confirmations. First exact confirmation transitions its source recording and
invalidates affected legacy-person profile revisions. Existing exact selections
are backfilled into this transition; ordinary legacy recordings are not guessed
or automatically bound. Pack construction, Host matching and local reference
fetches exclude legacy evidence from transitioned recordings. Removing the last
bound confirmation or deleting its person does not remove the transition. Legacy
names and links remain unchanged as history, not enrollment authority.

The app build passed. Thirty-seven XCTest and 20 Swift Testing tests passed without
skips. The mixed fixture now recognizes only the chosen voice, applies correction
consistently, and cannot resurrect old enrollment after withdrawal. Tests also
verify transition persistence on reopen and migration of an existing selection.
Before/after failure logs and source/app-library hashes are retained under
`speaker-accuracy/evidence-transition/`.

This closes legacy-pool contamination for sources explicitly transitioned to bound
enrollment. Untransitioned legacy recordings still require the planned review and
migration flow. Local suggestion consumers now refuse old references for transitioned
sources but still need to consume the selected snapshots directly. Production UI
confirmation/linking remains unconnected; no broad identity-readiness claim is made.

## Local suggestion references — September 7

`SpeakerSuggestionEngine` now consumes `speakerRecognitionReferences`: eligible
legacy references from untransitioned recordings plus exact selected snapshots
through the shared confirmed-snapshot selector. Reference values carry recording
identity and vector, not a fabricated mutable speaker index. Both post-diarization
and new-person backfill use these references. Backfill no longer requires an old
mutable source embedding row; it requires eligible confirmed reference evidence
from the source recording. Same-recording exclusion and person ambiguity margins
remain in place.

The separate `SpeakerReIDService` similarity lookup used `allSpeakerEmbeddings`,
which had escaped the previous transition filter. That query now excludes
transitioned legacy records too. This closes that remaining stale-reference route;
its match-list UI still needs a representation for bound reference identities.

The app build and 53 tests passed (36 XCTest, 17 Swift Testing) without skips.
A new real suggestion-engine fixture exercises both triggers with a selected
snapshot, no mutable source embedding, and a short independent query. Both produce
the expected person suggestion. Mixed-pool tests also verify the selected reference
bytes and exclusion from the legacy similarity query. Logs and source/app-library
hashes are retained in `speaker-accuracy/bound-local-suggestions/`.

This connects local person suggestions to selected evidence. It does not yet bind
pending suggestion review actions or production UI confirmation/linking to a
current-artifact review token; those remain necessary.

## People review failures — September 7

People review now retains confirmation and dismissal errors in the view model
and presents them through a native alert. Confirm All stops on the first failed
mutation, keeps earlier successful confirmations, and refreshes the remaining
suggestions. Previously these errors were silently discarded.

The macOS app build passed. Focused app-linked validation passed 36 XCTest tests
and two Swift Testing tests (three cases), with no skips. The new cases verify
that stale confirmation preserves a newer person correction, that a subsequent
successful action clears the error, and that batch failure behaves correctly
both before and after an earlier successful confirmation. Evidence and hashes
are retained in `speaker-accuracy/people-review-errors/`.

This verifies view-model behavior and app compilation. The alert has not been
exercised on screen. These review actions still use the legacy suggestion API;
current-artifact tokens and atomic bound enrollment/display updates remain open.

## Atomic current Host review — September 7

The Store now supplies an opaque `HostSpeakerReview` containing the exact current
snapshot and the reviewed recording revision, person link, confirmation time,
confirmation status, label and evidence-selection token. Confirmation re-reads
these in the writer transaction and rejects any change. It then updates selected
voice evidence, the confirmed person link, the visible label, pending/dismissed
suggestions and the Library revision together, followed by OKF reprojection.
This catches same-artifact corrections through legacy link APIs as well as
artifact replacement. Review values cannot be constructed by external callers.

The app build and 36 XCTest plus two Swift Testing tests (three cases) passed
without skips. The current-publication fixture now verifies stale legacy-link
rejection, a missing target, and an injected database label-write failure after
enrollment changes. The injected failure rolls back the selected person and
token; a fresh retry commits the name, link and selected evidence together.
Evidence and hashes: `speaker-accuracy/atomic-speaker-review/`.

This is the transactional operation needed by review UI. Production UI callers
still need to retain and submit these review values; the old enrollment-only
operation remains separate. No live UI or broad recognition qualification is
claimed by this Store diagnostic.

## People suggestion review integration — September 7

The People view model now loads and retains exact Host review values alongside
suggestions. Confirm and Confirm All submit those values to the atomic Store
operation. Review values include the pending proposals as well as assignment and
artifact identity, so a dismissed or replaced proposal invalidates a retained
review. Overlapping suggestion loads cannot publish an older completed load.

Unbound legacy recordings retain their existing confirmation path. A recording
with retained snapshots or an enrollment transition cannot fall back to that
path when current evidence is unavailable. The Store enforces this again at
legacy confirmation time, closing the race after UI loading. Other callers of
the legacy confirmation API now receive a visible rejection for these sources;
the Library inspector still needs the same retained-review integration.

The app build passed, followed by 36 XCTest and 12 Swift Testing tests without
skips. The new real People view-model fixture seeds a published Host artifact,
checks rejection while unpublished, rejects a dismissed proposal and a newer
legacy person correction, then confirms a fresh suggestion and verifies the
selected evidence, person link and visible name. Evidence and hashes are in
`speaker-accuracy/people-bound-review/`.

This connects the People confirmation UI action through its production view
model. It does not establish on-screen usability, playback review quality,
standalone evidence production, legacy migration or general voice accuracy.

## Library suggestion review integration — September 7

The Library inspector now retains review values when loading its suggestions and
submits them on confirmation. The shared immutable `SpeakerSuggestionReviewBatch`
owns this behavior for both the inspector and People view model. Bound confirmation
uses the atomic Store name/enrollment operation; only legacy confirmation runs
the inspector's separate label mirroring. A generation identifier prevents older
inspector suggestion loads from replacing newer completed loads.

The macOS app build and 36 XCTest plus 12 Swift Testing tests passed without
skips. The bound fixture now additionally exercises the inspector's shared batch:
a fresh correction changes the name and selected voice person together, requires
no legacy label mirroring, and rejects reuse of the consumed review. Logs and
source/app-library hashes are retained in `speaker-accuracy/library-bound-review/`.

This connects suggestion confirmation in both desktop review surfaces. Direct
person linking/creation/unlinking, legacy evidence migration and standalone
snapshot production still require integration. The live screen, physical audio
capture and general recognition accuracy remain unqualified.

## Direct person linking and removal — September 7

The Library retains current review values for its speaker slots. Selecting an
existing person submits the exact reviewed voice to the atomic name/enrollment
operation. Removing identity uses `unlinkHostSpeakerReview`, which validates the
same review and removes that exact enrollment, the slot link, pending suggestions
and visible label in one transaction. It bumps speaker profiles and the Library
revision and reprojects OKF. Retained evidence and the permanent exclusion of
legacy references remain. Other independently selected evidence is not withdrawn.
Legacy unlink now rejects sources with bound evidence, including after the last
selected sample was withdrawn; it cannot silently leave enrollment behind.

The final app build and 36 XCTest plus 12 Swift Testing tests passed without
skips. The Library helper fixture rejects stale unlink, injects a label-write
failure after enrollment removal and verifies rollback, then successfully removes
the enrollment/link/name while retaining provenance. It also reenrolls through
the existing-person picker path and rejects a stale correction. Evidence and
source/app-library hashes are in `speaker-accuracy/bound-speaker-slots/`.

Creating a new person from a slot still uses the older path and requires atomic
create-and-enroll integration. Split behavior, legacy migration, standalone
snapshot production, live UI validation and recognition quality remain open.

## Creating a person from a speaker — September 7

The Library create-person action now uses its retained slot review. Bound Host
creation inserts the new stable person and invokes the same transaction-local
confirmation implementation as existing-person selection. Review validation,
voice enrollment, name, link and Library revision all commit together. A stale
review or failed write rolls back the inserted person. The legacy fallback now
also creates the person, link and label atomically and refuses a source that has
acquired bound evidence since review loading. Legacy identity authority still
needs migration; this transaction does not invent a binding for older samples.

The app build and 36 XCTest plus 13 Swift Testing tests passed without skips.
Bound tests reject stale creation, inject a label failure after person/enrollment
writes, verify no orphan person or changed enrollment, then retry successfully.
A separate legacy fixture verifies the same no-orphan rollback and combined
name/link success. Evidence and hashes: `speaker-accuracy/create-speaker-person/`.

All Library suggestion/direct picker/create/unlink actions now have a bound Host
path. Split behavior, standalone snapshot production, legacy migration and live
UI validation remain open. Existing `HARC_UI_TEST_ROOT` isolation and Library
launch hooks are available for the next on-screen qualification work; tests of
Store and view-model helpers do not substitute for exercising those controls.

## On-screen qualification attempt — September 7

Added an opt-in DEBUG `HARC_UI_TEST_BOUND_SPEAKERS` fixture under the existing
isolated UI test root. It stages synthetic transcript/embedding metadata through
the real Store publication APIs. Its canonical metadata and voice vectors are
synthetic UI state, not audio-processing or accuracy evidence. The UI case drives
create person, relaunch, unassign and relink and retains a final screenshot if it
reaches completion. Stable speaker-picker accessibility identifiers target the
controls. The picker no longer mutates its displayed draft name before Store
acceptance; successful changes flow back through the saved labels.

The first attempt failed to compile the new XCTest waiting code; that was fixed.
The second built the app and test runner, but XCTest timed out enabling automation
mode before exercising controls. Current `ioreg` reported
`CGSSessionScreenIsLocked = Yes`. The run terminated with exit 65; its result
summary reports zero passing tests and one failure. The execution checker rejects
it. No screenshot or screen qualification is claimed. The exact xcresult remains
at `/private/tmp/harc-app-validation/BoundSpeakerUIV2-20260907.xcresult`.

The rebuilt app's focused regression run passed 36 XCTest and 13 Swift Testing
tests without skips. Logs, exported failed UI results, checker output and source/
app-library hashes are retained in `speaker-accuracy/bound-speaker-ui-attempt/`.
Resume this same UI case when macOS automation can initialize. The rest of the
speaker migration, split and standalone evidence work remains independently open.

## Standalone replacement defect reproduced — September 7

The app-linked `StandaloneSpeakerReplacementProbe` starts with a confirmed local
256-dimensional vector, replaces it through the actual `upsertSpeakerEmbeddings`
API with an orthogonal vector at the same index, and reads the actual recognition
pack. Before replacement the original voice matches the confirmed person. After
replacement the unrelated voice matches that person at score 1.0 and the original
voice no longer matches. One XCTest fails two invariant assertions. The probe,
log and exact source/app-library hashes are retained in
`speaker-accuracy/standalone-speaker-replacement/`; it remains an unresolved
regression, not a passing qualification or model benchmark.

Current caller audit: post-stop and import persist mutable rows; Identify
speakers persists the new vectors but not the returned segments/overlap timeline;
local library reprocessing also persists mutable rows. None of those paths uses
the Host snapshot/current-publication mechanism. Host-only fixes therefore do not
close the standalone identity defect.

Next integration must publish the current diarization timeline and exact
embeddings as one generation, retain canonical audio identity and a real local
producer identity, and keep old confirmed evidence immutable. It must invalidate
old slot authority without silently assigning the replacement voice or rewriting
user edits. `HarcDesktopClientFiles.canonicalizeWAV` already produces canonical
PCM hashes for client export; standalone evidence needs an appropriate bounded
hashing/publication path, not fabricated Host identity or UI-test metadata.

## Standalone generation preparation — September 7

Added `HarcStandaloneSpeakerGeneration` beside the desktop local reprocessor.
Preparation reads the protected canonical WAV through the existing bounded PCM
inspection code and produces its canonical hash/frame count. Building encodes
one exact SessionTranscript (including manual-edit provenance), hashes those
bytes and binds each embedding to the supplied canonical recording and explicit
producer identity. Local clusters use `local-speaker-N`, not Host provenance.
Duplicate embedding indices, missing clusters, overlapping same-speaker turns,
out-of-audio turns and embedding duration beyond its cluster are rejected.

The app build, eight Store XCTest tests and four Swift Testing tests passed
without skips. The new tests retain manual-edit metadata, distinguish changed
transcripts, reject timeline/payload mismatches and inspect a disposable canonical
WAV. The PCM digest matches the known bytes, the reader leaves the master intact,
and a one-byte audio change changes the evidence identity even with identical
transcript bytes. Evidence and hashes: `speaker-accuracy/standalone-generation/`.

This is a preparation primitive, not a completed standalone fix. It is not yet
called by capture/import/Identify speakers/reprocessing, and Store current-map
validation still accepts only Host clusters. Next work must add local publication,
real local identity resolution and those callers, while preserving old selected
evidence and handling legacy confirmation explicitly. The retained standalone
replacement regression remains failing and production accuracy stays unqualified.

## Local publication and post-stop integration — September 7

`publishLocalSpeakerGeneration` now commits exact immutable transcript bytes,
canonical audio metadata, retained snapshots, current cluster mappings and query
embeddings as one generation. Recording revision and previous artifact digest
reject stale work. Replacing a generation archives old labels/person links in
immutable `speaker_assignment_history` (v26), clears their active slot authority
and stale suggestions/dismissals, and excludes mutable legacy enrollment. Exact
previously selected snapshots remain enrolled; the new generation does not inherit
their person. Local current snapshots use the same review actions as Host snapshots.

Post-stop standalone embedding persistence now prepares and publishes this
bound generation instead of replacing only mutable rows. It resolves a dedicated
persistent local signing identity with identity-loss checks against retained local
evidence, inspects the protected canonical WAV off the main actor, and binds the
saved structured transcript. It begins after the durable Library commit; errors
use the existing visible processing failure state and do not discard audio.
No real Keychain identity was created or capture performed by these tests.

The app build and 37 XCTest plus six Swift Testing tests passed without skips.
A file-backed replacement fixture confirms voice A, publishes unrelated voice B at
the same index, and proves A remains recognized while B stays unconfirmed. Active
old labels/links are cleared with archived history, current query bytes match B,
and evidence/recognition survive an independent reopen. Injecting a current-map
insert failure rolls back the whole generation and history change. Late stale
publication is rejected. Evidence and hashes: `speaker-accuracy/local-speaker-publication/`.

The old raw-upsert standalone regression is still a valid failure for callers
not yet migrated. Import, Identify speakers and local reprocessing must adopt
this path; legacy historical enrollment still needs explicit review/migration.
Archived label history is preserved in the Store but has no dedicated review UI
yet. Physical post-stop behavior, real inference output compatibility, identity
service failure behavior and live UI remain unqualified.

## Identify speakers and import integration — September 7

Identify speakers now captures the recording revision and prior transcript digest
before inference, uses the launcher's actual socket, propagates startup errors,
and publishes returned speaker segments, overlap assessment and embeddings as one
local generation. It preserves words, manually edited text and edit provenance;
superseded chunk-local speaker guesses are cleared. Cancellation and stale
recording/transcript changes reject publication rather than naming a newer slot.
Import now uses the same generation publication path and visible post-processing
failure state instead of silently ignoring mutable-embedding persistence errors.

The app build and 37 XCTest plus seven Swift Testing tests passed without skips.
The added transformation test verifies timeline replacement while retaining manual
text and all words. A separate read-only replay used the retained real-model AMI
ES2002b 180-second output (627 tokens, 33 turns, six voice vectors). Preparation
accepted all six snapshots and reproduced the stored canonical PCM hash. This
was one additional passing XCTest using a diagnostic producer ID, not fresh
inference, physical capture, a real Keychain lifecycle or UI interaction. Logs,
input/output/source hashes and the disposable replay source are retained under
`speaker-accuracy/local-speaker-callers/`.

Local archive reprocessing still persists mutable vectors and needs integration.
Legacy enrollment migration, history review UI, split behavior, end-to-end live
identity service/capture qualification and model accuracy concerns remain open.

## Local-library reprocessing generation — September 7

The local-library-to-Host preparation path now captures the existing structured
transcript/digest before inference, uses the actual daemon socket and explicit
required diarization when enabled, and submits a complete generation instead of
saving text and mutable vectors separately. Manually edited joined text and its
edit timestamp are carried forward while new timed words remain marked as
approximate through that existing manual-edit provenance. Recording revision and
prior artifact digest reject edits made during processing.

Local generation publication now optionally accepts transcript text and model
provenance together, updating text, STT model, transcription timestamp and search
index invalidation inside the same transaction as the timeline and snapshots.
The publisher rejects a text/model pair with only one component. The regression
fixture now verifies that a failed current-map write leaves the prior text and
model intact and a successful retry commits the replacement text/model.

After correcting an API-name compilation error, the app build and nine XCTest
plus six Swift Testing tests passed without skips. Required-diarization tests
continue to reject text-only success after diarization failure. Evidence and
source/app-library hashes: `speaker-accuracy/local-reprocess-generation/`.

This is the Client migration/reprocessing path. The Settings whole-archive job
uses `ArchiveReprocessor` and `DaemonArchiveTranscriber`, whose interface returns
only text; that separate production route still needs structured publication.
No whole-archive, live Keychain, physical capture or UI qualification is claimed.

## Settings archive publication — September 7

The archive engine interface now has a recording-aware `reprocess` operation.
Settings supplies `PublishingArchiveTranscriber`, whose resident-app callback
runs the same structured local generation publication as local-library-to-Host
reprocessing. The archive counts success after publication completes; it no
longer independently writes a text-only result for this production provider.
Diarization/VAD settings and the model identity are captured for the job. Empty
ASR results remain failures, manual text is preserved, and cancellation is checked
before generation publication. The text-only compatibility implementation now
checks the queued recording revision before committing, rejecting concurrent edits.

The app build and nine XCTest plus 18 Swift Testing tests passed without skips.
New orchestration tests prove dispatch to the publishing operation, continued
processing after an injected item failure, and rejection of the legacy text
commit when the recording was edited during inference. Existing archive skip,
progress, cancellation and search-index tests remain passing. Evidence and
source/app-library hashes: `speaker-accuracy/settings-archive-publication/`.

This connects the Settings production provider; it is not a real-model
whole-archive or live Keychain test. Missing/corrupt structured transcripts,
concurrent audio replacement, legacy enrollment migration, history review UI,
split behavior and long-form inference deadlines still need qualification and/or
hardening. Physical recording and screen automation gates remain open.

## Confirmed-sample listing and split — September 7

People now lists selected immutable voice samples separately from legacy mutable
voice rows. `enrolledSpeakerEvidence` carries exact snapshots and opaque current
confirmation tokens without fabricating a current speaker index for historical
generations. The bound split action checks every selected token/person before
writing, creates one new person, moves exact evidence, and updates a current
label only when that current slot still resolves to the selected sample. Earlier
generations remain exact history. The whole operation rolls back on failure.
Legacy numeric-slot split refuses bound sources so it cannot silently leave their
selected evidence assigned to a different person.

After correcting a duplicated view-builder annotation, the app build and 37
XCTest plus 13 Swift Testing tests passed without skips. A mixed current/historical
fixture verifies split identity, current label change, immutable sample retention,
no orphan person on injected current-label failure, and stale-token rejection.
The People VM test verifies selected-sample loading, visible stale-selection error
and successful split refresh. Logs and hashes: `speaker-accuracy/split-speaker-evidence/`.

The new section has not been exercised on screen. Audio audition and useful
historical-generation context still need UI work; a sample's duration/title alone
is not a complete human-review experience. Legacy migration, live capture/identity
qualification and the measured model-quality problems remain unresolved.

## Store publication boundary audit — September 7

Local publication now decodes the actual transcript speaker turns and validates
cluster presence, nonnegative/in-audio intervals, nonoverlap per speaker and the
available speech duration before accepting snapshot claims. An exact artifact
digest alone no longer suffices for a voice absent from the document. Generations
must have a single producer; explicit transcript text must equal joinedText and
model provenance cannot be blank. These checks supplement the trusted local
builder rather than treating it as the only defense against caller mistakes.

The app build and nine XCTest plus nine Swift Testing tests passed without skips.
New negative cases bind valid snapshot digests to empty, too-short, overlapping
or negative-time timelines and supply mismatched flat text. All are rejected with
no recording revision or evidence persistence change. Existing publication,
rollback, split, People and archive dispatch checks remain passing. Evidence and
hashes: `speaker-accuracy/local-publication-boundary/`.

This validates stored consistency, not actual identity accuracy or audio ownership
through a long inference run. Concurrent master replacement, legacy migration,
review audition and live capture/UI qualification remain open.

## Audio identity across inference — September 7

Identify speakers and both archive reprocessing entry points now retain a
canonical PCM hash/frame count plus filesystem identity before inference. Local
preparation compares a fresh observation before accepting the output. Inspection
checks device/inode, length, modification and change timestamps before and after
the bounded PCM read and rejects nonregular/symlink paths. A persistent content
change or replacement with identical bytes invalidates the inference result.

The app build and nine XCTest plus eight Swift Testing tests passed without
skips. The canonical WAV fixture accepts an unchanged master, rejects a changed
sample, rejects atomic replacement with the original bytes, and rejects a symlink.
Existing Store publication and archive dispatch checks remain passing. Evidence
and hashes: `speaker-accuracy/audio-identity-inference/`.

This verifies change detection between observed boundaries, not permanent control
over externally accessible files or a malicious privileged actor. Capture/import
inference has its own protected-master lifecycle and still needs end-to-end
qualification. Legacy enrollment migration, sample audition, model-quality and
live UI/capture gates remain open.

## Host and accepted-edge replacement labels — September 7

A new regression reproduced stale identity inheritance in both Host staging and
accepted-edge publication: changed structured transcripts retained the old name
and person link at the reused numeric cluster, with no assignment history. The
pre-fix run failed six assertions across the two paths.

Publication now archives prior labels/links, clears active assignments,
suggestions and mutable embedding rows when transcript identity changes, and
invalidates affected recognition profiles in the same database transaction.
Selected immutable voice evidence remains enrolled. An identical-artifact retry
preserves its valid label. Injected assignment-history failure rolls publication
back, including recording revision and sidecar binding.

The macOS app build and ten XCTest plus eight Swift Testing cases passed with
no skips. Retained before/after logs, source and app binary hashes are under
speaker-accuracy/host-name-replacement/.

This covers changed transcript artifacts. An unchanged transcript with newly
computed, different embedding evidence still needs a separate generation-level
audit; transcript byte equality alone cannot prove voice-sample equality.
Historical-assignment presentation, legacy enrollment migration, real-model
identification errors and live UI/capture qualification remain open.

## Identical transcript with changed voice evidence — September 7

The next regression reproduced stale name inheritance with identical transcript
bytes and a different retained embedding: two assertions failed before the fix.
Host staging now retains the prior mapping when the artifact path is unchanged;
processing/projection state still prevents current review during inference.
Artifact-path changes continue to invalidate the mapping through the existing
database trigger. Publication compares the complete prior mapping to the exact
new evidence digests before installing it.

A changed or missing evidence set retires the previous active labels/links into
history while preserving selected immutable enrollment. Fresh mutable embeddings
are retained at this publication boundary because the worker has already written
the new inference output. Exact evidence retries preserve their valid assignment.
Rejected unretained evidence rolls the transaction back, including label changes.

The macOS app build, eleven XCTest and ten Swift Testing cases passed without
skips. Tests cover identical evidence, changed evidence, empty evidence, rejected
publication and existing review/arbitration behavior. Before/after logs, sources
and app binary hashes are in speaker-accuracy/same-transcript-voice/.

This closes the observed unchanged-transcript Host replacement gap. Legacy
enrollment, transport admission and observation ordering still require broader
end-to-end work. No new real-model inference or on-screen review was performed,
and the measured identification errors remain unresolved.

## Recognition confidence tradeoff — September 7

Added a strict retained-decision confidence replay with input hashes and three
passing Python tests. Missing/duplicate decisions, nonfinite scores and invalid
intervals fail the evaluation. Three short retained clusters lacked embeddings;
their explicit unknown completion has separate provenance. The .65 baseline
exactly reproduces the existing current-timeline re-embedding identity totals.

On ES2002b, .65 gives 80.70% correct known activity and 4.233 seconds wrong-name
speech. At .80 this falls to 51.17% correct known activity while wrong names
remain for 3.305 seconds. At .85 both correct and incorrect names disappear.
The results cover both meetings and all eight predefined thresholds, including
unannotated activity and errors outside overlap warnings. Evidence:
speaker-accuracy/confidence-sweep/report.md and results.json.

No production threshold changed. This is a replay of retained re-embedding
candidate output, not fresh model inference, word-ownership accuracy, or a model
holdout. High-confidence mixed clusters need segment-level consistency evidence
and evaluation on separate recordings; scalar threshold tuning alone does not
resolve the observed identity problem.

## Window evidence consistency experiment — September 7

A fresh local diagnostic retained 217 masked WeSpeaker window vectors across the
six fixed AMI excerpts, reproducing every prior re-embedding centroid exactly.
Actual audio hashes were checked against the retained reference manifest.
The quantized matcher evaluated each window using the same two enrolled people.

Requiring window agreement reduced ES2002a wrong-name activity from 5.014 to
3.544 seconds, with correct known activity falling from 84.70% to 82.79%.
On ES2002b it only reduced wrong names from 4.233 to 3.829 seconds, while correct
known activity fell from 80.70% to 74.82%. The concrete C-to-D sentence still
passes its window check as D (score .666115). The full report, vectors, matcher
decisions, scripts and hashes are in speaker-accuracy/window-consistency/.

No production rule changed. Window masking is still broader than an individual
turn; this candidate does not solve the observed identity failure. Individual
turn isolation is the next discriminating experiment. These same-day AMI training
recordings and this diagnostic binary do not qualify real-world accuracy.

## Isolated-turn identification experiment — September 7

Fresh local inference covered all 242 detected turns, cropping the actual audio
before feature extraction rather than masking a broader neighboring window.
228 turns produced embeddings; 14 remained explicitly unknown. The quantized
matcher used the unchanged B/D enrollment. The run completed in 12.03 seconds;
input audio hashes match the retained manifests.

Direct turn decisions reduced ES2002b wrong-name activity from 4.233 to 1.172
seconds (outside overlap warnings: 2.147 to .333 seconds), while correct known
activity fell from 80.70% to 71.39%. The known C-to-D turn now remains unknown:
its similarity to D is .095631 rather than the wider window's .666115.
ES2002a also loses correct activity, from 84.70% to 68.51%, despite lower wrong
names. Requiring agreement with the cluster further hurts ES2002b coverage.

No production rule changed. The full report and both candidate arms are retained
under speaker-accuracy/turn-isolation/. Duration-stratified missed-known analysis
and independent recordings are needed before calibration. This development
activity diagnostic is not lexical ownership or real-world accuracy qualification.

## Fragment-loss analysis and contiguous-run isolation — September 7

The prior 242 detected segments include processing-window fragments, not only
natural speaker turns. Many lost correct names have usable three-to-five-second
embeddings below the match threshold. Detailed per-turn attribution and a
non-promoted negative-evidence sweep are retained in turn-isolation/.

Unioning only touching/overlapping same-cluster intervals yields 102 contiguous
runs, with identical active-speaker sets at every original/new boundary and
unchanged overlap warnings. Fresh local inference supports 97 runs. Direct
identification gives ES2002a 82.62% correct known activity and 3.504 seconds wrong
names; ES2002b gives 79.16% correct and 2.135 seconds wrong names (.333 seconds
outside overlap warnings). The known C-to-D sentence remains unknown.

This recovers much of the fragment-isolation coverage loss, but no production
change is justified yet. Contiguous clusters can themselves contain different
real people; the failing sentence's merged run has D similarity .600870.
Freeze this diagnostic candidate for separate-recording evaluation instead of
further tuning on the same examples. Full scripts, decisions, hashes and report:
speaker-accuracy/contiguous-turn-isolation/.

## Frozen separate-recording comparison — September 7

The contiguous-run candidate was frozen by source/binary/enrollment hashes before
obtaining ES2002c results. The evaluation used the first three 180-second excerpts
from the official AMI headset mix, unchanged B/D enrollment and .65 matcher.
Metadata confirms the same people and same-day training-set status: this is a
separate recording, not a different-participant or model holdout.

The candidate processed 26 contiguous runs (24 supported). Compared with the
whole-cluster re-embedding arm, it removes only .650 seconds of wrong names while
losing 9.495 seconds of correct named activity. Wrong names outside overlap
warnings remain 1.093 seconds. Per-person and combined metrics, all raw decisions,
audio/source/binary hashes and post-run model-cache hashes are retained in
speaker-accuracy/ami-third-meeting/.

Do not promote this rule as a general accuracy improvement. Context contamination
is supported by the earlier example, but this frozen result is weaker and leaves
the unwarned error intact. Further investigation must preserve this negative
result and use additional people/day/microphone conditions for qualification.

## Residual-error raw segmentation trace — September 7

Traced exact words and every raw segmentation window of the ES2002c evaluation.
The instrumented run exactly reproduces original segments, embeddings and overlap
warnings. Of 1.093 seconds of unwarned false naming, .770 seconds is A's “Yep”
inside a long B run; the remaining .323 seconds is at predicted run starts.

All 49 raw frame supports touching the interior interjection report the same local
speaker slot, with no change in the surrounding context. This localizes the
observable missed speaker change before global clustering or name matching.
Another centroid threshold cannot recover a boundary absent from segmentation.
Transition timing errors need independent checks rather than a fitted offset.

Evidence, exact intervals, local-slot traces and hashes are retained in
speaker-accuracy/ami-third-meeting/raw-trace/. Next investigate raw segmentation
confidence/context sensitivity with false-overlap and missed-speech costs across
complete recordings. No production changes or readiness claim.

## Segmentation uncertainty diagnosis — September 7

Retained all seven raw powerset scores before argmax over all ES2002c windows.
Every winner and final segment/embedding/overlap output reproduces the original.
At the missed interjection, conditional alternative-speaker probability averages
only .308%; silence accounts for most nonwinning mass (mean 26.48%).

Five fixed exploratory uncertainty cutoffs (5%-40%) all miss the interior error.
At 5%, suppressing names removes 31.597 seconds of correct named activity while
the .770-second interjection remains wrongly attributed. Do not promote a simple
alternative-speaker uncertainty warning. Speech/silence uncertainty must not be
presented as evidence for a different person.

Scores, transformations, full-corpus warning costs, model/binary hashes and report
are retained in speaker-accuracy/ami-third-meeting/segmentation-confidence/.
Next investigate context sensitivity or independently validated segmentation
alternatives. No production or readiness change.

## Fixed segmentation-context offsets — September 7

Evaluated four predeclared ten-second-window offsets (0, 1.25, 2.5, 3.75 seconds)
across all nine excerpts. Continuous, disjoint sample ownership was validated.
Every offset still reports one local slot through the missed ES2002c interjection
and its one-second surrounding context. No offset exposes that speaker change.

Full-recording speech/overlap tradeoffs vary by meeting; no offset consistently
improves detection. Do not change production window alignment based on this run.
Raw frames, all per-case metrics, model/audio/binary hashes and report are under
speaker-accuracy/segmentation-context/. Unannotated activity is not automatically
a false alarm, and this is not full identity or word-ownership qualification.
The next investigation needs an independent segmentation approach rather than
more tuning of this model's window alignment.

## Independent Sortformer third-meeting comparison — September 7

Verified the locally cached Sortformer model against its retained hashes and ran
all three ES2002c excerpts unchanged. Its missed annotated speaker activity is
98.245 seconds versus 28.960 seconds for current segmentation. The targeted A
interjection receives no segment, so avoiding its wrong name is not successful
speaker recognition.

Using the same masked WeSpeaker re-embedding and unchanged enrollment, correct
named activity falls from 93.65% to 79.41% (70.022 seconds lost) while wrong-name
speech falls from 3.242 to 1.112 seconds. This excessive missed-speaker cost
rejects the model/configuration as a replacement. Full anonymous and fixed-name
scores, logs, timelines and hashes: speaker-accuracy/ami-third-meeting/sortformer/.

No production changes. Missed speaker labels are not lost recording audio.
Earlier negative first/second-meeting results remain part of the evidence and
must not be overwritten by a favorable single-example interpretation.

## Sortformer post-processing audit — September 7

Inspected the actual integration: fresh per-recording timeline, .5 thresholds,
no duration filtering or padding. Retained full probabilities on all nine
excerpts and replayed actual DiarizerTimeline at .2/.35/.5. The .5 replay exactly
reproduces every earlier timeline.

The missed interjection has maximum speaker probability .001968. Neither lower
cutoff recovers it. At .2 in ES2002c, missed speaker activity improves by 9.740
seconds while extra activity increases by 13.793 seconds. No threshold change
is promoted. This rules out the configured short-segment filter explanation,
not possible conversion/frontend issues or all other model configurations.

Probabilities, all cases, source/model/binary hashes and report are retained in
speaker-accuracy/sortformer-postprocessing/. No production or readiness change.

## Audio frontend numerical audit — September 7

Inspected pinned conversion sources and the compiled graph input path. The
128-band/no-normalization Swift defaults agree with NVIDIA's streaming-family
configuration; the older offline family is not interchangeable.

An independent NumPy centered FFT/Slaney reference matches shared Swift log-mel
frames closely: maximum absolute difference .000253 on seeded noise and .0000365
on real interjection context. An unaligned 16079-sample fixture exposes 102 Swift
frames versus 101 standard centered-FFT frames. All nine 180-second evaluation
clips are hop-aligned, so this tail discrepancy cannot explain the interior error.

Exact NeMo checkpoint/neural conversion equivalence is still unverified. No
normalization/FFT change or production patch was made. Full source, inputs,
numerical results, pinned documentation and hashes: speaker-accuracy/sortformer-frontend/.

## Reliable manual speaker corrections — September 7

Returned to the production correction path after the model experiments. Rename,
legacy split, merge, threshold and delete actions had remaining swallowed Store
errors. Rename could update the displayed name despite a rejected write; delete
could navigate away despite failure. These now report operation-specific errors.
Displayed rename/threshold values change after successful writes. Merge/delete
navigation is gated on success, and failed split preserves sample selection.

The actual app build and 39 XCTest plus five Swift Testing cases passed without
skips. A new regression injects people-update, delete and insert failures and
checks rejected rename/threshold, merge/delete rollback, failed split without
orphan creation, then successful retries. Evidence: speaker-accuracy/manual-corrections/.

The current console session was rechecked and remains locked. No live UI claim
is made; sheet/alert presentation and user interaction still need on-screen
qualification. General async loading/order issues and recognition-pack propagation
of threshold edits remain separate audits. Model accuracy is still unresolved.

### Speaker threshold propagation — September 7

Verified a production bug: updatePersonThreshold changed the recognition payload without advancing either profile or pack revision. Host afterRevision polling therefore returned unchanged; same-revision client cache admission also rejects altered payloads. The save now atomically updates the threshold and both revisions, rejects invalid finite/range values and missing people, and rolls back on pack publication failure. Clearing the override publishes the default with a new revision.

Actual macOS app build passed. App-linked focused validation passed 40 XCTest and 5 Swift Testing tests with no skips. The regression checks override/reset revisions, invalid and deleted targets, and an injected pack-write failure. Its initial comparison failure came from independently generated timestamps; using a fixed generation time isolates the intended rollback invariant. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/threshold-propagation/. No live UI/client qualification or model-accuracy claim.

Next audit: pack generation timestamps vary on reads while the client rejects unequal encoded payloads at the same revision. Inspect refresh/expiry and canonical transport encoding before deciding whether this is an additional production defect.

### Durable recognition-pack renewal — September 7

Confirmed the timestamp/cache interaction: the Store generated new dates with every read under the same revision; the Host suppressed refresh whenever afterRevision matched, including after expiry; and the client correctly rejected conflicting same-revision payloads. After seven days without a profile edit, provisional matching could remain disabled even with a reachable Host.

Added durable publication through publishedSpeakerRecognitionPack, used by the Host service. The exact payload is retained across reads and reopen. Expiry advances the pack revision and persists the replacement in one transaction; failed publication rolls the revision back. Changed profiles publish at their new revision. v27 creates the publication table and invalidates pre-publication client packs once. The raw configurable snapshot builder remains for local evaluation. Client equivocation checks remain strict.

Validation: actual macOS app build passed; 42 XCTest and 9 Swift Testing tests passed, no skips. Includes file-backed reopen, a second Store connection, exact expiry, injected publication failure, threshold updates, old enrollment migration, and Host afterRevision behavior before and after expiry. The older migration assertion required the intentional additional v27 revision increment. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/pack-expiry/. No live client transport, UI, or improved recognition-accuracy claim.

### Desktop speaker retry evidence — September 7

Verified that needsSpeakerObservations trusted a Host-bound successful marker without binding it to the current capture sidecar. Reprocessing could leave old speaker decisions marked complete. Existing retry IDs also omitted the canonical recording, changed embedding/duration and proposed identity payload, allowing changed requests to collide with an earlier Host idempotency record.

Desktop submission now hashes the exact sidecar bytes it decoded. The completion marker retains that digest; changed or legacy unbound sidecars are resubmitted. Submitted operation IDs additionally bind the digest and complete candidate observation (including canonical ID, quantized embedding, duration, model, source revision and proposal), while identical retries remain deterministic. Existing Host authority checks remain. Full sidecar replacement can intentionally cause resubmission even when voice vectors are unchanged.

Validation: actual app build passed; app-linked 30 XCTest and 27 Swift Testing tests passed, no skips. Added request mutation/identity, stable retry, changed-sidecar, legacy-marker and Codable round-trip assertions. Retained source/binary hashes and logs under build/qualification/production-hardening-2026-09-05/speaker-accuracy/desktop-evidence-retries/. These are software checks; no live transport or UI evidence. The legacy wire observation still uses a numeric speaker index, so Client-to-Host cluster mapping and bound RPC admission remain unresolved. Also audit invalid/duplicate input rows, which can still be skipped or conflict before a complete decision set is persisted.

### Validate complete desktop speaker submissions — September 7

Removed silent invalid-row skipping. The production submission path now prepares and validates the entire observation array before the first submitSpeakerObservation RPC. Negative, zero or overflowing counts/durations/indices, duplicate speaker indices, zero/empty/nonfinite embeddings and invalid model IDs fail the batch; checked integer conversions avoid process traps. Failure flows through the existing deferred speaker error and does not create a successful completion marker. Identical valid batches retain deterministic request IDs.

Actual macOS app build passed. App-linked validation passed 30 XCTest and 28 Swift Testing tests with no skips, including mixed valid/invalid batches, duplicate rows, overflow boundaries, invalid vectors/model, preserved valid fields and stable retries. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/desktop-evidence-validation/. No live transport/UI, cluster-mapping or recognition accuracy claim. Speaker-count completeness against the transcript itself, exact Client-to-Host cluster mapping and bound RPC admission remain open.

### Reproduced cross-device cluster misnaming — September 7

NEGATIVE EVIDENCE: the legacy Store observation entry point can name the wrong canonical voice. A disposable fixture enrolled Alice from a separate recording, published exact current Host evidence for an orthogonal voice at host-speaker-0, then submitted Alice's vector from another device at its numeric speaker index 0. The decision was matched and canonical speaker_names[0] became Alice, while retained current Host evidence still contained the other vector. No manual confirmation existed on the target. This isolates a cluster-mapping defect independently of model error.

Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/legacy-cluster-mapping/. The diagnostic deliberately asserts the unsafe behavior; its successful execution is a reproduced defect, not a correctness pass. It was removed from the ordinary temporary test inventory after retaining source, logs and binary/source hashes. The actual Host service and authenticated transport adapter call this same unbound Store entry point without resolving artifact/cluster identity.

Required next implementation: activate a versioned bound-observation transport contract; validate authenticated producer, adopted origin, canonical PCM identity and currently selected exact processing artifact; resolve local cluster through that artifact's Host projection before applying any label. Keep inference matching separate from authority to name a canonical cluster. Legacy/unmapped observations must retain visible unresolved review state and must not mutate a differently bound current cluster. Preserve valid Host-local identification and exact replay semantics rather than disabling naming globally. Test swapped indices, replaced artifacts, stale replays, manual corrections, successful exact mappings and both direct/relay transport paths. Bound envelope conversions and HarcValidatedSpeakerEvidenceV1 currently exist, but no active RPC carries them; do not describe them as production protection.

### Contain legacy remote cluster bypass — September 7

The processing-artifact service already refuses edge artifacts with unmapped speaker information, but the legacy speaker RPC bypassed that invariant. Host service submission now calls retainUnmappedSpeakerObservation: a v28 table retains complete request, authenticated source, digest, timestamp and pending-review decision separately from usable speaker observations. It changes no canonical labels, links, suggestions, revisions or enrollment pack. Identical same-device replays are durable across reopen; changed payload or source rejects. Existing local Host processing continues using its separate matching path. No global disablement of Host-local naming.

Converted the swapped-voice negative diagnostic into a Host-service correctness regression. It now proves pending review, unchanged canonical voice evidence/name and enrollment pack, exactly one retained unmapped row, zero usable observation rows, durable replay, and rejection of authority/payload substitution. Actual app build passed; 43 XCTest and 4 Swift Testing passed with no skips. Test import needed @testable HarcHost for the internal session fixture constructor. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/unmapped-speaker-boundary/.

This is containment, not completion of cross-device identification. Legacy clients will show unresolved speaker review until a validated mapping path exists. Bound RPC negotiation, selected signed artifact admission, explicit cluster-to-canonical mapping, direct/relay exercises and old-version wrong-name review remain required. Existing historical automatic names are not automatically erased: older observation provenance cannot reliably distinguish Host-local versus remote production. Do not call the product or speaker-accuracy goal complete.

### Host-local generation retry identity — September 7

Host-local observation IDs previously included only canonical recording, numeric speaker index and model. New evidence under the same model could collide with a retained request, and unchanged requests could replay a decision from an earlier generation. The production worker now requires the retained evidence digest for each submitted index and captures the current published recognition-pack revision. The observation identity binds those values plus the complete embedding row. sourcePackRevision is recorded in the submitted observation. Identical generation retries remain stable; changed artifacts, vectors, durations or recognition revisions produce distinct IDs. Legacy helper behavior remains only for callers omitting both new binding arguments; production supplies both.

Validation: actual app build passed, 42 XCTest and 5 Swift Testing tests passed without skips. Added generation/revision changes, stable retry and malformed/incomplete binding checks alongside Host evidence, Store recognition and remote boundary regressions. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-generation-retries/.

Still required: end-to-end worker ordering of local observations and publishHostProcessedProjectionIfNotReady. Observations currently precede final evidence-map installation, so replacement invalidation may erase fresh automatic labels. Bound client RPC and mapping, old-label review and real model accuracy remain open.

### Stage replacement evidence before Host recognition — September 7

Fixed ordering where new automatic names could be erased at final publication when identical transcript bytes carried different voice evidence. The worker now stages the retained evidence map before mutable embedding updates and recognition. That serialized step verifies the exact staged transcript hash and retires old generation names first; ready edge winners are left alone. Final publication sees the same map and preserves fresh names.

Host-local production observations now supply expectedEvidenceSHA256. Inside the same write transaction, before idempotent replay, Store verifies current slot mapping, exact artifact digest, embedding, model, duration and segment count. A replaced generation cannot replay an old decision even when operation bytes are otherwise identical. Legacy remote observations remain on their separate unmapped path.

Actual app build passed; 43 XCTest and 5 Swift Testing tests passed without skips. New Store-sequence regression uses identical words with replacement voice evidence, verifies successful recognition survives final publication, then replaces the evidence again and proves stale replay rejection without a stale name. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-publication-order/. This covers actual Store operations in worker order, not a live worker/daemon/capture run. Cross-device mapping and bound RPC implementation remain open, as do physical qualification and real-world accuracy.

### Host evidence boundary fault checks — September 7

Expanded the Store-sequence regression to verify mismatched vectors, models, durations and segment counts cannot use a current evidence digest, and leave zero durable recognition decisions. A wrong transcript digest cannot clear staged evidence. After an edge result becomes ready, late Host evidence staging, observation replay and final publication cannot overwrite the winning transcript or add names. All 13 selected XCTest passed with no skips; Swift Testing selected zero cases and is not claimed as additional validation. Product source unchanged; reused the last successful app build. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/host-evidence-boundary-faults/. Still not live processing, bound remote cluster mapping, or real-model accuracy qualification.

### Pending-review presentation and mapping prerequisites — September 7

Verified current source propagation: marker dispositions other than matched increase concernCount; the coordinator counts Host-bound concerns; runtime produces SpeakerSync.needsAttention; Settings renders need-review text rather than Observations current. Seven Swift Testing persistence/connection-state tests passed, zero XCTest selected, no skips. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/speaker-review-status/. ioreg still reports the console locked; no rendered pane qualification.

The next cross-device slice must preserve more than numeric turns: TranscriptWordV1 and TranscriptUtteranceV1 carry optional local_speaker_id, but HarcCore.Word stores only text/startMs/endMs. acceptedTranscriptData strips speaker IDs and emits an empty speakers list; canProjectSpeakerInformation protects production by rejecting those speaker-bearing artifacts. ProcessingBundleV1 validates individual cluster strings/ranges but does not establish an artifact-scoped canonical mapping. Do not enable acceptance by merely relaxing that gate.

Implementation order required: (1) define an artifact-scoped mapping tied to canonical recording/audio, authenticated producer and exact bundle digest; (2) preserve word/utterance associations in the local structured projection, with legacy decode compatibility and rendering tests; (3) atomically persist selected mapping with the accepted transcript and invalidate it on replacement; (4) activate negotiated bound observation admission against that selected artifact and mapping; (5) wire desktop producer and test real direct/relay transport, swapped indices, stale artifacts and replay. Legacy unmapped observations must continue as pending review until these requirements hold. This remains unfinished application work, not a completed architecture gate.

### Artifact-scoped cluster map value — September 7

Implemented HarcDomain.SpeakerClusterMap: canonical recording/audio, producer and exact artifact digest bind a deterministic sorted mapping of opaque cluster IDs to indices. Evidence resolution checks all four bindings and membership; numeric-looking IDs are never interpreted as canonical indices. A canonical mapping digest includes all bindings and length-prefixed IDs. Codable decoding uses validation, rejecting duplicate or malformed clusters. Internal spaces are preserved consistently with existing evidence identifiers.

Actual app build and five Swift Testing tests passed, zero XCTest selected, no skips. Tests cover input-order independence, nonnumeric interpretation, serialization, changed recording/audio/producer/artifact, unknown clusters and malformed decode. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/speaker-cluster-map/.

This value is the first implementation slice, not active remote protection or an authenticated mapping by itself. Next integrate map derivation from the complete validated bundle, preserving transcript word/utterance speaker associations in the local projection and persisting selection atomically. RPC admission must independently authenticate the producer and select the current exact artifact before using the map. Legacy remote names remain disabled/pending review until the complete path is implemented and qualified.

### Derive cluster maps from validated bundles — September 7

HarcValidatedProcessingSubmissionV1 now derives a SpeakerClusterMap from every diarization turn, utterance local_speaker_id and word local_speaker_id in the exact authenticated bundle. The caller supplies only the resolved canonical recording ID; audio hash, producer and artifact digest come from validated metadata/bytes. HarcValidatedSpeakerEvidenceV1 exposes that map and its resolved canonicalSpeakerIndex separately from the original request. Numeric observation indices do not select the mapped slot; original request bytes/identity remain available for idempotency.

Actual app build and 13 Swift Testing tests passed, zero XCTest selected, no skips. Added client index 99 resolving to canonical index 0, complete three-source namespace coverage, exact binding assertions and mapping identity change on a different bundle, alongside existing invalid-authority/artifact/duration tests. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/validated-cluster-map/.

No active RPC carries this validated type yet. Current artifact selection remains caller-supplied validation context pending the Store admission transaction; persist the selected map with projection and preserve word/utterance associations before enabling edge speaker acceptance.

### Persistent explicit word attribution — September 7

Added optional Word.speakerAttribution with three meanings: absent preserves legacy midpoint lookup, present with an index resolves to the selected projection's cluster, present without an index explicitly remains unresolved. Negative indices reject at initialization/decode. Serialization preserves the distinction. Word.displayWords preserves equal assignments and marks conflicting SentencePiece continuation assignments unresolved without splitting a lexical word. TranscriptPlainTextRenderer and PromptTranscriptAdapter share resolution and honor explicit words even without timing segments; overlap warnings still suppress named attribution.

HarcStandaloneSpeakerGeneration.applying clears old assignments from both top-level and chunk words before applying replacement diarization, preserving lexical text/timestamps/manual edits. Existing timing-only fixtures remain compatible. Actual app build and 23 selected Swift Testing passed, zero XCTest selected, no skips. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/word-speaker-attribution/.

Next: populate assignments from validated word/utterance IDs during edge projection, preserve them through any word retiming/copy paths, and atomically bind the projected transcript to its selected cluster map. No speaker-bearing edge acceptance or bound RPC has been enabled. The older buildDisplaySegments UI helper still uses a separate timing algorithm; current source search found it populates a state array without any rendering consumer, but audit/remove that obsolete path before claiming all display paths unified.

### Preserve word attribution through copies — September 7

Audited word reconstruction after adding explicit attribution. TranscriptAssembler now carries the field through overlap-prefix trimming and timestamp rebasing; SpeechCoverageRecovery token normalization preserves it on existing words. New recovered words intentionally discard attribution from the separate no-diarization request and use the current timeline. This differs from existing words and from replacing a complete diarization generation, which clears old assignments.

Actual app build and 40 Swift Testing tests passed, zero XCTest selected, no skips. Added overlap removal assertions that prove the trimming branch executed and attribution survived; rebased timing is checked. Existing PCM/Float recovery tests now also assert preservation of original attribution and rejection of a new recovery pass's unrelated speaker index. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/word-attribution-copy-paths/. Edge projector integration, durable selected mapping and negotiated bound RPC remain unfinished.

### Word attribution IPC compatibility — September 7

All existing IPC round-trip checks passed after the Word extension. Added a result-envelope test containing legacy, explicitly assigned and explicitly unresolved words together. The decoded legacy word uses the timing fallback, the assigned word keeps its selected index and the unresolved word stays unknown despite a covering segment. All ten Swift Testing tests passed, zero XCTest selected, no skips. Test-only changes reused the prior app build. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/word-attribution-ipc/. This is envelope serialization, not a live daemon exchange.

Projection design audit also confirms utterance-only input remains a separate gap: accepted wire utterances may carry local_speaker_id without word timings. Populating only Word.speakerAttribution would still discard that association. Preserve an attributed-utterance representation (or an equivalent lossless projection) before relaxing speaker-bearing edge acceptance. Do not treat word-level support alone as complete transcript projection.

### Attributed utterance storage — September 7

Added HarcCore.AttributedTranscriptUtterance with exact text, real start/end range, optional parent attribution and optional fine-grained words. Words without attribution can inherit the parent; explicit assigned or unresolved words override it. No word timings are synthesized when absent. Initializer/decoder validate positive ranges and contained word intervals. SessionTranscript now retains an optional attributedUtterances array, absent in legacy data. Replacement diarization clears old parent and nested-word assignments while preserving text/timings.

Actual app build and 26 Swift Testing tests passed, zero XCTest selected, no skips. Coverage includes utterance-only round trip, per-word overrides, immutable inheritance output, malformed ranges, SessionTranscript round trip and clearing both levels during replacement. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/attributed-utterance-storage/.

Next implement rendering/summary consumption and edge projection population, honoring manual text edits and mixed utterances with/without timed words. Selected map persistence and negotiated bound RPC remain open; this new representation is storage support only and has not enabled speaker-bearing edge acceptance.

### Attributed utterance rendering and summary input — September 7

Shared displayRuns consumes real timed words with parent inheritance/explicit overrides and overlap suppression. Utterances without complete word-text coverage retain their full text; conflicting word overrides suppress a whole-utterance name rather than dropping untimed text. No word timestamps are synthesized. TranscriptPlainTextRenderer and PromptTranscriptAdapter consume these runs. Manual edits take priority over stale attributed data. Untranscribed-audio notices absent from runs remain visible (appended after the runs in this new branch).

SessionPromptAssembler.Part carries attributed utterances and manual-edit provenance; AppDelegate populates them for single and combined summaries. Combined summaries collect speaker names from explicit utterance/word indices as well as timeline segments. Existing legacy paths remain available.

Actual app build and 29 Swift Testing tests passed, zero XCTest selected, no skips. Tests cover full untimed text, partial-word-list preservation, explicit parent/word behavior, overlapping words, manual text, visible failure notices and combined-session prompt propagation. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/attributed-utterance-rendering/. No live model/UI or cross-device publication claim.

Next populate the structure from validated bundle data and persist exact selected mapping with the projection in one transaction before enabling bound RPC admission.

### Mapped edge transcript projection — September 7

acceptedTranscriptProjection derives its cluster map and transcript/turn data from HarcValidatedProcessingSubmissionV1, checks the Host recording PCM identity, and returns data plus map. The active accepted-edge path now uses this projector, but canProjectSpeakerInformation remains unchanged: speaker-bearing artifacts are still not accepted before atomic mapping selection and admission exist.

The local JSON projector now preserves mapped diarization turns, complete attributed utterances, explicit word overrides, and parent inheritance in the flattened compatibility word list. Untimed utterances remain wordless. Missing maps for speaker-bearing input and unknown IDs throw; labels are anonymous canonical indices, never authenticated Person names. Existing unbound speakerless projection remains compatible.

Actual app build and 11 Swift Testing tests passed, zero XCTest selected, no skips. Added mapped sidecar decode/render assertions with a different word speaker and a wordless attributed utterance; verified unknown/missing-map rejection. Existing overlap export and closed acceptance gate tests passed. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/mapped-edge-projection/.

Next persist the map and exact local projection identity atomically in RecordingStore, invalidate selection on artifact/audio/producer replacement, and expose a checked lookup for bound observation admission. Do not relax the acceptance gate yet.

### Atomic selected cluster mapping — September 7

v29 stores the selected artifact cluster map, its digest and the exact projected JSON digest in the transcript publication transaction. Selection invalidates on recording/audio/origin/path replacement. Checked lookup requires a ready live record and unchanged exact projection bytes. Accepted speakerless edge publication now persists its empty map; speaker-bearing acceptance remains closed.

Actual app build, 14 XCTest and 5 Swift Testing tests passed with no skips. Fault checks cover selection-insert rollback, reopening, tampered projection bytes, changed PCM identity and unmapped replacement. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/selected-cluster-map/. This does not yet authorize remote naming; bound observation admission must check selection in the mutation transaction.

### Transactional selected edge admission — September 7

Added a Store admission method for a bound observation plus the Host-validated cluster map. It rechecks the live, ready selected map, exact projection bytes, canonical audio/recording and producer in the same write transaction as the recognition decision. It resolves the opaque local cluster ID into the canonical index, leaving the original complete bound request in the replay hash. The shared observation replay check now also requires the original source device. Selection is checked before replay so an old successful decision cannot be replayed after another artifact takes over.

Actual final app build, 46 XCTest and 5 Swift Testing tests passed, no skips. A file-backed regression maps client index 99 to canonical index 0, rolls back the name on decision-journal failure, reopens and replays unchanged evidence, rejects changed original hints and another producer, then installs another valid artifact using the same cluster label and rejects the stale original replay. Existing enrollment, legacy remote containment and sidecar projection tests pass.

Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/selected-edge-admission/. This remains a trusted Store boundary, not an active remote endpoint. Next connect authenticated retained bundle retrieval and protocol validation to this API, persist bound observation provenance for current review/confirmation, and implement negotiated bound RPC/client submission. Keep speaker-bearing edge acceptance and legacy remote naming closed until those pieces are validated together. No real-model accuracy, live transport, UI or physical qualification is claimed.

### Durable bound decision provenance — September 7

The selected edge admission transaction now retains the immutable exact SpeakerEvidenceSnapshot and stores the complete original bound request plus map digest alongside its observation decision. Migration v30 adds the provenance journal with an immutable-update trigger and cascading deletion through the observation or retained recording evidence. Earlier migrations are unchanged. Exact replay validates the request bytes, map digest and decoded retained snapshot, after the existing selected-artifact and producer checks.

The final actual app build and 46 XCTest plus 5 Swift Testing tests passed, no skips. The file-backed admission regression injects failure at the final provenance insert and verifies no name, observation decision or new snapshot survives. Reopening preserves exact original client index/evidence; ordinary SQL cannot mutate either provenance or snapshots. Disposable-fixture corruption bypasses those triggers and verifies replay refuses corrupted request and voice bytes. Historical evidence survives artifact replacement; deleting the fixture recording removes dependent provenance without a foreign-key failure.

Two intermediate failures are retained: the initial corruption injection was blocked by the existing snapshot immutability trigger; a subsequent deletion test caught a misplaced foreign-key edit. The test now verifies the trigger before deliberately removing it only in its disposable database. The foreign-key edit was corrected in v30 and the earlier migration restored and compared with the previous retained source. Final logs and source/application hashes: build/qualification/production-hardening-2026-09-05/speaker-accuracy/bound-speaker-provenance/.

This closes retention and replay integrity, not current review/confirmation or authenticated transport integration. Next install and resolve current edge evidence for the selected canonical slot with generation-safe review tokens, then connect authenticated retained bundle retrieval and negotiated bound submission. The processing service currently keeps private artifact paths in HarcProcessingPreparedEffect; selected map storage does not yet expose an authenticated selected bundle locator. Do not enable speaker-bearing edge acceptance until the full chain is verified. No improvement to real-model accuracy is claimed by these Store tests.

### Current edge voice review and correction — September 7

Bound edge admission now installs the exact current snapshot at the Host-resolved canonical index in the decision transaction. A changed snapshot archives and retires only that speaker slot's assignment, suggestions and mutable embedding; other speaker slots and historical confirmed evidence remain intact. The recording is reloaded before matching, so retired names cannot be accidentally copied back. Current evidence changes advance the Library revision even without an automatic match.

The existing opaque HostSpeakerReview path now also resolves current edge snapshots through the checked selected cluster map. A selected map without voice evidence refuses legacy editing. An edge snapshot whose map disappears cannot masquerade as Host/local evidence. Exact bound replay must still point to the current snapshot; replacing voice evidence within the same processing artifact invalidates the older replay.

Actual app build and 47 XCTest plus 5 Swift Testing tests passed, no skips. The new two-speaker test confirms one voice, injects an assignment-history failure and proves the complete prior review remains unchanged, replaces that voice with a nonmatch, rejects stale confirmation and replay, preserves the other speaker's name/evidence, retains historical enrollment, then reopens and creates/confirms a person for the replacement voice. Existing provenance rollback, corruption, deletion, enrollment and legacy remote containment tests pass. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/current-edge-review/.

This is Store-level correction support, not on-screen or remote qualification. Next establish an authenticated selected-bundle locator and connect retained signed metadata/bundle validation to negotiated bound RPC admission. Speaker-bearing edge acceptance remains closed until the actual client/Host transport and review chain is validated. Real-world voice identification and production readiness remain open.

### Selected authenticated artifact locator — September 7

Migration v31 stores a Host-local reference to retained signed metadata and bundle files, including exact SHA-256 values, under the selected cluster map. The authenticated processing submission path now supplies this reference to applyAcceptedEdgeTranscript. It commits with transcript/map selection and cascades away when that map is replaced or invalidated. Selection verifies file bytes and the bundle-to-map binding. The checked lookup requires a ready, current map and rehashes both files. The reference has no Codable conformance and must never be a network DTO; consumers must independently hash the bytes they actually decode after lookup.

Actual app build and 48 XCTest plus 5 Swift Testing tests passed, no skips. A disposable file-backed storage fixture proves final-reference-insert failure rolls back transcript/revision/map, reopening preserves the reference, altered metadata or bundle bytes reject lookup, a mismatched bundle cannot replace the selected reference, and unmapped transcript replacement cascades the reference away. This fixture is explicitly storage-only and does not claim signed-object authentication. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/selected-artifact-source/.

Next: add explicit selected-historical processing validation. HarcValidatedProcessingSubmissionV1 currently requires initialCommandAcceptance and rejects historicalEvidence, correctly preventing general historical verification from granting new submission authority. Preserve that default while adding a distinct revalidation path used only after resolving exact durable selection. Connect current session authority, retained metadata signature/bundle validation, bound evidence membership and Store admission through negotiated RPC. Legacy map selections with no source reference must not acquire remote naming authority through a client-supplied hash or path.

Additional source audit finding: HarcHostProcessingArtifactService.persistExact returns immediately for matching existing files without retrying synchronization; artifactPaths uses FileManager directory creation without ancestor durability barriers. Harden these retry/publication barriers before qualification. Current selected-file lookup detects missing/changed derived files but does not prove power-loss durability. Speaker-bearing edge acceptance remains closed; no live transport, UI or model accuracy qualification is claimed.

### Processing artifact persistence retry barriers — September 7

Closed the persistence gap identified during locator work. An exact-byte retry now repeats file fsync, parent-directory fsync and F_FULLFSYNC instead of returning after a content comparison. Both first publication and retries use the same final barrier path, preserving O_NOFOLLOW checks. Artifact directory creation uses HarcCore.DurableFileIO so a failed parent barrier is retried. HarcHost now declares that direct dependency; xcodegen generation completed without a project diff.

Actual app build, 18 XCTest and 7 Swift Testing tests passed, no skips. The new Host persistence tests inject two consecutive final barrier failures and prove matching existing bytes cannot bypass either failure, then execute the actual OS barriers successfully. They also verify conflict preservation, successful new publication/retry and symlink rejection. Existing directory parent-barrier fault tests, selected evidence storage tests and accepted sidecar tests passed. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/processing-artifact-durability/.

These checks prove software behavior and accepted OS barriers, not physical power-loss durability. Continue with explicit selected-historical processing revalidation, preserving the default initialCommandAcceptance requirement, followed by current session authority and negotiated bound submission. Speaker-bearing edge acceptance remains closed; real-world identification accuracy remains unqualified.

### Distinct retained processing revalidation — September 7

Added HarcValidatedRetainedProcessingArtifactV1 as a separate value from HarcValidatedProcessingSubmissionV1. It requires historical authentication plus exact selected signed-object and bundle SHA-256 values. These hashes must come from the Host's durable selection, not the requester; the type validates bytes, not the fact of Store selection. The live constructor still requires initialCommandAcceptance and cannot accept the retained type. Both constructors share the existing body validation for exact length/hash, canonical frames, artifact/origin/audio/protocol and coverage consistency.

Retained artifacts can derive the same opaque cluster map and feed the same speaker membership validator through a distinct overload. Canonical identity, producer, current artifact hash, diarization membership and duration checks are shared, with no weakened historical branch.

Actual app build and 17 Swift Testing tests passed; zero XCTest selected, no skips. Added valid retained revalidation, wrong purpose, missing/wrong selected hashes, changed bundle bytes even when the supplied digest is changed to match, invalid canonical frame limits and signed audio/header mismatch checks. Existing historical-to-live rejection remains passing. Speaker tests run the same invalid cluster, excessive duration, producer, artifact and canonical-recording inputs through retained validation, and verify client index 99 still resolves to canonical index 0. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/retained-processing-validation/.

Next implement the Host service path: require current speakerObservationWrite session authority and Library/recording ownership; resolve the selected source locally; perform bounded reads and hash the actual consumed bytes; historically authenticate the retained metadata with the producer key; validate the bundle/evidence; then call transactional selected edge admission. Wire negotiated RPC/client submission only after that path has authenticated service tests. Speaker-bearing acceptance remains closed. No live transport, UI, physical or real-model accuracy qualification is claimed.

### Host bound speaker admission service — September 7

HarcHostProcessingArtifactService.submitBoundSpeakerObservation now requires current speakerObservationWrite registry authority, matching Library and recording ownership, and the authenticated producer. It resolves the selected source locally, reads metadata and bundle with protocol byte caps, historically authenticates the signed metadata, verifies exact selected hashes and Library/Host authority bindings, and runs shared bound speaker validation. It rechecks current permission after file IO. Store admission rechecks the selected signed-metadata reference inside the decision transaction as well as the cluster map, closing replacement with different metadata for the same bundle.

Actual app build, 20 XCTest and 7 Swift Testing tests passed, no skips. The new service fixture uses a cryptographically signed processing artifact and a seeded current registry grant; it proves scope denial without retained evidence, successful canonical index 0 admission from client hint 99, replay, and historical revalidation after the original submission window expired. It rejects tampered metadata, stale metadata selection with the same bundle, and invalid signed metadata even when stored hashes match. Separate file-read tests cover exact limits and one-byte overflow across a 64 KiB block boundary. Existing Store evidence and protocol binding tests pass. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/bound-speaker-service/.

The fixture explicitly seeds the authenticated session and selects a speaker-bearing artifact through the trusted Store seam using validated signed data. It does not qualify session establishment, acceptance-policy activation, or network transport; production speaker-bearing edge acceptance remains closed. Next add negotiated wire/client support and route it to this service, retain legacy pending-review behavior, and exercise real authenticated transport with the selected artifact and review chain. Real-world identification accuracy, UI and physical qualification remain open.

### Negotiated bound wire request and Host routing — September 7

Added field 3 bound_observation to SubmitSpeakerObservationRequestV1; existing field 2, RPC count and enums remain unchanged. The new required feature is harc.speaker-evidence.v1. Both the request constructor and decoder require negotiated support; bound wire requests also require critical field 3 and the required-feature marker. Exactly one payload form is permitted. Declaring bound evidence while carrying only legacy data rejects rather than downgrading. Older readers reject unknown critical/required fields.

HarcLibraryGRPCServiceAdapterV1 reads negotiated feature IDs from the authenticated session, validates the request form and routes bound data to HarcHostProcessingArtifactService. Bootstrap factory passes that service through. Legacy requests retain the unmapped pending-review path. The compatibility layer recognizes the new required feature, but production capability advertisement and desktop submission are unchanged, so this does not activate normal bound traffic or speaker-bearing edge acceptance.

The schema checksum guard initially flagged the intentional field addition; the reviewed library schema hash was refreshed and the guard now passes with 7 schemas, 6 services, 27 RPCs and 29 enums. Swift wire output was generated by the existing build plugin. Final actual app build, 2 XCTest and 23 Swift Testing tests passed, no skips. Coverage includes serialized bound and unchanged legacy payloads, absent negotiation in construction/decoding, missing critical/feature markers, mixed or missing payloads, missing evidence, downgrade rejection, and simulated older-reader rejection. Existing capability/domain conversion and bound/legacy service tests pass. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/bound-speaker-wire/.

Adapter routing compiled but has not yet been exercised over gRPC. Next integrate desktop evidence construction from the exact submitted artifact, enable feature advertisement only with that client path and verify direct pinned-TLS and relay transport with authenticated sessions. Do not enable speaker-bearing acceptance based only on these conversion/service tests. Real-world identification, UI, physical and production readiness remain open.

### Desktop processing generation binding — September 7

The desktop audit found that processing submissions and completion markers were bound to recording/grant or Host but not the sidecar generation. Added optional sidecarSHA256 to the persisted submission and processing marker. Submission generation hashes exactly the sidecar bytes decoded for the bundle. The coordinator reads those bytes once, passes them to the builder and uses a generation-specific protected submission path. Matching retries reuse that path; changed sidecars get a different path while old signed bytes remain untouched. Loaded submissions must match the requested generation. Completion checks now require both Host and sidecar bindings; legacy missing hashes are stale.

Actual app build and 37 Swift Testing tests passed, zero XCTest selected, no skips. Disposable-file regression covers initial pending state, matching completion, changed transcript becoming pending again, legacy completion refusing to suppress work, current completion, missing Host binding, stable same-generation paths, changed-generation path separation, reopening unchanged submission bytes and legacy submission mismatch. Existing desktop framing, speaker observation identity and file tests passed. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/desktop-processing-generation/.

This closes a prerequisite for exact bound client evidence; it does not yet construct or send bound desktop observations. Next consume the exact current submission and sidecar together, authenticate their producer/artifact binding and construct evidence for the bundle's opaque cluster IDs. Do not lower a claimed embedding duration merely to satisfy bundle membership: the bundle's diarization projection excludes overlap and actual embedding inputs must agree with those retained ranges. Verify expired persisted submission/retry behavior and lifecycle cleanup of historical submission files before release. Feature advertisement, speaker-bearing acceptance and live transport qualification remain closed/open as previously recorded; real-world accuracy remains unqualified.

### Desktop exact bound speaker batch — September 7

The desktop constructor now authenticates the producer's exact signed metadata and bundle against the exact sidecar generation, recording, canonical audio, Library and Host authority before constructing a batch. Each observation carries the bundle's opaque cluster identity and retained voice evidence. Shared validation rejects cluster or duration mismatches, including overlap-excluded turns. The complete batch must validate before it can be returned for transport. An empty embedding list cannot bypass recording/audio checks. Bound operation identities include the exact bundle hash, so identical retries retain their identity and new artifacts receive new identities; existing legacy identities are unchanged.

Actual Debug app build succeeded. The final app-linked run passed 27 Swift Testing tests, zero XCTest selected and no skips. The signed fixture covers valid batch/retry, changed artifact identity, sidecar mutation, wrong producer/Library/audio, altered bundle, missing generation binding, unknown cluster, excessive duration, zero vector and a mixed valid/invalid batch. Evidence is retained under build/qualification/production-hardening-2026-09-05/speaker-accuracy/desktop-bound-speakers/. These are synthetic cryptographic and boundary fixtures, not real-model accuracy measurements. The constructor is not yet called by the live sender.

Live retry audit: durableProcessingSubmission returns the cached signed command without checking its lifetime. Host submit performs initialCommandAcceptance before its exact-replay lookup; therefore an expired command cannot be recovered by that replay branch. A renewal must preserve historical signed bytes and use a new artifact/operation identity rather than overwrite metadata at the old artifact path. Before implementing renewal, account for an accepted response lost before the client marker and for Host-selected derived processing. Do not weaken initial-command expiry or mistake historical evidence authentication for renewed command authority. Speaker completion must follow the selected artifact, not merely successful upload. Feature advertisement and speaker-bearing edge acceptance remain disabled; transport, UI, physical and actual voice-identification accuracy remain open.

### Expired desktop processing command renewal — September 7

The live durableProcessingSubmission path now authenticates the cached command with the installation public key and checks its exact bundle length/hash before reuse. Within the signed lifetime it retains exact bytes and repeats synchronization. At expiry it copies the exact persisted envelope to a content-addressed archive and completes file, parent and drive-cache barriers before permitting a fresh signed artifact and operation in the generation slot. A retry interrupted between archive and replacement verifies the existing exact archive and repeats barriers. New command publication also completes these barriers before transport. Corrupt archives, wrong signatures and changed bundle bytes fail without replacing the generation slot. Source/archived symlinks are rejected. The Host's initial-command deadline checks remain unchanged.

Final actual Debug app build passed; 27 Swift Testing tests passed, zero XCTest selected, no skips. Added signed-fixture checks for reuse one millisecond before expiry, renewal exactly at expiry, wrong key, exact archive/current byte retention, interrupted-renewal retry, conflicting archive and tampered bundle. The first test run exposed a disposable test URL comparison issue caused by temporary-directory normalization; selecting the archive by its explicit filename prefix corrected the fixture and the final run passed. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/desktop-command-renewal/.

This changes the live client retry path, but tests do not yet exercise a lost Host response over transport. A new submission after such a loss is a new command/artifact, not an expired exact replay; old signed evidence remains local. Host selection and bound speaker completion must be verified together during integration, including Host-derived processing and renewed artifacts. Automatic archive retention/cleanup is still open. Negotiated bound sending, speaker-bearing edge acceptance, actual identification accuracy, UI and physical qualification remain open; this is not a production-readiness claim.

### Selected artifact in authenticated processing status — September 7

Added optional selected_edge_bundle_sha256 (field 7) to ProcessingStatusV1. Host status resolves its currently selected edge source and verifies the retained signed-metadata and bundle files before returning the bundle digest. Both origin and canonical recording lookup routes retain current recordingReadOwn authority checks. The gRPC adapter serializes only the digest; no local paths are exposed. Because SubmitOwnArtifact responses contain this status, replay and accepted-submission responses can now identify current selection without interpreting their disposition as an artifact identity.

The digest is advisory, not naming authority or an atomic guarantee with the rest of the status snapshot. Bound admission still reauthenticates consumed bytes and rechecks the current selection inside the naming transaction. Missing selection is represented by field absence; clients must not infer permission for numeric legacy mapping. The desktop sender does not yet consume this field.

Actual Debug app build, 17 XCTest and 9 Swift Testing tests passed, no skips. The Host signed fixture checks absent selection, both lookup routes returning the selected digest, and rejection after selected metadata bytes change. Protobuf tests cover absence and exact digest round trip. Existing selected-evidence Store and desktop bound-batch/renewal checks passed. The intentional processing schema hash was refreshed; the schema guard passes with 7 schemas, 6 services, 27 RPCs and 29 enums. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/selected-artifact-status/.

Next consume the selected digest in desktop completion and bound submission, preserving the exact selected signed artifact even after command expiry. A Host-derived or absent selection must remain a separate processing state, not trigger legacy naming or false speaker completion. Feature advertisement, speaker-bearing edge acceptance and bound transport qualification remain closed; actual voice-identification accuracy and UI/physical gates remain open.

### Negotiated desktop bound delivery — September 7

Connected the live desktop sender to the bound constructor behind harc.speaker-evidence.v1 negotiation. It reads the retained submission without renewing its command lifetime, authenticates the complete sidecar/bundle batch, queries authenticated processing status and requires matching canonical recording, origin, canonical audio and selected bundle digest. It constructs all bound requests before sending any. Missing or different selection defers delivery through the existing recovery path; an error in this negotiated branch never falls back to legacy. Unnegotiated peers retain the existing durable unmapped pending-review behavior.

Speaker completion now records the bound artifact digest. Processing completion retains the selected digest reported by the Host. Local completion checks reject missing/different processing selection, changed Host or changed sidecar. This observes selection recorded locally; independently changed Host selection still requires a status refresh. A Host-derived selection is currently deferred rather than treated as completed local speaker delivery. That state needs full integration qualification before feature advertisement.

Final actual Debug app build passed. Focused app-linked tests passed 1 XCTest and 28 Swift Testing tests, no skips. Added matching/missing/changed selected-artifact status, wrong canonical recording/audio, completion digest mismatch and Codable reopen checks. Existing signed whole-batch, command renewal, protocol negotiation and Host selected admission tests pass. The first app build caught a Host trust wrapper type mismatch; explicit AdoptedTrustTuple conversion corrected it before the successful final build. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/desktop-bound-delivery/.

The private live sender compiled but has not yet been exercised over a real connection; helper/service tests do not prove the complete sender loop, lost-response behavior or partial-batch retry. Direct pinned-TLS and encrypted-relay regression plus an authenticated bound round trip remain required. Feature advertisement and speaker-bearing edge acceptance are still disabled. Do not enable them until Host-derived processing, evidence duration/overlap handling and completion refresh are qualified together. Real-world voice identification, UI and physical gates remain open.

### Bound speaker round trip through direct TLS and relay emulator — September 7

Extended PairingLifecycleLoopbackIntegrationTests to negotiate harc.speaker-evidence.v1 in the fixture capability policy/offer and pass the shared processing service into the Library adapter. Production feature advertisement is unchanged. The existing lifecycle still pairs, opens authenticated sessions, checks Host revocation, forgets and re-pairs using the same key. Processing submission/replay now verifies selected-artifact status presence and digest for accepted edge output and absence for speaker-bearing output deferred to Host.

After proving the speaker-bearing acceptance gate remains closed, the fixture historically authenticates the exact signed artifact, derives its map and transcript projection and explicitly selects its retained files through the trusted Store seam. It then queries selection over gRPC, submits a bound speaker observation and retries the exact request. Client numeric hint 99 resolves to canonical speaker 0 with the exact retained voice evidence; no current evidence appears at index 99. A changed retained metadata file causes bound replay to reject over the connection. No known-person match is asserted; the fixture has no enrolled person and uses a synthetic embedding.

The isolated app-linked suite passed over direct pinned TLS (1 Swift Testing test, zero XCTest, no skips), then passed over the local encrypted relay emulator (the same 1 Swift Testing test, zero XCTest, no skips). The direct run compiled the updated fixture; the relay run used that exact known-good test binary with --skip-build and HARC_RELAY_EMULATOR_ORIGIN set to the disposable emulator. The fixture's environment branch routes the pinned gRPC connection through RelayEmulatorTunnel with no fallback. Wrangler 4.120.0 used --local and owned temporary state. The runner removed its opt-in marker, stopped its emulator and removed temporary state after completion. These are app-linked executions of the script-selected suite, not literal runs of the repository scripts against a freshly compiled root SwiftPM package. Production app sources were unchanged this slice; the previously successful Debug app binary was reused.

Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/bound-speaker-transport/. This closes the fixture's bound wire/adapter/session round trip through both local paths. It does not exercise HarcDesktopClientTransferCoordinator end to end, lost acknowledgement or partial-batch recovery, normal speaker-bearing acceptance, real secondary Macs, two physical networks, public deployed relay, model accuracy or UI. Next qualify coordinator recovery and Host-derived selection/refresh semantics before activation; actual voice-identification errors remain unresolved.

### Bounded refresh of completed bound speaker evidence — September 7

Found that fully matched markers never became due and successful queue drains cleared the only timer. Bound completions now carry a six-hour review deadline whether or not decisions contain concerns. Older bound markers without an explicit deadline derive one from acceptedAt; legacy no-concern markers retain their old behavior. Inventory after launch and successful drains reconstruct the earliest future deadline from committed, unblocked outboxes with retained masters and matching Host bindings. Scheduling a review does not increment failure backoff; failed review inventory uses the existing bounded retry path.

submitProcessingArtifactIfPresent now checks the existing Host/sidecar-bound processing completion before loading or renewing a command. This prevents a speaker-only review from creating a new processing artifact after command expiry. The bound sender still reads/authenticates historical bytes, queries current Host selection and refuses mismatches before sending. Host-derived or changed selection currently defers and remains subject to recovery; this is not complete Host-derived speaker reconciliation.

Actual Debug app build passed. App-linked focused validation passed 18 Swift Testing tests, zero XCTest selected, no skips. New tests cover no-concern bound deadline, the boundary immediately before and at six hours, reopening overdue evidence, resetting the deadline after refresh and preserving legacy behavior. Existing unresolved-review, failure-backoff, generation marker, selected-evidence and renewal tests pass. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/bound-speaker-refresh/.

The scheduler and processing short-circuit compiled in the actual app; the tests cover deadline/persistence helpers and generation predicates, not an observed six-hour timer or the entire private coordinator. Wake/relaunch timing, remote changes after local cleanup, Host-derived selection, lost responses and partial batches still need coordinator-level qualification. Feature advertisement and speaker-bearing acceptance remain closed; transport fixture evidence from the preceding slice does not close real-world identification, UI or physical gates.

### Actual coordinator deadline, shutdown and restored backoff — September 7

Added HarcDesktopSpeakerReviewCoordinatorTests to exercise the actual desktop coordinator instead of only marker predicates. It seeds a disposable adopted Client Store, committed upload/receipt state, retained master and matching processing/speaker markers. The fixture uses a one-second persisted review deadline. Calling resumePending first reports no pending speakers; the scheduled inventory then runs and reports exactly one pending speaker with zero pending processing. Shutting down before expiry prevents that later inventory. With durable failure backoff already saved, resumePending restores it and does not let the earlier speaker review deadline trigger inventory.

The app test target now shares the existing ClientStoreFixtures.swift file. Its fixture accepts an optional software signing key so the coordinator identity matches the adopted device; all existing callers retain the same default behavior. The shared file uses test-only HarcTransfer import access for its package-internal trust constructors. Production access control was not widened. xcodegen regeneration and the actual Debug app build passed.

App-linked validation passed 10 Swift Testing tests covering the new actual coordinator test (three scenarios) plus existing deadline/backoff cases, then 6 receipt persistence regressions passed; zero XCTest selected and no skips in either run. The copied receipt regression uses only a testable import adaptation for the external app-linked harness; its production source file was not changed. Initial compilation caught missing try in the new fixture and required test-only package access; both were corrected before the successful runs. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/speaker-coordinator-timer/.

These tests deliberately use test-only seeded trust and receipt evidence with no Host route. They qualify coordinator timer scheduling, cancellation and persisted failure-backoff precedence, not pairing/authentication or delivery. The previously recorded transport fixture separately covers authenticated bound RPCs. Connecting the full coordinator to that transport, Host-derived selection/reconciliation, partial-batch/lost-response recovery and actual sleep/wake endurance remain open. Feature advertisement and speaker-bearing edge acceptance remain disabled, and real-model identification, UI and physical accuracy gates remain unresolved.

### Actual desktop sender over TLS/relay and durable batch retry — September 7

Extracted reusable pairing and relay support under Tests/HarcHostTransportTests/Support. The original transport suites retain their test wrappers; the app test target includes only shared support and the existing recording-transfer test double, not duplicate gated transport suites. Added an optional callback after explicit fixture artifact selection. HarcDesktopBoundSpeakerTransportTests uses that callback to call the actual coordinator speaker-delivery method through the authenticated pinned connection. The method is module-internal for app test access; production transport authorization is unchanged.

The first actual sender run exposed a real retry defect: after initial delivery advanced the Host's recognition-pack revision, loss of the local completion marker caused the client to construct a different operation ID and admit another Host decision. The earlier separate constructor/transport tests did not catch this interaction. Added HarcDesktopBoundSpeakerBatch, persisted with file/parent synchronization before any bound RPC. Retry revalidates Host/sidecar and exact acoustic evidence against the newly authenticated proposed batch, but retains the original operations and pack-bound request fields. Unfinished batches have no retry expiry; completed batches remain replayable during their six-hour review interval. After all responses succeed, batch completion persists before the completion marker. Corrupt bindings and symlink journals reject; existing journals repeat barriers before reuse. Marker source-pack provenance now comes from the actual sent observations rather than a newly fetched pack.

Final actual Debug app build passed. The actual sender test passed directly over pinned TLS and again through the local encrypted-relay emulator (1 Swift Testing test each, zero XCTest, no skips). The test explicitly observes a newer cached pack revision while replay retains the original operation and the Host bound-decision count remains unchanged. It also proves that a mixed valid/invalid batch and absence of selected Host processing create no additional decisions and do not overwrite the existing completion marker. The fixture restores selected processing before its existing tampered-metadata replay rejection. Eleven additional Swift Testing regressions passed, zero XCTest and no skips, covering unfinished batch reuse after seven hours, completed retry, new review after six hours, mismatched sidecar rejection and the actual coordinator deadline/cancellation/backoff scenarios.

Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/actual-speaker-sender/. These are dirty-tree app-linked tests of the actual sender method and real transport; they do not yet drive the complete outbox transfer/route-opening loop. Missing local completion is exercised by deleting the disposable marker after acceptance, not by dropping a network packet. A partial multi-observation network interruption, batch barrier fault injection, Host-derived recognition reconciliation, deployed two-network behavior and local journal retention/cleanup remain open. The fixture uses synthetic voice evidence and no enrolled real person. Production feature advertisement and speaker-bearing acceptance remain disabled; actual identification accuracy, UI and physical gates are unresolved.

### Two-speaker recovery after a committed RPC reply failure — September 7

Extended the actual sender fixture to include two nonoverlapping speaker turns and a test-only SpeakerReplyFailureService. This wrapper forwards every Library RPC to the real adapter; when explicitly armed, it waits for authenticated bound admission to return, then returns one gRPC unavailable error instead of the successful reply. The Host decision has already committed. Production composition still constructs the real Library adapter; only the factory's stored Library service type and internal test composition seam now use the generated ServiceProtocol so a test wrapper can be registered. No fault hook or altered acceptance policy was added to the production adapter.

The actual sender test submits a two-observation batch and proves that the injected failure occurred exactly once, exactly one Host decision exists, the durable batch remains unfinished and the previous completion marker is unchanged. It then shuts down that coordinator, reopens the transfer and Library-cache databases and constructs another coordinator. Retrying through the authenticated connection replays the first operation and adds only the second decision. Both original operation IDs survive, the batch becomes completed and the final marker contains exactly those operations. Existing pack-revision replay, invalid-batch, absent-selection, pairing/revocation/re-pairing and retained-metadata rejection assertions remain in the fixture.

Actual Debug app build passed. The isolated app-linked test passed over direct pinned TLS and again over the local encrypted-relay emulator (1 Swift Testing test each; zero XCTest selected, no skips). The emulator runner used the just-verified test binary with --skip-build, owned temporary state and cleanup. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/partial-speaker-reply/.

This closes the actual sender's tested partial-batch recovery under an ambiguous post-commit RPC error and coordinator/store recreation. It does not simulate dropped TCP packets, expiry/re-authentication of the session, OS process termination or replay through a newly opened connection. The complete outbox transfer/route-opening loop, batch synchronization fault injection, Host-derived recognition reconciliation, journal cleanup and physical network/sleep/wake qualification remain open. Fixture selection and synthetic embeddings do not qualify normal production speaker acceptance or real-world voice-identification accuracy; activation remains disabled.

### Pending batch recovery with a new connection and authenticated session — September 7

Extended the shared loopback fixture with a fresh-connection factory. It creates another pinned connection, negotiates capabilities against the validated adoption and opens a new signed-challenge session. In relay mode it opens a new RelayEmulatorTunnel instead of reusing the old tunnel. Failed connection/session setup closes only the newly owned resources. The existing retained-metadata corruption check now runs before the app callback, then restores the exact fixture metadata, so a callback may close the original channel without weakening that rejection test.

After the existing post-commit reply fault, the app test shuts down its first coordinator, gracefully closes the original channel and verifies stoppedGracefully. It requires a different connection object and different session credentials, reopens both client databases, creates another coordinator and resumes the same durable batch through the fresh authenticated connection. The Host count increases only for the missing observation, both original operation IDs survive and completion remains conditional on the full batch succeeding. Both old and new connections/tunnels are cleaned up.

The isolated app-linked actual sender test passed over direct pinned TLS and again through the local encrypted-relay emulator (1 Swift Testing test each; zero XCTest selected, no skips). Only test/support and documentation sources changed; these tests reused the preceding successful Debug app build. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/fresh-speaker-session/.

This adds verified fresh-session and replacement-connection recovery to the actual sender path. It remains a post-commit RPC error followed by an orderly connection close, not dropped TCP packets, expired/revoked credentials, or whole-process termination. The full outbox/route-opening loop, Host-derived recognition reconciliation, batch barrier failure injection, journal cleanup, physical network/sleep/wake qualification and real-world identification accuracy remain open. Normal feature advertisement and speaker-bearing edge acceptance stay disabled.

### Bound-batch synchronization failure and retry — September 7

Added a synchronous test seam for the final journal barrier while preserving DurableFileIO.synchronizeFileAndParent as the production default for initial persistence, reuse and completion. Tests inject two consecutive failures after first publication: both calls throw even though the exact pending journal exists after the first attempt. A subsequent real OS synchronization succeeds and returns the same observations without rewriting those bytes.

The completion case writes completedAt and injects a barrier failure, then injects another failure while reopening that existing completed journal. Both calls throw. A successful actual barrier retry returns the original completed batch with unchanged observations and bytes. Thus file existence and a serialized completion timestamp cannot bypass the final barrier. The sender's existing call ordering still persists the batch before requests and persists batch completion before its completion marker.

Actual Debug app build and 11 app-linked Swift Testing tests passed, zero XCTest selected and no skips. Existing coordinator timer/cancellation/backoff, review deadline and durable operation-identity tests remain passing. Evidence: build/qualification/production-hardening-2026-09-05/speaker-accuracy/speaker-batch-barriers/.

This is deterministic failure injection at the journal persistence helper plus accepted real OS barriers. It is not a physical power-loss, full-disk or storage-removal drill, and the injected closure is not threaded through the live sender's network test. The previously verified sender/transport ordering and reconnection tests are separate evidence. Host-derived recognition reconciliation, full outbox/route recovery, journal retention/cleanup and real-world speaker accuracy remain open; production activation stays disabled.

### Revalidate Host outcome speaker inventory on read — September 25

A new Store regression damaged only the persisted outcome inventory while retaining the correct transcript digest. Reads incorrectly accepted all three cases: an omitted speaker, a substituted speaker, and an extra speaker. Publication already checked inventory, but the read path skipped it when no transcript bytes were supplied. Validation now loads the selected transcript when needed, hashes those exact consumed bytes and checks every cluster against the decoded speaker inventory before returning the outcome. This prevents a damaged outcome from suppressing missing-evidence concerns or inventing speakers.

The regression reproduced three failures before the fix. The corrected Store/domain/protocol run passed 17 XCTest and 14 Swift Testing cases without skips, including the valid-restoration control. Evidence and before/after source hashes are retained under build/qualification/host-speaker-inventory-20260925/. The current-source build needed a scratch directory outside synced Documents because generated MLX bundles repeatedly acquired FinderInfo that blocked signing. This is unshipped package validation, not live Client/Host delivery, physical durability or speaker-identification accuracy.
