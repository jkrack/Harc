# AGENTS.md

Guidance for Codex when working in this repository.

## Project

**Harc** is a local-first macOS speech-to-text app. It lives in the menu bar,
captures long meetings, transcribes on Apple Silicon, stores recordings and
transcripts in a searchable library, and prepares context for LLM paste workflows.

The repo is no longer greenfield. Treat the current SwiftPM/Xcode project as
authoritative.

## Hard Constraints

Flag the user before violating these product decisions.

- **Private inference only.** No cloud STT, no third-party audio processing,
  and no external telemetry. Standalone Harc keeps content on the current Mac.
  The authenticated adopted host is the only automatic Harc-managed
  synchronization or processing destination. A user may explicitly export a
  local recording through a system share/export surface after Harc clearly
  identifies that the chosen destination is outside the adopted-host trust
  boundary; no unattended export or implicit cloud destination is allowed.
- **Apple Silicon first.** The package currently targets macOS v26 in
  `Package.swift`; verify deployment-target changes against `project.yml`.
- **Menu bar resident.** The primary recording surface is the status item and
  compact panel, with the Library as the fuller workspace.
- **Long-form reliability over live latency.** Durable audio and recoverable
  stop/failure states matter more than live partial transcript UI.

## Architecture Map

- `HarcApp/` contains the macOS app shell, app delegate, entitlements, window
  controllers, and asset catalogs.
- `Sources/HarcCore/` defines shared IPC, version, runtime log, and vocabulary
  types.
- `Sources/HarcSTT/` is the `harc-stt` executable daemon. It receives IPC
  requests and uses FluidAudio for transcription, VAD, diarization, and stitching.
- `Sources/HarcClient/` launches and talks to the daemon, chunks WAV files,
  assembles transcript output, writes sibling transcript files, and handles
  vocabulary replacement.
- `Sources/HarcAudio/` captures microphone/system audio, mixes levels, writes
  WAV files, and manages recording destinations.
- `Sources/HarcPresenceUI/` owns the shared iOS/macOS organic presence blob,
  its semantic capture states, cross-platform palette, and Reduce Motion
  behavior. Use it for Harc's persistent capture presence instead of creating
  platform-specific blob renderers.
- `HarcMobileWidgets/` renders the local recording Live Activity and Dynamic
  Island. `HarcMobileActivityShared/` contains its attributes and recording-bound
  stop intent; `HarcMobileLiveActivity` is presentation-only and must never block
  capture. A stale activity action must not stop a newer capture. Validate with
  `HarcMobileLiveActivityTests` and build the HarcMobile scheme (which embeds the
  widget extension).
- `Sources/HarcStore/` owns the GRDB-backed library, people, recovery queue,
  cache recovery, and migrations.
- `Sources/HarcUI/` contains SwiftUI/AppKit-facing state and views, including
  the menu bar panel, Library, settings, local-stack readiness, recovery inbox,
  transcript editor, and speaker identity UI.
- Dictation (`docs/dictation-plan.md`): Push-to-talk via `KeyboardShortcuts`. 
  `DictationController` in `Sources/HarcUI/` owns the state machine. Mic-only 
  capture via `MicDictationRecorder` + `AudioFileWriter` (temp WAV in 
  `~/Library/Caches/Harc/dictation/`), warm daemon transcription (`dictate()` 
  wrapper, no VAD/diarization), and insert-at-cursor via `FrontmostAppPaster`. 
  `DictationModeStore` holds built-in + user modes (name, icon, prompt, model, 
  per-mode hotkey, context toggles). `SummarizerService.transform()` post-processes 
  via LLM modes. `DictationHistoryStore` logs recent dictations. `DictationHUDView` 
  (NSPanel, non-activating) shows live waveform + status. `DictationKeepWarmController` 
  pings daemon to prevent idle shutdown. Mutual-exclusion guard vs recording.
- `Sources/HarcSummarize/`, `Sources/HarcModels/`, `Sources/HarcExport/`,
  `Sources/HarcMeetingDetect/`, and `Sources/HarcVoiceprint/` cover optional AI
  summaries, model management, export formats, meeting detection, and speaker
  embeddings.

## Approved Host/Client Buildout

The implementation contract for HarcMobile, Host mode, and secondary-Mac Client
mode is `docs/specs/2026-08-02-host-client-mobile-implementation-spec.md`. The
short architecture and ordered PR plan live beside it under `docs/architecture/`
and `docs/plans/`. The spec wins if planning prose drifts.

`HarcDomain`, `HarcIdentity`, `HarcTransfer`, `HarcClientStore`, the
transport-free `HarcHost` core, `HarcProtocolWire`, `HarcProtocol`,
`HarcHostTransport`, `HarcClientTransport`, `HarcRemoteTransport`, and
`HarcAudioMobile` are active, focused-tested modules. `HarcProtocolWire` is
generated only from the seven schemas in `Protos/`; `HarcProtocol` owns the
validated domain boundary, exact binary/security codecs, signed-object
authentication, capability policy, and container validation. The ordered PR
slices through Host ingest, transport, mobile capture/transfer, secondary-Mac
Client mode, and the optional blind relay are implemented in the current
SwiftPM/Xcode project. Do not infer that their unit or integration tests close
the physical-device codec, two-network, App Store, or real secondary-Mac
qualification gates. Physical qualification records the actual iPhone hardware
and OS used; it does not require an iPhone SE (2nd generation), iPhone 17, or
any other named marketing-model role. `HarcAudioMac` and `HarcInference` remain
documentation-only boundaries; do not add either as a placeholder module to
`Package.swift` or `project.yml`.
Keep the V1 host in the resident Mac app, keep the existing daemon, issue the
audio-safety receipt before derived processing, and do not expose local paths
or GRDB records as network DTOs. In Host mode, `harc-mcp` must route through
authenticated local IPC and must never fall back to direct database writes when
the resident host is unavailable.

Desktop Client reliability is fail-closed and self-healing. Recoverable Host
work has persisted bounded backoff and retries after launch, network recovery,
and wake. LAN route repair must authenticate a discovered candidate against the
existing adoption. A proved pairing claim may reconnect only until its original
expiry, both clients enforce that deadline even if a Host keeps returning
pending, and a resumed claim must retain its original authority and SAS.
Settings renders trust,
route, session, recording delivery, processing delivery, and speaker sync as
separate axes; last-contact evidence is valid only for its bound Library and
Host authority. Processing and speaker completion markers are bound the same
way; unbound legacy or differently bound markers must be resubmitted. Host gives
desktop edge artifacts a short grace period and
performs derived work only when system load, power, thermal state, and active
Harc capture indicate spare cycles. Speaker-pack revisions and every Host
observation decision are durable; nonmatches remain visible review concerns.
Unresolved speakers are retried on a bounded schedule and on recognition-pack
revision changes. Speaker enrollment requires an explicit user-confirmed link;
automatic Host assignments retain names but cannot train later matching or enter
recognition packs. Preserve that provenance through corrections and merges. Fresh
Host reevaluation excludes the current recording's own evidence; exact operation
replay remains immutable. Validate with `swift test --jobs 2 --filter
'PeopleStoreTests|SpeakerConfirmationMigrationTests|SpeakerRecognitionMatcherTests'`. A local diarization failure is durable and visible separately
from transcript coverage; Client recovery retries it from the protected master.
Host transient processing failures retry in-process with bounded backoff, while
canonical artifact binding changes remain fail-closed. Explicit local receipt repair requires macOS owner
approval, unchanged inode/ownership/permissions/length, and complete signed
receipt/audio revalidation. Preserve the original publication identity; append
an immutable, receipt-bound repair chain atomically. Incoming RPCs never authorize
repair. Validate with `swift test --jobs 2 --filter CanonicalIngestServiceTests`. Closing or rejecting a
pairing window must invalidate every suspended continuation before it can save
route or adoption state.

A distinct explicit local moved-library recovery may accept a changed device or
inode only after a cheap safe-identity prepass, complete manifest/receipt and WAV
hash validation before and after one batch owner approval, and an atomic immutable
binding event. Original publication identities and exact receipts remain unchanged.
An authorized pre-receipt event must remain resumable if receipt completion fails;
ordinary recovery and every incoming RPC remain unable to authorize rebinding.
Validate metadata-only, copied-file, receipt-prepared, legacy-chain, and interrupted
recovery cases with `swift test --jobs 2 --filter CanonicalIngestServiceTests`.

Host speaker outcomes bind the exact canonical audio and Host transcript artifact.
Publication accounts for every transcript cluster with either missing voice
evidence or a committed, evidence-bound decision; a decision may remain unmatched
or pending review. Disabled diarization is explicit. Generic transcript readiness
and legacy rows never imply speaker completion. Reprocessing invalidates the
stored outcome, and reads revalidate artifact bytes and decision provenance.
Transport reconciliation must not infer a speaker receipt from these generic
ready states. Validate with `ProcessingArbitrationTests`,
`HostSpeakerProcessingOutcomeTests`, and `SpeakerEvidenceStoreTests`.

Desktop metadata work may continue without a local master only for a committed
outbox whose verified receipt matches the current adopted Host, origin, producer,
canonical PCM hash and frame count. Recovery may reconstruct a missing capture
sidecar from that immutable outbox, without inventing a transcript or recreating
audio. Corrupt sidecars and integrity blocks remain failures. Validate missing
master/sidecar review scheduling with `HarcDesktopSpeakerReviewCoordinatorTests`
and recovery with `HarcDesktopClientRecoveryTests`.

Published speaker-recognition packs have one durable payload per revision,
including validity dates. The Host uses `publishedSpeakerRecognitionPack`;
expiry renewal advances the pack revision atomically with publication so an
`afterRevision` poll cannot strand a client on expired recognition data. Threshold
edits advance both person and pack revisions. Keep same-revision client payload
checks strict. Validate with `swift test --jobs 2 --filter
'PeopleStoreTests|SpeakerConfirmationMigrationTests|HarcHostLibraryServiceTests'`.

Desktop bound speaker batches must validate the exact signed processing bundle and
sidecar together before sending any observation. Bind retry identities to the exact
bundle as well as the sidecar. Reject mismatched cluster membership or embedding
duration; never clip a duration claim to fit overlap-excluded transcript turns.
Validate the app boundary with `HarcDesktopBoundSpeakerTests` in the Harc scheme.
This constructor does not itself enable negotiated bound delivery or qualify voice
recognition accuracy.
The desktop sender uses bound observations only when harc.speaker-evidence.v1 was
negotiated. Validate the entire batch and authenticated Host status recording/audio/
selected-bundle binding before sending. A mismatch defers delivery; never downgrade
that negotiated request to legacy. Bind completion to the selected artifact as well
as Host and sidecar generation, and reject stale completion after local selection
changes. Host admission still rechecks selection transactionally.
Bound speaker completions have a persisted six-hour review deadline even when all
names matched. Reconstruct the next eligible review timer after launch and successful
work without incrementing failure backoff. A speaker-only review must reuse completed
processing evidence, not renew and replace its artifact. Deadline unit tests do not
qualify the running coordinator timer, wake behavior or Host-derived reconciliation.
HarcDesktopSpeakerReviewCoordinatorTests drives the actual coordinator with persisted
committed fixture state and a short deadline, verifying inventory wake-up, shutdown
cancellation and precedence of restored failure backoff. The HarcAppTests target
shares ClientStoreFixtures.swift for test-only trust/receipt construction. These
fixtures do not qualify real Host connectivity or six-hour sleep/wake endurance.
Persisted desktop processing commands reuse exact bytes only within their signed
lifetime. Before renewal, authenticate and archive the expired envelope and bundle,
complete file/parent barriers, then create new artifact and operation identities.
Archive or synchronization failure must prevent replacement. Never extend command
authority using historical authentication or overwrite metadata at an old Host
artifact ID. Keep expired local evidence until lifecycle cleanup is qualified.
Bound speaker delivery persists its exact batch before the first RPC. A changed
recognition-pack revision must not regenerate operations for an unfinished batch
or a completed batch retried within its review interval. Revalidate retained batch
acoustic evidence against the current signed bundle/sidecar before reuse. Persist
batch completion before the user-visible completion marker. Validate the actual
sender with HarcDesktopBoundSpeakerTransportTests, in isolation from other network
suites. Shared loopback support lives under Tests/HarcHostTransportTests/Support;
it explicitly selects fixture artifacts without opening production acceptance.
The sender transport test also injects a post-commit gRPC reply failure, reopens
client stores, recreates the coordinator and verifies that only the missing decision
is added before completion. This is RPC-failure recovery, not a TCP packet-loss or
whole-process termination drill.
The recovery fixture closes the original pinned connection and obtains a new
connection and session before resuming; the relay variant opens a new tunnel too.
Keep pending batch identity independent of connection/session credentials while
retaining current Host authorization checks.

The legacy remote speaker-observation RPC carries no artifact-to-cluster binding.
Retain those requests as durable pending-review observations in
`unmapped_speaker_observations`; never project their numeric speaker indices into
canonical names or use that table for enrollment. Host-local recognition retains
its separate path. A future bound RPC must prove the currently selected artifact
and resolve its cluster mapping before enabling remote name projection. Validate
the boundary with `swift test --jobs 2 --filter UnmappedSpeakerBoundaryTests`.

Selected edge cluster maps commit with the exact transcript projection and invalidate
on audio/origin/artifact replacement. Bound observation admission must recheck the
selected map and projection inside the naming transaction, including before exact
replay, and resolve opaque cluster IDs instead of trusting client numeric indices.
The Store admission API requires prior authenticated bundle membership/duration
validation by the Host; its existence does not enable the legacy RPC. Validate
with `swift test --jobs 2 --filter SpeakerEvidenceStoreTests`.
Bound edge decisions retain the complete original request, map digest and immutable
voice snapshot in the naming transaction. Replay must verify that provenance;
retention alone does not make a sample current or human-confirmed enrollment.
Current edge evidence is selected per canonical speaker inside that same transaction.
Replacing it archives only that slot's assignment and preserves other speakers and
historical enrollment. Reviews resolve through the selected artifact map; an old
review or observation replay cannot authorize the replacement voice. Missing edge
evidence must not fall back to legacy index-based editing.
Selected edge publication also retains a Host-local signed-metadata/bundle reference
with exact hashes. It commits with the cluster map and is invalidated with it.
Never send these filesystem paths in network DTOs or accept client paths as source
authority. Rehash the actual bytes consumed after resolving the selected reference.
Historical processing revalidation uses HarcValidatedRetainedProcessingArtifactV1,
a separate type from live submission authority. Resolve its expected hashes from
Host selection, never from the requester. HarcValidatedProcessingSubmissionV1 must
continue rejecting historicalEvidence. Both paths share exact bundle consistency
and speaker membership checks; validate with `swift test --jobs 2 --filter ProcessingSubmissionTests`.
The bound Host service requires current speakerObservationWrite authority and
recording ownership, reads only the selected local files with protocol size limits,
and authenticates their exact consumed bytes. The naming transaction rechecks the
selected signed-metadata reference as well as the bundle map. Validate this service
with `swift test --jobs 2 --filter BoundSpeakerServiceTests`; the fixture seeds an
authenticated session and does not qualify session establishment or transport.
Bound wire requests use SubmitSpeakerObservationRequestV1 field 3 and require
critical field 3 plus negotiated harc.speaker-evidence.v1. Exactly one observation
form is permitted; declaring bound evidence while carrying only the legacy field
must fail. The shared request constructor requires negotiated support as well.
Desktop processing submissions and completion markers bind the exact capture
sidecar SHA-256. Unchanged generations reuse the same protected submission; changed
sidecars use a new generation path without overwriting old signed bytes. Legacy or
Host-mismatched completion markers cannot suppress resubmission.
Default feature advertisement is still unchanged. Validate with
`swift test --jobs 2 --filter 'SpeakerEvidenceBindingTests|CapabilityNegotiationTests'`
and `./scripts/check-harc-protocol-schemas.sh`.
Processing artifact persistence must repeat file/parent barriers and drive-cache
flush on exact-byte retries. Existing files do not prove a prior barrier succeeded.
Directory creation uses DurableFileIO; persistence retains no-follow file checks.
Validate with `swift test --jobs 2 --filter 'ProcessingArtifactPersistenceTests|DurableFileIOTests'`.

A fresh Host speaker nonmatch removes the prior unconfirmed automatic assignment
and its pending suggestion, with a Library revision change. Preserve confirmed
assignments and separately edited labels. Historical observation replay is
immutable and must not restore a superseded displayed name. Validate with
`swift test --jobs 2 --filter PeopleStoreTests`.

Once a recording transitions to exact bound speaker enrollment, its legacy
recording/index payloads must never become enrollment evidence again, including
after all bound confirmations are withdrawn. Preserve historical labels and links;
pack, Host matching and local reference queries must respect the durable transition.
Validate with `swift test --jobs 2 --filter SpeakerEvidenceStoreTests`.

Host edge adoption must preserve all speaker information it claims to accept.
Until Client cluster IDs are explicitly bound to Host speaker identity, bundles
with diarization turns or transcript-local speaker IDs retain their exact signed
bytes but continue through Host processing. Do not mark a lossy text-only
projection ready. Text and raw overlap-only projections remain supported.
When Host diarization is enabled, completion uses the explicit diarization IPC
endpoint through `transcribeRequiringDiarization`; the combined transcribe endpoint
is best-effort and cannot prove speaker processing succeeded. Failures must reach
the Host retry path before staging or ready publication.

## Reliability Rules

- VAD compaction retains original gaps up to 100 ms to avoid cutting speech at
  maximum-duration segment splits. Preserve those samples and their original
  timestamp mapping; do not insert synthetic silence. Keep longer silence
  trimming and evaluate changes against both clean and degraded local fixtures.

- Directory creation must retry the parent synchronization even when the target
  already exists: a previous mkdir may have succeeded while its barrier failed.
  Never treat that existence check as proof of durable creation. Barrier errors
  remain failures; do not silently downgrade them to continue publication.

- Standalone capture/import writes a local `.wav.destination.json` binding before
  audio creation. It records the original destination root and volume identity;
  startup recovery must use it instead of current preferences. Corrupt bindings
  are preserved and fail closed. Keep the binding through the Library commit,
  remove it with successful cleanup or explicit cancellation, and never include
  its filesystem paths in portable/network artifacts. Client committers retain
  their existing adopted-host authority path.

- Interrupted WAV recovery and publication hashing must use bounded buffers and
  drain Foundation autoreleased read data per block. The opt-in
  `HARC_LARGE_RECOVERY=1 swift test --jobs 2 --filter RecordingCacheRecoveryTests/largeStreamingRecovery`
  exercises a disposable 512 MiB PCM file and reports the test process peak RSS.
  Keep at least 6 GiB free before this diagnostic so its output stays above the
  5 GiB operational floor; it does not qualify live capture endurance.

- Recording starts in `~/Library/Caches/Harc/recordings/` and finalizes into the
  user-visible destination hierarchy.
- Recovery is product-critical. `RecoveryQueue` persists artifacts in
  Application Support and scans cache WAVs into recoverable inbox rows.
- Recovery must finish file and parent-directory synchronization before the
  Library/queue commit permits source cleanup. Metadata and capture-issue
  sidecars use `DurableFileIO`; barrier failures remain recoverable errors.
  A passing barrier test is not physical power-loss or cross-volume qualification.
- Standalone and import publication retain an immutable `.wav.publication.json`
  intent in the cache until the Library row exists. Publish through journal-owned
  staging on the destination volume with exclusive rename; never overwrite an
  occupied destination or rebind the recovery source to its published copy.
  `scripts/qualify-publication-cross-volume.sh` exercises a disposable mounted
  APFS volume; real removable/network storage and power loss remain separate gates.
- File-backed Library and Host databases use SQLite `synchronous=EXTRA` plus
  `fullfsync=ON`; client WAL databases retain `synchronous=FULL` and request
  `fullfsync=ON` after GRDB configures WAL. Preserve these per-connection
  settings across reopen; pragma read-back is software evidence, not a power-cut drill.
- A recovery artifact's source path is its durable scan identity. Do not recreate
  duplicate pending rows for the same cache file after metadata changes,
  especially if the user already discarded or failed it.
- Recovery journals its reserved output before publishing. It retains the
  cache master until the output, Library row, and queue completion succeed;
  interrupted retries reuse that output and row. A persisted `recovering`
  intent without an active owner is retryable, not a permanently busy UI state.
- Host upload staging is maintained by the resident runtime: reap once after
  startup, every six hours, and after system wake. Reaping is fail-soft and
  observable, must coalesce overlapping passes, and must preserve the seven-day
  post-expiry/abandonment resume window plus permanent attempt provenance.
- Capture readiness should distinguish blocked recording requirements from
  degraded quality and optional AI features. Missing destination/microphone can
  block recording; missing or cold STT degrades processing but must not block
  durable audio capture. Missing summaries/search/paste helpers must not make
  core capture look broken.
- Durable recording start must not wait for daemon/model warmup. Measure
  request-to-capture and inference-ready latency independently; inference
  failure degrades later processing rather than discarding or aborting audio.
- Concurrent daemon startup callers must reuse the launcher's running child.
  Cancelling one waiter must end its polling without stopping other callers'
  daemon; stopping the launcher invalidates suspended startup attempts.
  Validate with `swift test --jobs 2 --filter DaemonLauncherTests`.
- Recording warmup completions belong to their capture attempt. Cancelled or
  replaced work must not change readiness or clear a successor's task; reset
  invalidates the completion even if the underlying operation ignores cancel.
  Validate with `swift test --jobs 2 --filter RecordingWarmupControllerTests`.
- System audio denial is degraded "mic only" capture, not a hard block.
- Summary generation must honor the runtime's final stop metadata. Output-limit
  and unexpected runtime stops must fail instead of publishing valid-looking but
  incomplete text. Actual caller cancellation/unload remains cancellation;
  unexpected runtime stops are visible generation failures. Interim token counts
  are not completion evidence. Validate with
  `swift test --jobs 2 --filter SummaryTerminationTests`.
- Short summaries extract confirmed commitments and factual prose in separate
  passes over the same transcript. A failed or malformed facts pass must not
  publish the first pass alone. Summaries use the dedicated deterministic
  `ContainerLike.generateSummary` path; ordinary Q&A and transforms keep their
  existing generation profile. Test wrappers must forward that method and retain
  every raw pass while scoring the combined service result. The parser supports
  legacy `Action Items` and `Confirmed Commitments` headings, but malformed rows
  still require review. Validate with
  `swift test --jobs 2 --filter 'TwoPassSummaryTests|SummaryParserTests'`.
- New summary results must reject an explicit refusal emitted as an action item
  before publication, on both short and reconciled long paths. This narrow check
  is not semantic validation of every task; preserve legitimate removal work and
  negation inside an otherwise accepted task. Validate with
  `swift test --jobs 2 --filter SummaryTaskValidationTests`.
- Over-budget summaries must process every transcript section in chronological
  order and reconcile later cancellations/ownership changes before publication.
  Intermediate generation/format failures and non-shrinking reconciliation must
  fail the job, never save only the successful sections. Oversized utterances
  split without losing words or speaker attribution. Validate with
  `swift test --jobs 2 --filter LongSummaryTests`.
- Summary input-budget truncation must remain visible in stored/exported text,
  independently of whether the model follows the output format. Track the
  utterances actually omitted; never label a suffix-only summary as complete.
  Empty summary sections require review. Cancellation or unload invalidates a
  suspended summary generation even if the model ignores cancellation.
  Validate with `swift test --jobs 2 --filter 'SummaryPromptTests|SummaryOutputTests|SummaryParserTests|SummarizerServiceTests|SummarizerConcurrencyTests'`.
- Capture buffers may be planar or interleaved Int16/Float32. Copy complete
  native frames and use CoreMedia's PCM-copy API; never assume that
  `floatChannelData` exists for a hardware buffer. Validate this boundary with
  `swift test --jobs 2 --filter 'PCMBufferCopyTests|AudioMixerTests'`.
- Diarization tracking is scoped to one complete recording. Model windows retain
  overlapping real audio context, including the final short tail, while emitted
  time intervals have disjoint ownership. For recordings shorter than the model
  window, extract identity from the original short samples and exclusive speaker
  mask so FluidAudio applies corresponding waveform/mask padding; do not pass
  segmentation's zero-padded window as if it were real speech. Published audio,
  speaker timestamps and durations must remain unchanged by embedding padding.
  FluidAudio tracker thresholds are
  cosine distances, whereas identity matching uses cosine similarity; do not
  confuse their directions. Validate with
  `HARC_INTEGRATION_TESTS=1 swift test --jobs 2 --filter 'DiarizerTests|DiarizationWindowPlanTests'`.
  Automatic identity matching pools prototypes by person and rejects ties or
  near competitors through the same Host/provisional ranking rule. Ambiguous
  observations retain the existing durable no-match/review path. Historical
  observation decisions are immutable provenance; recognition evidence follows
  the current person-speaker link so manual correction and unlinking affect both
  Host matching and client packs. Compact packs retain at most one valid prototype
  per recording/speaker source, including local/remote copies and repeated
  observations; invalid vectors must not consume the prototype budget. Validate with
  `swift test --jobs 2 --filter 'SpeakerRecognitionMatcherTests|PeopleStoreTests'`.
  Synthetic speaker fixtures and source-window timeline scores are regression
  diagnostics, not human-voice identification or standard DER qualification.
- Accepted Client transcript artifacts project their validated words and overlap
  assessment into local SessionTranscript JSON before the Library publishes its
  ready state. Keep the local JSON decode contract covered by
  `HarcAcceptedTranscriptSidecarTests`; retain the exact signed artifact for frame
  precision and cluster provenance, and never invent person bindings from local
  cluster IDs.

- Host-generated structured transcripts publish to immutable content-addressed
  `.harc-derived` JSON before the serialized Library binding is updated. Retry
  reuses and synchronizes exact bytes; an already-ready winner prevents late
  Host publication. A text-only edge winner must clear a losing Host JSON binding
  so exports cannot read the wrong transcript. Validate `ProcessingArbitrationTests`.

- Signed transcript overlap assessment uses critical TranscriptArtifactV1 field 4.
  Presence means assessed (including empty); absence remains legacy unknown.
  Validate canonical-frame bounds/order and require the critical marker. Prior
  readers must reject the extension, never silently treat overlap as absent.
  Regenerate wire code from Protos and deliberately refresh the schema checksum
  inventory after reviewed changes; run `scripts/check-harc-protocol-schemas.sh`
  and `ProcessingSubmissionTests` for the signed boundary.

- Raw overlap evidence is independent of tracked speaker IDs. IPC and saved
  `SessionTranscript.overlapRanges` use nil for unassessed legacy results and an
  explicit empty array for assessed results with no detected overlap. Preserve
  that distinction through retries and serialization; never infer no overlap
  from a single final speaker. Ranges cover model frame support, not exact
  ground-truth turn boundaries.

- Short-recording voice re-extraction must exclude raw segmentation overlap,
  independently of the final tracked speaker timeline. A channel omitted for lack
  of isolated speech is not evidence of silence. If isolated activity or a valid
  re-extracted vector is unavailable, withhold that voice row rather than falling
  back to its earlier centroid. Validate with `swift test --jobs 2 --filter
  'DiarizationWindowPlanTests|DiarizerTests'`; enable `HARC_INTEGRATION_TESTS=1`
  for the real-model cases. This does not qualify final overlap timelines.

- Across all recording lengths, withhold voice embeddings whose cluster has no
  exclusive timeline support after raw overlap and simultaneous different speakers
  are excluded. Preserve speaker segments and overlap for missing-evidence reporting.
  Do not clip retained embedding duration claims to make signed validation pass.
  Validate with `DiarizerTests` and `DiarizationWindowPlanTests`.

- Speaker embedding model provenance travels with each IPC row into storage and
  desktop observations. Missing legacy JSON identity means WeSpeaker; malformed
  explicit identity must not fall back. New-model observation IDs must not replay
  old-model decisions, while legacy operation IDs remain stable. Validate Core
  compatibility with `swift test --jobs 2 --filter SpeakerEmbeddingProvenanceTests`
  and the app boundary with `HarcDesktopSpeakerObservationIdentityTests`.
- WAV RIFF chunk sizes are little-endian and may be unaligned. Read them with
  unaligned loads and advance over even-byte padding after odd payloads. Validate
  with `swift test --jobs 2 --filter WAVChunker`.
- Reconstruct SentencePiece continuations with `Word.displayWords` before speaker
  attribution. Never split a lexical word at a speaker/overlap boundary or infer
  a name from the previous/nearest segment when its midpoint lacks evidence.
  Validate text, prompt, and subtitle rendering together.
- Chunk stitching must remove the same verified complete-word prefix from plain
  text and timed words. Do not discard timed tokens using a coarse overlap-time
  cutoff; retain the successor when prefix alignment cannot be established.
- **Never silently drop transcript audio.** Chunk failures retry with
  backoff (all errors, not just model_not_loaded); exhausted chunks become
  visible in-transcript markers + `ChunkedTranscriber.failedRanges`, never
  a silent hole. Empty-under-VAD chunks with audible energy get one no-VAD
  retry. A change that can discard a chunk without a marker is a bug.
- Finalization retries diarized speech with no lexical token overlap from bounded
  saved-audio excerpts. Preserve original words and speaker segments; cancellation,
  empty/invalid results and exhausted budgets must leave visible failure notices
  plus structured coverage issues. Accumulate short AVAudioFile reads until the
  requested frames are complete or EOF is proved. Validate with
  `swift test --jobs 2 --filter 'SpeechCoverageRecoveryTests|ChunkedTranscriber'`.
  This detector cannot prove complete coverage within partially transcribed segments.
- Failed-audio notices must survive speaker-labelled transcript rendering, summary
  input, document exports and subtitles without being attributed to a speaker.
  Keep their format/parser shared in `UntranscribedAudioMarker`; retain complete
  fallback text when word timings are absent.
- Dictation clips in `~/Library/Caches/Harc/dictation/` are disposable — never
  route them into the recording recovery inbox. `DictationCacheCleaner` deletes
  orphans.

Standalone speaker generations publish through `RecordingStore+LocalSpeakerPublication`:
keep exact snapshots and transcript bytes together, reject stale recording/artifact
state, and archive previous slot assignments before a new generation reuses their
indices. Selected historical voice evidence remains immutable. New local evidence
must not inherit old numeric-slot enrollment. Validate with
`swift test --jobs 2 --filter SpeakerEvidenceStoreTests`; actual app callers also
require an Xcode build and live capture qualification.

Settings archive reprocessing uses `ArchiveTranscriber.reprocess` and the resident
`PublishingArchiveTranscriber` callback so text, timeline and voice evidence commit
as one generation. Do not replace this with a text-only daemon result. Job options
must match its model provenance; queued recording revisions protect concurrent
edits. Validate archive orchestration with `ArchiveReprocessorTests` and
`ArchivePublishingTests`, then build the Xcode app target.

## Common Validation

Voice enrollment uses the shared `SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs`
five-second evidence floor in both standalone suggestion triggers, re-identification
suggestions, recognition packs, cached-pack matching,
and Host reference matching. Short observations and manual names remain stored;
confirmation alone does not make a short sample eligible for automatic recognition.
Standalone single-person suggestions use the shared identity-separation margin
after pooling references per person; new-person backfill must compare competing
people too. A runner-up below its own acceptance threshold still causes ambiguity.
This consistency floor is not a calibrated accuracy guarantee. Validate with
`swift test --jobs 2 --filter 'PeopleStoreTests|SpeakerRecognitionMatcherTests|SpeakerReIDServiceTests|SpeakerSuggestionEngineTests'`.

Speaker identification evaluation must count query cases separately from enrollment
replay and must not count absent speech as a successful unknown rejection. Use
`scripts/quality/check-speaker-identification.py` for single-speaker corpora and
`scripts/quality/score-speaker-timeline.py` for time-resolved mixed-voice diagnostics.
Validate the single-speaker gate with
`python3 -B -m unittest discover -s scripts/tests -p test_speaker_identification_gate.py`.
Neither checker converts synthetic or audiobook fixtures into meeting qualification.

For repeatable local STT diagnostics, generate synthetic fixtures with
`scripts/quality/make-synthetic-stt-corpus.py <output-directory>`, then run
`HARC_INTEGRATION_TESTS=1 HARC_STT_CORPUS=<output-directory>/corpus.json swift test --jobs 2 --filter RealModelGoldenSampleTests/test_localCorpus_reportsPerCaseAccuracyTimingAndCompleteness`.
Retain the corpus, exact audio/model/source hashes, results.json and logs. These
synthetic excerpts do not qualify real-world accuracy, diarization, summaries,
or long-form capture. The ordinary suite skips real-model evaluations.

`./scripts/qualify-publication-faults.py` compiles the actual Core publication
sources into a disposable driver, verifies its own child stopped at each named
boundary, sends SIGKILL, and checks two independent restarts. It retains exact
byte and immutable-journal evidence. This covers process interruption only;
Library commit, physical power loss and storage-device failures are separate.

`./scripts/qualify-publication-storage.py` requires 6 GiB starting headroom and
fills only an owned 128 MiB APFS image. It verifies ENOSPC, refusal after volume
detachment, and retry after reattachment. Publication journals bind the volume
UUID (or fail-closed mounted-device identity when no UUID exists); a disappeared
mount must never redirect a journaled master to the host filesystem. Unbound
pre-release diagnostic journals are preserved, never automatically rebound.

Run focused tests for the surface you changed, then broaden only as risk
requires.

Use local focused tests as the default development feedback loop, with the
existing SSD build caches. Do not push each intermediate edit just to obtain
GitHub test feedback. Run the affected package suites or app/simulator tests
locally, then push a review-ready candidate for full CI before merging. Keep
required app, physical-device, security and release gates; a focused local pass
does not replace them. Pull requests run the full package, macOS and iOS CI
jobs. PRs and pushes to main also run the bounded, credential-free relay lane:
`node --test scripts/check-production-privacy.regression.mjs` and `npm run check`
from `CloudflareRelay/` (source policy, types, local tests and dry bundles only).
Pushes to main run `bash scripts/test-post-merge-smoke.sh` for package manifest
validation, protocol contracts, tooling regressions and Xcode project generation. This smoke check does not compile or launch the app and cannot
replace pre-merge CI or release qualification.

For local iOS Simulator configuration and navigation regressions, run
`bash scripts/test-mobile-local.sh`. It selects an available iOS 26+ iPhone,
keeps per-worktree DerivedData and package caches under
`/Volumes/MacMiniSDD/HarcBuilds/local-ios`, and retains a fresh result bundle
for each run. Set `HARC_LOCAL_IOS_ROOT` to use another build volume. The SSD
must be mounted; the runner never silently falls back to internal build caches.
Install a compatible runtime with Xcode before the first run. These simulator
checks do not qualify physical audio capture or a release. CI's package, macOS,
and mobile jobs build independently and must not wait on one another unless an
actual artifact dependency is introduced.

On the current constrained development Mac, cap Swift and Xcode concurrency at
two workers and stop before free disk falls below 5 GiB.

    swift test --filter RecordingCacheRecoveryTests
    swift test --filter LocalStackHealthTests
    swift test --filter CustomerExperienceE2ETests
    swift test

Socket fixtures must keep blocking POSIX I/O off Swift's cooperative executor.
`Task.detached` uses that same executor. The STT listener accepts on a dedicated
thread, and socket test peers use dedicated threads with kernel deadlines.
AVAssetReader conversion also uses a dedicated thread: its synchronous sample
reads can exhaust the same executor on hosted Macs. Carry task cancellation
explicitly into that thread.
CI builds tests separately, bounds their execution, and runs this deterministic
single-worker regression before the full suite:

    LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build --jobs 2 --filter 'HarcSTTClientTests|ClientConnectionTests|SocketServerTests|DaemonIdleClockTests|LocalMCPIPCIntegrationTests|MediaImportServiceTests'

Run HarcMobile UI qualification through
`scripts/qualify-harcmobile-ui.sh` so the destination, exact source manifest,
logs, result bundle, and artifact digest stay together. Use
`--derived-data-path <SSD-cache-directory>` to reuse an external build cache. A dirty-tree run must be
explicitly labeled diagnostic and cannot qualify a release.

Pairing transport changes must also pass the real pinned-TLS lifecycle through
both the direct socket and local encrypted-relay emulator paths:

    ./scripts/test-pairing-lifecycle.sh
    ./scripts/test-pairing-lifecycle-relay-emulator.sh

MCP shutdown joins a cancellation-independent broadcast completion. The accept
worker owns descriptor close and inode-checked socket unlink before releasing
any shutdown caller. Runner cleanup tracks the owned process group even when
its immediate parent exits; verify its lifecycle fixtures with:

    python3 -B -m unittest discover -s scripts/tests -p test_run_package_tests.py

Physical legacy Keychain fixtures share the serialized parent
`LegacyMacOSKeychainIntegrationTests`. A serialized child suite alone does not
isolate its Security.framework mutations from sibling suites. Preserve the real
persistence/identity assertions and concurrency within individual tests.

**Known flaky suites — all timing-based, all load-induced.** Under the full
parallel suite these intermittently fail while Core ML models compile, then pass
immediately in isolation; that load/no-load contrast is the tell. Observed again
on 2026-08-02:

- `SummarizationQueue` / `SummarizationQueueStore`
- `PostStopTrayState` (TTL auto-fade)
- `DictationKeepWarmController` (ping counts)
- `LibraryMaintenanceStore` ("indexing clears the index backlog")
- `DictationController` (async cancellation/override timing)
- `ChunkedTranscriber` (live-preview scheduling)

Re-run the named suite alone before treating one as a regression:

    swift test --filter "SummarizationQueue|SummarizationQueueStore|PostStopTrayState|DictationKeepWarm|LibraryMaintenanceStore|DictationController|ChunkedTranscriber"

The Xcode helper embed phases must run their incremental SwiftPM build even
when an embedded binary already exists. Keep `basedOnDependencyAnalysis: false`
in `project.yml`; output-only script phases otherwise reuse stale helper code.

**`swift test` does not cover `HarcApp/`.** AppDelegate, the window
controllers and the NSPanel HUD compile only in the Xcode app target, so a
green package suite says nothing about them. Always finish with an
`xcodebuild` before calling the tree green.

The embedded helper scripts resolve their executable directory with
`swift build --show-bin-path`; do not hard-code SwiftPM's output layout.
Current Xcode toolchains may use `out/Products/Release` instead of the
older architecture-specific directory.

CI's Xcode lanes must also pass `scripts/check-xcode-test-results.py` against
the summary and test tree exported by `xcresulttool`. Zero tests, skipped or
expected-failure tests, missing required bundles/UI cases, and inconsistent
result counts fail the gate. Keep required selectors in `.github/workflows/ci.yml`
aligned with the test source. Validate the checker with
`python3 -B -m unittest discover -s scripts/tests -p test_xcode_execution_gate.py`.

SwiftPM CI exports Swift Testing XML and retains the serial XCTest log, then
runs `scripts/check-swift-test-results.py`. Report passed and skipped counts
separately for each framework: Swift Testing's final count includes skips.
Only the named opt-in cases in `scripts/swift-test-skip-policy.json` may skip;
their availability in the test inventory does not qualify their model/device
behavior. Changes to that policy or discovery floors require deliberate review.

Use `scripts/production-source-snapshot.py --write <ignored-output.json>` to
record candidate source identity and `--check <ignored-output.json>` to detect
later file or commit changes. Stop writers/builds while recording and checking.
The snapshot includes non-ignored documentation and tests, not just app code;
it always remains unqualified and cannot substitute for artifact/device gates.

The shared `Harc` scheme in `project.yml` includes `HarcAppTests` and
`HarcAppUITests`. Run it with `xcodebuild -jobs 2 -project Harc.xcodeproj
-scheme Harc -destination 'platform=macOS,arch=arm64'
-parallel-testing-enabled NO test` for app-hosted and UI validation. CI also
selects the Simulator-safe mobile UI cases explicitly; those do not qualify
physical microphone, storage protection, or endurance behavior.

For isolated local Mac testing, `HARC_MAC_DIAGNOSTIC_SUFFIX=.TideDiagnostic`
gives the app a separate bundle identity; keep `HARC_UI_TESTING=1` and temporary
test roots as well. A separate bundle ID alone does not isolate library data.
In DEBUG UI tests, `RecordingDestination` resolves capture and recovery cache
paths under the same test root (`RecordingCache`), including the process-specific
fallback when the explicit root is absent. Never scan the normal recording cache
from an isolated test library. Validate this boundary with
`RecordingDestinationTests` and a fresh-root Mac launch with no recovery fixtures.
If an SSD-launched diagnostic app is blocked by removable-volume permission,
`build-for-testing` products and their relative-path xctestrun can be copied to
internal temporary storage and run with `test-without-building`. Verify the
copied app signature and retain the original build and relocated test results.

**Neither tests nor the compiler catch a missing `@EnvironmentObject`.** It is
a runtime `assertionFailure` — a SIGTRAP in Release. A crash of exactly this
kind shipped into `main` and survived a 686-test green run because nothing
constructs the SwiftUI `Settings` scene. When a view gains an environment
dependency, add it to `harcSettingsEnvironment(...)` rather than to one call
site, and open the pane in a real build.

The Settings-only SwiftUI scene can replace the resident app's main menu.
Check the installed Edit menu before handling events; a one-time installation
flag does not prove editing shortcuts still exist. The UI suite checks Select
All in search and transcript replacement, undo/redo, autosave and relaunch.

A newly stopped recording can be selected before its Library row arrives.
Initialize the empty transcript editor from the selected row's observation,
without replacing dirty user edits or applying an old selection's update.
Clearing text must keep an active editor available for replacement typing.
Validate with `HarcAppUITests` through the shared Xcode scheme.

After changing package/project/version metadata, run:

    xcodegen generate

For local release artifacts, use:

    ./scripts/build-local.sh

### Package.resolved churns during releases — that is expected

`Harc.xcodeproj` sits in the same directory as `Package.swift`, so Xcode
never creates its own `xcshareddata/swiftpm/Package.resolved` — both tools
share the root one and disagree about a single pin:

- `swift build` / `swift test` resolve from `Package.swift` → **no Sparkle**
- `xcodebuild` (i.e. `build-release.sh`) also sees `project.yml` → **adds Sparkle**

Whichever ran last wins, so the file cannot be clean for both. The committed
state is deliberately the **SwiftPM version, without the Sparkle pin**,
because everyday `swift build`/`swift test` then leaves it untouched and only
a release build dirties it.

So: a `Package.resolved` diff that only adds Sparkle is a release-build
artifact — **leave it out of the commit** (`git checkout Package.resolved`).
Do not "fix" it by committing the Sparkle pin; that inverts the noise onto
every test run. Sparkle's `from:` requirement in `project.yml` permits stable
versions from that minimum up to the next major version; it is not an exact
version pin. The archive preflight accepts only one Xcode-added Sparkle pin
from the official source within that requirement, with its revision matching
one exact official version tag (annotated tags are peeled), and generated
`originHash` churn. Tag lookup is noninteractive, bounded to 15 seconds and
fails closed on missing/ambiguous tags, mismatch or resolver failure. Every
other committed pin and lockfile field
must remain unchanged. Record the resolved Sparkle version/revision with build
evidence; do not expand this exception to other dependency changes.

## Release Ritual

Releases auto-install via Sparkle, so the appcast must be updated with a
signed entry for every release — in this order:

1. Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`,
   run `xcodegen generate`, build with `./scripts/build-release.sh`
   (Developer ID + hardened runtime + secure timestamps). Do NOT ship
   `build-local.sh` output — it is ad-hoc signed and not notarizable.
2. Notarize and staple, in that order:
   `xcrun notarytool submit build/release-dist/Harc-<version>.dmg --keychain-profile harc-notary --wait`
   then `xcrun stapler staple build/release-dist/Harc-<version>.dmg`.
   Confirm the exact candidate with
   `./scripts/verify-release.sh <version> <build> build/release-dist/Harc-<version>.dmg`.
   The release build refuses a dirty tree and embeds the exact 40-character
   source commit as `HarcBuildSHA`. The verifier checks that value against the
   checked-out commit, plus the DMG signature and checksum, stapled ticket,
   Gatekeeper assessment, mounted app and nested signatures, version/build,
   bundle ID, and arm64 application/helper architecture. Run it from a normal
   terminal session with access to macOS trust services; a restricted sandbox
   can hide the keychain certificate chain and produce a false signature
   failure.
3. Copy the **stapled** DMG to `Harc-local.dmg` (the asset name every
   appcast enclosure points at) and zip it to `Harc-local-dmg.zip`.
   Stapling rewrites the DMG, so it must happen before signing — the
   signature must cover the exact bytes that get uploaded.
4. Sign that DMG and get the appcast entry:
   `./scripts/make-appcast.sh <version> <build> build/release-dist/Harc-local.dmg`
   (EdDSA private key lives in the login Keychain, service
   "https://sparkle-project.org"; sign_update may prompt — Always Allow).
5. Insert the printed `<item>` at the top of `appcast.xml`'s `<channel>`.
6. Commit (including `appcast.xml`), tag `vX.Y.Z`, push main + tag. The
   appcast is served from main via raw.githubusercontent — pushing main
   publishes it.
7. `gh release create vX.Y.Z --latest` attaching BOTH
   `build/release-dist/Harc-local-dmg.zip` and `Harc-local.dmg` — the
   appcast enclosure points at the release's `Harc-local.dmg` asset, so
   the uploaded DMG must be the exact bytes signed in step 4.

`build-release.sh` produces only the DMG; the `.zip` in step 3 is a manual
`ditto -c -k --sequesterRsrc` of the **stapled** DMG. Every published release
so far carries both assets.

Ordering hazard in steps 6–7: the appcast is served from `main`, so pushing
publishes an update feed pointing at a release asset that does not exist yet.
Existing users' Sparkle clients will see the new version and fail to download
it until step 7 lands. Do them back to back, or create the release first.

### Releases can only be cut from the Mac that holds the keys

Three credentials are machine-bound and none of them are in this repo:

- the **Developer ID Application** certificate + private key (login keychain)
- the **`harc-notary`** notarytool profile (login keychain)
- the **Sparkle EdDSA private key** (login keychain, service
  `https://sparkle-project.org`, account `ed25519`)

A second Mac can clone, build, test and run `build-local.sh` (ad-hoc) with no
setup, but cannot notarize or produce a valid appcast signature until those
are exported to it. The Sparkle key in particular has no recovery path — lose
it and existing installs can never be updated again, because Sparkle pins the
public key. Back it up before it is ever needed.

## Verifying UI changes on screen

Computer-use visibility varies with the tool and window state. Older tools
omitted the menu-bar agent; current CUA successfully inspected the diagnostic
app by bundle ID with Library open in an unlocked session. Try current app
selection and inspect the returned image before assuming Harc is invisible.
XCTest screenshots can capture another foreground app, so verify their contents
before counting them as visual evidence.

If Harc is unavailable through computer use, the following shell fallback works:

- **Observe:** `screencapture -x -R x,y,w,h out.png`, then read the PNG.
  Unfiltered, and it captures the menu-bar panel.
- **Drive:** `osascript` + System Events. Settings panes switch via
  `set selected of row N of outline 1 of scroll area 1 of group 1 of
  splitter group 1 of group 1 of window "<pane>"`; the panel toggles via
  `click menu bar item 1 of menu bar 2`.
- **Scroll and click:** System Events has no scroll verb and `click at` is
  unreliable. Compile a small `CGEvent` helper — the panel and Settings panes
  only respond to real wheel events.
- The Settings window's title is the **selected pane name**, not "Harc
  Settings", so address windows by current pane.

Do not read accessibility labels through AppleScript's `description`: it
returns the *role* ("button") for SwiftUI controls, which reads as a missing
label when one is present. Query `AXDescription` via the AX API directly.

## v0.9.0 UI overhaul — structural facts agents must know

- There is **no TranscriptEditor window**. `Sources/HarcUI/TranscriptEditor/`
  is gone; the Library detail pane edits in place via
  `TranscriptDetailEditor` + `TranscriptDocument` (loader/saver, OKF-aware).
  `WordIndex`, `TranscriptAudioPlayer`, `TranscriptFind` live at the top of
  `Sources/HarcUI/`.
- `LibrarySelection` has a `.live` case for the in-progress recording. It is
  never persisted and never restorable — `PersistedLibrarySelection` refuses
  it and the resolver invalidates it.
- Design tokens are mandatory (`Sources/HarcUI/DesignSystem/`): five type
  roles (`.harcTitle/Body/Label/Caption/Mono`), status colors only via
  `Color.harc(_:)`, spacing via `HarcSpacing`. Deliberate exceptions carry
  `// token-exempt:`. Grep-audit before declaring UI work done.
- The menu-bar panel must never scroll. New conditional surfaces go behind
  the status row into `ActivityView`, not into the panel.
- Readiness/recovery have one renderer: `ActivityView`. Do not add a second;
  that is how the `pendingRecoveryCount: 0` suppression hack was born.

## Documentation

Keep this file current when repository structure, build tooling, validation
commands, or non-negotiable product constraints change. Prefer documenting the
behavioral invariant and the validation command over copying implementation
details that will drift quickly.

## Explicit local receipt repair

Receipt repair requires local macOS owner authentication, unchanged inode, owner,
permissions and length, and full signed receipt/audio validation. Preserve original
publication identity and append an immutable receipt-bound repair chain atomically.
Incoming RPCs never authorize repair. Validate with
`swift test --jobs 2 --filter CanonicalIngestServiceTests`.

Moved-library recovery is a separate local owner-authorized action. It may rebind
a changed device or inode only after exact signed evidence and full audio validation
on both sides of approval, records the transition in the immutable canonical
artifact binding chain, and resumes pre-receipt publication idempotently. It is
not exposed through Host RPCs.

Embedded helper scripts resolve executables with `swift build --show-bin-path`
using the same product, architecture, configuration and scratch path as the build.
Do not hard-code SwiftPM output directories; Xcode 27 changes the default engine.
The release build verifies that both embedded helpers are arm64 and signed.

Client archive recovery compares Host-only sidecars through the transfer store's
millisecond-since-1970 Date codec before exact capture-fact comparison. Keep
foreign identity, filename conflicts and changed metadata fail-closed and distinct;
never use a broad time tolerance or rewrite evidence to clear a warning. Activity
reports archive completion independently of delivery and retains per-recording
failure feedback through retries until that recording succeeds. Validate with
`HarcDesktopClientRecoveryTests`, `HarcDesktopSpeakerReviewCoordinatorTests`,
`ClientHostConnectionStateTests`, and `HarcTransportErrorDiagnosticTests`.

Inventory failures have no recording identity and clear after a successful scan.
Retained recording failures clear only after successful transfer or independently
verified receipt/Host-bound metadata evidence with completed durability barriers.
An empty eligible queue is never proof of delivery; preserve errors for blocked,
missing, corrupt or foreign evidence. The desktop speaker-review coordinator
suite includes deterministic inventory and post-commit cleanup fault regressions.
