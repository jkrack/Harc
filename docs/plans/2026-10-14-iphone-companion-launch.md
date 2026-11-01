# iPhone companion launch plan

## Current checkpoint — November 1, 2026

This checkpoint supersedes the dated status snapshots below. Source merges,
fixture checks and release qualification are separate evidence scopes.

The implementation baseline verified on main is `ccc6bad4388dfe20e608abac25213fe6a29f2eae`, tree
`6e7fab2b7d94316982143e2cb09af790a65e479b`. On October 31, corrected preparation
[#170](https://github.com/jkrack/Harc/pull/170) and the UI stack
#159 → #161 → #162 → #163 → #165 → #166 merged normally in dependency order.
The stack is no longer held as unmerged drafts. Integration
[#171](https://github.com/jkrack/Harc/pull/171) is closed unmerged as evidence;
its tested aggregate tree equals resulting main `ee4823f`. Source branches remain
preserved. Held [#155](https://github.com/jkrack/Harc/pull/155) remains unmerged at
`3c5c07b3b9078f660bc6fe1207b54bb46ab1b32a`; its diagnostic and artifacts are unchanged.

[#172](https://github.com/jkrack/Harc/pull/172) then added a test-only Library
cache regression: a valid update followed by a stale tombstone rolls back the
whole delta, retains records/cursor after reopen, and accepts a corrected retry.
All six focused cache tests passed. [Exact-head CI](https://github.com/jkrack/Harc/actions/runs/41234273680)
passed at `1304c343ae58778d19878b01300f248b19e67ac9`; hosted tested merge
`1dca5258987c994e328a72746186b33932aa2e8b` has that baseline tree.
[Post-merge CI](https://github.com/jkrack/Harc/actions/runs/41237916396) passed
smoke and relay. Heavy PR-only lanes were skipped on the push as designed.
This is cache transaction/reopen coverage, not a physical stale-cursor diagnosis,
whole-process termination drill or phone → Host → phone Library qualification.

The [aggregate UI/preparation CI](https://github.com/jkrack/Harc/actions/runs/41209018171)
and #172 CI each passed the selected mobile (89 tests) and macOS (86 tests)
execution gates. #170's original Library-navigation assertion failure is retained;
one unchanged-head mobile retry passed, without establishing the failure's cause.
Local integrated visual testing passed 16 component tests and the light
normal/largest-text Library summary/navigation case, then stopped at the disk
floor: the overall run was interrupted (17 passed, one canceled failure) and its
execution gate correctly failed. Fresh full dark/full-app acceptance and spoken
VoiceOver remain incomplete. Separate local Tide fidelity work is active on
November 1 and is not included in this recorded main; do not start competing
simulator jobs or count its unfinished results as acceptance.

Shared preparation configuration is 0.14.20 (75), but no sealed phone release
source/archive or qualified Mac release artifact is selected. Current main now
includes the UI stack; the October 30 maintenance branch's narrower scope must
not be mistaken for the current main's contents. Select and validate the eventual
exact source/artifact pair before distribution; matching version strings do not
transfer historical passes. The [active candidate register](../evidence/harcmobile-current-candidate-readiness.md)
retains the open gates. GitHub release metadata rechecked November 1 still lists
[v0.14.19 (74)](https://github.com/jkrack/Harc/releases/tag/v0.14.19) as latest.
Asset/feed byte verification remains scoped to the October 28 record, not this
metadata check. Accumulated source improvements warrant continued preparation,
but publication is blocked on applicable physical capture/Stop/recovery and final
signed/notarized/Sparkle artifact checks. Mac Host distribution remains direct
through Sparkle, not the Mac App Store.

The phone critical path remains sealed exact-source codec PCM/EOF qualification,
production transfer, durable verified receipt, complete canonical PCM hash and
protected-master retention, then the ordinary Library playback/transcript round
trip. The October 20 Host file-binding and stale phone Library failures remain
separate and unresolved. Leave the diagnostic app and pending OS dialog untouched
without the applicable authorization. App Store submission remains NO-GO;
archive, privacy/owner fields, screenshots, physical acceptance and explicit
submission approval are still open. Issue #105 remains separate absent a proved
phone dependency. Preserve the one-time cache backup; the October 31 cleanup is
not continuing deletion permission. Honor the 5 GiB internal disk floor and the
existing denial of external simulator device-set creation.

## Historical checkpoint — October 30, 2026

This checkpoint supersedes the dated status snapshots below; historical test
results remain scoped to their original source, artifact and device.

The preparation base is main `ec04ea8329afc02a40555581a3b52c52422c767a`.
It includes #164's plan reconciliation, [#167](https://github.com/jkrack/Harc/pull/167)'s
typed privacy checks, [#168](https://github.com/jkrack/Harc/pull/168)'s lost chunk
acknowledgment recovery and [#169](https://github.com/jkrack/Harc/pull/169)'s
receipt-recovery regression after persistence reopen. The separate
[0.14.20 (75) preparation refresh](../evidence/2026-10-30-mac-maintenance-refresh.md)
uses this main without rewriting held draft [#155](https://github.com/jkrack/Harc/pull/155)
at `3c5c07b3b9078f660bc6fe1207b54bb46ab1b32a`. Neither draft is release-qualified.

Published [0.14.19 (74)](https://github.com/jkrack/Harc/releases/tag/v0.14.19)
remains live. October 28 independent downloads passed GitHub digest/size checks,
ZIP-to-DMG byte matching, signatures, stapled-ticket and Gatekeeper verification;
the live feed's version/build, URL, length and Ed25519 signature matched the
published app's public key. This qualifies those published bytes, not installation,
an upgrade or physical capture. The release notes retain the owner-waived affected-Mac
audible-recording check. Evidence is linked in the preparation refresh record.

For held #155, October 26 development signing preserved hardened runtime and
entitlements and enabled diagnostic startup after the ad-hoc library-validation
failure. A microphone-only Start then visible Stop left Saving unresolved and no
persisted test audio at the last permitted lifecycle check. Owner idle/normal-quit
and diagnostic-signing approvals had arrived; the outstanding blocker is reporting
and resolving the pending OS dialog, not those older approvals. No dialog permission
is inferred. Mac capture, visible/hotkey Stop, durable playback, recovery and final
release-artifact gates remain open on the eventual selected candidate.

On unchanged main, the October 30 independent audits reported 57 passing receipt
fail-closed tests and 15 passing Library/cache fixtures, with no source change
warranted. Full-resync RPC was reviewed statically only; the physical stale-cache
cause is still unresolved. Preserve the independent October 20 Host file-binding
and phone Library-cursor failures. These fixture results do not close either
physical failure or qualify a newly versioned build.

The phone critical path remains sealed exact-source codec bit-exact PCM/EOF,
production transfer, durable verified receipt, complete canonical PCM hash match
and protected-master retention, followed by ordinary phone → Host → phone Library
playback/transcript acceptance. Use the [physical runbook](../operations/mobile-physical-qualification.md).
Named model pairs and three-hour endurance are optional coverage, not codec blockers.
The UI drafts #159/#161/#162/#163/#165/#166 remain separate and unaccepted as a full
physical/accessibility release surface; do not import them into this maintenance draft.
Mac-only maintenance gates are separate from phone launch gates. App Store remains
NO-GO: exact archive/export, privacy review, owner fields, screenshots, physical
acceptance and explicit submission approval remain open. Issue #105, secondary-Mac
qualification, Mac App Store and standalone phone inference remain deferred.

## Historical checkpoint — October 26, 2026

This checkpoint records the October 26 state and is superseded by the current checkpoint above.
Historical results remain scoped to their recorded source, artifact and device;
no old pass closes a current physical or submission gate.

Main is `02b3a22b2611499d65fbdea8557fe66031406ad9`. It includes
[#146](https://github.com/jkrack/Harc/pull/146), making Accessibility optional
for auto-paste and avoiding automatic permission prompts during finalization,
and [#160](https://github.com/jkrack/Harc/pull/160), removing fixed local compiler
caps while retaining CI budgets, disk safeguards and test serialization.
[#106](https://github.com/jkrack/Harc/pull/106)'s bounded-validation work is
merged and complete within its tested scope; do not reopen it solely because
older snapshots below describe a draft or failed run. Mobile configuration CI
is now present. Physical product acceptance remains distinct from these results.

The latest listed Mac release is
[v0.14.19 (74)](https://github.com/jkrack/Harc/releases/tag/v0.14.19).
This is repository/release metadata reconciliation, not fresh verification of
published asset bytes, the live feed, signatures or the installed upgrade path.
Draft [#155](https://github.com/jkrack/Harc/pull/155) prepares 0.14.20 (75) at
`3c5c07b3b9078f660bc6fe1207b54bb46ab1b32a`; its
[exact-head CI](https://github.com/jkrack/Harc/actions/runs/40214998656) passed.
The October 25 retained native diagnostic build receipt also passed metadata,
arm64 app/helper and ad-hoc signature checks, plus source/public-URL preflight:
`/Users/jlane/Documents/Codex/2026-10-25/task/harc-pr155-diagnostic-build-result.json`.
That local receipt is not a signed/notarized release artifact, physical capture
acceptance or phone qualification. The candidate remains draft and unqualified
for release; its [current gate register](https://github.com/jkrack/Harc/blob/3c5c07b3b9078f660bc6fe1207b54bb46ab1b32a/docs/evidence/harcmobile-current-candidate-readiness.md)
and [Mac preparation record](https://github.com/jkrack/Harc/blob/3c5c07b3b9078f660bc6fe1207b54bb46ab1b32a/docs/evidence/2026-10-24-mac-maintenance-preparation.md)
retain their own source-specific evidence and ownership.

The UI draft stack is separate from main and #155:

| Draft | Exact reviewed head | Automated evidence |
| --- | --- | --- |
| [#159](https://github.com/jkrack/Harc/pull/159) | `c044b9464815dc3b3d30b2cfa9d43877653790cb` | [CI passed](https://github.com/jkrack/Harc/actions/runs/40155990145) |
| [#161](https://github.com/jkrack/Harc/pull/161), based on #159 | `05d086149ba486c2e727a38aeaee280769a741f6` | [CI passed](https://github.com/jkrack/Harc/actions/runs/40213894471) |
| [#162](https://github.com/jkrack/Harc/pull/162), based on #161 | `2ca64686ee130878ae5abc84779c4a73de9d1fbc` | [CI passed](https://github.com/jkrack/Harc/actions/runs/40215659159) |
| [#163](https://github.com/jkrack/Harc/pull/163), based on #162 | `784e652bade24e874c9fec8ea14b629248c5e40b` | [CI passed](https://github.com/jkrack/Harc/actions/runs/40220604960) |

All four are unmerged. CI and focused visual checks do not establish full
accessibility acceptance: VoiceOver, broad accessibility-audit flags and affected
physical traversal remain open. Device Hub approval for the independent UI task
is pending; this plan reconciliation does not authorize or duplicate that work.

### Current phone critical path

1. Select and seal the exact candidate source/build on an available physical
   iPhone. Prove bit-exact canonical PCM encode/decode including exact EOF,
   production-path transfer, a durable verified Host receipt, a complete
   Host/phone canonical PCM hash match, and protected-master retention until
   receipt verification. Follow the [physical qualification runbook](../operations/mobile-physical-qualification.md).
2. On that qualified source and a known-good signed Mac Host, complete ordinary
   phone recording → Host receipt/processing → phone Library refresh, playback
   and transcript acceptance. Keep capture, delivery, processing and Library
   failures separate; pairing or a receipt alone is not the full round trip.
3. Complete applicable physical reliability, protection, upgrade and accessibility
   gates, then the exact archive/export, privacy/dependency review, owner fields,
   current screenshots and submission package in the
   [App Store runbook](../operations/app-store-release-readiness.md). **App Store
   remains NO-GO; submission requires owner approval.**

The [October 18 physical diagnostic](../evidence/2026-10-18-omega-alac-product-path-diagnostic.md)
was an engineering pass with an unsealed source/Debug override, not current
release qualification. The [October 20 reconciliation](../evidence/2026-10-20-omega-processing-and-library-diagnosis.md)
retains independent Host file-binding and stale phone Library cursor failures;
neither failure is explained away by the other or by subsequent CI. Reproduce
and close affected failures with exact-candidate evidence rather than deleting
or relabeling their records. Named phone-model pairs and three-hour endurance
runs are optional coverage, not codec-enablement blockers; Omega is eligible.

Mac-only maintenance capture/Stop/playback/recovery and signed-artifact gates
remain separate from companion-launch qualification. Owner idle/closed-app
confirmation is pending for the exclusive Mac test window. Issue #105,
secondary-Mac Client qualification, Mac App Store distribution and standalone
phone inference remain deferred from this critical path unless evidence proves
a dependency. This documentation task does not merge, build, capture, use
credentials, install, publish or waive any physical/security/submission gate.

## Historical checkpoint — October 19, 2026

The active delivery branch is `codex/omega-delivery`, based on main `3afdccf`.
Navigation, Setup/Sync, unified Library and recording motion (#130–133) are
merged. The 0.14.17 (72) candidate combines the physical ALAC EOF correction,
upload-capacity error mapping, and prepared-receipt recovery. Its normal mobile
configuration selects CAF/ALAC; no Debug launch override is required. Matching
Mac and phone builds and physical recording-to-Library acceptance are pending.

Omega is eligible. Named-device pairs and three-hour endurance runs are optional
coverage, not release blockers. Preserve bit-exact PCM, verified receipt, matching
Host/client hashes and protected-master retention requirements. App Store
submission is outside this delivery checkpoint and remains unqualified.

## Historical checkpoint — October 17, 2026

**Mac Sparkle: approved 0.14.15 (70) candidate. App Store: NO-GO.**
GitHub main at `c715538c34ba97de37cc1f955d9220ad0f5eb1ca` includes the
reviewed P-256 correction from PR #124. Its
[push CI 39037211911](https://github.com/jkrack/Harc/actions/runs/39037211911)
passed. The October 16 signature failures below are retained historical evidence;
they do not describe current main.

PR #125 merged into the stacked correction branch at
`e68ca972d546b2aba902705dfa08764567ecfdd9`. The release integrates that reviewed
mobile change with main. Both final apps embed built source
`5f16c7427f320b5de68daab33a3f59b9b80f7245` and identify 0.14.15 (70).
The shared fallback version is aligned with the marketing version. On this exact
source, local validation passed 1,616 Swift Testing tests, 124 XCTest tests with
four skips, 31 strict-executor tests, and the direct and local encrypted-relay
pinned-TLS pairing lifecycle. The native Swift 6.4 test-launcher issue and its
isolated main-thread runner workaround are preserved with unchanged test bodies
and object-file provenance in the SSD release evidence.

Apple accepted notarization `c8ae24ea-d526-4c2e-a6a1-d9dd9f6a42df`; stapling,
Gatekeeper, nested signatures and Sparkle verification passed. The final DMG is
66,948,477 bytes with SHA-256
`3bd23a1c256e3ed69e89c5113446752008f2c1190ea6fabc964c533030930804`.
James explicitly approved publishing this Mac update. The separate signed iOS
development archive remains private; neither app has been installed by this
release task. The superseded private candidate and all original failures remain
in `/Volumes/MacMiniSDD/HarcBuilds/release-0-14-15-evidence-20261017/`.

Named-device codec, durable physical phone-to-Host-to-Library acceptance,
real-model, accessibility, privacy and App Store gates remain open. This Mac
release does not enable a closed codec/upload gate, submit to the App Store,
change credentials or accept new agreements. Historical observations below are
superseded only for their dated source/build/CI status, not for unclosed physical
or submission requirements.

## Historical checkpoint — October 16, 2026

**Release eligibility: NO-GO for public Sparkle or App Store distribution.**
Reviewed main is `3f9f090ae4bd1266651ceb94f2a553f10d1de08a`; no open PRs were
found before this documentation follow-up. James merged
[#122](https://github.com/jkrack/Harc/pull/122) and
[#120](https://github.com/jkrack/Harc/pull/120). Combined-main
[CI 38901509843](https://github.com/jkrack/Harc/actions/runs/38901509843)
failed exactly two retained positive-signature assertions. Keep them active.
Mac app/helper and mobile checks in that run were skipped after package failure.
The [correction assessment](../evidence/2026-10-16-p256-main-blocker.md) records
why no supported production fix has been established in the current scope.

[PR #106](https://github.com/jkrack/Harc/pull/106)'s original package-executor
stall objective is satisfied within its tested scope: its exact-head CI passed;
current main's 31 strict-executor tests passed and its full test run terminated
with the two signature issues. This does not close physical recording reliability,
issue #105, real-model or release acceptance. The
[readiness evidence](../evidence/2026-10-16-readiness-and-private-builds.md)
separates these results and records exact sources, artifact hashes and unrun work.

Fresh private 0.14.14 (69) builds are retained on the external SSD. The Mac
Release app and both helpers built; Apple accepted notarization, stapling and
Gatekeeper verification passed. The iOS development app built for physical
`iphoneos` and passed signature/archive checks. These artifacts derive from
local commit `cbaba907c36f204a536b3d2c0956aa79a42b7afc`, whose only difference
from reviewed main is the version/build bump. They have not been installed or
published. The owner's private-install choice remains pending; leave it untouched.
Installed 0.14.13 (68) builds remain the baseline. Codec/upload gates remain closed.

| Objective / acceptance | Owner | Current status | Smallest next action |
| --- | --- | --- | --- |
| Bounded package execution / PR #106 | Codex | Passed in tested scope; current strict lane remains green | Preserve the bounded runner and strict lane; investigate a new stall only if observed. |
| Combined-main security validation | Codex + James | Blocked by two retained P-256 positive assertions | Arrange cross-OS validation or separately authorize Apple escalation/provider review; no report sent. |
| Discoverable Sync details / PR #122 | Codex | Merged; final branch CI passed 70 logical / 87 mobile case executions; current-main mobile job skipped | Retain branch evidence; run required combined-source checks after a supported security correction. Manual and physical checks remain open. |
| Private 0.14.14 (69) retry artifacts | James for pending choice; Codex for execution | Mac notarized/verified; iOS signed/verified; neither installed | Await the existing install choice and idle-app confirmation before an in-place test update. |
| Host Library diagnosis | Codex + James | No fresh typed physical result from the new Sync surface | After an authorized update, inspect Host Library operation/RPC status without recording; paused transfer copy alone does not identify a cause. |
| Physical codec and durable phone → Host → Library acceptance | Codex + James for hardware | Unqualified; gate closed | Qualify the selected codec and full product path on the recorded physical phone; Omega is eligible. |
| Privacy, accessibility and submission | Codex + James | Open; not release-ready | Complete owner fields, manual checks and exact-archive acceptance in the milestones below. |

No physical recording, gate bypass, credentials/trust/permission change, external
bug report, App Store action or public release occurred in this follow-up. Dirty
checkouts, recordings and unique diagnostic evidence were preserved. The dated
snapshot below is historical, including its draft-PR and continuation instructions;
use this checkpoint for current status. References in that snapshot to two named
codec-matrix phones are superseded by the physical qualification decision in the
current plan and runbook.

## Mac mini handoff snapshot — October 15, 2026 (Pacific)

**Done:** Both development apps were installed from
`0ce24fe5e94090ddcec26fd6c5d6f4c59796f60a`, version 0.14.13 (68). The Mac
candidate passed Apple notarization, stapling and Gatekeeper. Existing phone
pairing authenticated after launch; retained recording metadata was checked.
These are installation and connection results, not upload acceptance.

**In progress:** [Draft PR #122](https://github.com/jkrack/Harc/pull/122) is ready
for code review after automated validation. [CI run 38844699721](https://github.com/jkrack/Harc/actions/runs/38844699721)
passed at head `83848c152a9139e324fda9b5dc897deaeb2a5c2f`, including the Mac
app/helper checks and hosted mobile tests. The iPhone 17/iOS 26.5 simulator result
contains 70 logical tests / 87 case executions, all passed, including nine new
status tests and both selected UI tests; zero skips or runtime warnings. The
[Sync evidence record](../evidence/2026-10-16-mobile-sync-status.md) names exact
source/tree/artifact identities and package-test skips. This record's follow-up
changes documentation only. The UI has not been installed on a physical phone.

**Blocked:** New audio transfer remains behind the closed codec qualification
gate. Physical phone upload, durable Host receipt and the subsequent phone
Library round trip remain unqualified. Host Library reads are a separate path;
the user's report of “syncing is paused” does not establish a Library RPC cause.

**Next validation:** Review the scoped draft. Manual accessibility, a fresh
physical Host Library diagnosis and the qualified phone-to-Host acceptance gates
remain open. The Mac mini has no local simulator runtime; focused UI execution
was completed safely on the hosted simulator. No merge, physical installation or
release is authorized by this validation task.

| Objective / acceptance | Owner | Status | Next action |
| --- | --- | --- | --- |
| Current development baseline: both apps identified, signed Mac accepted, existing adoption retained | Codex | Done for installed `0ce24fe` candidate | Preserve the dated installation evidence below. |
| Discoverable Sync details: Library and Host entry points; accurate pending/Host/Library states; valid recovery actions; local playback/export retained | Codex | Draft PR #122; native tests, app/test compilation and hosted app/UI checks passed | Complete code review; manual accessibility and physical checks remain open. |
| Codec: physical bit-exact regression and one verified phone → Host receipt before enablement | Codex + James for hardware | Open; gate closed | Follow the revised physical qualification runbook on an available physical iPhone; no named marketing model is required. |
| Phone → Host → Library: verified durable receipt, matching audio identity, one canonical recording, retry/restart behavior | Codex + James | Unqualified; depends on qualified codec | Run sealed-source physical acceptance after codec decision. |
| Host Library diagnosis: actual operation/RPC result, distinct from transfer availability | Codex + James | User-visible failure not yet reproduced with a fresh typed result | Use the new status surface after it is validated; do not infer cause from paused copy. |
| Submission: exact archive, privacy/dependencies, screenshots and owner fields accepted | Codex + James | Open; not release-ready | Complete applicable gates in the milestones below. |
| Deferred Mac UI and issue #105 | Codex | Separate work; no demonstrated launch dependency | Keep separate unless evidence establishes a dependency. |

### Continue in native Codex on the Mac mini

- **Worktree:** `/tmp/harc-mobile-sync-status-20261016` (a local temporary path;
  retain it until the branch and handoff are safely published).
- **Branch:** `codex/mobile-sync-status`. Initial implementation:
  `ade0039c0bdb631438e33b41410e4ba01658f775`; first passing app/test-bundle build:
  `e017038b42acb4f9687f949630ee1a59f3c82fd4`. Read the current HEAD with
  `git rev-parse HEAD` before resuming.
- **Base:** main `16fe2e9bbeb79d4e432cb5bbf2eea2cdf6a5bf27`, the merge of
  [PR #121](https://github.com/jkrack/Harc/pull/121). Its tree matches the
  installed `0ce24fe` candidate. The
  [main CI run](https://github.com/jkrack/Harc/actions/runs/38797324831) passed;
  that older result does not validate this new UI commit.
- **Continuation:** James resumed this work through the connected Mac mini task.
  Reviewed code `280caf4c97d70bbbe4a68a5dd2b4767c1a0a5783` passed the
  app/test-bundle build; the branch is pushed and draft PR #122 is open.
  CI passed at head `83848c152a9139e324fda9b5dc897deaeb2a5c2f`; that run
  and its watcher have finished. No local app build/test is running. This
  evidence follow-up is
  documentation only; inspect current PR checks for subsequent runs. Leave
  Xcode-only Sparkle lockfile churn out of commits.
- **Local evidence:** `/tmp/harc-sync-evidence/mobile-sync-status-ios-build.log`
  and `.json`; focused tests in
  `/tmp/harc-sync-evidence/mobile-sync-status-reviewed-native.log` and `.json`.
  The reviewed full-SHA build is `mobile-sync-status-ios-reviewed.log`/`.json`;
  `mobile-sync-status-reviewed-manifest.json` verifies the app stamp, binary
  digest, both test bundles and absence of the qualification define. All are
  in that evidence directory; the build retained at least 7.83 GiB free.
  Hosted evidence is retained under
  `/tmp/harc-sync-evidence/ci-38844699721/`, including the verified result bundle,
  test tree and manifest. The earlier failed build used a short source stamp
  and remains diagnostic only. New builds must use the full actual source SHA.
- **Other checkout:** `/Users/jlane/Documents/GitHub/Harc` contains pre-existing
  unrelated changes; leave it untouched. Deferred Mac UI is separately at
  `/tmp/harc-library-activation-20261015`, commit `6ef08e8`.
- **Resume instruction:** Read this tracker, `AGENTS.md`, applicable `.agents`
  instructions and the Sync evidence record, then continue this exact worktree.
  Preserve the closed codec gate. Continue the existing draft PR #122; do not
  duplicate the branch or PR. Inspect `git status --short` and the current PR
  checks before resuming; the final tracker follow-up changes documentation only. Do not install,
  launch, record, refresh the physical phone, alter pairing/security/credentials,
  or publish a release under this handoff.

### Installed baseline evidence

The Mac mini is an Apple M4 Mac16,10 on macOS 26.6.2 (25G83). The connected
physical phone was an iPhone 15 Pro Max, iPhone16,2, on iOS 26.6 (23G71), wired,
paired and with Developer Mode enabled. It is an eligible physical qualification
phone and not a simulator. A later read-only source
query was blocked by the phone's locked/passcode state; no unlock was attempted.

Apple accepted notarization submission `c68b27a0-361c-42b6-921f-cabf3cbe7302`.
The installed stapled DMG has SHA-256
`281ac4880235c973140b3299511a8889041fcdc9750459c9984967cced070fe5`;
the iPhone development ZIP has SHA-256
`1ce1ed2d8d4ac4c7d0f1a79cbf931293c8067030560c9e88b61c99b8d8886ed7`.
The Mac packaging reused reviewed Debug binaries and existing Developer ID
credentials; it is not a production Release build. Earlier unnotarized/ad-hoc
candidates are superseded.

Local installation receipt:
`/tmp/harc-mac-ui-evidence-20261015/both-development-updates-installed-20261016.json`.
Notarization receipt:
`/tmp/harc-library-0ce24fe-mac-timestamped-development/notarization-20261016/notarized-candidate-receipt.json`.
Mac ordinary database counts, 221 audio-file metadata records and 24 phone
capture-artifact metadata records were retained across the update. No recording
contents or playback were used for that check. Pairing authentication does not
prove a new recording was uploaded or receipted.

The assessment below is the original October 14 review. This dated tracker
supersedes its historical CI/build-status observations; the normative spec and
unexecuted physical/release gates remain in force.

**Date:** 2026-10-14  
**Status:** Agreed launch scope; implementation and qualification remain in progress  
**Review baseline:** `main` at `7cb2d18772bb249d86a2de74ba4843711dca68c8`, Harc 0.14.13 (68)

## Launch decision

Launch HarcMobile on the iPhone App Store as an offline-capable companion to a
user-owned Mac Host. Keep Mac distribution on the existing signed, notarized
Sparkle path. Defer Mac App Store distribution and independent on-device iPhone
transcription, diarization, and summaries.

The phone must remain useful without a reachable Host: record durably, recover,
play local audio, and explicitly export it. The Mac Host owns canonical storage,
transcription, summaries, and the shared Library. Pairing or inference availability
must not become a prerequisite for local capture.

This is a launch plan, not a release-ready declaration. Preserve dated evidence
and keep unexecuted gates open. The normative
[implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)
continues to govern safety, security, and physical qualification. This plan narrows
the launch scope of the
[production reliability plan](2026-08-23-production-reliability.md); it does not
silently waive its applicable requirements.

## Historical assessment and evidence limits — October 14, 2026

The review covered the complete tracked file inventory, package/project
configuration, mobile application composition, capture and transfer paths,
mobile audio implementation, build/qualification scripts, app tests, representative
store/transport/receipt tests, architecture decisions, plans, recorded qualification,
release history, and draft [PR #106](https://github.com/jkrack/Harc/pull/106).

It was a source and recorded-evidence review, not a new test run, physical
qualification, or exhaustive security audit. Existing installed artifacts may use
external build overrides that are not represented in the checked-in configuration.
The latest committed mobile readiness record is dated August 23 and names
0.14.10 (65); the successful archive/export record names 0.14.1 (56). Neither
qualifies the current 0.14.13 candidate.

Later commits correct physical UI-test interaction and align tests with the active
Stop control. The last recorded automation-mode timeout is therefore a historical
test-service blocker, not proof that today's service is still broken. A fresh
physical run must establish its current state.

## Historical foundation inventory — October 14, 2026

These capabilities are implemented and have focused or historical validation:

- Native iPhone-only iOS 18 application with bounded microphone handoff, canonical
  PCM conversion, protected durable masters, checkpoints, recovery, route rebuilds,
  interruption accounting, and visible recording/Stop state.
- Local playback and foreground export with destination trust-boundary disclosure.
- QR adoption, device identity, signed grants, pinned TLS, authenticated direct/relay
  routing, and Host-health reporting.
- Persistent outbox, immutable background batches, task reconciliation, signed ACKs,
  lost-response recovery, and verified-receipt cleanup gates.
- Host Library snapshot/delta cache, search, detail, verified audio, signed metadata
  edits, conflicts, and shared speaker identity.
- Store upgrade/idempotence fixtures, protection/backup-exclusion tests, and durable
  writer/receipt regression coverage.
- Offline reviewer sample, privacy policy, monitored public support contact,
  submission copy, icon, screenshot tooling, and archive/distribution preflight.
- A historical clean iOS archive and Apple distribution export that passed signature,
  profile, entitlement, and installation checks.

Do not estimate these as new feature implementation. Their current composition and
physical behavior still require acceptance evidence. See the
[mobile readiness record](../evidence/2026-08-09-harcmobile-app-store-readiness.md),
[archive/export evidence](../evidence/2026-08-09-harcmobile-release-archive.md), and
[latest physical diagnostics](../evidence/2026-08-23-harcmobile-current-tree-physical-diagnostics.md).

## Historical gap assessment — October 14–15, 2026

The baseline/configuration and CI statements in this section are historical,
not current instructions. Use the October 26 checkpoint for active status;
preserve the unclosed safety and physical acceptance requirements.

### Production codec and new-recording transfer

`HarcMobileTransferCoordinator.transfer()` requires the selected codec to be
CAF/ALAC before encoding or opening a Host session. Selection is nil unless
`HARC_MOBILE_QUALIFIED_CAF_ALAC` is defined. No checked-in project setting,
shipping build script, qualification wrapper, workflow, or alternate tracked
Xcode configuration enables it at the review baseline.

The default build therefore preserves new recordings locally and reports paused
transfer. Pairing, local capture/playback/export, Host health, and reading an existing
authorized Host Library are separate paths. Packaging preflight alone cannot prove
capture-to-Host transfer works.

Qualify CAF/ALAC on the available physical iPhone using bit-exact decoding,
a production transfer, verified receipt, matching canonical hashes, and master
retention. The October 18 owner correction supersedes the former four-cell,
named-device and mandatory three-hour requirements. Optional endurance results
remain useful characterization; they do not block this delivery.

### Historical validation and physical acceptance

**2026-10-15 update:** PR #106 is merged. Combined main `c802dce6` passed
[CI 38738216824](https://github.com/jkrack/Harc/actions/runs/38738216824),
including mobile app tests. Subsequent bounded synthetic checks reproduced `.invalidSignature` in the
unchanged intermediate-CI test and captured a deterministic valid-signature
verification discrepancy. The baseline remains blocked by that unresolved
[finding and regression](../evidence/2026-10-15-p256-verification-qualification.md);
the passing combined run is not a fix. The paragraphs below retain the original
review snapshot.

PR #106 addresses package/STT/MCP executor starvation and bounded validation. At
review, its published head was `e29b4b72cdb514b808b4dbf6d2080d72da7fd2ab`;
[that exact CI run](https://github.com/jkrack/Harc/actions/runs/38499275839) failed.
Use the subsequently completed exact-head result rather than this snapshot when
selecting a candidate.

Neither the reviewed main workflow nor that PR workflow includes iOS build/mobile
app-test execution. Add focused mobile continuous validation after the baseline
is stable. Simulator and unit tests do not replace physical acceptance.

Open evidence includes physical capture/endurance, background/system-termination
transfer, delayed capabilities, Host restart and route/leaf rotation, cellular
transitions, revocation, manual accessibility, protection transitions, and installed
upgrade. Prior Omega diagnostics establish specific historical behavior; they do
not close the revised product-path qualification for new bytes.

### Packaging, privacy, and metadata

Refresh the exact version/build/source evidence before archive creation. The
preflight requires its candidate line to match `project.yml`; the reviewed
readiness record still names 0.14.10 while the project names 0.14.13.

Re-audit the final dependency graph, bundled privacy manifests and required API
reasons. Verify production relay logging/retention and prior-record closeout,
public policy/support reachability, and truthful in-app/metadata disclosures.
The Account Holder must confirm exact-build App Privacy and export answers.

Three screenshot sources are committed for 0.14.1 (56). Capture all five required
current-build images, including real active recording and a non-sensitive Host
Library fixture. Produce and verify the current clean archive/export, then retain
App Store upload/processing results. TestFlight is optional; App Store processing
and submission readiness remain required.

## Milestones and completion evidence

This original milestone breakdown retains the planning baseline. Milestone 1’s
“Finish PR #106” is complete; current-source selection and validation remain
required. Historical version/configuration gaps above must not be treated as
new implementation tasks. The October 26 critical path governs remaining work.

| Milestone | Work and dependencies | Evidence required to complete |
| --- | --- | --- |
| 1. Reliable current baseline | Finish PR #106; select clean source; run bounded package, macOS Host, and iOS build/test checks; refresh preparation drift. | Exact SHA/version/build, successful required CI and local app-target results, declared skips and real-model coverage limits. No bypassed failure. |
| 2. Qualified codec | Use an available physical iPhone; stabilize physical test execution; run the bit-exact codec regression and production-path transfer. | Exact sealed-source physical test result, matching decoded hash, one verified durable Host receipt with the local master retained until verification, reviewed codec decision, then tested production enablement. |
| 3. Safe phone → Host → Library round trip | Use milestone 2 codec and a known-good signed Mac Host. Record ordinarily, transfer, obtain receipt, process, and refresh the phone Library. | Matching source/Host PCM hashes, exactly one canonical recording, verified durable receipt, retained source until receipt, visible processing result, phone playback/transcript and separate failure states. |
| 4. Physical reliability | Execute applicable C/T/P/H, two-network/security, accessibility, protection and upgrade scenarios against sealed source. | Named device/OS/build identities, required repetitions, hashes/logs and pass/fail per scenario; no silent gaps, duplicate publication, trust bypass or premature final-copy deletion. |
| 5. Submission candidate | Create exact archive/export and screenshots; refresh privacy/dependencies/URLs/copy; resolve owner fields; upload only after applicable gates pass. | Passing archive/distribution and screenshot preflight, exact source/artifact identity, processing warnings resolved, owner-confirmed privacy/export/metadata, reviewable submission package. Submission requires confirmation. |

A fix reopens the candidate: reseal and repeat affected gates. Do not relabel older
results as current passes. Follow the
[physical qualification runbook](../operations/mobile-physical-qualification.md)
and [App Store release runbook](../operations/app-store-release-readiness.md).

The earlier repository plan named an oldest/current pair. That requirement is
superseded: no iPhone SE (2nd generation), iPhone 17, or other named marketing
model is required. Omega may supply the physical codec and product-path evidence.
Additional devices broaden confidence but do not block the selected codec.

## Work ownership and dependencies

Automatable work includes source fixes, focused regressions, bounded builds,
protocol/lifecycle checks, qualification report validation, provenance/preflight,
metadata consistency, public URL checks, and evidence organization.

Physical work includes phone availability, consent/indicators, recording/lock/
interruptions, Bluetooth route changes, thermal/endurance runs, actual iOS
background scheduling, reboot/first-unlock, two-network transitions, VoiceOver,
largest text, and installed upgrade. Automated device scenarios still need real
hardware and a functioning device test service.

Owner/account work includes hardware access, review contact, app record/name/SKU,
pricing/regions/agreements and other account fields, exact-build privacy/export
decisions, and App Store submission confirmation. Do not create credentials,
change security settings, or accept agreements without the required approval.

## Historical effort estimate — October 14, 2026

The following estimate is retained for provenance, not a current remaining-work
forecast. Re-estimate from the October 26 critical path after physical acceptance.

Plan for **15–30 focused person-days**, plus **5–10 days contingency** for failures
and repeat qualification: approximately 3–6 focused working weeks with 1–2 reserve
weeks. Confidence is medium-low until the first qualified physical round trip.

| Workstream | Person-days |
| --- | ---: |
| Current baseline, focused iOS validation, preparation consistency | 1–3 |
| Codec experiments, analysis, qualified enablement | 2–4 |
| Physical capture/transfer/Host/two-network acceptance | 5–9 |
| Accessibility, protection transitions, installed upgrade | 2–4 |
| Exact archive/export, screenshots, privacy/metadata, processing preparation | 2–4 |
| Integration hardening and ordinary affected-gate reruns | 3–6 |

The range assumes required phones, a working signed Mac Host, existing signing
access, and timely owner decisions. It excludes hardware acquisition, account
waiting, Apple review time, a major redesign, and independent mobile AI. If a
different production codec is needed, provisionally allow 3–8 additional days
for integration plus affected hardware reruns; revise after the experiment.
These are planning allowances, not measured completion percentages or promises.

Keep these separate from the phone critical path unless evidence links them:

- **Secondary-Mac Client qualification:** the phone requires a Mac Host, not a
  second Mac Client. Full PR9 qualification remains open for its own operating
  model. Preserve that gate without making it an automatic phone-launch dependency.
- **Mac recording-stop issue #105:** important ongoing reliability work, but its
  reported `RecordingSession.stop()` hang is not the phone's local finalization
  path. Host ingest issues a durable receipt before derived processing. Validate
  actual Host processing and promote #105 to a phone dependency only if evidence
  establishes the link.

Independent phone recording/playback/export is largely present. Independent
phone transcription/summaries remains deferred and needs a measured feasibility
decision. Mac App Store distribution remains deferred; its sandbox/helper/storage/
feature boundary needs separate engineering rather than reuse of a Sparkle DMG.

## Release authority

Worthwhile Mac changes may be merged and published through existing Sparkle
tooling when all applicable validation and release checks pass. Preserve
signing/notarization, exact artifact identity, version, feed signature, and
published asset verification. Never bypass a failing gate.

App Store submission still requires owner confirmation. Complete and present a
concrete validated submission candidate first. Existing release authority does
not authorize new credentials, security-setting changes, or agreements.
