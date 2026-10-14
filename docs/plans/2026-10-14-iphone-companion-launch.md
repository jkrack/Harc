# iPhone companion launch plan

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
