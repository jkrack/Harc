# Combined release: speaker playhead validation handoff

## Candidate scope

Harc 0.14.23 (79) combines the Apple on-device transcription work, post-recording
detail, iPhone haptics, and the requested Mac Speakers playhead. The playhead
commits `87c7d45` and `57c1c5d` descend directly from `7f3c047`; there is no
conflict or independent product merge. Graph/project-refinement work is not
included and is not a shipped UI. Existing LLM summarization is unchanged.

## Evidence retained before hosted validation

- Base `7f3c047` passed full CI run `43974776732`. Its CI checkout
  `f14f11c2e2ae03495775204dc3f1de71ffbebf43` has the same Git tree
  `60e3b3abe650fefd1c7e9df00dff00d23a74a47d`. The strict gates recorded
  120 Mac and 143 mobile test methods, with zero failures or skips. This is
  base evidence, not a pass for the later playhead commits.
- Local `PlaybackSeekPositionTests` passed all seven cases. Xcode's isolated
  `build-for-testing` on `57c1c5d` succeeded, including the app and UI target.
- The local UI execution did **not** run a test. It failed initializing the
  runner with `Timed out while enabling automation mode`. The retained
  `playback-ui.xcresult`, `ui-build.log`, and `ui-tests.log` are in the
  development SSD's `HarcBuilds/speaker-playhead-20261117` evidence directory.
  Owner authentication is required; an earlier grant is not a new pass.
- Independent source review found no blocker in the marker mapping, endpoint
  clamping, non-hit-testing/AX-hidden overlays, or playback-state preservation.
  Source review cannot establish rendered contrast or an actual runtime pass.

The integrated CI selector/evidence follow-up passed all 202 local Python
tooling regressions. Independent review found no selector, skip-policy or
evidence-scope regression. This does not turn the blocked native run into a pass.

## Remaining hosted and release gates

The repository's local-first workflow permits a review-ready candidate after
focused local package tests. Run full CI on the exact final head, retain its
source/tree identity, and require both dark and light playback UI methods.
Missing or skipped appearances must fail the gate. Inspect the actual retained
screenshots to verify Harc and the visible playhead in both modes and appearances.
A green aggregate without those methods and visual evidence is insufficient.

The existing 0.14.23 (79) Mac DMG and development-signed iOS archive identify
`7f3c047`, not the playhead source. Preserve them as earlier preparation evidence;
do not relabel them. Rebuild final source-bound artifacts after source selection.
Mac notarization needs the outstanding explicit owner approval, then accepted
notarization, stapling, signature/Gatekeeper verification and exact public
asset/feed checks. No notarization submission or release is claimed here.

TestFlight remains an internal owner beta for James Only - Experimental only.
Recheck signing, privacy/preflight, Apple processing and group assignment for
build 79. No App Store submission, external testers, credential creation or
security-settings changes are part of this handoff. Physical Apple-model
availability, real capture/Stop/playback, protected-master/codec and authenticated
phone-to-Host/Library gates remain open; hosted tests do not waive them.

## November 18 successor integration

The exclusions above apply to the November 17 candidate. Successor source
`8a0f013` combines `49f776d` with graph/consent integration `f5b9c0f`; it includes
the explicit read-only accepted map and project-refinement stack. Its exact
head requires new full CI and artifact/device release checks. No earlier pass
is relabeled as qualification of the successor, and no publication is claimed.
