# Apple on-device speech migration

## Scope

The Mac daemon now defaults to SpeechTranscriber on macOS 26+, using the native
Speech framework, English (en-US), and original-file time attributes. There is
no cloud transcription route and no silent fallback. Apple may download its
OS-managed model assets. FluidAudio diarization remains separate and unchanged.
Explicit `v2` / `unified` engine overrides remain local diagnostic options.

Capture durability, adopted-Host transfer, codec qualification, speaker evidence
binding and publication integrity are unchanged. This branch does not add phone
inference. iOS has a separate implementation/qualification track.

## Safety and compatibility

- Each analysis owns fresh state; only finalized results are published.
- Word timings preserve the original file timeline; Apple processing bypasses
  Parakeet's VAD compaction. Missing/invalid lexical timing fails visibly.
- Final-result seams preserve lexical boundaries and untimed whitespace.
- Cancellation cancels/drains analysis, never publishes partial results.
- Availability and installed assets are checked; evicted assets re-enter visible
  preparation. Asset failures leave audio available for the normal retry path.
- Actual engine identity is returned in status and transcription replies. The
  launcher and client reject old/mismatched helpers, rather than labeling their
  transcripts as Apple results. Readiness is engine-scoped and reports mismatch.
- Apple asset revision is not exposed; `apple-speech-transcriber` identifies the
  provider, not a fabricated model version. Existing stored transcripts remain
  untouched until explicitly reprocessed.

## Validation (2026-11-16)

Mac mini: macOS 26.6.2, Apple Silicon, Xcode 27 SDK. Focused candidate run passed
76 Swift Testing cases across UI (19), STT (29), Core (1), and Client (27), with
`HARC_INTEGRATION_TESTS=1`. The filter included AppleSpeechEngineTests,
TranscriberTests, DaemonLauncherTests, ASREngineSelectionTests, HarcSTTClientTests,
STTReadinessTests, WelcomeFlowModelTests, SpeechEngineIdentityTests,
ArchiveSpeechProvenanceTests, SpeechReadinessIdentityTests, and RequestHandlerTests.
The broad TranscriberTests regex also selected chunk-recovery regressions.

Both short-speech fixture paths used the actual Apple engine. The synthetic
fixture returned eight ordered timing runs spanning 0–2971 ms, with nonempty
transcript and word timings. No Parakeet comparison was run.

The Mac Xcode Debug app build passed, including fresh release builds of both
embedded helpers. An isolated IPC smoke of that built `harc-stt` transcribed a
44.560-second synthetic repetition (15 copies of the fixture): 120 ordered timed
words, 15 mentions of “test,” first timestamp 0 ms and last 44280 ms. The reply
reported `apple-speech-transcriber`. No user recordings were read; the app was
not installed. Evidence is retained on the development SSD.

This is functional/regression evidence, not an accuracy benchmark, real-meeting
or long-recording qualification, or a release. Full PR CI and installed-app
validation remain gates; do not publish from this evidence alone.
