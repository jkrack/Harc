# Combined release CI: synthetic playback lifetime

## Retained failure

PR #207 head `53118b83189b8f6668e798d90366c71d02981121` was tested by CI run
[43799606474](https://github.com/jkrack/Harc/actions/runs/43799606474). The hosted
merge `f2bc6cb1712a4b642f62956b432f09c6a7241e64` has the same Git tree,
`9fbc3be24b6f24dab09c45cdb19a96d767f07e79`.

The mobile execution result was a failure, not an infrastructure-only timeout:
130 of 131 test methods passed, one failed, and none skipped. The failed method
was `HarcMobileRecordingDetailUITests/testLocalDetailPlaybackSectionsAndReopening`.
At line 56, the test expected the playback button to read Pause but found Play.
The iPhone 17 Simulator ran iOS 26.5 (23F77).

The downloaded evidence archives were checked against GitHub's SHA-256 digests:

- `mobile-execution-diagnostic`, artifact 14196902705:
  `4f70aa84ea7e874150d019d9eea19c92e8c1a607b69a085ba8894dc22fd1b457`
- `mobile-configuration-evidence`, artifact 14196593345:
  `5fce3c170480f2667dbb718acddf115b7fa9e35c02a483fee7d4b277fc74e5ba`

The original xcresult, console log, video and exported attachments remain
preserved in the SSD investigation evidence. No unchanged rerun was used to
replace this failure.

## Observed cause

The test used a real 60-second synthetic WAV, paused it, and verified a midpoint
seek between 25 and 35 seconds. Resume was synthesized at test time 43.56 seconds,
and Pause was observed at 45.05 seconds. Accessibility navigation through
Transcript, Notes and Summary delayed the final label query until 84.90 seconds:
more than 41 seconds after resume, exceeding the remaining audio.

The retained video frame at approximately 84 seconds shows **1:00 / 1:00**, the
slider at its endpoint, Summary selected and the Play button. Successful audio
EOF deliberately transitions the controller to Play at the full duration. A
controller stop/reset would instead clear the position. Independent source and
image review found no confirmed production section-change reset.

## Scoped correction

Only the playback/navigation case opts into a 600-second DEBUG audio fixture.
The additional argument still requires the existing freshly reset, identified
UI-test root and the normal local-recording fixture flag; duplicate or incomplete
combinations fail closed. Other fixture consumers retain 60 seconds. Tone and
silence buffers are reused without changing their sample bytes or the durable
writer's per-second calls.

A dedicated 60-second UI seek case retains the original 25...35-second midpoint
assertion, seconds-valued accessibility, and no-autoplay-while-paused checks.
The long case instead checks exact +15/-15-second paused controls before resuming
and navigating sections. Its final Pause, section retention, reopening and Library
navigation assertions remain. An additive app test uses real 600-second audio and
AVAudioPlayer to check exact paused seeking to 300 seconds within one source audio
frame, including a bounded observation that paused time does not advance.

No production slider or playback-controller behavior changes. Timeouts, retry
policy and skips are unchanged. The revised tests must run successfully; this
record is not a playback fix, codec/physical qualification or release claim.

## Local diagnostic follow-through and retained seek failure

The first amended diagnostic snapshot built successfully and its seven local
transcription tests passed in a sealed, strictly gated result. A subsequent UI
attempt was interrupted by the capacity guard before any complete case passed.
After scoped resource recovery, a single controlled retry reached an actual
midpoint-seek assertion failure. Both interrupted results remain unqualified.

That retry used the earlier unsplit 600-second case with a new 295...305-second
window. Its recorded paused value was **314 seconds of 600 seconds**. The slider's
accessibility frame was x=32...370 (width 338); XCTest pressed at (40, 479.5), held
0.25 seconds, then moved/released at (201, 479.5) at 0.57 seconds. The release point
is the frame midpoint, but the press began near the left edge. The before value
was 1/600; the after value stayed 314/600 with a Play label. This rules out elapsed
playback as the extra time. A retained thumb-grab offset is plausible, not proved.

The fixture extension inadvertently tightened normalized acceptance tenfold:
25...35/60 was 41.67...58.33%, whereas 295...305/600 was 49.17...50.83%.
Apple documents the [normalized slider adjustment](https://developer.apple.com/documentation/xcuiautomation/xcuielement/adjust%28tonormalizedsliderposition%3A%29)
as approximate. This does not prove human scrubbing geometry correct. The reviewed
split preserves the original short-case accuracy bar instead of widening the
failed window, and adds exact long-audio coverage. Human slider geometry remains
an explicit unproven manual/physical follow-up.

The runner stalled in CoreSymbolication while reporting that assertion; the
owned processes were stopped and the unsealed result, hierarchy and sampled
failure stack retained. No pass is inferred from the interrupted result.

## Execution coverage correction

The bounded mobile CI selector did not include the seven new
`HarcMobileLocalTranscriptionTests`; their earlier focused local pass was not a
full-CI execution guarantee. The suite and all seven exact test requirements are
now added. The selection-regression fixture retains the original baseline
fingerprints and separately checks these reviewed additions exactly once. The new
short UI seek and real long-audio exact-seek methods are also mandatory executed
tests, not merely compiled test source.

The amended source requires fresh applicable CI and source-bound release
artifacts. The signed but unpublished Mac artifact at `53118b8` remains prior
preparation evidence, not an artifact silently relabeled for this follow-up.
No new TestFlight upload, notarization, Sparkle publication or App Store
submission follows from this diagnostic record alone.

## Revised focused local execution passed

The reviewed split was built and executed from a new isolated diagnostic snapshot
of base `53118b83189b8f6668e798d90366c71d02981121` plus tracked patch
`a35c16eb79e4636be16405ba220978d2881154d2969ba996e92adf9731041a91`.
The source manifest SHA-256 was
`c172b690b1b20f999afbbd2850ef51ac4434050534ea35ba7c434f66636c2f17`.
Previous snapshots and failed/interrupted results were retained unchanged.

On the arm64 iPhone 17 Simulator, iOS 27.0 (24A434):

- Build-for-testing exited 0.
- All eight selected app tests passed, zero failures or skips: the seven local
  transcription cases and the new real 600-second audio/player exact paused
  300-second seek/no-advance case.
- All four recording-detail UI cases passed, zero failures or skips: long-audio
  section retention/reopening with exact paused +15/-15 controls; the original
  60-second midpoint/no-autoplay check; largest Dynamic Type; and persistent
  storage-warning navigation.
- Both sealed result bundles passed the strict named-test execution checker.
  The unit-gate SHA-256 is
  `e8427dcfb10f3b4871877a3fabbaf5a9f92ac441edf0b05134af9ff25761e54e`;
  the UI-gate SHA-256 is
  `412ca2dae85eeba0c4e062cfae7362cf1018ede0a308c494959cfd3589553a95`.
- Exported normal/largest-text screenshots were visually inspected. They show
  the intended detail UI, Pause state and New recording control.
- The same executed package lock was used throughout; its SHA-256 is
  `c53a5db32857fafabae0130d299490724342415b153e64454908feafb8527ad1`.
  Xcode adds the existing Sparkle 2.10.1 pin for its project graph; other pins
  are unchanged. This executed lock is preserved with the results.

The retained runtime warnings include synchronous audio-session work on the main
thread. These are not test failures, but remain performance follow-up evidence;
this change does not claim to fix them. All 200 tooling tests also passed.

This focused pass validates the revised diagnostic test/source snapshot. It is
not clean release qualification, full hosted CI, physical capture/codec coverage,
or proof of human slider geometry. Focused Mac runtime validation remains
blocked separately. No push, merge or publication is established by this record.
