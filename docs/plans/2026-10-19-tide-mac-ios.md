# Tide implementation: Mac and iOS

Requested outcome: finish both native apps tonight (October 19, America/Los_Angeles). Goal is active. Time is a target, not grounds to skip validation or claim incomplete work is finished.

## Latest status (October 20, 07:21 PT)

The overnight target was missed. Both app builds pass. Implementation checkpoint `de8abb4` is committed locally on `codex/tide-mac-ios` in this isolated worktree. Mac fixture rendering/playback and physical iPhone capture/recovery/background Live Activity stop have passed their checks. No push, production installation or release has happened.

The checkpoint was compared with every entry in the final physical run's source checksum manifest. All application, test and build-script files match. Only this progress document and `Package.resolved` differ: the latter has the expected Xcode-added Sparkle/origin-hash churn reverted per AGENTS.md. Existing diagnostic binaries still embed the baseline build SHA; their source is identified by the retained dirty-run manifest, not by claiming they were built from the checkpoint commit.

The physical accessibility issue is now resolved: slightly larger/heavier caption text, bold microphone text and semibold day-axis labels pass the full Record/Review Sample/Privacy audit, with no suppression. Evidence: `/Volumes/MacMiniSDD/HarcBuilds/tide-type-audit-01-20261020/HarcMobileUITests-attempt-1.xcresult`; source manifest `c1a9213d2294d67f64e5724b86642d0933b20bf54d1344d9137c042641758894`; log `/private/tmp/harc-tide-type-audit-01.log`. Temporary contrast-probe, frozen-animation and appearance experiments were removed.

A complete physical regression passed: **8 passed, 0 failed, 1 skipped** (opt-in App Store screenshots). Log `/private/tmp/harc-tide-physical-final-01.log`, evidence `/Volumes/MacMiniSDD/HarcBuilds/tide-physical-final-01-20261020`, same source manifest as the focused audit above. This covers accessibility, navigation, real microphone start/stop, force-quit durable recovery, storage-exhaustion recovery and strictly backgrounded Live Activity stop. It remains diagnostic dirty-tree evidence. XCTest reported four priority-inversion warnings, with no test failures.

Retained screenshots in `/private/tmp/harc-tide-physical-final-01-attachments` show the revised Record text without clipping (`3DA531DB-7D18-4A13-A5AE-BC9ED24C3ADA.png`), Home-screen compact Island at 0:13 (`FF8BBA0F-5563-48E2-9291-9FB970E64825.png`), and Notification Center activity at 0:21 with 0:15 audio saved (`DA40E78F-7399-4C93-8DD0-3B43F26AFD91.png`). The latter includes iOS's subsequent “continue to allow” / “Always Allow” prompt; stop still succeeded. Do not describe it as a permission-free screenshot or an actual passcode-lock test. No capture remains running after test cleanup. Earlier chronological notes below describe superseded states.

Remaining: paired Library/detail/Search and both platforms' pairing/device screens; actual passcode-locked stop; final reviewable source and build handoff. Live Host pairing/transfer requires the outstanding explicit approval because it adds trust and a test recording to the canonical Host, beyond the approved isolated diagnostic phone testing. Do not treat that unanswered question as permission.

## Source and boundaries

### Playback report follow-up

The user reported a saved local recording plays but sounds confined to the iPhone earpiece. A silent physical-device regression on Omega showed initial local playback already selects the `Speaker` output. It also reproduced a separate resume defect: after pausing and changing the shared session to capture's `.record`/`.measurement`, resuming left the session in recording mode, returned playback failure and exposed no output route.

Local and Host-downloaded playback now reestablish `.playback`/`.spokenAudio` and activate the session before resuming; failed resumes remain visible failures. No speaker override is applied, preserving system accessory routing. The local controller is internal so its real behavior can be exercised from app tests.

Before-fix evidence: `/Volumes/MacMiniSDD/HarcBuilds/tide-playback-route-before-20261020.xcresult`, log `/private/tmp/harc-tide-playback-route-before.log`. After-fix evidence: `/Volumes/MacMiniSDD/HarcBuilds/tide-playback-route-after-20261020.xcresult`, log `/private/tmp/harc-tide-playback-route-after.log`: all 13 focused tests passed on Omega, and both initial and resumed routes reported `Speaker`. This confirms the resume repair, not the audible cause of the user's first-play report. Manual listening remains necessary. Tests use a temporary silent file, with no recording deletion or microphone capture.

### iPhone animation cadence follow-up

The user reported choppy frame delivery. Source inspection found intentional 15–24 FPS presence caps and four-per-second live trace/playback updates. The iOS presence and recording indicator now request 60 FPS; live energy samples and playback visuals update approximately 30 times per second. Updates stop when the iOS scene is inactive. Reduce Motion keeps static presence and slower data updates; widgets remain static. Mac presence retains its existing rates and does not assume an inactive menu-bar app means its panel is invisible. Audio capture, metering on the writer queue, and durable writes are unchanged.

Full physical UI diagnostic run passed (8 passed, 1 skipped): `/Volumes/MacMiniSDD/HarcBuilds/tide-smooth-ui-20261020/HarcMobileUITests-attempt-1.xcresult`, manifest `431ece6b52f8691e4824f09eadf2df32714f88feb101c2a9db6310057d9798e6`, log `/private/tmp/harc-tide-smooth-ui.log`.
The full Mac Xcode app build also passed after the shared renderer change (`/private/tmp/harc-tide-mac-smooth-build.log`).

A 15-second Animation Hitches trace attached to the foreground diagnostic app on Omega retained 937 Harc frame updates at 59.99 updates/second. Median update work was 5.96 ms, p95 7.90 ms, maximum 9.78 ms; the hitch table had no rows. Display frame starts were approximately 16.67 ms apart. Evidence: `/Volumes/MacMiniSDD/HarcBuilds/tide-smooth-idle-20261020.trace`; exported tables `/private/tmp/harc-tide-smooth-{updates,frames,hitches}.xml`. This qualifies the sampled idle animation, not sustained recording, scrolling, thermal behavior or every screen.

The 14 artboards in `docs/design/tide-2026-10-19/manifest.json` are the visual reference. They were extracted from rendered Claude artboards with CSS and generated SVG geometry; scripts were removed. They are not editable original project files.

Implement native SwiftUI with existing capture, library, pairing and transfer coordinators. Preserve private inference, durable start without model warmup, protected masters until verified receipt, separate trust/route/delivery states, and visible recovery. Use real data; never copy sample durations, security words, connection timestamps or disabled-transfer claims into production behavior. Preserve `HarcPresenceUI` as the capture-presence renderer and `ActivityView` as the Mac readiness/recovery renderer. The menu panel must not scroll.

## Execution order

1. **Baseline and feasibility.** Record branch/commit, inspect nested instructions and current changes, inspect all artboards visually, inventory current states and available destinations, disk and build caches. Check Live Activity extension/signing needs early; no widget target was found in the initial project inspection. Inspect whether energy history, saved-through evidence and summary annotations already exist. Implement missing presentation data only from trustworthy capture/library evidence; expose unavailable states honestly.
2. **Shared visual foundation.** Map Tide colors, type, spacing, condition rows, timeline geometry and controls onto existing design tokens and `HarcPresenceUI`. Support light/dark appearance, Dynamic Type, accessibility labels and Reduce Motion. Extract small reusable components rather than duplicating screen renderers.
3. **Mac capture surfaces.** Implement idle and recording menu panels, recording island and Quick Capture in `MenuBarPanelView`, `RecordingIslandView` and `QuickCaptureView`. Preserve input selection, dictation, start/stop/discard safeguards and activity access. Connect waveform/history and saved-through indicators to actual evidence.
4. **Mac library and devices.** Implement Tide library/sidebar, detail hierarchy, timeline/playback, summary/actions and transcript composition using current library and session views. Keep editing, search, speaker review and recovery reachable. Update Devices & Sync and pairing presentation while preserving authority, expiry, SAS and capability checks.
5. **iOS primary flows.** Refactor `HarcMobileRootView` into focused views as needed; implement Record, Recording, Library, Recording Detail and Search. Retain local and Host recording distinctions, originating device, transfer/retry visibility, playback, export disclosure, editable metadata and accessibility identifiers.
6. **iOS trust and persistent capture.** Implement Setup & Sync and Pair a Mac with existing coordinators. Implement Lock Screen/Dynamic Island Live Activity through an appropriate extension and shared activity state, with truthful durable-save status, reliable stop handling and stale/ended cleanup. If platform/signing or shared-state requirements need a material architecture decision, surface the concrete decision early while continuing independent UI work.
7. **Validation and repair.** Run focused model/state tests for changes and existing capture/recovery/library coverage. Build both Xcode app targets with at most two workers, sequentially. Run iOS UI qualification using `scripts/qualify-harcmobile-ui.sh`; label dirty-tree runs diagnostic. Inspect real rendered Mac panes and iOS screens, including empty/error/offline/recording states, not only sample fixtures. Exercise record → stop → playback and available Host transfer → verified receipt → Library. Run pairing lifecycle scripts if transport behavior changes. Re-run checks after relevant repairs.
8. **Delivery.** Keep a screen-by-screen completion checklist and exact build/test evidence. Prepare reviewable commits and runnable build artifacts. Identify physical-device qualification separately from simulator coverage. Public release, appcast publication and replacement of installed production apps are separate delivery decisions.

## Acceptance checklist

- [x] Mac Library — seeded/restored selection, summary/transcript layout and real diagnostic-audio playback inspected; canonical Host delivery remains a separate gate.
- [x] Mac menu bar recording — timer, trace, save control and post-stop transition inspected with isolated fake capture; destination-prefix fix compiled in Mac build 7.
- [ ] iPhone Lock Screen and Dynamic Island — strict background-state assertion, compact Island rendering, Notification Center activity, durable-save update and stop passed on Omega in focused attempt 8; actual passcode-locked interaction remains manual.
- [x] iPhone Record — simulator audit passed in attempt 7; physical audit passed after increasing caption size/weight, microphone-label weight and Today-axis weight. No audit findings suppressed; full physical regression remains separately tracked.
- [x] iPhone Recording — physical screenshot verifies timer, durable saved-through status and stop control; real start/stop and recovery tests passed in physical attempt 3.
- [ ] iPhone Library
- [ ] iPhone Recording Detail
- [ ] iPhone Setup & Sync — unpaired screenshot and navigation verified; paired-device state still needs verification.
- [ ] iPhone Pair a Mac
- [ ] iPhone Search — empty/offline screenshot and navigation verified; connected Host results still need verification.
- [x] Mac menu bar idle — rendered idle and post-stop states inspected; Today count and Last capture update after isolated fake capture.
- [ ] Mac Devices & Sync
- [ ] Mac Pair a Device
- [x] Mac Island and Quick Capture — fake capture starts through Quick Capture; compact/expanded Island render and its stop action saves and hides it.
- [x] Focused tests and both app builds pass — 12 iOS unit tests, 6 durable-writer tests, full Mac build 7, simulator UI run 7 and complete physical diagnostic run final-01; this is not release qualification.
- [ ] Visual and interaction evidence retained
- [ ] Available physical-device checks and any remaining gates reported accurately

## Operating limits

Use this isolated worktree. Preserve unrelated work and real profiles. Cap Swift/Xcode concurrency at two workers; stop builds before free space falls below 5 GiB. Prefer the mounted external SSD for regenerable build output where available. Do not relocate recordings or databases. Track progress against all 14 screens; missing surfaces or unresolved failures keep the goal active.

## Implementation checkpoint (October 19, 22:28 PT)

Shared Tide surfaces, energy traces, day timelines and authenticated security-word cards are implemented. Mac menu/island/Quick Capture, Library, pairing and Devices & Sync have source changes. iPhone Record/Recording, Library day filtering, Search, Setup & Sync, pairing and detail tabs have source changes. Live Activities use local ActivityKit state and session-bound stop actions; durable-save seconds come from synchronized writer checkpoints.

Validation evidence:
- Full iOS Simulator build passed before the latest Search/playback presentation edits.
- All 11 focused iOS activity/capture presentation tests passed (`/private/tmp/harc-tide-ios-tests.log`).
- UI qualification attempt 1 stopped before tests due Bash 3 empty-array expansion; script repaired and now accepts `--derived-data-path` for SSD caches.
- Attempt 2 built/launched, then stalled in the simulator accessibility audit for over an hour. Cancelled as inconclusive; log `/private/tmp/harc-tide-ui-qualification-02.log`, evidence directory `/Volumes/MacMiniSDD/HarcBuilds/tide-ui-diagnostic-02-20261019`. This is not a passing qualification.
- Record screen visually inspected from isolated simulator profile (`/private/tmp/harc-tide-record-loaded.png`). Light appearance shows the capture blob, condition row, Today card and native tabs without clipping at default text size.
- All 14 imported reference artboards visually inspected in Chrome. Local reference preview server: port 8923, exec session 86953.
- The first Mac build was stopped before its embedded helper cache consumed the internal-disk safety margin. Only this worktree’s regenerable `.build-daemon` cache was moved to `/Volumes/MacMiniSDD/HarcBuilds/tide-daemon-20261019` and symlinked back. The resumed two-worker build uses log `/private/tmp/harc-tide-mac-build-02.log`, exec session 29592. Check this handle rather than starting a duplicate build. Source edits during compilation require incremental verification afterwards. Internal free space is about 6.5 GiB.

Remaining: finish Mac compilation; rerun focused iOS navigation with screenshots and bounded test timeouts; repair accessibility issues; inspect remaining artboards and native surfaces; complete playback/summary fidelity with real data; run durable writer regression tests; report physical-device gates separately. No screen is accepted solely on source changes. No production app installed or release published.

Additional implementation since that checkpoint: wide Mac Library detail now places summary/notes beside the transcript; playback has a larger actual-energy plot and accessible seeking; the menu idle view reads a Today timeline from the local store; Devices uses cards; iPhone Search has its own empty/result view, Library has a day map, and Detail adds actual downloaded-audio energy, seeking and Copy for Prompt with explicit clipboard export disclosure. Audio-envelope test added but not yet run. UI qualification now bounds individual tests to five minutes and checks SSD build headroom separately from the internal five-GiB floor. Omega (iPhone 15 Pro Max) is connected; no physical build installed yet.

Mac build update: attempt 2 compiled app/module sources and built `harc-stt`, then failed because the embed scripts assumed the old SwiftPM binary directory. The current toolchain reports `.build-daemon/out/Products/Release`. Both helper embed scripts now use `swift build --show-bin-path`. Attempt 3 is running, exec session 56529, log `/private/tmp/harc-tide-mac-build-03.log`; this supersedes session 29592. Required next: finish this build, regenerate project for the new audio-envelope test, and rerun iOS tests/build/UI checks.

## Verification update (October 20, morning)

- Mac full Xcode build attempt 3 passed (`/private/tmp/harc-tide-mac-build-03.log`), including embedded helpers. A separate ad-hoc diagnostic bundle (`com.harc.Harc.TideDiagnostic`) runs against `/private/tmp/harc-tide-mac-ui-fixture`; production remains untouched.
- Latest focused iOS tests passed: 12 capture, Live Activity and real-audio-envelope tests (`/private/tmp/harc-tide-ios-tests-02.log`).
- Simulator qualification attempt 3 completed with one failing accessibility audit: four Today-card contrast findings and six Dynamic Type findings. Record entry, offline review and Tide Search/Setup navigation passed; four tests were skipped. Evidence: `/Volumes/MacMiniSDD/HarcBuilds/tide-ui-diagnostic-03-20261020`. This is diagnostic evidence, not release qualification.
- User approved SimulatorTrampoline removable-volume access; the exact macOS permission was allowed. A separate Python local-network prompt was left untouched.
- Corrective changes use body-scaled condition/day-map text and full primary contrast. Mac summary metadata now wraps below its title/actions rather than squeezing the title in the narrow insight column. Attempt 4 verifies the iOS correction (`/private/tmp/harc-tide-ui-qualification-04.log`). Mac incremental build remains required after the header change.
- Native computer-use calls stalled for hours; the overnight target was missed. Use the repository-authorized shell UI inspection for Mac diagnostics. The goal remains active; physical-device capture, transfer, Live Activity and complete visual acceptance remain unqualified.

### Morning follow-up

- Simulator attempt 4 passed all four applicable tests, including the full Record/Review Sample/Privacy accessibility audit; four physical/screenshot-gated tests were skipped. Screenshots exported to `/private/tmp/harc-tide-ui-04-attachments`. This version used oversized body text; subsequent compact typography revisions require fresh qualification.
- Mac build attempt 4 passed. The diagnostic Library screenshot `/private/tmp/harc-tide-mac-library-04.png` confirms the summary header repair. Relaunch exposed a previously missed initialization path: a persisted selection may precede library rows, leaving the document/waveform empty. Detail task now initializes those when the recording becomes available; rebuild/relaunch verification remains pending.
- The isolated dummy WAV was replaced with valid 90-second diagnostic tone data. This is playback test data, not captured meeting audio. Fake capture start/live/stop exercised successfully; screenshot `/private/tmp/harc-tide-mac-live.png`. No actual microphone capture was claimed.
- Live Activity now uses the shared presence renderer. An explicit `animates: false` option supports static widget snapshots, preserving normal Reduce Motion behavior in apps. Attempt 5 exposed a read-only SwiftUI environment key and was fixed; attempt 6 compiled the shared widget successfully but still failed six small-text accessibility findings. Current source uses an identity-preserving adaptive condition layout and 14-point body-scaled small text; it is not yet requalified.
- Durable writer regression run is active in `/private/tmp/harc-tide-durable-writer-tests.log` using the SSD release cache with two workers. Verify its process handle before starting another compiler job.

### Current verification checkpoint

- Devices & Sync opened in the diagnostic app and standalone controls rendered without missing environment dependencies. Screenshot: `/private/tmp/harc-tide-devices.png`. The form was still using the legacy background; `HarcSettingsForm` now applies the shared Tide background specifically to Devices & Sync. That source change awaits the next Mac build.
- The durable-writer test process remains live (exec session 82730), progressing through dependency compilation. Do not launch another build until it completes; log `/private/tmp/harc-tide-durable-writer-tests.log`. Internal free space is approximately 7.8 GiB.
- The diagnostic status item exposes AXPress, but repeated attempts have not yielded a capturable menu panel. This is incomplete UI evidence, not a passing menu qualification. Production Harc has not been targeted.
- Next sequential steps: finish durable-writer test run; build Mac with the Library initialization and Settings background changes; relaunch diagnostic app to check transcript/title/envelope restoration and playback; rerun iOS qualification for the current 14-point scaled text and identity-preserving layout. Widget static presence compiled successfully in attempt 6; its physical Live Activity behavior remains unqualified.

### Durable-audio result

The package build completed successfully after 652 seconds. Its first command did not emit execution results, so it was treated as build-only evidence. An explicit `swift test --skip-build --enable-swift-testing --filter HarcMobileDurableMasterWriterTests` run then executed and passed all six durable master tests (finalization, checkpoint truncation, writer failure, storage exhaustion, empty recovery, immutable artifact publication). Execution log: `/private/tmp/harc-tide-durable-writer-run.log`.

Full Mac build attempt 5 now validates the restored-selection loading fix, Devices & Sync background and latest shared presentation components. Log: `/private/tmp/harc-tide-mac-build-05.log`. Reuse the existing process handle; do not start concurrent builds.

### Mac runtime verification after build 5

Full Xcode Mac build 5 passed. The refreshed diagnostic process is PID 18573 (launch session 36656), isolated bundle/profile unchanged. Relaunch now restores title and transcript (`/private/tmp/harc-tide-mac-restored-05.png`). Selecting the valid 90-second fixture loads its actual amplitude envelope and summary (`/private/tmp/harc-tide-mac-audio-05.png`); playback advanced to 0:02 with a moving playhead, then was paused (`/private/tmp/harc-tide-mac-playing-05.png`). Devices & Sync renders the Tide background without environment-object failures (`/private/tmp/harc-tide-devices-05.png`). This verifies standalone/fixture behavior, not real Host pairing or captured audio.

The helper scripts now canonicalize a symlinked build-cache path with `pwd -P` to avoid separate cache identities. Both pass `bash -n`.

Current iOS qualification: attempt 7, exec session 85113, log `/private/tmp/harc-tide-ui-qualification-07.log`, output `/Volumes/MacMiniSDD/HarcBuilds/tide-ui-diagnostic-07-20261020`. It is still building; do not start a duplicate or mark the compact typography accepted until results and screenshots are inspected.

### iOS attempt 7

Attempt 7 passed all four applicable simulator tests; four physical/screenshot-gated tests were skipped. The current compact 14-point body-scaled condition row and Today labels passed the accessibility audit. The retained Record screenshot confirms the horizontal condition row and unclipped idle layout: `/private/tmp/harc-tide-ui-07-attachments/7D99C9B5-7D6C-4675-A13D-567CDFDDFD9F.png`. Full result: `/Volumes/MacMiniSDD/HarcBuilds/tide-ui-diagnostic-07-20261020/HarcMobileUITests-attempt-1.xcresult`.

A debug-only `HARC_UI_TEST_OPEN_MENU=1` option opens the existing status popover after test-store bootstrap for direct rendering inspection. Mac build attempt 6 is active (exec 19695; `/private/tmp/harc-tide-mac-build-06.log`). Physical Omega microphone/Lock Screen testing is awaiting the user’s answer to the diagnostic-install and brief-audio-capture question. Do not install or record until that answer arrives.

### Physical diagnostic authorization and morning capture checks

- User explicitly approved a separate diagnostic installation on Omega and brief microphone/Live Activity testing. The signed device build succeeded (`/private/tmp/harc-tide-ios-physical-build.log`), with app identity `com.harc.HarcMobile.TideDiagnostic`, extension `com.harc.HarcMobile.TideDiagnostic.RecordingActivity`, and team `63TNU5M7P4`. The regenerated project sets the diagnostic display name to Harc Tide Test while preserving normal product defaults.
- The qualification script now accepts an explicitly diagnostic bundle suffix only with `--allow-dirty-diagnostic`; its source identity records the suffix. Two physical attempts installed the runner but failed before test execution: `Timed out while enabling automation mode`. Evidence directories: `/Volumes/MacMiniSDD/HarcBuilds/tide-physical-diagnostic-01-20261020` and `tide-physical-diagnostic-02-20261020`, both source manifest `293b54a0e1e374584b2b757bb3b6f83fc050a4cad04c91ed7cd0bfa6385d24a4`. These are infrastructure failures, not passing physical capture evidence. User has been asked to unlock Omega and acknowledge any automation prompt; do not retry until readiness changes.
- Added a physical background Live Activity stop test using Notification Center and the public Home-button API, with cleanup that returns to the app and stops capture on failure. Actual locked-device behavior is a separate manual gate; no public XCTest lock-button API exists in the installed SDK. This test has not executed yet.
- Mac menu rendering is confirmed after waiting for the panel to settle. Direct PID accessibility inspection avoids ambiguity between production and diagnostic apps. Screenshots `/private/tmp/harc-menu-settled.png` and `/private/tmp/harc-menu-recording.png` show idle and fake recording states without scrolling; fake start/stop works. A duplicated destination prefix was found on-screen and repaired. Mac build 7 (`/private/tmp/harc-tide-mac-build-07.log`) is in progress, including an opt-in Debug-only capture-surface launch flag for Quick Capture and Island inspection. Production behavior remains unchanged by that flag.
- The physical-attempt manifests precede the Mac-only destination text and capture-surface-hook edits. Do not treat those manifests as evidence for the later Mac source state. All runs remain diagnostic dirty-tree evidence.

### Executed physical checks and remaining audit discrepancy

- Mac build 7 passed (`/private/tmp/harc-tide-mac-build-07.log`). Refreshed diagnostic bundle PID 39926 uses the same isolated root. Quick Capture rendered at 560×278, accepted a diagnostic title, and started fake capture. Island compact (142×34) and expanded (413×52) states rendered; its Stop button saved the fake recording and hid the Island. Evidence: `/private/tmp/harc-quickcapture-moved.png`, `/private/tmp/harc-island-07.png`, `/private/tmp/harc-island-expanded-07.png`.
- After the user confirmed Omega unlocked and ready, physical attempt 3 executed: 7 passed, 1 failed, 1 skipped. Real microphone start/stop, force-quit durable recovery, bounded storage exhaustion recovery, and Notification Center Live Activity stop all passed. Source manifest: `13943fb86208c0e0d2e983a7334e61ff078c3ea8bd684edbe455bcdb99902d1f`. Physical screenshot shows 0:08 elapsed and 0:05 durably saved. This does not qualify actual passcode-locked interaction or Host delivery.
- The failure is five Record-screen contrast findings on iOS 26.6 (caption, microphone label and three day-axis labels). Simulator iOS 27 had passed. The failure video itself shows white text on the navy surface. Sampling core-text and local-background luminance from that video yields approximately 14.04:1 for caption, 13.10:1 for microphone label and 11.57:1 for the first axis label; this is supporting diagnostic evidence, not a blanket accessibility waiver. Video frame: `/private/tmp/harc-physical-audit-frame.png`.
- Physical attempt 4 tested an explicit foreground-color hypothesis. It produced the same five findings while physical capture/recovery/Live Activity tests passed again. The ineffective style experiment was reverted. Its manifest `2a7028048ba9fc4c8c7b764ac8e0551b7a0deeba1e91b21eacb696fe2bc6330f` therefore represents that experiment, not final source. Do not report the device audit as green.
- Physical screenshots revealed the inline Live Activity permission prompt despite a working stop action. User authorization covers that exact prompt. The physical test now handles the named Harc Tide Test prompt and waits for the activity's durable-save text before stop. A diagnostic-only test selector was added to the qualification wrapper, recorded in source identity and prohibited without dirty-diagnostic mode. Focused attempt 5 is running (`/private/tmp/harc-tide-physical-live-05.log`, evidence `/Volumes/MacMiniSDD/HarcBuilds/tide-physical-live-05-20261020`). It cannot qualify the entire suite.

- Focused physical Live Activity attempt 5 passed (26.352 seconds), manifest `357e30311a4632b0e87a3a6fa397f293840dfc99f340ea2ba80322ab1280ecda`. XCTest tapped the exact inline Allow button; the retained screenshot shows 0:16 elapsed and 0:10 audio saved, with no permission question. Stop then returned Saved locally. Screenshot: `/private/tmp/harc-tide-physical-live-05-attachments/29D11700-19E9-4C0A-950C-36FA610A1040.png`. A final focused run adds a Home-screen screenshot for compact Dynamic Island evidence (`/private/tmp/harc-tide-physical-live-06.log`).
- Direct PID accessibility control is necessary for same-name Mac processes: AppleScript may resolve a stored process reference back by the name Harc. The direct AX helper is PID-bound; it was used for diagnostic Quick Capture and Library positioning. A production window was repositioned during diagnosis, but no production data or configuration was edited. Subsequent interactions use the diagnostic PID or its freshly observed control coordinates.
- Current Library screenshot `/private/tmp/harc-library-current-07.png` shows restored seeded selection, the real diagnostic tone waveform, transcript/speaker labels, summary with a truthful stale-content warning, notes, and sidebar timelines. The fake capture loop intentionally uses its canned title; naming persistence is not qualified by that loop.

- Focused attempt 6 passed, manifest `b6026c45b4e9ca840db429614b4583b62ccfed90af4747fcdaf8e5660ba3da8c`, but its nominal Dynamic Island attachment still shows Harc's foreground recording view. Therefore the earlier test name is stronger than its evidence: Notification Center activity stop is confirmed; fully backgrounded capture and compact Island are not yet confirmed. Added an explicit `app.wait(for: .runningBackground, timeout: 10)` assertion immediately after Home. Focused attempt 7 is running in `/private/tmp/harc-tide-physical-live-07.log`. Keep this distinction in the user-facing result.

- Attempt 7 correctly failed the new background-state assertion: the Home-button event did not background the app in this XCTest session. The test now explicitly activates SpringBoard after Home and keeps the assertion. Focused attempt 8 passed with that strict assertion, durable-save text and stop outcome, manifest `07bacc3b2d94df945377445e4fba0426dc12054c46e9406fbacc117c18615d00`. Its screenshot genuinely shows the Home screen with the compact shared presence and 0:14 timer in Dynamic Island: `/private/tmp/harc-tide-physical-live-08-attachments/9A1227CE-22E1-4498-90DB-7F4FF95C1694.png`. This supersedes the earlier background-evidence gap. Actual passcode-locked interaction remains untested.
- No compiler/test process remains active after attempt 8. The separate Mac diagnostic Library remains open, with fake capture stopped. Device tests stop capture in cleanup. The full physical suite still has the five unresolved Record contrast findings; no waiver or green full-suite claim is justified. Remaining screen qualification includes paired-Host Library/detail/search, Devices/Pairing states, and the actual locked-phone gate. Goal remains active.
