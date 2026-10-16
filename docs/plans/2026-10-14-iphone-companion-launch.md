# iPhone companion launch plan

## Current tracker and Mac mini handoff — October 15, 2026 (Pacific)

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
| Codec: all four named-device three-hour cells pass frozen thresholds before enablement | Codex + James for hardware | Open; gate closed | Follow the physical qualification runbook; no bypass or threshold change. |
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
paired and with Developer Mode enabled. It is supplementary Pro-device evidence,
not either named codec-matrix phone and not a simulator. A later read-only source
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

## Assessment and evidence limits

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

## Existing foundation

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

## Verified gaps

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

Complete the four physical three-hour codec cells and review their results before
enabling the production condition. The earlier ALAC run was bit-exact but failed
the frozen thermal threshold. Current production encoding, negotiation, and Host
decoding use CAF/ALAC; FLAC is a qualification candidate, not a drop-in production
choice. If ALAC fails, review additional integration scope rather than bypassing
the gate or loosening thresholds without a reviewed specification change.

### Current validation and physical acceptance

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

Open evidence includes named-device capture/endurance, background/system-termination
transfer, delayed capabilities, Host restart and route/leaf rotation, cellular
transitions, revocation, manual accessibility, protection transitions, and installed
upgrade. Prior Omega diagnostics establish specific historical behavior; they do
not close the full matrix for new bytes.

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

| Milestone | Work and dependencies | Evidence required to complete |
| --- | --- | --- |
| 1. Reliable current baseline | Finish PR #106; select clean source; run bounded package, macOS Host, and iOS build/test checks; refresh preparation drift. | Exact SHA/version/build, successful required CI and local app-target results, declared skips and real-model coverage limits. No bypassed failure. |
| 2. Qualified codec | Obtain both named phones; stabilize physical test execution; run short functional checks and all codec cells. | Four fresh-process sealed-source reports, independent matrix validation, frozen integrity/performance/thermal thresholds, reviewed codec decision, then tested production enablement. |
| 3. Safe phone → Host → Library round trip | Use milestone 2 codec and a known-good signed Mac Host. Record ordinarily, transfer, obtain receipt, process, and refresh the phone Library. | Matching source/Host PCM hashes, exactly one canonical recording, verified durable receipt, retained source until receipt, visible processing result, phone playback/transcript and separate failure states. |
| 4. Physical reliability | Execute applicable C/T/P/H, two-network/security, accessibility, protection and upgrade scenarios against sealed source. | Named device/OS/build identities, required repetitions, hashes/logs and pass/fail per scenario; no silent gaps, duplicate publication, trust bypass or premature final-copy deletion. |
| 5. Submission candidate | Create exact archive/export and screenshots; refresh privacy/dependencies/URLs/copy; resolve owner fields; upload only after applicable gates pass. | Passing archive/distribution and screenshot preflight, exact source/artifact identity, processing warnings resolved, owner-confirmed privacy/export/metadata, reviewable submission package. Submission requires confirmation. |

A fix reopens the candidate: reseal and repeat affected gates. Do not relabel older
results as current passes. Follow the
[physical qualification runbook](../operations/mobile-physical-qualification.md)
and [App Store release runbook](../operations/app-store-release-readiness.md).

The repository currently names an iPhone XR/iOS 18 and a current non-Pro iPhone 17
on current iOS. Omega is supplementary Pro-device evidence. Codec cells alone
require 12 device-hours; repeated C1 and C2 add 24 device-hours, before other
scenarios and reruns. Some runs can overlap on two phones. A changed launch floor
or matrix requires an explicit specification decision.

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

## Effort and scope control

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
