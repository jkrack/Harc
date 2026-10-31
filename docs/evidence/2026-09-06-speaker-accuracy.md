# Speaker identification diagnostic — 2026-09-06

**Current verdict: not qualified for automatic naming.** The short mixed-voice
stress cases below expose incorrect known-person labels despite the earlier
single-voice improvements. The expanded human turn-length test also assigns an
unfamiliar human voice to an enrolled person. Passing unit tests and builds do
not close this gap.

The audio-to-speaker path now uses recording-scoped tracking, overlapping real
model context with disjoint output ownership, and a stricter tracker distance
cutoff. The previous path merged an unfamiliar synthetic voice into an enrolled
voice in the longer fixture. This is an improvement on a small synthetic corpus,
not production qualification for human speaker recognition.

Two installed macOS voices (Samantha and Daniel) were enrolled using one text
and queried using a different text. Karen was never enrolled. All generation,
model inference and identity matching ran locally. No People database was changed.
Twelve runs include enrollment, replay, alternating speakers, overlap, quiet
speech, noisy speech and four turns containing the unfamiliar voice.

The exact current source was compiled into a diagnostic executable against the
existing FluidAudio dependencies. Embeddings were passed through Harc's actual
SpeakerRecognitionMatcher using an in-memory pack. Nine focused Swift tests
passed, including two real-model cases, with zero skips. Four Python timeline
scorer tests passed. This isolated test harness is not the complete package suite.

Source-clip timeline agreement (exact predicted identity set over the union of
reference windows):

| Fixture | Before | Current |
| --- | ---: | ---: |
| Alternating known voices | 94.7% | 99.6% |
| Overlapping known voices | 78.3% | 97.8% |
| Four turns with unfamiliar voice | 59.6% | 97.4% |

In the four-turn fixture, unfamiliar audio incorrectly assigned a known identity
fell from 8,441.6 ms to zero. A late transition back to Samantha remains. These
windows include natural pauses; the percentages are neither standard diarization
error rates nor estimates of human identification accuracy. The longer fixture
was used to select the cutoff and is no longer independent held-out evidence.

The tracker cutoff is cosine **distance** 0.35, corresponding to the existing
cross-recording cosine **similarity** starting floor of 0.65. This is not broad
calibration: noisy Daniel scored about 0.682, and unfamiliar Karen's longer-case
centroid scored about 0.647 against Samantha. Both sit close to the identity
threshold. Similar human voices, other microphones, room acoustics and longer
conversations need independent testing. Exact/near-tie identity ambiguity is addressed by the follow-up below;
the abstention margin still needs independent human-voice calibration. Replay equality did not demonstrate a prior cross-session
failure; resetting the tracker enforces the intended recording boundary.

Evidence is retained locally under
`build/qualification/production-hardening-2026-09-05/speaker-accuracy/`:

- `validated-audio/extended-corpus.json`: source texts, conditions, audio hashes.
- `baseline-extended.json` and `current-source.json`: segments and embeddings.
- Corresponding `-matches.json` files: actual matcher decisions and similarities.
- `timeline-reference.json` and `*-timeline.json`: timing references and scores.
- `reproduction/`: exact diagnostic source and local generator/build commands.
- `provenance.json`: source/model hashes and dirty-tree diagnostic identity.
- `focused-tests-final.log` and `harc-hardening-macos-speaker-build.log`.

The first restricted speech-generation attempt produced empty files despite a
successful exit; `baseline-invalid-input.json` and the root-level original files
are invalid and excluded. Only `validated-audio` is used in the comparison.

To rescore the retained evidence, run from the repository root:

```sh
python3 scripts/quality/score-speaker-timeline.py \
  build/qualification/production-hardening-2026-09-05/speaker-accuracy/timeline-reference.json \
  build/qualification/production-hardening-2026-09-05/speaker-accuracy/current-source.json \
  build/qualification/production-hardening-2026-09-05/speaker-accuracy/current-source-matches.json \
  /private/tmp/harc-speaker-timeline.json
python3 -B -m unittest discover -s scripts/tests -p test_speaker_timeline.py
```

Build inspection also found that the daemon and MCP embedding phases declared
outputs but no source dependencies. Xcode could skip them after helper changes.
Both phases now always invoke their incremental SwiftPM build; SwiftPM determines
which sources need recompilation. The diagnostic app project must apply the same
rule. A dirty-tree unsigned app build is not release or physical-device evidence.

The forced diagnostic Xcode build succeeded and its log confirms rebuilding,
linking, signing and embedding `harc-stt`. The helper source snapshot includes
the exact current diarizer and window planner. This verifies app/helper build
integration, not on-screen behavior or full-source release provenance.

## Ambiguous identity follow-up

The Host previously chose a maximum-scoring prototype without considering another
person with an equal score. Ties could therefore assign a name based on candidate
iteration order. Both Host decisions and provisional pack matching now pool the
best score per person and abstain unless the winner leads the next person by more
than 0.05. The winning person's existing acceptance threshold still applies.
The runner-up is considered even if it would fail its own threshold.

This margin is a conservative policy starting point, not a calibrated confidence
probability. It trades some automatic naming for fewer unsupported assignments.
An observation without a proposed identity remains a durable `noMatch`; one with
a proposed identity follows the existing `pendingReview` path. No existing manual
speaker names or historical decisions are rewritten by this change.

Validation: the actual updated app modules passed 20 PeopleStore XCTest cases and
three domain Swift Testing cases, with zero skips. Tests cover tied observations
remaining unnamed, idempotent decision replay, near competitors, clear winners,
invalid scores, multiple prototypes of one identity, pack expiry and matching.
All retained synthetic matcher outputs are unchanged. The unsigned diagnostic
Xcode app build passed. This still does not qualify similar human voices.

Follow-up evidence is in `speaker-accuracy/ambiguity/` (source copies, test/build
logs, isolated harness manifest and file hashes), with `ambiguity-matches.json`
beside the original synthetic outputs. The harness links the newly built app
modules and uses disposable in-memory stores; it is not the full package suite.

## Speaker correction follow-up

A failing database regression showed that remote observations continued to train
Alice's profile after the speaker was reassigned to Bob. The next observation
still matched Alice; unlinking did not remove the evidence. Four assertions
failed against the previous app modules.

Both recognition-pack construction and authoritative Host matching now join
observation evidence through the recording's current person-speaker assignment.
Reassignment transfers its evidence to the corrected person; unlinking excludes
it. The original decision JSON remains unchanged for idempotent historical replay.
No schema migration or rewrite of historical decisions is required. This addresses
correction authority; it does not independently calibrate automatic learning.

The rebuilt app passed 21 PeopleStore XCTest cases and three domain Swift Testing
cases (zero failures or skips), including the previously failing correction,
future matching, unlinking and immutable-replay scenario. The unsigned diagnostic
Xcode app build passed. Evidence and exact source copies are retained in
`speaker-accuracy/correction/`, including `correction-before.log` and
`correction-after.log`. This is software evidence, not a human-voice benchmark.

## Short-recording embedding follow-up

A duration stress test cut the original query audio into 0.5, 1, 2, 3 and 5 second
prefixes. Both the original diarizer and the initial windowing fix failed to
recognize the two known voices on all eight 1–5 second queries. The 0.5 second
clips produced no speaker segments; these are unavailable identity results,
not successful unknown-voice rejection.

Inspection found the manager passed its ten-second zero-padded segmentation
buffer to the embedding extractor. This prevented the extractor from applying
its own corresponding repeat-padding to short real audio and its activity mask.
An explicitly repeated-audio diagnostic restored recognition, narrowing the cause.

For recordings shorter than the model window, Harc now re-extracts identity from
the original samples with an exclusive-speaker activity mask. Silence, competing
speakers and overlap are masked out. The extractor handles its internal padding;
no recording bytes, output timestamps or reported speech duration are repeated.
This leaves segmentation unchanged and corrects only the identity vectors.

The final source recognized both known voices in all eight 1–5 second cases and
left all four available unfamiliar-voice cases unknown. Half-second clips still
produced no segments. All existing extended-corpus identity decisions remained
correct, including quiet/noisy and overlapping cases. These are synthetic
regressions; they do not establish human short-utterance accuracy.

Ten focused Swift tests passed with zero skips, including the real-model cases
and exclusive-mask tests. Final-source probe outputs exactly matched the
experimental candidate; published timelines exactly matched the pre-fix results.
The diagnostic Xcode build rebuilt and embedded the helper and passed.

Evidence is retained in `speaker-accuracy/short-duration/`: original and transformed
fixture manifests, source-audio hashes, baseline/candidate/final results, matcher
decisions, logs and source copies. The transformed repeat fixture is solely a
mechanism diagnostic and must not be reported as natural short-speech accuracy.

## Short mixed-voice stress test — failing gate

Four additional synthetic recordings place two-second turns into clips shorter
than ten seconds: two known voices, a known and unfamiliar voice, three voices,
and short overlap. Source clip windows include natural pauses. All audio and
inference remain local; no user recording was altered.

The current source merges the two known sequential voices into one identity
(50% source-window identity agreement), and assigns 2,000 ms of unfamiliar Karen
to Samantha in both the two-voice and three-voice fixtures. The overlap fixture
scores 97.5% by this diagnostic. These are not human DER scores.

An isolated candidate disabled pre-embedding cluster merging within a short model
window. It separates the two known sequential voices, but still fails on the
similar known/unfamiliar pair. This indicates that the segmentation model can
already emit those voices as one channel; fixing embeddings afterward cannot
recover a distinction that has disappeared. The experimental channel candidate
was not applied to production source.

The prior single-voice success is therefore insufficient to qualify automatic
naming. The current short-embedding change remains an unqualified working-tree
candidate. Required next work: detect inconsistent/mixed voice evidence before
assigning a known person, evaluate any resulting abstention or segmentation change
against both these failures and the previous single-voice and longer fixtures,
and then obtain independent human-voice evidence. Do not lower matching thresholds
to force these cases to pass.

`short-mixed/` retains corpus/reference manifests, source hashes, actual/candidate
segments and matches, time-resolved scores, generator and exact candidate source.

## Independent human-voice pilot and rejected approaches

Two additional approaches were evaluated without changing production source:

- Two-second window consistency: the minimum same-voice cosine in a clean query
  was about 0.480, compared with 0.474 in the missed known/unfamiliar transition.
  A simple minimum-similarity cutoff would reject valid speech as well, so it was
  not adopted.
- FluidAudio offline diarization: official models were downloaded at pinned
  revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594` (21.6 MB; per-file hashes
  retained). Default offline clustering, with overlap output enabled, still
  merged the short sequential voices and reduced the overlap fixture to one
  speaker. It was not substituted into Harc. Enrollment was rebuilt within the
  offline pipeline for this comparison; cross-model profile compatibility was
  not assumed.

The next pilot uses actual human speech from the [LibriSpeech test-clean corpus](https://www.openslr.org/12)
(CC BY 4.0; attribution retained). The 346,663,984-byte archive passed its published
MD5 checksum and also has a retained SHA-256. Selection was fixed before scoring:
first six numeric speaker IDs, first lexically ordered clips lasting 6–30 seconds,
four enrolled speakers with separate query recordings and two unknown speakers.
IDs are 61, 121, 237, 260 (enrolled), 672 and 908 (unknown). Enrollment replay
scores are not counted as accuracy tests. This is disjoint enrollment/query audio,
not a claim that the corpus was absent from the model's training data.

All four known query recordings matched the correct enrollment (scores roughly
0.728–0.949), and both unknown speakers remained unknown. This is a six-query
pilot, not a population accuracy estimate or natural-meeting qualification.

Predetermined short mixtures of those human query clips still failed: the two
known sequential voices had 0% exact source-window identity agreement; the
known/unknown pair had 50%; three turns had 25.1%; and overlap had 40%. These
figures include natural pauses and are not standard DER. No unknown speech was
incorrectly named as a known speaker in this small human mixture set, but known
speakers were lost or left unknown. Automatic naming therefore remains unqualified.
The next work must improve short mixed-voice separation and recognition, not
merely tune thresholds to the successful single-speaker pilot.

Evidence: `human/` contains archive provenance, attribution, clip manifests,
original FLAC/WAV hashes, generation/scoring source, model results and matcher
outputs. `human/mixed/` contains constructed-mixture references and time-resolved
scores. `short-mixed/` retains window consistency and offline-model comparison
outputs plus pinned model provenance. No production source was changed by these
experiments.

## Duration controls and repeatable identification gate

Standalone prefixes of the same six human query recordings separate input-duration
limitations from mixing failures. All four known voices were recognized at five
seconds. At two seconds only two of four were recognized; the others remained
unknown. At one second the four known clips produced no speaker output. The eight
unknown-speaker prefix cases (two speakers at four lengths) remained detected and
unnamed. Thus 17 of 24 query cases passed: nine of 16 known-voice queries and eight
of eight unknown-voice queries. Enrollment replay is excluded from these counts.
This explains some short-mixture failures, but not the loss of the recognizable
voice when combined with another speaker.

An isolated Silero VAD experiment with a 150 ms minimum silence found the intended
sequential spans in the human mixtures, but not the missed synthetic transitions.
It is not a complete replacement boundary source and production VAD settings were
not changed. A four-setting offline clustering comparison (similarity thresholds
0.8/0.9 and VBx Fb 0.8/0.4) also failed: the known/unfamiliar synthetic pair still
merged, overlap remained one speaker, and the human two-known case returned
`noSpeechDetected`. Some settings split a single-speaker enrollment into two.
The first uncaught diagnostic error terminated its process; the completed rerun
records each error explicitly and continues other cases. None was promoted.

`scripts/quality/check-speaker-identification.py` now provides a reproducible
single-speaker gate. It excludes enrollment from accuracy, rejects missing and
duplicate results, requires detected speech and one speaker, and fails wrong or
missing identities. No speech is not credited as successful unknown rejection.
Mixed references are rejected because they require the separate timeline scorer.
Seven gate tests passed. The full-clip human pilot passes 6/6 queries; the duration
stress set correctly exits nonzero with 17/24. Input hashes accompany each report.

```sh
python3 -B -m unittest discover -s scripts/tests -p test_speaker_identification_gate.py
python3 scripts/quality/check-speaker-identification.py   build/qualification/production-hardening-2026-09-05/speaker-accuracy/human/corpus.json   build/qualification/production-hardening-2026-09-05/speaker-accuracy/human/results.json   build/qualification/production-hardening-2026-09-05/speaker-accuracy/human/matches.json   /private/tmp/harc-human-identification.json
```

Evidence is in `human/duration/`, both mixed-corpus `vad-spans.json` files, and
`offline-sweep/` (all completed outcomes, errors, settings and probe source).
These are additional failure characterization and evaluation-tool changes, not
new production accuracy claims.

## Sortformer comparison — retained, not promoted

The full-precision offline Sortformer model already supported by pinned FluidAudio
0.15.5 was evaluated in isolation. Official model revision
`ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1` contributed 241,582,803 downloaded bytes;
all sizes and SHA-256 hashes are retained. Harc's existing WeSpeaker extractor and
identity matcher were used on the new segmentation masks. Each comparison rebuilt
its enrollment from the same source clips; compatibility with existing user
profiles was not assumed. No production model selection or user data changed.

Full-clip human queries still pass 6/6, with enrollment excluded. Source-window
identity agreement on human mixtures changed as follows:

| Human fixture | Current pipeline | Sortformer comparison |
| --- | ---: | ---: |
| Two known sequential voices | 0% | 40% |
| Known and unknown sequential voices | 50% | 76.2% |
| Three sequential turns | 25.1% | 51% |
| Overlap | 40% | 30.4% |

The known voice that was recognizable alone is recovered in sequential mixtures,
but the other two-second known voice remains unknown. On synthetic mixtures,
Sortformer separates the two different known voices (100% source-window agreement)
but still assigns 2,000 ms of unfamiliar speech a known identity in each of the
similar-voice fixtures. Thus this is not an acceptable wholesale replacement.
Scores include natural pauses, are not standard DER, and do not establish meeting
accuracy. The model's four output slots also need consideration before any wider
integration or long-form claim.

All three comparison runs completed. Execution JSON retains elapsed time and
maximum child RSS (cumulative high-water mark of the sequential runner). Source,
model provenance, results, identity decisions and timelines are under `sortformer/`.

The single-speaker evaluation gate was also hardened against empty, all-zero and
nonfinite embeddings and invalid speech intervals. Nine checker tests pass; the
existing six-query human pilot and Sortformer control result remain 6/6.

The remaining failure is a speaker region containing multiple real identities.
Further work should evaluate time-resolved identity evidence against the enrolled
profiles, rather than assuming a pooled region embedding can safely name every
word in that region. No setting tested here closes that gate.

## Time-resolved identity experiment and profile-source diversity

Two-second windows (one-second stride, midpoint output ownership) were scored
against the unchanged full-clip enrollment. This recovered changing identity
evidence inside merged regions: the synthetic known/unfamiliar case improved
from 50% to 93.8% source-window agreement, with wrongly named unfamiliar speech
reduced from 2,000 ms to 250 ms. Other synthetic sequential cases improved too.
However, two valid full-clip human controls retained their correct name for only
48.2% and 30% of source-window time. Window-only labeling was not adopted; it
throws away useful longer-context evidence. These are diagnostic source-window
figures, not DER. Raw and canonical-name-mapped decisions are both retained under
`window-identities/`; the two synthetic enrollment IDs are explicitly mapped to
the original reference display-name capitalization.

Inspection also found a production evidence-selection bug: three observations
of one recording/speaker could occupy all three compact recognition prototypes,
even when other recordings existed. A regression reproduced `[15000,15000,15000]`
for the selected speech durations rather than `[8000,9000,15000]`. Adding the local
embedding for that same speaker could consume another duplicate slot.

Pack construction now selects at most one valid prototype per recording/speaker
source across local and remote evidence, retaining the existing duration/segment
ranking and deterministic ID ordering. Invalid vectors consume no slot. Historical
observations remain intact. This affects newly constructed packs; it does not
rewrite already cached client packs or claim independent human accuracy gains.

The regression now passes, together with 22 PeopleStore XCTest cases and three
domain Swift Testing cases (25 total, zero skips). The diagnostic Xcode app build
passed. Exact sources, the failing/passing logs and build evidence are retained
under `profile-diversity/`. This fixes lost enrollment diversity; short mixed-voice
separation and identity timing remain open.

## Expanded enrollment and actual daemon-to-Host integration

Two more utterances per known human speaker were selected lexically before scoring,
excluding all original query files. All eight additional clips produced one
speaker. Three-prototype matching improved speaker 260's window-level name coverage
from 30% to 75%, but the duration score remained 17/24 and the mixed-voice results
were unchanged. Wider enrollment alone is not the missing segmentation fix.
Sources and outputs are retained under `human/multi-enrollment/`.

The actual built `harc-stt` executable was then launched on an isolated, privately
owned Unix socket. Ten human clips passed through its real JSON request/response
path. Segment timelines and embedding values exactly matched the prior direct-model
outputs. A nonexistent input returned an explicit error; a following valid request
succeeded. The daemon accepted shutdown and exited zero. No installed daemon or
user library was touched.

Daemon-produced embeddings were passed through the actual compiled RecordingStore
Host decision code in an isolated in-memory database. Four enrolled query speakers
received the correct canonical stored names; two unenrolled speakers remained
unnamed. Replaying each observation returned the identical decision. This verifies
application logic and IPC, not disk persistence across restart, Host network
transport, the Swift client wrapper, live capture or UI behavior.

An initial run logged an E5RT/Core ML shape warning during ASR startup. Follow-up
runs waited for explicit `modelLoaded: true` and `modelState: ready`, then submitted
real transcribe requests with VAD, timestamps and diarization enabled. All six human
query clips returned text and one speaker embedding. Compared with the published
LibriSpeech references, there were two word edits across 169 words (1.183% WER).
Errors were FEVEVER for FEVER and Adonna for ADONA; no benchmark-specific corrections
were added. These transcription-produced embeddings also passed all six Host name,
storage and replay checks. The backend warning persisted but did not prevent these
requests; its internal cause was not established by this run.

Evidence under `daemon-ipc/` includes executable/source hashes, protocol outputs,
status, error/recovery and shutdown records, direct-output comparisons, Host
decisions and exact harness source. `asr-pilot/` retains reference/hypothesis text,
normalization rules, per-case and aggregate WER, speaker outputs and joined Host
verification. Enrollment clips are excluded from the six-query ASR score. This is
a small clean-audiobook integration pilot and does not supersede the failing short
mixed-voice gate at the top of this document.

## Mixed-voice transcription exposes missing later turns

The actual built daemon was exercised on all four constructed human mixtures,
with explicit ASR readiness, real `transcribe` IPC, timestamps and diarization.
The three-turn fixture returned only `He gave way to the others very readily.`
Its final token ended at 2240 ms although detected speech continued in intervals
2801–3864 ms and 4995–6500 ms. A nonempty successful result therefore did not
establish transcription completeness or speaker-attributed content coverage.

A separate daemon run with VAD disabled produced identical text for all four
fixtures. This is expected from the inspected source: clips at or below 30 seconds
already bypass VAD. Silence trimming does not explain this particular omission.
The decoder/model cause remains unresolved; do not attribute this observation to
the Core ML warning without separate evidence.

A diagnostic cropped each detected segment with up to 200 ms of original context
on each side, using only model-produced boundaries, and transcribed each excerpt
independently. The three sequential excerpts returned `He gave way to the others
very red`, `Hay fever`, and `The place he had was a very`. However, the two overlap
excerpts returned empty text and `Yeah.`. This is evidence that resetting the
recognition context can recover missing sequential speech, not justification for
shipping segment-by-segment decoding. Crops and exact boundaries/hashes are
retained in `daemon-ipc/mixed-segment-asr/corpus.json`.

`scripts/quality/check-transcript-speaker-coverage.py` now flags detected speech
segments with no overlapping lexical token. Punctuation alone is insufficient;
missing speaker evidence and daemon errors require review; malformed timestamps,
duplicate IDs and empty evaluations are invalid. This is a diagnostic only:
timing overlap cannot establish correct words, correct identity, or full coverage.
It must not replace WER or annotated speaker evaluation. Seven focused Python
regressions pass. The six clean query controls produce no flags; the four mixed
queries flag the three-turn omission, both with and without VAD. Independently
decoded excerpts also flag the empty overlap result.

Evidence is retained under `daemon-ipc/mixed-asr/`, `mixed-asr-no-vad/` and
`mixed-segment-asr/`, including actual responses, coverage reports, shutdown/exit
records, executable hashes and harness sources. All three daemon processes exited
zero. No production decoding change, installed app, or user library was modified.
Next work must address missing sequential speech while retaining overlap and clean
control behavior, alongside the still-open speaker separation/identification gate.

## Decoder limits and selective coverage retry diagnostic

A direct FluidAudio v2 probe compared the default 10 symbols/step and 150
 tokens/chunk with 100 symbols/step and 1000 tokens/chunk. All eight enrollment
and mixed inputs produced identical text and final token times. The three-turn
omission is unchanged. Inspection of the pinned dependency also shows that its
consecutive-blank limit applies to finalization after encoder frames are exhausted,
not an early silence break during ordinary frame processing. No production decoder
limits were changed. Exact probe, configuration, outputs and hashes are retained
under `decoder-limits/`.

A subsequent offline composition diagnostic used the already-executed segment
requests only where the original detected segment had no overlapping lexical token.
It recovered the two omitted sequential turns (`Hay fever` and `The place he had
was a very`) and left the other three mixed responses exactly unchanged, including
the original overlap response. Retried timestamps were rebased to the original
recording; only tokens whose midpoint fell inside the triggering segment were added.
The resulting four responses have no empty-segment flags, but that check cannot
prove correct words or names. In particular, preserving the overlap response does
not fix its existing transcription/identification errors.

This is a promising recovery direction, not a shipped fix: the diagnostic composes
saved responses and has not implemented or tested live bounded retries, failure
markers, cancellation, false-positive diarization, long recordings, or the actual
Client finalize path. Retained evidence under `daemon-ipc/coverage-retry-diagnostic/`
includes the exact composition harness, source-input hashes, added-token audit and
coverage report. Production acceptance still requires these broader checks and the
original speaker-accuracy gate.

## Actual Swift Client path and WAV header crash fix

The compiled `HarcSTTClient` → `ChunkedTranscriber.finalize` →
`TranscriptPlainTextRenderer` path reproduced the three-turn omission. Its stored
processing coverage had empty degraded/failed ranges despite the omitted speech.
This demonstrates a real completeness-reporting gap, not merely a Python IPC
harness result. Baseline outputs are in `daemon-ipc/client-finalize/`.

A live Swift recovery prototype then used the actual client for independent retries
on detected segments with no lexical word overlap, wrote temporary audio excerpts,
rebased token timestamps, and rendered the result. It recovered both later turns,
but the first clean control crashed with `load from misaligned raw pointer`.
Inspection found an aligned UInt32 load from a sliced Data buffer in WAVChunker's
RIFF chunk walk, plus missing padding advancement for odd-sized RIFF payloads.

WAVChunker now uses an explicit unaligned little-endian load and advances past the
mandatory even-byte RIFF padding. Regression fixtures contain metadata payloads of
one, two and three bytes; sliced sample order/amplitude is checked within the
existing conversion's one-PCM-quantum tolerance. Six focused Swift Testing tests
pass (the new parameterized test covers all three fixtures), and the diagnostic
Xcode app build passes. No decoder or speaker-matching configuration was changed.

After rebuilding, the live Swift recovery prototype completed all ten queries:
four mixtures and six clean controls. Both missing sequential turns were recovered;
all six clean transcript texts exactly matched the earlier actual-daemon results.
The other three mixture texts were preserved. The daemon shut down with exit zero.
The third voice still renders as Speaker 1 rather than a distinct third speaker;
text recovery does not fix the diarization/identity failure.

Evidence is in `wav-alignment/` and `daemon-ipc/client-recovery-fixed/`, with exact
source/artifact hashes and harnesses. The earlier incomplete crashing run remains
in `daemon-ipc/client-recovery/`. The retry itself is still a diagnostic prototype:
it does not yet implement production retry budgets, recovery failure markers,
all cancellation boundaries, signed coverage updates or durable chunk integration.
Those remain required alongside real-world speaker qualification. Only the WAV
parsing fix is implemented in the application source during this step.

## Segment-first identity extraction: improved separation, failed controls

An isolated candidate extracted independent embeddings for each detected short
segment before grouping them. Existing 0.65 similarity and 0.05 ambiguity margins
were retained; overlapping segments could not be merged. With the original whole
clip plus exclusive masks, the human three-turn case separated into three speakers,
but single-speaker enrollment 260 split into three and query 121 split into two.
The normal enrollment matcher correctly refused this ambiguous enrollment; no
candidate enrollment success is claimed.

A second candidate extracted each segment from its original audio excerpt with
rebased exclusive masks, rather than passing the entire mixed waveform. That
restored enrollment 260 to one speaker, but query 121 still split into two. Its
first roughly 1.15-second phrase had only 0.51 similarity to the existing correct
profile; the later phrase matched at 0.778. Thus simply lowering the grouping or
identity threshold is not supported by these results.

For explicit compatibility diagnostics only, both candidates were scored against
the unchanged baseline enrollment pack. Mixed source-window agreement was 42.4%,
50%, 52.5%, and 40% (two-known, known/unknown, three-turn, overlap). This improves
some segmentation/attribution compared with the earlier candidate, but does not
resolve names for all turns or the continuous known/unknown merge. Scoring against
an existing pack does not erase the first candidate's enrollment failure.

Both candidates remain outside production source. Exact candidate code, compile
scripts, model outputs, baseline-pack input joins and scored results are retained
under `segment-first/`. This narrows the failure: extracting before grouping can
separate distinct turns, but short within-person voice evidence can still produce
false splits. Production promotion requires those clean controls to pass as well
as the mixtures, without tuning a threshold solely to these examples.

## Longer human turns and order reversal

The same known human query speakers 61/121 and unenrolled speaker 672 were tested
with three- and five-second original prefixes. Each known pair, known/unknown pair
and three-person sequence was constructed in forward and reverse order with 250 ms
gaps, yielding twelve additional development mixtures. These remain constructed
speech excerpts, not held-out natural meetings. Source hashes, sample windows and
complete audio are retained under `human/turn-length/`.

| Turn duration | Known pair, forward/reverse | Known/unknown, forward/reverse | Three speakers, forward/reverse |
| --- | --- | --- | --- |
| 3 s | 44.4% / 0% | 50% / 50% | 23.2% / 24.0% |
| 5 s | 80.5% / 79.9% | 49.4% / 50% | 77.3% / 78.9% |

These percentages are source-window exact identity-set agreement, not DER. The
three-second known/unknown forward case is materially worse than its aggregate
50% suggests: the detector merged both voices into one segment, and its mixed
embedding matched enrolled person 61 at 0.71185. That applied a known name over
2622 ms of the unfamiliar human's source window. The reversed order returned no
known identity. The five-second known/unknown cases still merged both voices but
did not assign a known name.

A fresh compilation from current Diarizer sources reproduced all sixteen outputs
(four enrollment plus twelve queries) exactly in both segments and embeddings.
This confirms that false known-person attribution is present in human audio, not
just the synthetic stress fixture. Longer context improves some cases, but duration
alone is not a reliable fix. Existing segment-first candidates cannot split a
single continuous detected segment and therefore do not resolve this failure.
No threshold or production source was changed for this experiment.

## Host matching must not corroborate a recording with itself

The human mixed embedding was passed through actual compiled RecordingStore logic
in an in-memory library. Host assigned and persisted person 61, confirming the
false name reaches canonical storage. A subsequent full query from unfamiliar
speaker 672 remained unknown; this experiment does not prove a cascading human
misidentification. Its result report deliberately fails the mixed-input expectation.
The probe's top-level thrown evaluation failure caused SIGTRAP after writing the
report; that is a harness assertion, not a Store crash.

Inspection found that automatically matched observations become future recognition
evidence. Independently, fresh operations could match a recording against its own
prior observation or local embedding copy. Host reevaluation now excludes the
recording being evaluated from both candidate branches. This prevents self-evidence
from manufacturing a fresh successful decision after independent evidence disappears.
Exact operation replay still returns the immutable original decision.

A regression first matches Alice from another recording, removes that external
link, and adds a local embedding copy to the incoming recording. A fresh operation
must return noMatch despite its previously matched remote observation and local
copy, while the original operation still replays identically. The regression and
existing focused suites pass: 23 XCTest cases plus three Swift Testing cases,
zero skips. The diagnostic Xcode build also passes.

This does not erase historical names or solve the broader problem of inferred
observations becoming cross-recording enrollment evidence. Manual-confirmation
provenance and protection against cross-recording feedback remain open. Exact
source, tests, logs and the human Host report are retained under `feedback/`.

## Confirmed enrollment is separate from automatic assignment

The cross-recording feedback path is now guarded in source. `person_speakers`
records explicit confirmation provenance. Host-generated assignments are unconfirmed
and cannot contribute to Host matching, exported recognition prototypes, or local
per-person enrollment queries. Displayed names and historical decisions remain.
Explicit linking, suggestion confirmation, canonical user assignment and user-driven
split operations authorize enrollment. Merging people retains each link's provenance.
A conflicting automatic result preserves an existing manual assignment and returns
pendingReview. An automatic name alone no longer advances the recognition-pack
revision, avoiding a revision/retry cascade without new trusted evidence.

Migration v20 preserves legacy links by default, then marks historical automatic
assignments unconfirmed where an immutable matched observation has the identical
recording, speaker index and assignment timestamp. That timestamp was written to
both records in the same transaction. Later manual confirmations have a new timestamp
and remain eligible. Existing labels and observations are not deleted. Where evidence
eligibility changes, profile and pack revisions advance so cached packs can refresh.
Already-issued cached packs are not retroactively rewritten; client refresh remains
necessary before they reflect this migration.

Tests cover inference exclusion through both local-copy and remote-observation paths,
explicit confirmation enabling later recognition, preservation of a conflicting
manual link, no pack-revision change for a new automatic assignment, previous-schema
migration, repeated migration and reading the migrated flags through a second
file-backed database connection. The final focused run passes 25 XCTest cases plus
three Swift Testing cases, zero skips; the diagnostic Xcode app build passes.
The actual compiled Host replay on six human query outputs still returns four correct
known names and two unknowns, with canonical storage and identical operation replay.

Exact sources, tests, build/test logs and human Host decisions are retained under
`confirmation/`. This closes the identified automatic-enrollment feedback mechanism,
not the underlying mixed-voice false-name problem. Automatic naming remains
unqualified by the human mixture evidence above. No installed user library was
migrated and no release was published during this diagnostic work.

## Automatic assignments enter the existing confirmation flow

New automatic Host assignments now create a pending suggestion for the same speaker
slot, using the existing Inspector `May be…` / Confirm / Dismiss surface. Replaying
the same operation remains side-effect-free. `PersonSpeakerLink` also projects
`isUserConfirmed`; its historical `confirmedAt` field alone is no longer described
as proof of human confirmation. Explicit person-picker linking clears stale pending
suggestions for that slot. Confirming through the existing suggestion action makes
the evidence eligible, and subsequent automatic reevaluation does not reopen the row.

Tests exercise automatic/unconfirmed projection, queued review, correction/confirmed
projection, queue cleanup, Confirm and repeat evaluation. Final validation passes
25 XCTest plus three Swift Testing tests and the diagnostic macOS app build. One
intermediate test setup intentionally assigned identical evidence to two different
people before its next recognition assertion; the resulting abstention was correct.
Confirmation and contradictory-assignment scenarios are ordered independently in
the final regression. Retained logs distinguish that failed setup from the final run.

This verifies the store integration with the existing view/callback wiring, not a
new on-screen UI qualification. Previously stored automatic links are not bulk
backfilled into the review queue by this change; the existing person picker can
still confirm them explicitly. Sources, logs and hashes are retained under
`confirmation-review/`. Mixed-voice model accuracy and production retry integration
remain open.

## Speaker review rendered on screen; interaction remains unverified

The actual compiled SpeakerNameEditor was hosted in a disposable AppKit window
with an in-memory RecordingStore. A real automatic Host observation supplied the
pending row. The screenshot shows the name, `May be Alex`, and visible Confirm
and Dismiss buttons without clipping. Store state reports one pending suggestion
and `isUserConfirmed: false`. The fixture uses deliberately identical vectors and
therefore displays similarity 1.00; this is rendering evidence, not voice accuracy.

Live button interaction could not be verified. The graphical session reported
`CGSSessionScreenIsLocked = 1`; activation and accessibility window lookup failed,
and the attempted screen-coordinate click did not change the store state. Both
unbundled and temporary app-bundle harnesses were tried. The owned processes were
terminated; no installed Harc library was used. `review-ui/` retains the screenshot,
harness, source hashes and explicit incomplete-interaction result. The previously
passing store confirmation tests remain separate from this on-screen check.

## Stale confirmation cannot undo a newer correction

`confirmSuggestion` previously accepted a person/recording/speaker tuple even after
the suggestion disappeared, allowing a delayed UI action to replace a newer manual
assignment. Confirmation now checks for the pending row inside the same database
transaction as the assignment. Without that row, it only accepts an identical,
still-confirmed assignment as an idempotent duplicate; otherwise it fails without
changing the link. A duplicate does not advance the recognition-pack revision.

Unlinking, signed canonical identity assignment and manual speaker splitting now
clear pending suggestions for their affected slots. Person-picker linking already
does so. Tests cover stale confirmation after correction and unlinking, duplicate
confirmation, split cleanup and canonical assignment/replay. The final focused run
passes 26 XCTest cases and six Swift Testing cases (32 total, no skips), and the
macOS diagnostic app build passes. Exact sources and logs are in `stale-review/`.
This protects correction/enrollment authority while mixed-voice model accuracy,
production missing-speech recovery and live UI interaction remain open.

## Dismissal rejects the automatic assignment, not just its review row

Dismiss previously hid the suggestion while leaving its automatic Person link and
canonical name intact; Host reevaluation also ignored the saved dismissal. Dismiss
now removes a corresponding unconfirmed assignment and removes its mirrored name
only when that name still equals the rejected Person. It advances the recording
revision/change feed. A confirmed assignment is preserved, and a stale Dismiss of
that confirmed person does not record a rejection. The inspector reloads resolved
labels after dismissal.

Host evaluates the normal winner/ambiguity first, then respects a saved dismissal
for that recording/speaker/person; it does not promote an inferior candidate just
because the winner was rejected. New operations return noMatch without recreating
the rejected name or suggestion. Historical exact-operation replay remains immutable.
Explicit person-picker linking, suggestion confirmation and signed canonical
assignment clear the corresponding dismissal, allowing intentional reversal.

Tests verify automatic-name removal, recording revision advancement, fresh-operation
rejection, absent replacement review row, explicit reversal, confirmed-name protection
and canonical dismissal clearing. The final run passes 26 XCTest cases plus six
Swift Testing cases (32 total, no skips); the diagnostic Xcode build passes.
Evidence is retained under `dismissal/`. This does not bulk-repair historical user
libraries or establish live UI interaction on the locked graphical session.
Underlying mixed-voice identification and missing-speech recovery remain open.

## Failed-audio markers survive derived output

Inspection before integrating coverage retries found another silent-loss boundary:
failed chunks had visible markers in `SessionTranscript.joinedText`, but labelled
transcript rendering, summary adaptation and exports rebuilt their output from timed
words, where those notices were absent. Those paths could hide an acknowledged
failure from the user or downstream summary input.

`UntranscribedAudioMarker` now owns the existing generated format and its bounded
parser. Transcript rendering, summary input and document export preserve these
notices in chronological order as separate, unattributed text. Subtitle cue creation
also preserves them without a speaker label, and ExportService supplies them to both
SRT and VTT rendering. Without usable word timings, document output preserves all
original fallback text. The parser accepts only the exact generated notice format,
rejects malformed/overflowing times, and retains the original notice text. Existing
human-readable notice times have second precision; this is not new precise speech
alignment evidence.

The final test run against compiled application modules passes 29 Swift Testing
cases, including the existing transcript, summary adapter and subtitle regressions.
Tests check leading/middle/trailing notices, no speaker attribution, SRT/VTT output,
no-diarization fallback, missing-timing fallback, Unicode surrounding text and invalid
timestamps. The final diagnostic Xcode build passes. Sources and logs are retained
under `failure-marker-output/`. This closes failure-notice propagation through these
software output paths; it does not yet implement production retries for the missing
human speech demonstrated above or qualify physical capture/end-to-end exports.

## Production finalization recovery — September 7

`ChunkedTranscriber.finalize` now retries diarized speech intervals with no lexical
word overlap, before vocabulary replacement. It reads excerpts from the saved master,
uses local ASR with VAD and diarization disabled, rebases valid timed words and retains
original diarization. Each owned interval is at most eight seconds plus 200 ms context
on each side. Recovery starts at most eight requests within a 60-second admission
budget; each production IPC request retains its separate 60-second timeout. This is
not a strict 60-second total stop deadline. Combined PCM buffers are capped at 32 MiB.
Short AVAudioFile reads before EOF are accumulated; an actual early EOF stays a failure.

Original text must match its timed tokens and be unedited before merging. Cancellation,
invalid/empty results, unavailable audio or exhausted budgets produce visible notices
and `stt.speech_without_text` coverage issues. Temporary excerpts are deleted and the
master is never modified. Existing acknowledged failed intervals are not retried here.
Original chunks retain their initial decoder evidence; final text/words include repairs.

The actual compiled finalizer and daemon were run on four constructed human mixtures
and six clean held-out human utterances (plus four enrollment diarizations). The
three-turn sample now retains the original first phrase and restores `Hay fever` and
`The place he had was a very`. The other three mixed transcripts and all six clean
transcripts are byte-for-byte unchanged from their respective prior baselines. Mixed
speaker segments are unchanged, including the incorrect merged speaker. Invalid input
returns an error, the next valid request succeeds, and daemon shutdown exits zero.

The focused run passes 53 Swift Testing tests, no skips, against compiled application
modules. It includes existing ChunkedTranscriber/output tests and new PCM16/Float32
recovery, master preservation, temporary cleanup, invalid timestamps, empty results,
request caps, prior failures, manual edits, and cancellation before/after a response.
The diagnostic Xcode app build passes. Evidence, exact source copies, binary hashes,
logs, corpus references and comparisons are under `daemon-ipc/production-recovery/`.

This closes the demonstrated missing-turn recovery defect, not general completeness:
a diarized interval containing even one lexical token is not inspected for partial
omissions, absent/mistaken diarization can miss or falsely flag speech, and an ASR retry
can itself be inaccurate. Overlap and mixed-voice identification remain unqualified.
No release, installed-app replacement, or real user-library migration was performed.

## Raw segmentation isolates the merged-voice failure — September 7

A new local probe inspected `SegmentationProcessor.getSegments` directly, retaining
both the binarized speaker channels and all seven raw powerset scores before any
embedding extraction, speaker tracker, centroid aggregation or person matching.
It used the same model and source-window plan on all ten original human clips
(four enrollment and six query) plus the twelve longer/reversed constructed mixtures.
All 22 cases completed; the corpus, outputs, probe, exact dependency source and
hashes are retained under `human/raw-segmentation/`.

All four known/unknown mixtures (three/five-second turns, forward/reversed) activate
only local channel 1 throughout detected speech. There is no second detected voice
for the downstream tracker to preserve. This directly locates the previously proved
false-known assignment upstream of identity matching. Both two-known mixtures at
both durations do activate two channels. The three-person sequences activate only
two channels, consistent with their merged-speaker failure.

The original single-person query 260 also activates a second channel for 23 nominal
frames in a window. This is another reason not to equate each raw channel with a
new person or promote segment-first extraction without clean controls. Raw channels
are local to each ten-second model window, not stable person IDs. Windows overlap;
these counts do not measure unique duration or standard DER, and nominal frame-grid
times are approximate.

No application threshold, model or speaker-assignment rule changed in this step.
Changing the name-match threshold alone cannot recover a speaker transition absent
from segmentation. The next candidate needs independent change detection or a better
segmentation model, evaluated against the same clean controls and unseen natural
conversation before production adoption. Existing unknown rejection and confirmation
provenance remain necessary but do not close this accuracy defect.

## Independent short-embedding change detection — September 7

A separate diagnostic compares nonoverlapping two-second voice embeddings, drawn
at one-second strides with at most a one-second gap between compared windows.
It does not use the segmentation model's speaker channels. Existing clean-control
embeddings were reused unchanged; the twelve three/five-second human mixtures were
newly evaluated. Evidence is under `human/change-detection/`.

The minimum within-person cosine across six original clean query clips is 0.20115.
All sixteen constructed transitions have a lower-cosine pair within one second of
the reference boundary. The four known/unknown transitions score -0.0051, 0.0359,
0.0268 and 0.0656. This contrasts with the raw segmentation model's complete failure
to detect a second channel in those four recordings. This first measurement is
optimistic recall selected around known boundaries, not an executable segmentation
result or a calibrated threshold.

A concrete diagnostic freezes a round 0.20 threshold, groups candidate times within
one second, and takes the minimum-cosine candidate per group without consulting the
reference. It matches 15/16 transitions within one second, creates two extra cuts,
and misses one transition. The missed prediction is 1,125 ms late in the reversed
five-second three-person case. The other extra cut occurs in the reversed known pair.
Original clean controls have zero triggered changes at this threshold. Thresholds
0.35 and 0.45 falsely cut one of six controls; 0.55 and 0.65 falsely cut four.

After freezing the rule, six additional previously unused speaker IDs were selected
by numeric rank 7–12 from the retained public LibriSpeech test-clean archive: 1089,
1188, 1221, 1284, 1320 and 1580. For each, the lexically first clip lasting 6–30 seconds
was selected before inference. The fixed rule triggers no changes in all six;
minimum within-person cosines range from 0.51394 to 0.66323. Source member/audio hashes,
selection script, vectors and scores are retained in `change-detection/heldout/`.
These are unseen speakers for this detector, but still clean audiobook speech from
the same corpus. They do not qualify noise, overlap, microphone changes or meetings.

No production code changed. This is a candidate independent change signal, not a
finished diarizer: timing/refinement, false extra cuts, unseen mixed-speaker trials,
name attribution after splitting and computational cost on long recordings remain
unverified. The signal justifies pursuing boundary refinement; it does not justify
promoting a threshold tuned to the original six controls into production.

## Unseen mixture check and dense-grid refinement — September 7

The frozen coarse change detector was evaluated on 24 new constructed mixtures from
the six additional speakers. Numeric adjacent pairs (1089/1188, 1221/1284, 1320/1580)
were tested in both orders, with three/five-second prefixes and zero/250 ms gaps.
Selection was fixed before scoring. Each recording contains exactly one source
transition. Corpus/audio hashes, preparation, scoring, vectors and outputs are in
`human/change-detection/heldout-mixtures/`.

The unchanged coarse rule finds 21/24 transitions within 1,000 ms, with zero extra
cuts at that tolerance. At 500 ms it matches 16/24; at 250 ms only 11/24. All three
undetected cases place 1188 before 1089. This shows that the initial development
result does not generalize perfectly even to constructed clean audiobook mixtures,
and a one-second tolerance conceals unsuitable boundary placement. A prediction
outside tolerance counts as both an extra prediction and a missed true transition;
these are event counts, not separate physical false-speaker episodes or DER.

A subsequent development candidate changes only sampling stride from 1,000 to 250 ms,
retaining two-second embeddings, threshold 0.20 and the same candidate-group/minimum
rule. It evaluates all 12 clean controls plus the 12 original and 24 new mixtures.
Because this refinement follows their results, none of these 48 cases is held-out
for the refined candidate. Evidence is in `human/change-detection/dense/`.

| Dense-grid subset | True transitions | Matched within 250 ms | Within 500 ms | Within 1,000 ms | Extra predictions at 1,000 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original mixtures | 16 | 9 | 12 | 16 | 2 |
| New mixtures | 24 | 11 | 17 | 24 | 0 |

The denser grid also produces a false change in one of twelve clean controls, where
the coarse detector had none. It therefore fails the no-regression requirement.
More sampling improves broad change detection but does not by itself locate the
actual transition; choosing a minimum distance can favor a point well inside speech.
No production code, model, threshold or naming behavior was changed. A viable next
candidate must separate detecting a possible voice change from refining its boundary,
retain clean-speaker stability, and then prove correct name assignment after splitting.

## Silence handling does not fix the clean false split — September 7

The low-similarity pair responsible for the dense detector's query-121 false split
compares 1,500–3,500 ms with 3,500–5,500 ms (cosine 0.03181). Local VAD detects speech
at 412–1,892 ms and 2,460–6,755 ms. Thus the first window contains about 1,432 ms of
speech across a pause; it is not predominantly silence. The same local VAD probe
completed all 48 current development recordings.

An occupancy experiment requires at least 1,500 ms detected speech in each compared
two-second window. With other detector settings unchanged, this removes all false
clean cuts, but finds only 9/16 original transitions and 22/24 new transitions within
one second. Nine of forty true transitions are lost. Evidence, VAD spans, scoring
and input hashes are retained under `human/change-detection/speech-supported/`.
This occupancy cutoff is rejected as a production solution.

A separate full embedding rerun retains the original waveform and supplies VAD
activity masks to the embedding extractor. The mask uses the model's nominal
10-second frame grid; its existing short-input repeat-padding handles the corresponding
real two-second waveform and activity-mask prefix. All 48 recordings complete.
Invalid/zero vectors are omitted from the diagnostic window inventory, never treated
as evidence of a new voice. The 0.20 threshold, 250 ms grid and grouping rule remain
unchanged; the 1,500 ms occupancy cutoff is not applied to this experiment.

Masking still falsely splits one of twelve clean controls. It finds 14/16 original
transitions plus 24/24 new transitions within one second, with one extra cut in each
mixture group. Within 250 ms it finds only 7/16 and 11/24 respectively. This fails
clean stability and loses recall relative to the unmasked dense candidate. The
masked probe, sources, VAD inputs, output vectors, scores and hashes are retained
under `human/change-detection/masked/`. Neither variant changes production behavior.
Silence handling alone does not establish a reliable voice-change decision; a next
candidate needs corroborating voice consistency on each side, with boundary precision
and clean-control regressions tested separately.

## Corroborated voice change and actual identity matching — September 7

A development detector now requires two two-second windows on each side, offset by
one second. Within each side, cosine must be at least 0.65; all four cross-side
cosines must be below 0.20. It retains the 250 ms grid, at most one-second gap
between the inner windows, and prior candidate grouping. No reference labels enter
prediction. This uses the original unmasked dense embeddings and is not a held-out
or calibrated production rule. Sources, inputs and scores: `change-detection/corroborated/`.

It produces no cuts in all twelve clean controls. In the original mixtures it
matches 14/16 boundaries within 250 ms, 15/16 within 500 ms and 16/16 within one second,
with no extra predictions at the one-second tolerance. In the newer mixtures it
matches 13/24, 17/24 and 19/24 respectively; at one second it has one extra prediction
and five misses. It therefore improves clean stability and original-case precision,
but remains incomplete on the broader development set.

The four original known/unknown cases were then cut at the detector's predicted
boundaries, without reference correction. Each resulting original-audio fragment was
independently embedded and passed to the actual compiled `SpeakerRecognitionMatcher`
using the unchanged four-person baseline enrollment pack and existing matching rules.
The known side matches person 61 in every case (scores 0.80625, 0.79739, 0.86137 and
0.86327); all four unfamiliar sides remain unnamed. Source-window exact identity-set
agreement is 100%, 100%, 100% and 96.25% for three-second forward/reverse and five-second
forward/reverse. Unfamiliar speech assigned a known name is zero in all four, versus
the baseline three-second forward case's 2,622 ms false-known attribution.

The last case's remaining error is known-speaker audio left unnamed due to boundary
placement. The diagnostic assigns each fragment a separate speaker slot and includes
its entire source interval, including pauses. It does not integrate existing VAD/
overlap timelines, recurring-speaker clustering, or persist decisions through Host.
It demonstrates that independent boundary evidence can repair the false-name case
with the existing identity model; it does not qualify a complete replacement pipeline.
The original production behavior is unchanged. Exact cuts, audio references, vectors,
matcher results, timeline scores, source and binary hashes are retained under
`change-detection/cut-identity/`. Broader misses, boundary precision, short turns,
overlap and long-recording cost remain required work.

## Expanded fragment identity and richer enrollment — September 7

The same predicted-cut fragment extraction was extended to the eight remaining
original mixtures, then joined with the four known/unknown results. The single-
prototype matcher uses the unchanged enrollment vectors and production thresholds.
Three-second known pairs score 50% exact source-window identity agreement in both
orders; three-second three-person cases score 66.7%. Speaker 121 remains unnamed:
its short-phrase fragments have only about 0.227 similarity to its enrolled profile,
even after the mixed voices are separated. Five-second known pairs reach 98.75%,
but five-second three-person cases remain about 65.8% because speaker 121 scores
0.617/0.591 and is rejected. No unknown voice receives a known name in this variant.

A second pass uses the existing three independent enrollment utterances per known
person, with the same exact query fragments and unchanged matcher. It recognizes
speaker 121 in the five-second three-person forward/reverse cases at 0.73957/0.71706.
Their exact source-window agreement increases to 99.17%/95.83%. Other decisions are
unchanged, including the short-phrase misses. However, the reversed case now assigns
500 ms of unknown-speaker audio to known person 121 because the predicted cut occurs
too early. The earlier unnamed result had hidden that attribution consequence.

This is a failed qualification, despite the improved aggregate scores: correct
fragment-level identity does not prove that all audio assigned to the fragment is
that person. Boundary error must be tested after recognition, and richer enrollment
cannot be promoted as a complete fix for mixed-speaker accuracy. All twelve cases,
exact inputs, single/multiple-prototype matcher outputs, timeline scores, probe
sources, enrollment/cut provenance and binary hashes are retained under
`human/change-detection/cut-identity-expanded/`. No production naming, enrollment
policy, installed application or user data changed.

## Boundary refinement and residual false naming — September 7

A pause-refinement experiment retains existing corroborated changes and computes
10 ms RMS frames from the original PCM. Quiet intervals must last at least 80 ms
at no more than 1% of the recording's peak frame RMS. Snapping to the nearest quiet
interval midpoint within 750 ms worsens original-case precision from 14/16 to 10/16
within 250 ms. Long natural pauses can put their midpoint farther from a useful cut.
This rejected variant is retained under `change-detection/pause-refined/`.

A second variant moves a predicted cut the smallest distance into a quiet interval,
staying 10 ms inside its edges, with the same 750 ms movement cap. A cut already
inside a usable interval remains unchanged. No nearby interval means no movement;
colliding/reordered results retain original predictions. No reference labels enter
refinement. The twelve clean controls remain unchanged. All 16 original transitions
are within 250 ms with no extra predictions. Of 24 newer transitions, 15 are within
250 ms, 17 within 500 ms and 20 within one second; four remain undetected at one
second. These cases now all belong to development, not held-out qualification.

All twelve original mixtures were re-embedded from the adjusted cuts and scored
with the same three-prototype enrolled profiles. Five-second known pairs and both
known/unknown orders reach 100% source-window agreement. The five-second three-person
forward case reaches 100%; reverse reaches 99.33%, with 100 ms of unknown source
still assigned a known name. Its early cut moves from 4,500 to 4,900 ms, inside a
measured quiet interval spanning 4,890–5,830 ms; the source boundary is at 5,000 ms
before the inserted pause. Thus the earlier 500 ms false-name interval decreases to
100 ms but does not close. Low RMS is not proof of absent speech, and source windows
include natural pauses; this remains a source-window attribution diagnostic, not DER.
Short-phrase identity misses are unchanged (50% for three-second known pairs and
66.7% for their three-person mixtures).

Evidence under `change-detection/pause-projected/` includes exact old/new boundaries,
quiet intervals, waveform hashes, scoring scripts, regenerated embeddings, compiled
matcher decisions and binary hashes. This demonstrates why boundary tolerance alone
cannot qualify naming: every original transition passes a 250 ms event tolerance,
yet an unknown source still inherits a known name. No production behavior changed.
Quiet-pause refinement is insufficient for no-pause, overlap, noisy or short-turn
qualification and must not conceal the remaining misses and attribution errors.

## Independent ECAPA embedding evaluation — September 7

To test the remaining short-phrase identity limit independently of boundary tuning,
SpeechBrain's official [ECAPA-TDNN speaker model](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb)
was downloaded at revision `0f99f2d0ebe89ac095bcc5903c4dd8f72b367286`. Its model card
identifies Apache-2.0 licensing, VoxCeleb training and 16 kHz mono input; its published
benchmark is not Harc qualification. The 83,316,686-byte embedding checkpoint has
SHA-256 `0575cb64845e6b9a10db9bcb74d5ac32b326b8dc90352671d345e2ee3d0126a2`.
Weights were loaded strictly with `torch.load(weights_only=True)`. Features, sentence
mean normalization and network parameters follow the pinned official hyperparameters.
Inference uses local CPU with two threads; audio is read locally as PCM without an
external audio service. No remote custom model code or untrusted YAML execution is used.

The isolated runtime pins PyTorch/torchaudio 2.5.1, SpeechBrain 1.0.3 and Hugging Face
Hub 0.29.3. It is separate from Harc dependencies. The model produces 192-dimensional
vectors, incompatible with the current 256-dimensional WeSpeaker profiles; they
were never mixed or imported into the application. The diagnostic evaluated twelve
enrollment utterances, twelve full queries (four known/eight unknown), and the
original six query voices at one/two/three/five-second prefixes: 48 embeddings total.
The inference loop took 2.31 seconds after model construction/loading, with process
peak RSS 991,543,296 bytes. This excludes cold startup and is not long-recording or
CoreML performance qualification.

Scores use maximum cosine per person over three separate enrollment utterances;
this is a Python diagnostic, not execution of Harc's production matcher. At threshold
0.25 plus a 0.05 ambiguity margin, full queries are 9/12 correct with three unknown
false names; prefixes are 20/24 correct with three unknown false names and one known
rejection. At threshold 0.65 plus the same margin, full queries are 12/12 correct,
but prefixes are only 16/24, with eight known rejections. Neither threshold/margin
combination is calibrated for this model's open-set identification. SpeechBrain's
0.25 default is for pair verification, not a justified Harc naming threshold.

| Clip group | Lowest known top score | Highest unknown top score | Correct known-person rank |
| --- | ---: | ---: | ---: |
| Full | 0.7389 | 0.3893 | 4/4 |
| 1 s | 0.2795 | 0.2002 | 3/4 |
| 2 s | 0.4765 | 0.3589 | 4/4 |
| 3 s | 0.4879 | 0.4064 | 4/4 |
| 5 s | 0.6209 | 0.3803 | 4/4 |

Thus two-second-and-longer development scores have separation that the prior short
phrase did not show; selecting a threshold from that observed gap would still be
in-sample tuning. One-second identity remains unreliable. Speaker 121's two/three-
second prefix scores are 0.4765/0.4879 with margins 0.456/0.383, while its five-second
score is 0.6209. This justifies independent calibration and unseen mixed-voice tests,
not automatic model replacement. Boundary placement, diarization, model identity/
profile migration and app-runtime packaging all remain separate requirements.

Evidence in `human/ecapa/` includes pinned model/config provenance, download and
inference source, runtime versions, original audio hashes, all vectors, scores and
logs. The torchaudio-backend warning does not affect this run: the diagnostic uses
Python's WAV reader and supplies verified 16 kHz mono tensors directly. No production
model, threshold, profile or installed application changed.

## ECAPA calibration and fresh quantized-matcher confirmation — September 7

Enrollment-only calibration used two/three/five-second prefixes of all twelve
independent enrollment recordings. Each prefix's complete source recording was
excluded from its matching person profile, preventing self-corroboration. The
maximum wrong-person cosine was 0.25481; minimum correct-person score was 0.45283.
The predetermined rule adds 0.05 to the maximum impostor score and rounds upward
to 0.01, producing threshold 0.31 with a separate 0.05 ambiguity margin. This rule
was frozen before new query inference. Evidence: `human/ecapa/calibration/`.

The first fresh test selected one unused lexical 6–30 second utterance for each
known person, plus six previously unused unknown speaker IDs (1995, 2094, 2300,
2830, 2961, 3570), each at full length and two/three/five-second prefixes. All known
examples were recognized, but six unknown examples received known names. Results
were 8/10 full, 8/10 at two seconds, 9/10 at three and five seconds. These 40 examples
are correlated variants of ten recordings. Enrollment-only negatives did not span
unknown-voice variation. This failed frozen test remains in `human/ecapa/fresh/`.

Background calibration then added the earlier eight unknown speakers and their
available short variants from the initial ECAPA diagnostic, excluding both fresh
test sets. The same maximum-impostor-plus-0.05 rule produces threshold 0.46 from
maximum impostor cosine 0.40644. This expansion was motivated by the first fresh
failure; that first set is no longer an untouched validation set. The expanded rule
was frozen before inference on a second newly selected set: another unused utterance
per known person, and unknown IDs 3575, 3729, 4077, 4446, 4507 and 4970. Full and
2/3/5-second variants all pass: 40/40, including 16 known matches and 24 unknown
rejections. Same-corpus material and repeated duration variants limit independence.

The second set was also passed through the actual compiled Harc domain matcher.
A separate ECAPA-specific 192-dimensional pack contains the same three enrollment
prototypes per person, quantized with `QuantizedSpeakerEmbedding`, threshold 0.46,
and an explicit model ID bound to the checkpoint revision. All forty quantized
matcher decisions match both the expected labels and the Python diagnostic. No
WeSpeaker vectors or existing user profiles were mixed into this pack. This verifies
the existing generic protocol/domain dimension and model binding for these candidate
inputs, not Host persistence, model migration, or the application inference pipeline.

`human/ecapa/fresh-background/` retains the fresh selection, audio hashes, exact
frozen rule binding, inference and matcher source, raw vectors, scores, binary
hashes and parity assertions. Model and environment provenance remain in the parent
ECAPA evidence directory. This is promising independent clean-speech confirmation,
not release qualification: the model needs mixed/noisy/overlapping-speech evaluation,
short-turn policy, supported app-runtime packaging and safe profile migration.
One-second behavior remains unqualified; this rule was evaluated only on clips at
least two seconds long. Production model selection and stored profiles are unchanged.

## Fixed ECAPA rule on mixed fragments and controlled noise — September 7

The ECAPA threshold remains 0.46 with the same 0.05 ambiguity margin and three
independent enrollment prototypes per person. All 28 fragments from the twelve
original mixtures were re-embedded using the existing pause-projected boundaries,
without label-based correction. The actual compiled Harc quantized matcher now
recognizes the previously missed short speaker-121 phrases. Eleven of twelve cases
reach 100% exact source-window identity agreement, including all three-second cases.
The five-second three-person reverse case remains 99.33%, with the same 100 ms
unknown-source interval assigned to the known person because its boundary remains
early. This is an identity improvement with a residual boundary defect, not complete
diarization qualification. Evidence: `human/ecapa/mixed/`.

Controlled additive white noise was then applied to the second fresh set's ten
three-second query clips at 20 dB and 10 dB nominal SNR. Noise is scaled against
whole-excerpt RMS including silence, with a fixed per-recording random seed shared
across SNRs. A common waveform gain prevents clipping and is retained in provenance.
Original recordings are untouched. These are twenty correlated synthetic degradation
examples, not recordings of actual rooms, microphones, overlapping voices or meetings.

Through the same compiled matcher and frozen rule, 20 dB cases pass 10/10. At 10 dB,
9/10 pass: known person 260 is rejected, with maximum unquantized same-person cosine
0.45244 below the 0.46 threshold. There are zero unknown false names or wrong known
names at either noise level. The threshold was not lowered after this failure.
Exact generated audio, source hashes, noise seed/gain, inference and matcher inputs,
raw results, scores, rule/model/binary provenance are in `human/ecapa/noise/`.

The alternative model now has positive clean, short-phrase and limited noise evidence,
but none of this changes Harc's production inference backend or stored profiles.
Current blockers to promotion include app-runtime/CoreML compatibility, safe model-
identity/profile transition, real mixed/overlapping speech, remaining missed boundaries,
and the explicitly retained unknown-source naming error. Clips below two seconds
remain outside this calibrated candidate's evaluated range.

## Native Core ML embedding-network parity — September 7

The candidate embedding network was converted with pinned coremltools 8.3.0 using
Apple's [ML program conversion](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html)
and [bounded flexible input](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html)
APIs. Conversion explicitly retains float32 precision and targets macOS 13; this
diagnostic target does not change Harc's deployment target. Input is a batch of one
80-bin SpeechBrain filterbank sequence with 201–3,001 frames (default 301). Sentence
mean normalization is included in the converted network. Waveform-to-filterbank
extraction is still the original Python/SpeechBrain implementation, not native Swift.

Core ML CPU-only inference was executed on 100 actual feature inputs: twelve
enrollment examples, forty fresh background-confirmation queries, twenty-eight
mixed fragments and twenty controlled-noise clips. Maximum absolute normalized
embedding difference from the PyTorch results is 0.00000115484; minimum cosine is
0.999999821. The varied frame lengths check more than the single tracing shape.
Both enrollment and query vectors from Core ML were then quantized and supplied to
the compiled Harc matcher with the frozen ECAPA-specific pack. All 88 query decisions
are unchanged, including the retained noise rejection and mixed-boundary error.

The observed model load call took 0.54 s and 100 prediction calls totaled 3.13 s;
process peak RSS was 622,788,608 bytes. These figures include neither Python feature
extraction in the prediction sum nor a controlled first-install/cold-cache benchmark.
They are CPU-only diagnostic evidence, not Neural Engine, GPU, mobile, long-recording
or end-to-end application qualification.

The package remains at `/private/tmp/harc-ecapa-coreml/ECAPA.mlpackage`. Exact package
file sizes/hashes, converter source, config, logs, all feature tensors and input hashes,
Core ML vectors, matcher inputs/outputs and parity assertions are retained under
`human/ecapa/coreml/`. The isolated runtime has coremltools 8.3.0; Harc dependencies,
production inference selection and user profiles remain unchanged. Remaining native
integration requirements include independently verified Swift feature extraction,
bounded/cancellable inference, model installation/readiness and explicit profile/model
identity transitions. Existing accuracy limitations are not closed by conversion.

## Native Swift waveform-to-embedding parity — September 7

The candidate front end is now implemented independently in Swift/Accelerate as
`scripts/quality/ecapa/ECAPAFeatures.swift`. It uses the pinned feature configuration:
400-sample periodic Hamming window, 160-sample hop, centered constant-zero padding,
201 power-spectrum bins, 80 symmetric triangular mel filters, 1e-10 power floor and
80 dB dynamic-range clipping. It deliberately preserves a 400-point DFT through
precomputed Accelerate matrix operations. Model sentence mean normalization remains
inside Core ML. Input is finite 16 kHz mono PCM, bounded to 2–30 seconds; feature
cancellation is checked every 32 frames.

On the same 100 actual audio intervals, maximum feature difference from SpeechBrain
is 0.000832 dB, with mean per-case mean difference 0.00000456 dB. Feeding those Swift
features into Core ML produces maximum normalized embedding error about 0.00000104
and minimum cosine 0.99999988 relative to the reference Core ML outputs. This checks
feature shape, padding and numerical behavior across varied recordings and durations.

`NativeECAPAProbe.swift` then performs the complete diagnostic path in Swift:
AVAudioFile reading (accumulating short reads), native features, CPU-only Core ML
prediction and vector normalization. All 100 outputs were quantized using the compiled
Harc matcher, including native-derived enrollment profiles. All 88 query decisions
remain unchanged, preserving the known rejection and residual mixed boundary error.
Feature/prediction/output-write intervals total 3.27 s across these inputs, excluding
model compilation/load and source audio reads; this is not a cold-start or app latency
benchmark. The earlier feature-only measured intervals total approximately 0.21 s.

Eight independent boundary checks pass: below/above-range and empty input rejection,
NaN/infinity rejection, correct silence output at both duration bounds, and cancellation.
The runnable sources, compile commands and constraints are retained under
`scripts/quality/ecapa/`; exact binary/source hashes, features, embeddings, comparisons
and matcher outputs are under `human/ecapa/native-features/` and `swift-inference/`.
This closes native diagnostic front-end parity without making ECAPA the app's backend.
Model installation/readiness, cancellable inference orchestration, profile/model
migration and remaining accuracy qualification still require implementation and testing.

## Application speaker-model provenance plumbing — September 7

Inspection found that Core IPC speaker embedding rows had no model identifier and
six recording/recovery/Host save conversions labelled every row as WeSpeaker.
Desktop observation submission likewise hardcoded WeSpeaker. That would mislabel
an alternative model before its otherwise model-bound domain matcher could protect
it. This prerequisite is now implemented without enabling the candidate model.

`HarcCore.SpeakerEmbeddingRow` carries immutable `modelID`. The existing initializer
still emits `wespeaker_v2`; new producers can specify a model explicitly. Older JSON
with an absent field decodes as WeSpeaker. Explicit null, wrong type, empty and
whitespace-only identities fail decoding instead of falling back to legacy. Encoding
preserves the explicit field. App save conversions persist the producer's model ID,
and desktop matching/observations use it. A different model also changes the
observation operation ID, so a retry cannot reuse an immutable decision from the old
model. The existing WeSpeaker operation bytes/UUID remain unchanged, covered by a
golden regression. Model changes and retries have separate deterministic-ID tests.

The final focused run passes 62 Swift Testing tests, no skips, using the rebuilt
application modules. This includes Core compatibility, the actual app observation-ID
function, matching, recovery and output regressions. The isolated harness required
app dependency module maps and Sparkle's development framework; its successful exact
configuration and log are retained. It is not an app-hosted/UI test session. The
final Xcode diagnostic app build also passes, with the updated Core source copied to
the isolated daemon source before its build.

The actual daemon returned explicit `wespeaker_v2` metadata on all ten retained human
cases, recovered from an invalid request and shut down with exit zero. Exact comparison
of vectors/segments to the prior IPC baseline is retained in `verification.json`.
Evidence and source snapshots are under `daemon-ipc/model-provenance/`.

Model-pack selection, historical-row migration and existing WeSpeaker-specific UI/
reprocessing selectors are deliberately still open integration work. No ECAPA producer
is connected to the resident app, and old clients are not qualified to receive ECAPA
results merely because they ignore unknown JSON fields. Explicit capability/model
selection and profile lifecycle must be completed before changing the active backend.

## Resumed speaker embedding readback — September 7

The existing-transcript branch of desktop local Library reprocessing scanned all
Library embeddings, selected only `wespeaker_v2`, and reconstructed IPC rows with
the legacy default model. It now fetches only the current recording and preserves
each explicit stored model ID. Null or blank model bindings remain in the database
and are excluded from recognition; no historical model identity is guessed.
The existing model-filtered Store API remains available with its original signature.

A regression inserts two recordings containing distinct model bindings and an
unbound legacy row, then checks recording isolation, exact model/blob/duration
preservation, and the original filtered lookup. The rebuilt application modules
passed 27 XCTest and 6 Swift Testing cases, with zero failures or skips; the Xcode
Debug application build also passed. Retained source, hashes, harness, logs, and
verification are under `daemon-ipc/model-readback/`. This is diagnostic software
evidence, not a live restart/Host delivery qualification or a model rollout.
Model selection, historical profile migration, and remaining accuracy gates stay open.

## Native overlap identity stress diagnostic — September 7

The frozen ECAPA rule was tested through native Swift features, CPU-only Core ML,
and the actual compiled quantized Harc matcher on 135 constructed concurrent-voice
mixtures plus ten solo controls. All 45 pairs of the ten previously used fresh-
background speakers were mixed at -6/0/+6 dB relative whole-excerpt RMS, using
three-second prefixes and common peak scaling to avoid clipping. These are
correlated development fixtures, not new speakers or natural meeting evidence.
Source intervals include pauses; no speech-only overlap timeline is claimed.

All ten solo controls retained the expected decisions. No overlap mixture named
an absent person. All 45 unknown/unknown mixtures were rejected. Of 72 known/
unknown mixtures, 35 received the known constituent's name and 37 were rejected.
Of 18 known/known mixtures, 12 received one constituent's name and six were rejected.

The last two results are not successful speaker separation: a whole-clip embedding
and single-name matcher cannot represent both concurrent speakers. A high identity
score is therefore insufficient evidence that the attributed interval contains only
that person's speech. Before enabling this candidate for automatic naming, the
processing path needs independently validated overlap handling and enrollment
eligibility; confidence threshold changes alone do not close that requirement.
The threshold and production model remain unchanged.

`human/ecapa/overlap/` retains the pre-inference corpus and rule, source/audio/model
hashes, generation/scoring code, native embeddings, actual matcher inputs and
decisions, and source/binary provenance. There is no live capture, Host persistence,
real-room acoustics, or simultaneous physical microphone qualification here.

## Overlap signal loss in current production diarization — September 7

The same 135 mixtures and ten exact three-second solo controls were passed through
the cached segmentation model, before embedding/clustering. All 135 mixtures had
at least one detected overlap run of approximately 100 ms; none of the ten solos
had any overlap frames. Frame timing uses the nominal ten-second model grid,
clipped to real audio length; this is not exact overlap-duration accuracy or DER.

A fresh probe compiled the current production `Diarizer.swift` and window planner
against the existing helper dependencies and ran the same 145 files. Only 18/135
mixtures retained distinct overlapping speaker IDs: 14/45 unknown/unknown, 4/72
known/unknown, and 0/18 known/known. Ninety-seven mixtures returned one embedding
row and twenty returned none. All ten solos returned one row. These are timeline
and embedding counts, not cross-recording naming results.

Source inspection narrows the loss: the dependency masks overlap during embedding
extraction, returns a zero vector for insufficient isolated activity, and omits
segments whose channel cannot obtain a speaker ID. Harc then derives its short-
recording exclusive mask from that already filtered timeline. A missing second
channel therefore cannot be excluded by that mask. Clustering can also merge
channels; these counts do not assign every lost case to one cause.

The next implementation must preserve raw overlap evidence independently of
successful speaker embedding/tracking and use it for identity/enrollment eligibility.
Absence of overlap in the final named timeline cannot serve as that evidence.
Do not solve this by merely increasing a cosine threshold or assuming unrepresented
channels were silence. Broader clean, sequential-turn, long-form, and natural-
overlap validation remains required. Evidence, dependency source, probe sources,
binary hashes, raw masks, and production outputs are in
`human/ecapa/overlap/segmentation/`. Production code was not changed by this diagnostic.

## Short-recording embedding mask correction — September 7

The production short-recording re-extraction path now retains the segmentation model
and independently obtains its raw hard masks. It intersects the tracked speaker's
mask with raw overlap exclusions, conservatively excluding any embedding bin touched
by an overlap frame when the grids differ. Missing/malformed raw masks authorize
no samples. Insufficient isolated activity or invalid/zero re-extraction withholds
the row instead of retaining the earlier centroid. Published embedding duration is
capped by isolated mask duration. The current WeSpeaker backend remains active.

Twelve focused tests passed with real-model tests enabled and no skips (the initial
ordinary run passed ten and skipped two opt-in cases). A freshly compiled production
probe reran all 145 retained fixtures: every segment timeline remained identical,
all ten solo vectors remained byte-for-byte identical, and eleven embedding rows
were withheld. Aggregate probe time was 14.44 seconds versus 11.95 before, excluding
model load and without a controlled performance benchmark; short files now require
an additional segmentation inference. The diagnostic Xcode app/embedded-daemon
build passed. Sources, logs, hashes, and assertions are retained in
`human/ecapa/overlap/segmentation/mask-fix/`.

This corrects identity pooling eligibility for short recordings. It does not restore
lost overlap channels to the published timeline, recover overlapping words, or prove
that model receptive fields contain no influence from nearby voices. Raw overlap
metadata, long-recording identity/enrollment policy, and visible overlap treatment
remain open. No production-model switch, user-profile migration, or release occurred.

## Raw overlap IPC and saved transcript evidence — September 7

`SpeechOverlapRange` now carries validated nonnegative, nonempty intervals in
Core IPC. Diarization and optional combined-transcription results carry an optional
overlap array: missing means unassessed legacy output, while empty means the
producer assessed it and detected none. The diarizer collects raw overlap for each
processing window independently of embeddings/tracking, clips to owned real audio,
and merges touching support intervals. Timing conservatively covers the pinned
segmentation model's 991-sample receptive window and 270-sample hop; it is not an
exact ground-truth overlap onset/offset. The short embedding path reuses these raw
masks. Longer recordings incur a second segmentation inference per window until
that signal can be exposed directly by the dependency.

The post-stop Client finalizer carries this evidence into `SessionTranscript` JSON.
Seventy-eight focused tests passed without skips across diarizer (including real
models), IPC, finalization, saved-transcript compatibility, and related output
regressions. The diagnostic app and embedded daemon build passed. Actual daemon
IPC returned nonempty overlap ranges for all 135 concurrent-voice mixtures and
explicit empty arrays for all ten solo controls. All ranges were sorted, disjoint,
and within the three-second audio; invalid-input recovery and shutdown exit zero
also passed. Sources, hashes, logs, responses, and runner are retained under
`daemon-ipc/overlap-provenance/`. Multi-window clipping/merge has focused software
coverage; these 145 IPC cases are short clips, not long-form qualification.

This closes transport to the post-stop saved transcript, not the entire user path.
Visible overlap warnings, overlap-aware word/name rendering, other construction/
reprocessing paths, signed cross-device artifact propagation, and recognition
policy still require work. The candidate ECAPA model remains diagnostic.

## Plain-text and summary overlap attribution — September 7

The plain-text renderer now preserves detected overlap as an unattributed quality
warning and labels any word intersecting its interval as “Overlapping voices.”
It does not select a tracked person's name for those words. Adjacent nonoverlapping
words retain their ordinary attribution; intersection covers the whole word, not
just its midpoint, and an exact interval end does not contaminate the next word.
No-speaker and no-word-timing fallbacks retain the warning and original fallback
text. Missing/empty overlap evidence retains existing rendering.

The summary adapter applies the same policy. Both recording-summary and combined-
session-summary app call sites pass the saved overlap evidence. The old adapter
signature remains available for legacy producers; it makes no overlap claim.
Seventy tests passed without skips against the rebuilt app modules, including five
new attribution/fallback/session regressions and existing failure-notice/recovery
cases. The diagnostic Xcode application build passed. Sources, hashes, harness,
and logs are retained in `overlap-rendering/`.

This verifies generated plain text and structured summary inputs, not on-screen
Library behavior or model-generated summary accuracy. Document/subtitle exports,
other transcript reconstruction paths, and cross-device artifact propagation still
need equivalent treatment. Existing user-edited documents were not rewritten.

## Export overlap attribution and notice timing — September 7

The shared document export input now carries an unattributed warning and
“Overlapping voices” text for words intersecting overlap. Untimed fallback text
retains the warning. SRT/VTT cue generation also suppresses person names for
affected words, and emits an unattributed timed notice for detected overlap
intervals with no recognized words. The export service passes saved overlap
evidence to this path. Existing no-word-timing subtitle export refusal remains.

A new regression reproduced a zero-duration subtitle cue when overlap and
transcription-failure notices began simultaneously. Notices at the same timestamp
now combine into one readable cue with both texts and the longer duration.
Seventy-four focused output/recovery tests passed without skips after that fix;
the initial failing test is retained. File-level tests loaded a saved transcript
and wrote Markdown, prompt, SRT, and VTT exports, verifying overlap text survived
and the known person's name was absent from the fully overlapping example.
The diagnostic Xcode application build passed. Evidence is in `overlap-exports/`.

The document-input path used by DOCX is covered by segment assertions, but this
turn did not visually inspect a generated Word document. Live Library display,
other transcript reconstruction/reprocessing paths, and signed cross-device
propagation remain separate work. This is not a release-readiness claim.

## Library reopening and edit preservation — September 7

The Library loader now refreshes generated text only when it matches the sidecar's
flat text or a known generated rendering, and only without a manual-edit stamp.
This allows older generated speaker labels to acquire the overlap treatment while
preserving arbitrary externally edited text even when it lacks a stamp. Reopening
does not rewrite the source artifact. Known generated speaker names are resolved
from recording overrides when rebuilding the presentation.

`TranscriptDocument` retains overlap metadata through presentation replacement.
The Library header presents its warning when the editable text does not already
contain it, including protected manual edits. A regression matrix covers flat,
default-labeled, named, explicitly edited, and externally changed artifacts, plus
metadata retention and unchanged source bytes. Eighty-one focused tests passed
without skips and the diagnostic Xcode app build passed. The initial build caught
an invalid color-token name, corrected to the existing attention token.

A fresh read of macOS session flags reported the console session locked. Therefore
interactive Library appearance and behavior remain unqualified; build/loader tests
are not a substitute. Sources, hashes, harness, logs, and verification are retained
in `overlap-library/`. Cross-device propagation, remaining reconstruction paths,
and broader natural/long-form accuracy work remain open.

## Host and Client transcript reconstruction — September 7

Three combined-transcription result conversions dropped overlap metadata: resident
Host processing, desktop local Library reprocessing, and Client protected-master
recovery. They now use a shared `SessionTranscript` initializer from `TranscribeResult`
that preserves text, words, speaker segments, and optional overlap assessment.
Processing coverage remains explicit at the existing call sites; missing legacy
overlap evidence stays nil. The initializer does not invent a manual-edit stamp.

Eighty-two focused tests passed without skips against the rebuilt app modules,
including a nil/empty/nonempty overlap conversion and serialization matrix. The
diagnostic Xcode app build passed. Sources, hashes and logs are retained under
`overlap-reconstruction/`. This proves conversion behavior and compilation of the
three call sites, not a physical recovery or end-to-end Host ingest exercise.

Inspection of `HarcDesktopProcessingArtifact.transcriptPayload` confirms the signed
Client-to-Host artifact still serializes text/word timings without overlap evidence.
That remaining boundary must preserve the assessment before cross-device overlap
handling can be considered complete.

## Critical signed overlap assessment — September 7

TranscriptArtifactV1 now has field 4, an optional message containing canonical-frame
overlap ranges. Message presence distinguishes assessed-empty from unassessed legacy
artifacts. Producers mark field 4 critical whenever present; validators require
that marker and reject a marker without its assessment, invalid/reversed/out-of-
bounds ranges, and overlapping/noncanonical ordering. Readers with the prior known
field set reject the critical field instead of silently discarding its meaning.
The seven-schema inventory checksum was deliberately refreshed; schema guard passes.

The desktop producer retains the local assessment and converts milliseconds to
canonical frames, permitting less than one millisecond of outward rounding at EOF.
Larger overrun is an error. Signed bundle hashes bind the new payload bytes through
the existing exact submission flow. Host retains the exact bundle and adds an
unattributed overlap warning to its accepted-edge Library text projection when
ranges are nonempty. It does not invent names or treat absent assessment as clear.

Ninety-three tests passed without skips, including signed submission round trips,
legacy-known-field rejection, malformed assessment rejection, direct producer EOF
conversion, and Host projection. The final diagnostic Xcode app build passed.
Sources, hashes, harness, and logs are retained in `overlap-wire/`.

This intentionally requires a reader that understands critical field 4. Physical
Client/Host delivery, mixed-version retry/update behavior, and reconstructing a
structured Host sidecar from the retained signed artifact remain unqualified. The
Library text projection retains the warning, but is not a structured timeline.
No deployment or release was performed.

## Durable Host-generated structured transcript publication — September 7

Inspection of accepted-edge storage revealed that resident Host-generated results
also staged only rendered text. The Host worker now encodes its complete
SessionTranscript, including words and overlap assessment, and supplies it to a
new Store staging overload. Inside the existing serialized writer transaction,
only a recording without a ready winner may publish a content-addressed JSON file
in `.harc-derived` beside the canonical audio. File and directory barriers precede
the database's json_path update. Identical retries verify and synchronize the
existing bytes; late Host work returns before creating another sidecar.

An accepted text-only Client result now clears the earlier json_path binding so
exports cannot read a losing Host transcript. The old sidecar is retained, not
deleted. Reconstructing the winning Client's structured sidecar from its retained
signed artifact remains unfinished and must replace this temporary text-only
projection with the winning structured data.

Ninety-nine focused tests passed without skips, including actual sidecar byte
publication, retry reuse, rejection of late work, filesystem publication failure
leaving the Library unchanged, and edge-winner invalidation. The initial test
compile used the wrong Store lookup name; the retained corrected run uses fetch.
The final diagnostic Xcode application build passed. Evidence is in
`host-structured-publication/`. These tests do not qualify physical power loss,
long-duration capture, or complete signed Client-to-Host delivery.

## Accepted Client structured sidecar publication — September 7

The validated accepted-edge branch now projects transcript words and optional
overlap assessment into the local SessionTranscript JSON schema. Paths and dates
come from the Host's recording; frame boundaries convert outward to milliseconds.
The exact signed artifact remains the authority for original frame precision and
local cluster IDs. The local projection does not invent authenticated person names
or reuse unrelated Host speaker indices. Legacy missing assessment remains absent,
and assessed-empty remains an explicit empty array.

Both Host-generated and accepted-Client JSON now share the same immutable durable
publication helper. The accepted-edge Store overload writes and synchronizes the
winning sidecar before binding json_path in its existing serialized transaction;
legacy text-only callers still clear stale Host JSON. Identical retries reuse
content-addressed bytes, and losing sidecars remain retained.

One hundred one focused tests passed without skips, including projection through
the actual SessionTranscript decoder, Store replacement of staged Host JSON,
ExportInputBuilder reload, and a real SRT file export containing the overlap label.
The test also checks retry path reuse and refusal of late Host publication. The
app build passed. Evidence is retained under `accepted-client-sidecar/`. This is
component integration through publication/export, not a live authenticated RPC
ingest or physical Client/Host transfer qualification.


## Signed overlap submission over real pinned TLS — September 7

The real socket pairing lifecycle now submits an exact signed processing bundle
through the production gRPC adapter/service after revoke, forget, and same-key
re-pair. It verifies accepted-edge disposition, exact replay disposition, ready
Library state, the overlap warning, and structured JSON containing the original
words and overlap interval. The same test passes through the local encrypted relay
emulator. Each run executed one Swift Testing case with zero skips; XCTest reports
zero cases because this test uses Swift Testing.

The test exposed a production Client builder defect: its bundle omitted the
required diarization entry and could not pass the protocol's required-entry gate.
The builder now emits transcript, diarization, and coverage entries. Exclusive
speaker turns retain local cluster IDs; intersecting tracked speakers and raw
segmentation overlap remain unattributed rather than choosing a speaker. A test
of the actual app builder checks the complete validated bundle and split turns.
All six builder tests passed, and the diagnostic Xcode app build passed.

The first socket fixture also incorrectly used ordinary upsert, which intentionally
strips origin/canonical bindings. The corrected fixture uses the existing capture
reconciliation API and asserts those fields before submission. Host ownership
checks were not relaxed. This fixture seeds canonical metadata; it does not qualify
capture, audio upload, canonical codec decoding, or a physical second Mac.

Relay startup initially exceeded the script's ten-second health wait while the
installed Wrangler loaded local dependency files. A retained diagnostic copy with
a two-minute startup allowance passed using Wrangler 4.120.0, local-only state,
and telemetry disabled. Task-owned wrappers invoke the installed Wrangler directly
and run tests against the isolated Xcode-built modules; no dependency install or
remote deployment occurred. Retained evidence, source hashes, app build, test
logs, and diagnostic runner are under `overlap-pinned-tls/`. These dirty-tree runs
are integration diagnostics, not release or real-meeting accuracy qualification.

After dependency loading completed, the unmodified relay script also passed with
its original ten-second startup limit (one case, zero skips). The retained
`overlap-relay-standard.log` is the final relay result; the extended-startup run
and earlier startup failures remain retained separately.


## Host speaker observation model binding — September 7

The Host worker saved each embedding's actual model ID but mislabeled every
SpeakerEmbeddingObservation as wespeaker_v2. It now passes the model supplied by
the daemon into the observation and binds nonlegacy models into the deterministic
operation ID. Historical WeSpeaker IDs remain byte-for-byte unchanged, while
other model revisions cannot replay those decisions. The production embedding
model has not changed; ECAPA remains diagnostic.

The extracted production observation constructor also checks integer bounds before
converting speaker indices, durations, and segment counts. Four focused Host/Client
identity tests passed without skips against the freshly built app modules,
including the fixed historical ID, distinct revision IDs, retained observation
fields, and oversized/negative evidence rejection without conversion traps. The
Xcode app build passed. Evidence is retained under `host-model-identity/`.
This closes a model-label/replay defect, not real-meeting identification accuracy.

## Natural meeting baseline: AMI ES2002a — September 7

Downloaded the headset mix and official manual v1.6.2 annotations from the
[AMI corpus](https://groups.inf.ed.ac.uk/ami/download/) (CC BY 4.0). Source URLs,
SHA-256 hashes, selected XML, and untouched audio are retained in `ami/source/`.
Selection was frozen before inference: three consecutive 180-second excerpts
covering 0–540 seconds. No silence trimming or speaker-based excerpt selection.

The real built harc-stt daemon processed all three excerpts locally, returned
model-labeled embeddings and overlap ranges, recovered from a missing-file error,
and shut down with exit 0. Exact binary/source hashes and lifecycle output are in
`ami/daemon-ipc/`. This exercised diarization, not transcription or enrolled-person
recognition. The meeting audio is a headset mix, not a physical Harc capture.

A new standalone scorer uses a one-to-one maximum-duration assignment between
anonymous output clusters and annotation speakers, exact interval boundaries,
no collar, and silence false alarms. It measures human segment annotations,
which include within-turn pauses; these numbers are not standardized AMI DER.
Five hand-calculated scorer regressions pass, covering permutation, missing
overlapping speech, silence, fragmented clusters, and invalid bounds.

| Excerpt | Segment-based error | Overlap precision | Overlap recall |
| --- | ---: | ---: | ---: |
| 0–180 s | 32.4% | 67.6% | 45.3% |
| 180–360 s | 48.3% | 98.4% | 15.5% |
| 360–540 s | 27.7% | 68.9% | 31.4% |
| Combined durations | 36.3% | 74.7% | 26.2% |

The combined reference has 455.293 speaker-seconds: 117.578 missed,
20.674 false-alarm, and 27.064 confused speaker-seconds. This is a poor natural
meeting baseline despite the earlier constructed-mixture detection result.
The next analysis must separate within-turn annotation pauses from actual missed
speech, examine fragmentation and missed overlap, and measure identification
using separate enrollment audio. No model thresholds were changed to fit these
excerpts. Retained inputs, runner, results, scorer, and aggregate are in `ami/`.

An additional source review confirms that accepted Client Library JSON still
omits speaker turns while retaining the signed diarization artifact. Resolving
that projection requires explicit cluster/identity binding; arbitrary Client
indices must not acquire unrelated Host person names. This remains an open
production gap, not a completed speaker-delivery claim.


## AMI word-boundary diagnosis and clustering comparison — September 7

Rescored the same frozen nine minutes and existing production results against
positive-duration lexical word timestamps from the official annotation archive.
Punctuation is excluded; no collar is used. Pauses and nonlexical vocalizations
are not reference speech, so this is a complementary diagnostic rather than a
replacement standardized score. Source XML, derived word reference, and results
are retained in `ami/`. No new model inference was needed for that baseline.

| Excerpt | Production clusters / reference speakers | Word-based error | Word-overlap recall |
| --- | ---: | ---: | ---: |
| 0–180 s | 11 / 4 | 27.9% | 69.6% |
| 180–360 s | 9 / 4 | 32.5% | 47.7% |
| 360–540 s | 7 / 4 | 20.2% | 65.8% |

Word boundaries explain part of the earlier segment-based result, but substantial
missed speech and fragmented speaker clusters remain. The diagnostic retains
per-cluster intersections with each annotation speaker for further analysis.

An isolated compiled candidate removed only Harc's 0.65 similarity override and
used the pinned FluidAudio manager defaults. Same models, same audio, same
windowing and overlap extraction. Candidate cluster counts were 4, 3, and 3;
word-based errors were 26.7%, 32.9%, and 17.2%. Missed-speaker durations were
unchanged in all three windows. It reduced fragmentation but did not preserve
all four speakers and worsened one window, so it was not promoted. The current
production source remains unchanged. Exact candidate/source hashes and runner
are retained under `ami/threshold-comparison/`.

The next identification experiment needs disjoint enrollment speech and explicit
unknown-speaker trials; optimal anonymous cluster mapping is not recognition.
Neither this comparison nor the earlier synthetic identity test closes that gate.


## AMI disjoint enrollment identity diagnostic — September 7

Enrollment uses later audio than the fixed 0–540s evaluation. The initial three
four-second isolated-turn rule failed for A; the revised nonoverlapping two-second
rule also could not provide three isolated clips for A/C. No recognition scores
were inspected to make those fixture changes. The completed diagnostic therefore
enrolls only B (clips starting 681.539, 684.980, and 692.468 seconds); A/C/D remain
unknown. Each clip avoids other annotated turns within 200ms. Three prototypes
come from one meeting/session, not independent enrollment sessions. The retained
manifest alone selects inputs; partial files from failed preparation are unused.

The actual daemon produced one embedding per selected clip. A standalone runner
linked to the built app's actual quantized SpeakerRecognitionMatcher uses the
existing WeSpeaker model, 256 dimensions, and 0.65 threshold. It matches only
previously retained production evaluation embeddings; no model tuning occurred.
The diagnostic build first needed correction for the app dylib name and embedded
Sparkle framework runtime path; the final matcher run completed successfully.

Across nine minutes, B is named for 203.979 of 230.920 annotated B word-seconds
(88.3%). Speech annotated only to unknown A/C/D is named B for 2.805 of 119.600
seconds (2.35%). Another 9.476 named seconds fall outside lexical-word annotations,
which include pauses/nonlexical exclusions and cannot be called acoustic silence.
One cluster is named B in each excerpt; the remaining clusters are unnamed.

This is not a clean unknown-rejection result. Next inspect wrong-name intervals
against audio and word/segment boundaries to separate temporal spill from mixed
or wrongly linked voice clusters. Single-profile matching does not qualify
competition among enrolled people, and same-session enrollment does not qualify
cross-session identity. Inputs, exact binary hashes, runner, scores, failed
preparation log and successful daemon lifecycle are retained under `ami/enrollment/`.


## Identity timeline versus rendered words; gap naming fix — September 7

The earlier 2.805 wrong-name seconds scored raw cluster intervals, not final
rendered words. Detected overlap covers 2.176 seconds; all remaining pieces belong
to reference words that touch detected overlap. The renderer's whole-word overlap
suppression hides those particular raw-interval errors. This does not establish
that the displayed transcript has zero wrong names.

An actual TranscriptPlainTextRenderer diagnostic uses the retained daemon segments,
measured identity decisions, reference word timing, and unique placeholder tokens.
It found four other unknown-speaker words rendered as B: one in a diarization gap
and three with midpoint containment in B's cluster (including concurrent speech
not detected as overlap). Reference words are not Harc ASR output, so this is an
output-path diagnosis, not an end-to-end transcription accuracy result.

Removed unsupported nearest/prior-speaker fallback from plain text, prompt, and
subtitle rendering. A word whose midpoint lacks speaker evidence remains unnamed;
a following supported word can resume its proper label. This deliberately trades
some boundary labeling for avoiding an unsupported person's name. All words remain
in output. The fixture's gap word now stays unnamed. Three wrong names within
attributed segments remain, requiring diarization/overlap improvement.

Twenty-six focused output tests pass without skips; the app build passed. The first
test run caught an accidental expectation replacement in an unchanged token-joining
case; that expectation was corrected before the final passing run. Before/after
rendered output, source hashes, tests and build evidence are in `ami/enrollment/`,
with the implementation evidence under `gap-fix/`. No model threshold changed.


## Actual combined transcription and complete-word rendering — September 7

Ran all three frozen AMI excerpts through the actual daemon's combined transcribe
request (English, timestamps, diarization and VAD enabled). All three returned
text, word tokens, speaker embeddings, and overlap assessment. The daemon also
passed invalid-input recovery and shutdown. Core ML emitted a zero-shape inference
warning during this run; it is retained and remains to be traced rather than
assumed harmless. Daemon/helper RequestHandler, Transcriber, and IPC source parity
was checked before analysis. This tests combined processing, not live capture or
Client chunk/recovery/publication behavior.

Chronological lexical-reference diagnostic word-error rates are 30.0%, 27.3%, and
14.9% (242 edits / 1051 reference words = 23.0%). The fixed normalization lowercases
ASCII alphanumeric words with internal apostrophes, ignores punctuation, and keeps
fillers. Simultaneous-reference ordering is ambiguous; this is not a standardized
AMI score. Exact combined outputs, references, matcher decisions using the same
later B enrollment, and render inputs are retained under `ami/combined-asr/`.

Actual rendered output exposed a defect beyond the earlier reference-word test:
speaker/overlap boundaries split SentencePiece fragments into separate visible
words. For example, already became alre / ady. The three raw outputs contained
310, 258, and 396 normalized words; rendering produced 318, 262, and 401.

Word.displayWords now provides shared reconstruction before attribution in plain
text, summary prompts, and subtitles. Labels use the complete word midpoint;
overlap intersecting any part suppresses its identity. Unsupported midpoint gaps
remain unnamed. All 964 normalized words now survive in exact order across the
three rendered outputs, with counts 310/258/396. This proves word reconstruction
for these outputs, not correct recognition of their words or speakers.

Twenty-seven focused tests passed without skips, including a regression with a
speaker boundary inside already and overlap intersecting only its first token.
The application build passed. Source hashes, tests and build log are retained in
`ami/combined-asr/complete-word-fix/`. Diarization, known-person attribution,
cross-session enrollment, and physical qualification remain open.

## VAD comparison and repeatability — September 7

Repeated the same nine minutes through the actual combined daemon with VAD disabled.
All requests, invalid-input recovery, and shutdown completed. Diagnostic WER became
39.1%, 19.4%, and 18.9% (262/1051 edits, 24.9% aggregate), compared with 30.0%, 27.3%,
and 14.9% (242/1051, 23.0%) with VAD. Disabling VAD helped only the middle excerpt;
production settings were not changed. The no-VAD render-input preparation has no
identity names and is not a separate identity/render qualification. Its scoring
script uses the same transcript normalization and reference ordering as baseline.

The no-VAD run did not log the Core ML zero-shape warning. A further VAD-enabled
repeat with request begin/end markers reproduced it; its captured bytes appeared
after the shutdown response marker. This is not proof that shutdown caused it:
the underlying diagnostic may use buffered C/C++ output. No VAD fallback or request
error was reported. Exact text, timed words, speaker segments, and overlap ranges
matched the original baseline in every excerpt, despite the later shared
Word.displayWords source/build change. Processing times and embeddings were not
used for that exact-repeat assertion.

Evidence is retained under `ami/combined-asr-no-vad/` and
`ami/combined-asr-phased/`, including runners, lifecycle, logs, per-file hashes,
accuracy and repeat comparison. The warning's origin remains unresolved; its
presence is not silently dismissed, and its absence with VAD disabled is not a
reason to promote an overall worse configuration. Production ASR settings remain
unchanged. Lower-level unbuffered phase instrumentation is needed before attributing
the warning to a particular model call.


## Core ML warning located before transcription — September 7

The first diagnostic attempt to disable C stdout/stderr buffering did not load:
the helper's hardened runtime ignored DYLD_INSERT_LIBRARIES. That run is retained
under `ami/combined-asr-unbuffered/` and is not unbuffered evidence. The application
and its bundled helper were not modified to bypass runtime protections.

A disposable copy was ad-hoc signed without hardened runtime solely for local
instrumentation. Its injected constructor disables stdout/stderr buffering and
prints an explicit marker; the runner requires that marker. This confirmed run
places the E5RT zero-shape warning immediately after listening, before model-ready
messages and before the first transcription request. Earlier apparent association
with VAD settings was therefore misleading. The model loading phase runs ASR and
diarizer loading concurrently, so the specific model/compiler root cause is still
not established. This warning is not evidence that VAD trimmed a failing input.

All three requests, error recovery, and shutdown succeeded. Exact text, word
timings, speaker segments, and overlap ranges match the earlier combined baseline.
Retained evidence under `ami/combined-asr-unbuffered-confirmed/` includes constructor,
runner, startup marker, phase log, source/binary hashes, and explicit comparison.
No runtime protection, inference setting, or model in the application changed.
The diagnostic copy is not a release artifact. The loading warning remains open,
but investigation of recognition quality can proceed independently of it.

## Actual Client chunking and recovery baseline — September 7

Ran the actual ChunkedTranscriber and HarcSTTClient against the bundled daemon on
all three AMI excerpts. The final valid harness waits for two completed updates
before finalization and verifies exactly three retained chunks per excerpt:
0–62s, 60–122s, and 120–180s. VAD, 60s chunks, 2s overlap, full-WAV diarization,
and SpeechCoverageRecovery use production defaults. Live preview is disabled;
the complete audio is already on disk, so this does not qualify physical capture,
wall-clock live pacing, cancellation, publication, or transport.

Earlier harness attempts are retained separately. Immediate finalization raced
the pump and produced a variable number of oversized tail chunks; a second attempt
incorrectly treated TranscriptUpdate.chunkIndex as a sequential index, although
its implementation contains a word count. The valid harness counts completed
update events and checks actual ranges. These earlier runs are not regular
chunking qualification and have not been pooled into final results.

Final speech-only diagnostic WER is 37.1%, 21.0%, and 17.2%: 254/1051 edits, or
24.2%, compared with 23.0% for direct full-excerpt daemon requests. Five exact Harc
failure notices are removed only from the word-error calculation and counted
separately. The initial uncorrected scorer included warning prose in WER; that
result is retained as `accuracy-including-warning-prose.json`, not the final score.

Five uncovered-speech intervals remain visible after bounded recovery:
152.500–152.548s in excerpt one; 100.838–102.171s and 133.510–134.893s in excerpt
two; 52.500–53.256s and 142.053–145.146s in excerpt three. Each intersects human
word annotations. Diarization itself completed in all excerpts. The next step
must inspect why recovery did not complete these intervals, including bounded
request/time admission, rather than suppressing their warnings to improve scores.

Evidence under `ami/client-finalize-three-chunks/` includes exact runner/binary
hashes, final transcripts with embeddings and failure ranges, all chunk outputs,
reference intersections, corrected scores, logs, and successful daemon lifecycle.
This advances application-path evidence but is not a production accuracy pass.


## Recovery admission repaired through aligned chunk stitching — September 7

Four of the five visible failures came from excerpts whose plain text and timed
words disagreed. SpeechCoverageRecovery correctly refused to merge into that
state (the same guard protects edited text); it was not request/time exhaustion.
The stitcher removed a matched duplicate text prefix by word count, but removed
timed tokens by the full two-second overlap duration, dropping a different set.

Stitching now verifies the matched prefix against reconstructed timed words and
removes the same complete words from both. New speech inside the overlap remains;
subword fragments cannot survive a coarse time cutoff. An uncertain timed-prefix
match retains the successor intact. Legacy text-only chunks retain their existing
text behavior. The manual-edit/recovery consistency check was not relaxed.

The repeated actual three-chunk Client run preserved the expected ranges and now
has normalized text/timing agreement in every excerpt. Four intervals completed
recovery, leaving only 152.500–152.548s in excerpt one visibly failed. WER improved
from 254/1051 (24.2%) to 246/1051 (23.4%): per-excerpt rates 37.1%, 20.0%, 16.1%.
This remains a poor accuracy baseline; the remaining 48ms failure was not hidden.

Eighteen focused stitching/recovery tests and 61 surrounding chunking/rendering
tests passed without skips. The app build passed. Evidence, source hashes, all
final transcripts and logs are under `ami/client-stitch-fix/`. A regression keeps
new speech inside the nominal time overlap and another preserves an unaligned
successor. Physical capture and release qualification remain open.


## Complete-word recovery at narrow boundaries — September 7

The remaining 48ms interval was part of a reference filler. A direct 448ms retry
(200ms context each side) returned Mm-hmm as SentencePiece fragments, but only
punctuation had its midpoint inside the target. A 2048ms context diagnostic returned
Um with timing ending before the target, so widening context did not establish
coverage and was not promoted. Both exact responses are in `short-recovery-context/`.

Recovery now reconstructs complete words before selecting them. It accepts a word
whose valid timed interval intersects the target and does not overlap existing
lexical words or earlier added words. This keeps boundary-spanning support while
rejecting duplicate context; the eight-request/60-second admission limits, 200ms
context, memory guard and manual-edit gate are unchanged. Whole-word midpoint-only
selection was also tested, retained under `client-recovery-word-fix/`, and exposed
three incomplete spans that isolated fragments previously counted as recovered.

The final actual three-chunk replay has two visible unresolved intervals in excerpt
one: 77.357–77.500s and 132.475–132.500s. Excerpts two and three have none. This is
not a zero-warning pass: more honest complete-word validation can expose previously
hidden uncertainty. Diagnostic WER is 245/1051 (23.3%), versus 246/1051 after the
stitching fix. Mm-hmm still differs from reference Um; completion is not correctness.

Sixty-three surrounding tests passed without skips and the app build passed.
Regressions cover reconstruction where only punctuation lies inside a tiny target,
a complete word straddling the target, and refusal to duplicate existing text.
Evidence is retained under `client-recovery-interval-fix/`. Accuracy and speaker
identification remain unqualified; no model or threshold changed.

## Same-day cross-meeting identity diagnostic — September 7

The next frozen corpus is the first three consecutive 180-second excerpts of AMI
ES2002b. Official meeting metadata binds B to participant FEE005 in both ES2002a
and ES2002b, recorded on the same day. The original three two-second B enrollment
clips from ES2002a, WeSpeaker model, 0.65 threshold and actual quantized matcher
were retained. A/C/D remain unknown. AMI labels this meeting as training data:
this is a new application evaluation meeting, not proof of model-training holdout.

Actual Client processing completed three 60-second chunks with two-second overlap
per excerpt, full-recording diarization and coverage recovery. All audio was
already on disk; this does not exercise live capture pacing. Diagnostic WER was
305/1475 (20.68%), with per-excerpt rates 22.31%, 13.47%, 23.71%. Visible unresolved
recovery ranges numbered two, zero and one. Error recovery and daemon shutdown
passed. This remains negative production-accuracy evidence.

The enrolled identity covered 102889/220680 ms (46.62%) of positive-duration
reference lexical activity for B. No identity was accepted in excerpts two or
three. No other-speaker-only reference activity was assigned B (0/183660 ms),
but this small one-person enrollment test cannot establish a safe false-accept
rate. The accepted cluster includes 4161 ms where B and others overlap; those
intervals count as B present, not successful separation or correct word ownership.
There are also 2000 named milliseconds without lexical reference support, which
can include pauses and nonlexical speech. These are cluster interval measures,
not an end-to-end score of the rendered transcript's named words.

Per-cluster unioned reference support narrows the missed-identification problem:

| Excerpt | Cluster | B-only support | Other-only support | Best raw enrollment cosine | Actual match |
| --- | --- | --- | --- | --- | --- |
| 0–180s | 2 | 98.728s | 0s | 0.6536 | B, quantized score 0.6531 |
| 180–360s | 0 | 26.344s | 0s | 0.6112 | Unknown |
| 360–540s | 1 | 9.129s | 0.082s | 0.6293 | Unknown |
| 360–540s | 4 | 47.315s | 0s | 0.6304 | Unknown |

The main rejected clusters contain substantial isolated B reference activity;
misses cannot all be attributed to mixing speakers. Anonymous diarization also
fragments voices: optimized word-activity timeline error is 18.98%, 15.82%, 22.83%
by excerpt, and overlap recall is only 31.87%, 21.70%, 53.50%. These exact-boundary,
no-collar diagnostics are not standardized AMI DER.

Enrollment is itself variable: pairwise raw cosine is 0.7249 between clips one
and two, but only 0.5141 and 0.4846 against clip three. That suggests inspecting
enrollment duration, acoustic support and prototype stability before calibrating
matching. It does not prove that clip three is a different person or should be
discarded. No threshold, enrollment policy or production model was changed to
fit this result. Next validation needs independently selected enrollment samples,
multiple known identities, and evaluation outside this same-day pilot.

Retained evidence is under `ami-second-meeting/`: official source/annotation
hashes and participant binding, frozen corpus, actual Client output and matcher
decisions, reusable cluster-support analysis, prototype consistency, scores and
logs. `retention-provenance.json` hashes the retained files and current binaries
and sources; it explicitly is a retention-time diagnostic, not a release seal.

## Paired enrollment duration and two known identities — September 7

Selected three six-second enrollment clips each for B and D from ES2002a after
600s, before running inference. Selection merges adjacent same-speaker annotation
turns with at most 250ms gaps, subtracts other-speaker turns with 200ms margins,
then takes the first three distinct eligible regions. Audio remains original
contiguous PCM. This resolves an overly restrictive earlier selection that
required every clip to fit one annotation utterance. Human annotation supplies
the selection; the app's automatic enrollment selection is not qualified here.

The actual daemon returned one embedding and no detected overlap for each clip.
The actual quantized matcher then evaluated the same 17 ES2002b cluster embeddings
with B and D enrolled, A/C unknown, threshold 0.65 and identity separation 0.05.
A paired run used only the first two seconds of each selected six-second clip.
Both daemon runs completed error recovery and clean shutdown. No application
source, matching threshold, or production enrollment policy changed.

| Enrollment | B activity correctly named | D activity correctly named | Wrong B naming over speech | Wrong D naming over speech |
| --- | --- | --- | --- | --- |
| Two-second prefixes | 0/220680 ms (0%) | 50710/66020 ms (76.81%) | 0 ms | 3518 ms |
| Six-second originals | 181033/220680 ms (82.03%) | 50710/66020 ms (76.81%) | 0 ms | 4425 ms |

These are unioned lexical-activity interval measures, not accuracy of rendered
named words. Overlap containing the named identity counts as that person present,
not correct separation. Six-second enrollment also produces 3150 ms of B naming
and 3768 ms of D naming without lexical annotation support; pauses and nonlexical
speech prevent interpreting those automatically as silence false positives.
Of D's 4425 wrong-name milliseconds over annotated speech, 2147 lie outside
detected overlap, so overlap suppression alone cannot remove this error.

This paired result supports investigating duration-sensitive enrollment, but
does not establish a universal six-second minimum or production accuracy. The
older two-second pilot used different source intervals and only one known person;
its 46.62% B result is not the controlled duration comparator. Evaluation remains
same-day public AMI training data, and this is development work after observing
earlier results. Multiple sessions and recording conditions remain necessary.

Evidence is retained under `ami/enrollment-six-second/`, including frozen clip
selection, audio hashes, actual daemon outputs, matcher inputs/decisions, scoring
scripts, wrong-name intervals and provenance. `paired-two-second/` retains the
matched shorter-input arm. All 17 evaluation embeddings were scored in both arms.

## Actual Store enrollment and recognition-pack replay — September 7

An app-linked probe now persists each measured enrollment embedding through
`RecordingStore.upsertSpeakerEmbeddings`, creates people, confirms each link
through `linkSpeaker`, and obtains `speakerRecognitionPack` from the actual Store.
It uses an in-memory diagnostic database and never opens the user's library.
Both six-second and paired-two-second packs reproduce every previous matcher
result exactly, including scores. The earlier manual pack assembly therefore
does not explain the observed duration sensitivity.

The Store admits all three prototypes per person in both arms. Reported speech
durations are 5653–5993 ms for the longer B samples and 1663–2000 ms for the shorter
B samples; D ranges are 5973–5993 and 1765–2000 ms. These are the daemon's support
estimates, not merely the WAV duration. UI re-identification suggestions already
ignore reference embeddings below 5000 ms, whereas recognition-pack construction
requires only positive duration and Host observation matching has no equivalent
reference-duration filter. Those are distinct current production paths, not a
shared calibrated enrollment policy.

This establishes the next product issue: separate the ability to name a speaker
from eligibility to reuse that voice evidence for automatic identification, and
apply a deliberate quality rule consistently. The present small diagnostic does
not establish a universal duration threshold. No such rule was changed here.
Evidence adds `AMIStoreMatchProbe.swift`, both actual Store packs and match outputs,
and `store-provenance.json` under `ami/enrollment-six-second/`. This exercises
persistence and pack construction, not the naming UI or full Host decision path.

## Shared enrollment evidence floor — September 7

Implemented the existing suggestion path's five-second reference-speech minimum
as `SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs`. Recognition packs now
exclude shorter confirmed local and remote evidence; Host matching excludes it
from both reference sources; cached-pack matching independently filters older
short prototypes. Suggestions share the constant and may request a stricter
minimum. All paths require positive segment count. Manual names, person links,
short observations and immutable historical decisions remain stored. This does
not retract old automatic names or suppress short query speech when eligible
reference evidence exists.

This is consistency with the existing product baseline, not an inference that
five seconds establishes accurate recognition. No cosine threshold changed.
The actual Store replay preserved every six-second comparison result exactly,
including its wrong attributions, while the two-second arm retains both people
with empty prototype lists and no automatic matches. Longer-sample recognition
accuracy remains unqualified.

The app build passed. Twenty-seven XCTest Store cases and twelve Swift Testing
matcher/suggestion cases passed, with no skips. New regressions exercise 4999/5000
ms boundaries for confirmed local and remote enrollment, preserve explicit manual
names and person links, and enforce the floor on older cached packs. The first
test run exposed a fixture assumption: `linkSpeaker` persists identity links but
does not itself write recording display overrides. The final regression explicitly
persists both, then verifies them; no production behavior was changed for that
test setup correction. Logs, rebuilt-module provenance and actual replay outputs
are retained under `ami/enrollment-floor/`. This is software evidence, not naming
UI or physical qualification.

## Actual named transcript output — September 7

Rendered the final ES2002b Client transcripts through the built app's actual
`TranscriptPlainTextRenderer`, applying the six-second Store-pack B/D identity
decisions. Every rendered whitespace token matches the reconstructed ASR words
exactly after removing the separately retained overlap/failure notices. The three
excerpts contain 339, 353 and 587 words. This checks actual ASR text and names;
earlier reference-placeholder rendering was a separate timing diagnostic.

A reference-word-midpoint audit flags nine named words whose predicted midpoint
has other-speaker lexical activity but no activity for the assigned identity.
Thirteen more named words have no lexical reference at their midpoint and remain
unscored. This is not speaker-attributed WER: timestamp error and simultaneous
reference speech can affect the comparison. In particular, the first excerpt's
flagged `Did` falls at the tail of B's annotated `Sorry`; it is not independently
confirmed as a wrong identity rather than timing/recognition error.

The third excerpt provides a clearer failure. At source time about 415.5–416.7s,
the rendered phrase `the clunky one is the one on the` is labeled D. The annotation
has C saying that phrase, with A speaking during part of it. Eight words are
flagged here. The upstream speaker timeline assigns this interval to cluster 2,
which matches D; its raw overlap ranges end at relative 55.159s and resume at
57.475s, leaving the erroneous named phrase outside the warning. The renderer
faithfully applies that timeline. No name-rendering patch or threshold adjustment
can be justified as the root correction from this evidence.

Retained `ami-second-meeting/named-render/` includes actual renderer input/output,
reconstructed words, strict sequence checks, the nine timestamp concerns,
original reference words around both windows, and source/binary hashes. Next
speaker work should inspect per-window tracking and overlap detection in this
concrete interval while preserving known-speaker recognition elsewhere. Production
speaker attribution remains unqualified.

## Stateful window trace of the wrong named phrase — September 7

A disposable copy of the current production Diarizer adds diagnostic writes for
source windows starting at 45–65s of the third ES2002b excerpt. It processes the
entire excerpt from its start, preserving tracker history. The resulting 53
published segments and overlap ranges exactly match the retained actual Client
output. No production source or model parameter changed for this trace.

The source window 50–60s owns publication from 52.5–57.5s. It assigns the relevant
speech to tracker ID 3 (published cluster 2), with segments 50.000–55.113s and
55.366–59.939s. At 55.5, 56.0 and 56.5s, raw segmentation reports one active
channel. The neighboring source window 55–65s also reports one channel at those
times and assigns 55.000–60.940s to the same tracker ID. Thus the missed C phrase
is not explained by clipping at the publication boundary: both model contexts
merge it into the tracked D voice.

The two windows' vectors have best raw cosines of about 0.664 and 0.642 to D's
enrollment, versus -0.004 and 0.013 to B. These window-local vectors are weaker
than the final cluster centroid's accepted D score (about 0.824), illustrating
how a strong aggregate identity can carry an incorrect local turn. They are
diagnostic raw cosines, not a calibrated per-turn confidence score. The later
window alone falls below the existing identity threshold; the earlier one does
not, so a single local cutoff would not explain a complete fix either.

Trace sources, exact raw activity, window segments/vectors, summary analysis,
output equality checks and hashes are retained under
`ami-second-meeting/window-trace/`. Next experiments must evaluate segmentation
and local tracking consistency across the corpus, including loss of valid names
and speech coverage. Merely shifting window ownership or raising the global
identity threshold is unsupported by this reproduction.

## Full-meeting excerpt comparisons: offline clustering and Sortformer — September 7

Ran both already-retained local alternatives on all six frozen 180-second excerpts
from ES2002a and ES2002b. No production model changed. The offline diarizer uses
its pinned segmentation/embedding/PLDA models with non-exclusive output enabled;
its identity rows are deliberately empty here because model compatibility cannot
be assumed. The retained Sortformer probe uses its local model and completes each
recording independently. These comparisons score anonymous cluster timelines,
not enrolled identity, ASR accuracy, or an app capture workflow.

| Meeting / excerpt | Current timeline error | Offline timeline error | Sortformer timeline error |
| --- | --- | --- | --- |
| ES2002a / 0–180s | 27.86% | 28.85% | 48.98% |
| ES2002a / 180–360s | 32.53% | 29.90% | 38.01% |
| ES2002a / 360–540s | 20.16% | 13.57% | 30.90% |
| ES2002b / 0–180s | 18.98% | 15.81% | 24.81% |
| ES2002b / 180–360s | 15.82% | 11.50% | 48.49% |
| ES2002b / 360–540s | 22.83% | 16.21% | 42.09% |

Aggregate exact-boundary lexical-activity timeline error is 22.80% current,
18.68% offline and 38.75% Sortformer. These diagnostics optimize anonymous cluster
assignment and use no collar; they are not standardized AMI DER. Alternative
overlap is derived from concurrent output speaker segments, whereas the current
pipeline publishes independent raw overlap evidence. Measured overlap recall
falls from 51.44% current to 23.86% offline and 37.75% Sortformer.

Offline clustering improves five excerpts but still assigns the target C phrase
to the cluster mapped to D (55.415–60.967s), and its overlap coverage is weaker.
Sortformer assigns the phrase to C, with A also active over part of it, but its
error increases on every whole excerpt. Neither is promoted: the former leaves
the concrete wrong-person case unresolved, and the latter demonstrates why a
single corrected phrase is not sufficient evidence for adoption.

Both guarded local runs completed all six cases successfully. Inputs, raw outputs,
overlap adapters, baseline and candidate scores, model/source/binary provenance
and logs are retained under `ami-offline-comparison/` and
`ami-sortformer-comparison/`. Accuracy remains open; the next candidate needs
both local attribution improvements and acceptable corpus-wide behavior.

## Standalone suggestion-path audit correction — September 7

The previous enrollment-floor audit missed `SpeakerSuggestionEngine`, invoked by
the app after diarization and when backfilling a newly named person. It writes
pending review suggestions, not automatic names, but both triggers still used
short voice references. The earlier statement that all suggestion paths shared
the floor was therefore too broad.

Both triggers now require the shared five-second reference-speech floor and
positive segment count. Short query speech remains eligible for comparison with
adequate reference evidence. They also exclude other speaker slots in the same
recording from independent corroboration, consistent with the backfill contract
and Host exclusion. Manual links and names are preserved. Previously stored review
suggestions are not removed by this change.

The app build passed. All 27 XCTest Store cases and 19 Swift Testing cases across
matcher, re-identification and standalone suggestion suites passed without skips.
New tests cover both triggers at 4999/5000 ms, permit a one-second query against
an eligible reference, preserve confirmation, and reject same-recording reference
reuse. Existing positive, dismissal and idempotence fixtures now use adequate
reference duration so they still exercise their intended paths. Evidence and
source hashes are retained under `ami/enrollment-standalone-floor/`. This closes
a policy implementation gap; it does not fix the measured diarization errors.

## Standalone competing-identity abstention — September 7

The standalone suggestion engine previously selected the largest cosine without
comparing distinct identities, and new-person backfill compared only the new
person's seed. Both triggers now pool eligible confirmed references per person,
then use `SpeakerRecognitionMatcher.unambiguousBestPerson` with the existing 0.05
separation rule. A competitor below its own acceptance threshold still counts;
the winning person's threshold is checked after ambiguity. Backfill only emits
the requested person's suggestion when that person wins against all competitors.
References are fetched once per person per invocation, then compared locally.

The final app build passed, followed by 27 XCTest Store cases and 20 Swift Testing
cases across three identity/suggestion suites, all without skips. New regressions
exercise both triggers with tied identities, a close runner-up below its own
threshold, and a clearly separated winner. Two eligible references belonging to
the same person do not create false ambiguity. Existing enrollment, dismissal,
confirmation and idempotence cases remain passing.

This changes generation of pending review suggestions, not stored manual names
or the core diarization model. Previously stored suggestions are not retroactively
deleted; refreshing their evidence remains separate work. Logs, final source and
built-module hashes are retained under `ami/standalone-ambiguity/`. The natural
meeting attribution errors remain unresolved and are not reclassified as passing.

## Offline timeline with current overlap and WeSpeaker identity — September 7

Tested whether the offline timeline's lower anonymous error could be retained
without losing current overlap warnings or substituting identity models. Both
current and offline timelines were re-embedded with the same current WeSpeaker
extractor on overlapping ten-second source windows. Only exclusive timeline
activity outside current raw overlap warnings contributes. Each vector is
normalized and weighted by accepted activity in its disjoint owned interval;
missing clean support leaves the cluster unnamed. This is a diagnostic extraction
method, not a production replacement or a calibrated local confidence measure.

Both arms used the same six-second B/D enrollment, actual quantized matcher,
unchanged thresholds, and fixed final Client ASR words from all six excerpts.
The current-timeline arm is a control for re-embedding, rather than silently
attributing every change to the alternate timeline. Across both meetings:

| Measure | Current timeline, re-embedded | Offline timeline, re-embedded |
| --- | --- | --- |
| B reference activity correctly named | 385012/451600 ms | 415111/451600 ms |
| Wrong B naming over other speech | 2805 ms | 5344 ms |
| D reference activity correctly named | 115340/152700 ms | 113317/152700 ms |
| Wrong D naming over other speech | 6442 ms | 15230 ms |

Actual named rendering retains all 2261 reconstructed ASR words exactly in both
arms. Both mark the same 131 words as overlapping voices. The diagnostic count
of named words with another identity at their predicted midpoint rises from 10
to 42 with the offline timeline. Named words with no lexical reference at their
midpoint remain unscored (46 current, 48 offline). The earlier timestamp and
overlap caveats apply: these are not speaker-attributed WER or independently
verified wrong-word counts. The known eight-word C-to-D phrase remains flagged
in both arms. Thus restoring overlap warnings does not make the offline timeline
an acceptable identification improvement.

All twelve embedding cases and both actual matcher/renderer arms completed.
Three control clusters lacked eligible isolated support; scoring explicitly treats
their absent embeddings as unnamed rather than dropping their timelines. Sources,
inputs, embeddings, actual decisions, rendered text, score scripts, timing and
hashes are retained under `ami-timeline-reembedding/`. Neither candidate was
promoted, and no production audio, model or identity policy changed in this run.

## Word error for each enrolled person's rendered transcript — September 7

Added `scripts/quality/score-named-speaker-words.py` to score explicit identity-to-text
tracks without optimizing the identity mapping or using predicted timestamps.
Reference tracks contain all positive-duration lexical AMI words for the selected
enrolled people B and D, including their overlapping speech. Hypothesis tracks
contain only their named paragraphs from actual rendering. Unknown, unassigned
and overlapping-voice paragraphs receive no known-person credit: missing words
remain deletions. The metric therefore combines transcription and naming errors
and penalizes abstention; it is not a pure voice-matching error rate or an official
AMI speaker-attributed WER benchmark. A/C identification is outside this metric.

The scorer uses bounded-memory edit distance, lowercase ASCII word normalization
with internal apostrophes, and retains fillers. Six hand-checkable tests pass:
swapped names do not receive perfect credit, unnamed speech remains missing,
false names without reference speech count as insertions, the edit breakdown
balances, zero reference has no invented rate, and duplicate cases fail.

| Rendered diagnostic | Reference words | Substitutions | Deletions | Insertions | Total word error |
| --- | --- | --- | --- | --- | --- |
| Current production timeline/embeddings | 1807 | 77 | 441 | 31 | 549 / 1807 = 30.38% |
| Current timeline, re-embedded | 1807 | 77 | 441 | 31 | 549 / 1807 = 30.38% |
| Offline timeline, re-embedded | 1807 | 99 | 372 | 54 | 525 / 1807 = 29.05% |

This refines the previous rejection rationale: the offline combination is not
worse on every measure. It reduces missing named words enough to lower this
aggregate error, while substitutions and insertions increase and the midpoint
audit flags more wrong-name concerns. Neither breakdown alone isolates identity
mistakes from ASR errors. The concrete C-to-D phrase remains unresolved. Keep
these tradeoffs visible rather than selecting whichever metric makes a candidate
look best; no candidate is qualified for production by this same-day development
corpus. Inputs, original and prepared named outputs, scores and hashes are under
`ami-named-word-score/`.

## Prevent lossy Host adoption of speaker-bearing Client artifacts — September 7

The Host's accepted-edge JSON projection deliberately emits no speaker segments:
Client-local cluster IDs are not bound to Host speaker indices/person assignments.
However, the acceptance gate previously allowed a bundle containing those turns
to mark processing ready, silently removing speaker information from the saved
transcript while retaining it only in the exact signed bundle.

The compatibility gate now declines adoption when a validated bundle contains
diarization turns, utterance-local speaker IDs, or word-local speaker IDs. Exact
signed metadata and bundle persistence still precede this decision. Such an
artifact returns Host-processing-scheduled and leaves canonical pending work in
the durable Host backlog. Text and raw overlap-only artifacts remain eligible
for existing configured adoption. This uses the implementation spec's explicit
pipeline-compatibility fallback; it is not a completed Client-to-Host speaker
identity mapping. More Host inference is required until that mapping exists.

The app build passed. Two focused compatibility/projection tests and a real
pinned-TLS lifecycle/submission test passed, followed by the same lifecycle through
the local encrypted-relay emulator. Each transport run tests both accepted
text/overlap and deferred speaker-bearing bundles, exact replay, no lossy sidecar
publication, and continued durable Host queue membership. The first fixture run
revealed that the Client recovery helper used for setup defaults to ready;
the fixture now explicitly uses the pending state of real canonical Host ingest.
No production state transition was altered to accommodate that fixture.

Logs, final source/built-module hashes and the relay runner are retained under
`edge-speaker-fallback/`. The tests seed canonical metadata rather than uploading
audio and do not run the subsequent inference worker. Actual Host inference
quality, physical delivery, cross-revision cluster/observation binding, and safe
direct adoption of Client speaker turns remain open.

## Required Host diarization cannot fail silently — September 7

Following deferred edge work into the Host worker exposed another completion gap.
Its combined `transcribe(diarize: true)` request used the daemon's deliberately
best-effort branch, which catches diarization errors, logs them, and returns text.
The worker could then stage that result and mark it ready without speakers.

Added `TranscribingClient.transcribeRequiringDiarization`, which transcribes without
the best-effort speaker branch, requests explicit full-WAV diarization, then merges
speaker turns, embeddings and overlap only after success. Cancellation and errors
propagate. The Host uses this path whenever diarization is enabled, before staging
or publication. Its existing persisted failure/bounded retry behavior therefore
receives diarization failures. A retry currently repeats the whole derived job;
audio remains protected, but partial ASR work is not cached by this helper.

The app build passed and nine tests across required diarization and Host/edge
publication arbitration passed without skips. Tests cover successful preservation
of words and speaker evidence, explicit diarization failure, and not starting
diarization after ASR failure. A real daemon replay of ES2002b's first 180 seconds
returned 627 timed tokens, 33 speaker turns and six embeddings. A second call used
an owned nonexistent path only for its explicit diarization phase; the actual
daemon error propagated rather than returning successful text. A later valid
request succeeded, and shutdown exited zero.

Evidence under `required-diarization/` retains the app-linked probe, raw result,
failure-propagation assertion, lifecycle/error-recovery output, tests, build log
and hashes. This verifies the new helper with real IPC and the worker's compiled
call site, not the full resident Host worker running a captured-device job. It
does not qualify model accuracy or close the broader speaker-binding work.

## Actual Host worker execution and persisted voice decisions — September 7

Ran the current `HarcHostProcessingWorker` source with the built app modules and
real `harc-stt` helper against ES2002b's first 180 seconds in a disposable on-disk
Library. The fixture seeded canonical metadata and the retained six-second B/D
enrollment embeddings. It forced admission to run and removed the Client grace
delay; no capture or upload was simulated as completed evidence.

This exposed a routing defect: the worker discarded `DaemonLauncher.ensureRunning()`'s
returned socket path and constructed a default-socket client. It now connects to
the socket returned by its launcher. The app build passed, and the isolated worker
completed using its own daemon socket. An initial fixture attempt failed canonical
path validation before inference; normalizing the temporary root fixed the fixture
without weakening production path validation.

The worker persisted 627 timed tokens, 33 speaker turns, seven overlap ranges, six
WeSpeaker embeddings and six Host observation decisions. Cluster 2 matched B;
clusters 1 and 5 matched D; three clusters remained unmatched. Both processing and
projection reached ready, and the durable backlog was empty. After the process
exited, an independent read-only SQLite check confirmed database integrity, the
persisted states, every speaker index's embedding, matching observation/name keys,
model identities, and the master PCM hash and frame count. No owned worker or
daemon remained running.

Evidence is retained under `host-worker-execution/`: the disposable database,
structured transcript, Markdown, probe source/compiler invocation, results,
post-exit verification, build log and source/input/binary hashes. This closes the
previous successful-worker-execution gap for this fixture. It does not establish
that the assigned names are correct, exercise worker failure/restart with real
inference, qualify device ingress or long-form capture, or resolve cross-revision
speaker binding. The anonymous stored text and separate name map are intentional;
the transcript editor renders names from the structured transcript and map.

## Fresh nonmatches must remove stale automatic names — September 7

Following observation reevaluation exposed a displayed-identity defect independent
of model quality. After matching Alice, removing the independent enrollment evidence
and submitting a fresh observation correctly returned noMatch, but the Library
retained Alice's automatic name, person link and pending suggestion. The existing
self-corroboration test checked only the decision, missing all three stale surfaces.
Adding projection assertions reproduced five failures, including an unchanged
Library revision and the stale name still visible after replay.

The observation transaction now removes the previous unconfirmed link and its
pending suggestion when a fresh evaluation has no accepted match. It removes the
display label only when it still equals the linked person's generated name, bumps
the Library revision/change log, and reprojects the recording. User-confirmed links
and names remain; a separately edited label is preserved while its stale automatic
link is removed. Historical observation decisions remain immutable and replay
does not reapply their name. Automatic evidence removal does not revise the
recognition pack, since it was never eligible confirmed enrollment evidence.

The app build passed. The related Store, matcher, reidentification and suggestion
suites passed: 28 XCTest tests plus 20 Swift Testing tests, with no skips. Coverage
includes fresh nonmatch cleanup, Library revision propagation, immutable replay,
confirmed assignments and edited labels. Before/after logs, source and app-library
hashes are retained under `stale-automatic-name/`.

This corrects reevaluation projection; it does not repair old observations without
a fresh evaluation. Inspection also confirmed that changing embedding payloads
under the same operation ID is rejected by the request hash, not silently replayed.
Host operation IDs still omit processing-artifact revision, and Client/Host cluster
authority binding remains unresolved. Those require a complete binding design;
simply generating new random IDs would not establish which timeline a name belongs to.

## Historical enrollment contamination reproduced — September 7

An app-linked disposable Store diagnostic submitted two unrelated orthogonal voice
vectors under separate operations for one recording/index, then confirmed that
slot as Bob. The recognition pack enrolled the older 20-second voice instead of
the newer six-second voice; Host matching accepted both as Bob. The test failed
three assertions. This proves an evidence-selection and confirmation-binding
defect without relying on a speech model's accuracy. The existing queries join
all historical observations to the current slot assignment; pack deduplication by
duration and Host matching over every row consequently disagree.

The intentionally failing diagnostic, logs and exact source/app-library hashes
are retained under `historical-enrollment/`. No user library was changed. No fix
is claimed: selecting the latest row would still confuse arrival order with
processing authority. The required coordinated schema, persistence, confirmation,
transport and replay work is specified in
[speaker evidence binding](../plans/2026-09-07-speaker-evidence-binding.md).

## Current-source AMI transcription diagnostic — September 25

The current package binaries transcribed the original ES2002a first three consecutive 180-second windows with VAD off and on. All six raw results were retained. Diagnostic WER off/on was 39.21%/30.40%, 19.22%/27.33%, and 18.79%/14.99%. Five cases exceeded the exploratory 15% bound fixed before this run. This is a previously used fixture, not held-out qualification; chronological overlap ordering, fillers and lexical versus numeric formatting affect raw WER. The strict final-phrase assertion also flags “alright” versus “all right”, so that failure alone does not establish dropped audio.

A concrete numeric mismatch warrants follow-up: the reference production-cost phrase contains “twelve fifty”, while both modes emit “$1.50” at that occurrence in the third window. Do not infer replacement numbers from neighboring text; isolate the annotated audio interval and evaluate bounded context/overlap before any mitigation. No production inference settings or acceptance thresholds were changed. Evidence: build/qualification/current-ami-stt-20260925/, including frozen corpus, annotation/audio hashes, all raw timed words, test log and summary. This measures transcription, not known-person identification.

### Numeric error depends on context and overlapping speech — September 25

Isolated the original PCM around the annotated D amount at 508.76–509.26 seconds without removing other speakers. B says “All together” from 508.17–508.92, overlapping the start of “twelve”. Six controlled excerpts were transcribed with the current local model: 500–518 seconds produced the correct “twelve fifty” with VAD off/on; 495–523 produced “$1.50” in both modes; 480–530 produced “$1.50” without VAD and “twelve fifty” with VAD. All raw outputs and reference intervals are retained in build/qualification/current-ami-numeric-20260925/.

This demonstrates context sensitivity; it does not isolate overlap as the sole cause, prove a generally better chunk policy, or justify picking whichever retry yields a plausible amount. The corpus was selected from a known failure and is not held out. No production transcript rewriting or chunk-policy change was made. Broader numeric fidelity needs independent labeled examples before a mitigation can be accepted.

### Preselected additional numeric contexts — September 25

Before inference, selected all 17 occurrences of an explicit number-token vocabulary after 540 seconds in retained ES2002a. Grouping occurrences separated by at most 20 seconds yielded six passages; each was tested with five and fifteen seconds of surrounding context, VAD enabled. Manual comparison of the 12 saved outputs to target annotations found the quantities preserved, including equivalent lexical/numeral forms (25, 18 pounds, five minutes, four or five devices, MP3, thirty minutes and ten to twelve). No additional target-quantity mismatch was observed. The overall corpus test still failed its exploratory raw WER/final-phrase checks; no threshold was relaxed.

These are additional passages from the same meeting and speakers, not independent population qualification. Raw WER counts legitimate numeric formatting changes as errors, so it cannot by itself measure numeric fidelity. The original overlapping twelve-fifty failure remains open, and no general chunk policy or automatic number replacement is justified. Frozen selection rules, audio/annotation hashes, all outputs and explicit manual review notes are retained in build/qualification/ami-numeric-expansion-20260925/.

## Local Unified ASR candidate comparison — September 25

Extended the opt-in corpus test with HARC_STT_CORPUS_ENGINE (v2 by default, explicit unknown values rejected). Every new measurement records its engine. The installed experimental Unified engine was run on the exact frozen six full-meeting cases and twelve additional numeric contexts. Raw WER improved on all 18 pairs. The unweighted mean over the six three-minute cases fell from 24.99% for v2 to 19.69% for Unified. Both third-window modes retained the annotated twelve-fifty occurrence, and manual comparison found the additional quantities preserved. Output timing rows were nonempty and within the existing bounds.

Full-window inference took 7.33–11.33 seconds with Unified versus 0.56–0.76 seconds for v2 on this machine; model-load time is separate. Both opt-in corpus test runs still failed their exploratory WER/final-phrase assertions. These are same-meeting, previously inspected diagnostics, not independent speaker-population or long-form qualification. Raw WER includes lexical/numeric formatting and overlap order effects. Production remains on v2; no daemon launch configuration or model-selection behavior changed. Further candidate acceptance needs different meetings/speakers, complete IPC word-timing/diarization behavior and realistic recording lengths.

Evidence: build/qualification/current-ami-unified-20260925/comparison.json, both candidate result directories, exact frozen manifests and local model hashes. The test-only engine selector was compiled and exercised by the actual candidate runs.

### Unified comparison on a second session and continuous nine-minute input — September 25

Frozen ES2002b's first three consecutive 180-second windows plus the contiguous first 540 seconds before comparing engines, with VAD enabled and unchanged exploratory thresholds. Unified lowered raw WER on all four pairs: 19.17→12.69%, 14.60→10.46%, 24.47→17.82%, and 19.82→14.98% on the full nine-minute input. The full input took 26.33 seconds for Unified versus 1.85 seconds for v2, excluding model load. All candidate word starts were monotonic, end times followed starts and stayed within the existing duration allowance.

Both test runs still failed overall; lower WER does not certify completeness or a production pass. ES2002b is a different session with the same participants, not an independent voice population. The first window has also been used in earlier speaker work. This does not test installed daemon/app transport, speaker attribution, live capture or prolonged resource use. Production remains unchanged. Corpus selection, source/audio hashes, exact texts/timings, logs, exit statuses and comparison are retained in build/qualification/ami-second-asr-20260925/.

### Unified through actual client/daemon IPC — September 25

Extended the existing opt-in EndToEndTests fixture with explicit diagnostic engine/audio/output options and isolated logs. It now requires model readiness, checks word timing order/bounds, rejects an invalid input, proves recovery with the valid short fixture and requests shutdown; thrown failures clean up the owned daemon. The normal engine remains v2. The test also locates the source fixture when Xcode 27 bundles differ.

The real DaemonLauncher/HarcSTTClient path passed one test with no skips using the explicit freshly built helper and Unified on the 540-second ES2002b fixture (53.094 seconds including startup and recovery). The returned 1,348 word rows passed timing checks. The text differs from the earlier in-process output; scored against the same reference, raw WER is 14.85% versus 14.98% previously. Variation is unresolved and these results are not interchangeable. Diarization was disabled for this transcription test; installed app, Host/relay, live capture and named-speaker accuracy remain unqualified. Evidence, exact helper/source hashes and raw result are in build/qualification/unified-client-ipc-20260925/.

### Unified with explicit diarization through client/daemon — September 25

The opt-in client integration test now supports HARC_CLIENT_E2E_DIARIZE=1, selecting the same required-diarization helper used by Host processing. It asserts returned speaker segments, nonempty finite embeddings with positive duration/count, explicit overlap assessment and ordered bounded word timings. Four tests passed without skips: the actual nine-minute path and three required-diarization merge/failure cases. Invalid input and subsequent short-file recovery remain covered. No production path or model default changed.

Execution success did not qualify speakers. Against positive-duration AMI lexical annotation windows, the retained output has 118 segments, 13 clusters/embeddings and four annotated participants. The existing best one-to-one anonymous mapping scorer reports 19.51% segment-based diagnostic error, 83.70% overlap precision and 45.41% overlap recall. This is neither standard DER nor enrolled-person identification; mapping is optimized on this same excerpt, and ASR engine selection does not replace the diarizer. Fragmentation and missed overlapping speech remain material. Evidence, reference windows, raw results and exact helper/source hashes: build/qualification/unified-diarization-ipc-20260925/.

### Fragmentation is not safely resolved by a looser merge cutoff — September 25

Analyzed the retained nine-minute output against annotation intersections and pairwise cosine similarity of final cluster embeddings. Nine of thirteen clusters have under five seconds of tracked speech. Cluster 1 has 4.10 seconds tracked duration but only 0.907 seconds of positive-duration lexical-reference intersection, entirely B. Its final embedding similarity to D-dominated cluster 5 is 0.7709, higher than same-dominant-speaker pairs 0/2 (B, 0.7323) and 6/8 (C, 0.7236). Thus a single final-centroid cutoff admitting those same-person pairs would also admit a cross-dominant pair.

This is an annotation-assisted diagnostic, not runtime authority or a replay of the online tracker. Overlapping reference speakers affect purity, and final centroids may differ from those available during tracking. It nevertheless rejects blindly loosening a post-hoc cosine merge cutoff as the next production fix. No thresholds, enrollment rules or stored names changed. Full per-cluster reference intersections and short-duration counts are retained in unified-diarization-ipc-20260925/cluster-analysis.json.

## Withhold long-recording voices with no exclusive support — September 25

The nine-minute real output exposed a duration/binding mismatch: eight embedding duration claims exceed their cluster's exclusive published support, and clusters 9 and 10 have no exclusive support at all. The independent sweep mirrors the production exclusive-turn construction; it is not an executed signed app-batch test. Simply clipping claims would not prove that the retained centroid came from the remaining speech.

Diarizer now applies an event-sweep support gate to all recordings: raw overlap and simultaneous different tracked speakers exclude support. A voice with no positive exclusive interval is withheld, while transcript segments and overlap remain intact for missing-evidence reporting. Repeated intervals of the same speaker are counted as one active identity; adjacent boundaries create no synthetic speech. Partially supported embedding bytes and durations are unchanged; their remaining duration mismatch is explicitly unresolved.

Fifteen focused cases, including real-model tests, passed without skips. An actual nine-minute Unified client/daemon replay also passed: embeddings fell from 13 to 11, exactly clusters 9/10 were withheld, and all 118 speaker segments, overlap ranges and retained embedding rows were identical to the prior run. This prevents unsupported voice evidence from entering subsequent name matching, but does not fix the timeline or establish correct identities. The change is unshipped. Evidence and exact source/helper hashes: build/qualification/exclusive-voice-support-20260925/.

### Isolated exclusive-support re-extraction — September 25

Compiled a CoreML/FluidAudio-only diagnostic against the current built dependency. It re-extracts embeddings from original ten-second windows, with masks accepting only fully contained bins of one tracked speaker and no raw overlap. Sixty-six fresh window vectors pool into eleven clusters; support counts stay below each cluster's exclusive timeline. No existing vector or duration is rewritten, and this candidate remains outside production.

The problematic 1/5 pair remains highly similar (0.7709→0.7604); same-dominant pairs 0/2 and 6/8 change 0.7323→0.6934 and 0.7236→0.7448. Thus re-extraction does not solve the demonstrated identity ambiguity. Uniform mask-bin timing is an approximation that still needs exact model receptive-field validation, and earlier short-voice clean controls must pass before any promotion. Probe, fresh vectors, window support counts, logs and hashes are retained at build/qualification/exclusive-reextract-20260925/.

Inspection of the installed WeSpeaker MIL graph confirms that its 589-point input mask is resampled to 125 pooling weights by `upsample_nearest_neighbor` before weighted statistics. Counting active input bins therefore does not establish effective pooling support. Exact runtime source-index mapping and feature receptive-field contamination remain unresolved; the diagnostic's uniform-bin duration must not become production acoustic provenance. Retained graph excerpt and model hash: build/qualification/exclusive-reextract-20260925/mask-pooling-findings.json and mask-pooling-graph.txt. No production extraction or duration claim was changed on this evidence.

A subsequent local runtime probe toggled each of the 589 mask positions independently on one ten-second public fixture. Exactly 125 toggles changed the embedding, matching the predicted sampled-index set `floor(outputIndex / Float32(scale))`; the other 464 left it byte-for-byte unchanged. Keeping only the predicted sampled positions also reproduced the full-mask vector exactly, as did a repeat control. The unrestricted run completed without the earlier sandbox cache warning. This supports the sampled-index set for the installed model, not the individual output time coordinates, temporal receptive field or speaker accuracy. All outputs, source and fixture hashes are retained in mask-runtime-exhaustive.json and mask-runtime-summary.json under the same evidence directory. Production extraction remains unchanged. Free space reached 4.9 GiB after completion, so further builds/model runs were paused at the operational disk guard.

### Current known-person comparison — September 25

After removing obsolete release build output, evaluated the current eleven retained vectors and experimental eleven re-extracted vectors with the current built HarcDomain quantized matcher. Both arms used the same six retained six-second B/D enrollment samples from ES2002a after 600 seconds, while queries came from ES2002b first 540 seconds. The threshold remained 0.65; A/C were unknown. This is a development diagnostic on previously used meetings and directly constructed packs, not held-out population accuracy or app enrollment qualification.

Both arms made exactly the same assignments: cluster 2 to B, clusters 1 and 5 to D, others unnamed. Cluster 1 has 907 ms of lexical reference intersections, all B, yet matched D with score 0.6793 current / 0.6855 experimental. Its 4.1-second timeline and incomplete lexical reference mean this is not an audited full-segment wrong-name duration. Across assigned clusters, both arms have 232,942 ms of matching reference intersections and 21,790 ms of other-speaker intersections; overlap is included, so these are not DER or speaker-attributed WER. The experiment does not improve identification on this case and remains unpromoted. Inputs, actual decisions, per-cluster comparison, probe and hashes: build/qualification/current-known-speaker-20260925/.

An annotation-assisted localization probe then used identical original audio from 15–25 seconds and three masks fixed before inference: the tracked cluster interval 17.733–21.834; its B segment-annotation intersections 17.733–17.978 and 19.463–20.523; and the exact unannotated complement. The complement alone matched D at 0.6837. The annotated-B mask remained unnamed (maximum raw similarities B 0.1985, D 0.3484); the full interval also remained unnamed in this shifted context (D 0.6440). This localizes the stronger D evidence toward unannotated audio and demonstrates context sensitivity, but cannot identify the actual speaker there. Missing annotations are not silence, and the model receptive field may cross mask boundaries. Do not use this diagnostic to relabel the reference, count the entire cluster as wrong, or tune a production threshold. Evidence: current-known-speaker-20260925/interval-probe/.

### Pooling masks do not isolate waveform evidence — September 25

The installed model subtracts the mean across all 998 temporal feature frames before the convolution stack and masked pooling. A controlled runtime probe on the same retained public ten-second context selected mask bins entirely within seconds 2–3, then zeroed only seconds 7–10 in a disposable in-memory copy. The selected audio was exactly unchanged. Repeating the original prediction produced zero maximum component difference; changing the distant unselected audio produced maximum difference 0.3510902822. This proves outside-mask influence for this case, without attributing its magnitude solely to normalization or measuring general identity error.

Consequently, the exclusive-mask re-extraction experiment cannot establish exclusive acoustic provenance merely from selected mask bins, even after correcting the 589-to-125 resampling. It remains rejected for production promotion on that basis. Existing zero-exclusive-support withholding remains a separate safeguard, not proof that retained vectors contain only one speaker. No production audio, thresholds or model changed. Probe, vectors, graph excerpt and hashes: build/qualification/exclusive-reextract-20260925/ContextProbe.swift, context-summary.json, context-runtime.json and whole-window-normalization.txt.

### Retained native ECAPA vectors through current matcher — September 25

Before repeating older cropped-segment experiments, reviewed their clean-voice false splits and the separate ECAPA native parity results. The historical temporary ECAPA package is no longer present; current default Python also lacks its conversion dependencies. Recompiled the retained ECAPA matcher probe against the current HarcDomain library and replayed all 100 retained native vectors (12 enrollment, 88 queries), preserving model ID, 0.46 threshold and current ambiguity policy. All assignments equal the prior results, including the documented noise rejection and residual boundary error. This confirms current matcher compatibility only; it is not fresh model inference or an accuracy pass. Restoring the pinned model conversion and running real-meeting evaluation remain prerequisites to considering this alternative. Probe, exact input/library hashes and comparison: build/qualification/current-ecapa-matcher-20260925/.

Restored the pinned checkpoint revision after verifying every downloaded file against retained lengths and SHA-256. Recreated an isolated Python 3.12 environment with torch/torchaudio 2.5.1, SpeechBrain 1.0.3 and coremltools 8.3.0; transitive versions are recorded rather than assumed identical. The retained converter rebuilt /private/tmp/harc-ecapa-coreml/ECAPA.mlpackage. CPU-only predictions on all 100 retained native Swift feature tensors passed the predeclared parity bounds (maximum normalized error below 1e-4, minimum cosine above 0.99999): observed maximum error 5.96046e-08 and minimum cosine 0.99999976. Model hashes, scripts, environment, logs and outputs are in build/qualification/ecapa-restore-20260925/. This restores numerical comparability, not fresh meeting accuracy or production integration. Free space ended at 5.7 GiB; the next model compilation requires rechecking the diagnostic headroom.

### Native ECAPA on current meeting intervals — September 25

With 6.1 GiB free at start, froze exact exclusive intervals from the current nine-minute ES2002b timeline, subtracting raw overlap and competing tracked identities. Merged adjacent same-speaker spans, split at 30 seconds, and explicitly excluded 16 residual spans below two seconds (20,518 ms). The 42 eligible query spans total 367,151 ms. No reference labels influenced selection. Re-embedded the six unchanged ES2002a B/D enrollment clips and every query using native Swift features and CPU Core ML, then the current quantized matcher with unchanged ECAPA threshold 0.46. All 48 inference cases completed.

On these same eligible intervals, current cluster names intersect 216,689 ms of matching lexical reference and 7,947 ms of other-speaker reference; ECAPA interval names intersect 224,168 / 5,875 ms respectively. Four decisions changed: two previously unnamed B-annotated spans gained B; a D assignment over A/C annotations became unnamed; and a fully unannotated early span gained B (unscored, not credited as correct). Other assignments were unchanged. Reference overlap and missing annotations remain, and current cluster-level extraction versus fresh interval extraction confounds model and extraction effects. This is a promising development result, not DER, speaker-attributed WER, an untouched holdout, or promotion evidence. Short intervals and remaining wrong-name intersections are open. Corpus, native outputs, exact model/source hashes, matcher decisions and scoring code: build/qualification/ecapa-meeting-20260925/. Production profiles and backend remain unchanged.

### Same-interval WeSpeaker control — September 25

Re-extracted WeSpeaker vectors from exactly the same original contiguous query and enrollment audio, restricting the comparison to 31 query intervals of 2–10 seconds because its extractor accepts at most ten seconds. All 37 inference cases completed. The extractor's normal repeat padding and full mask apply to these cropped clips; no surrounding meeting samples enter the input. Enrollment uses the same six B/D clips. Thresholds remain WeSpeaker 0.65 and ECAPA 0.46.

On this common subset, matching/other-speaker lexical intersections are 57,790/4,999 ms for current cluster names, 50,644/1,882 ms for cropped WeSpeaker and 65,269/2,927 ms for ECAPA. ECAPA names five intervals that cropped WeSpeaker leaves unnamed; four have B reference support, while the fifth is wholly unannotated. Thus ECAPA recovers more matching speech but adds 1,045 ms of other-speaker intersections relative to the cropped control. This is a coverage/error tradeoff, not a clean accuracy pass. Eleven longer queries and sixteen short residual intervals remain outside this paired comparison. Intrinsic padding/features differ between models, and missing/overlapping reference limitations remain. Evidence: build/qualification/wespeaker-interval-control-20260925/. No production inference or profiles changed.

### Separate reference mismatch, overlap and missing annotation — September 25

Refined that comparison with a disjoint wall-clock partition; all arms still use exactly the same 31 intervals and unchanged decisions. A named span is classified separately when the reference contains only that person, contains that person plus another voice, contains only other people, or has no lexical annotation. Unnamed spans also retain known/unknown/no-reference categories. Duplicate reference rows cannot inflate duration; duplicate/overlapping query intervals are rejected. Four synthetic checks cover overlap categories, duplicate reference invariance, abstention and query rejection; category totals equal evaluated wall-clock duration.

| Current evidence category | Current cluster names | Cropped WeSpeaker | ECAPA |
| --- | ---: | ---: | ---: |
| Named person is sole reference (ms) | 55,216 | 48,783 | 62,445 |
| Named person present in reference overlap (ms) | 2,574 | 1,861 | 2,824 |
| Named person absent from nonempty reference (ms) | 1,715 | 21 | 103 |
| Named with no lexical reference (ms) | 1,789 | 1,402 | 4,472 |

The prior 1,045 ms increase in other-speaker intersections is therefore not 1,045 ms of exclusive wrong-person labeling: the reference-mismatch increase versus cropped WeSpeaker is 82 ms, while additional overlap contains the named person too. Missing-reference naming remains unverified, and overlap presence does not prove separation. Lexical boundaries are not exhaustive acoustic ground truth; these are development diagnostics, not standard DER or an accuracy gate pass. Runnable partition scorer, retained reference and all categories: wespeaker-interval-control-20260925/partition-score.py and partition-results.json.
