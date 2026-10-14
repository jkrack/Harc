# HarcMobile current-candidate readiness

**Updated:** 2026-10-14
**Candidate configuration:** HarcMobile 0.14.13 (68), iOS 18+, iPhone only
**Decision:** NO-GO for App Store submission; candidate identification is not qualification.
**Sealed release source:** Not selected. Archive identity, executable digest, CDHash,
provisioning profile, and exact-build qualification manifests are unrecorded.

This is the active candidate and gap register. Update its configuration when
source version/build changes, then attach evidence scoped to the exact pushed
candidate commit. A matching version line lets repository preflight identify
what is being prepared; it does not transfer old passes or close external gates.

The [historical readiness record](2026-08-09-harcmobile-app-store-readiness.md)
retains its 0.14.10 (65), 0.14.3, and sealed 0.14.1 observations. Those observations
remain useful history and must not be relabeled as 0.14.13 qualification.

## Source-scoped observations

- Privacy correction [PR #108](https://github.com/jkrack/Harc/pull/108), commit
  `35b272dabeb8f9a23005a3d83eefcfb5a15f263b`: all 15
  `HarcMobileConfigurationTests` passed on an iPhone 17 Pro / iOS 26.5 Simulator
  using Xcode 27 and two workers. The packaged manifest contains exactly
  FileTimestamp/C617.1 and app-local UserDefaults/CA92.1. Shell syntax, plist
  lint, and the positive plus four malformed-manifest preflight fixtures passed.
  Local evidence: `/tmp/harc-pr108-configuration.xcresult` and
  `/tmp/harc-pr108-configuration.log`. This is simulator software evidence for
  that source, not a physical run or distribution-artifact qualification.
- The source preflight at that commit reported one open item: its candidate
  comparison still pointed to the historical 0.14.10 record. The active record
  corrects candidate identification while leaving the historical file unchanged.
- Validation [PR #106](https://github.com/jkrack/Harc/pull/106) is a separate
  source branch. Its package/protocol/app/helper results apply to its recorded
  commit and CI run, not automatically to a future combined release candidate.
- The read-only Mac device inventory on 2026-10-14 listed only simulators.
  No current physical-iPhone qualification was executed in this refresh.

Before sealing a combined candidate, merge/review its prerequisite changes and
rerun applicable checks on that exact clean, pushed source. Preserve manifests,
logs, result bundles, hardware/OS identity, and artifact digests together.

## Current-candidate gates

| Gate | Current status | Required closure |
| --- | --- | --- |
| Candidate version/build identification | Identified only | Match source 0.14.13 (68); choose a clean pushed source commit before artifact qualification. |
| Repository input preflight | Diagnostic source-input pass during preparation | `xcodegen generate` and source preflight passed in the isolated preparation worktree. Repeat on the clean committed candidate and retain its exit status. This does not close the gates below. |
| Packaged iPhone configuration/privacy assertions | Diagnostic pass at `35b272d` only | Repeat on the sealed combined candidate; retain exact-source result bundle and packaged manifest. |
| Package, Mac app, embedded helpers | Separate-branch evidence | Complete PR #106 gates, then validate the exact combined candidate. Keep Mac distribution on Sparkle. |
| Physical codec matrix | UNRUN for this candidate | Execute all specified real-time cells on both named qualification roles; Pro/simulator results do not substitute for them. Keep production codec activation fail-closed. |
| C/T/P/H capture and transfer matrix | UNRUN for this candidate | Perform the specified repetitions, durable-prefix/receipt/recovery checks, and actual phone-to-Mac-to-Library round trip. |
| Physical UI/accessibility/protection/upgrade | UNRUN for this candidate | Execute physical UI cases, VoiceOver/largest text, lock/reboot, interruption, storage, and installed-upgrade checks with provenance. |
| Physical two-network/direct-route/revocation | UNRUN for this candidate | Verify authenticated direct/relay lifecycle and visible revocation on actual devices/networks. |
| Deployed privacy and prior-record expiry | Not refreshed | Re-read deployed no-retention state and close expiry/export concerns; August observations remain historical. |
| Exact-build App Privacy and export answers | OPEN, Account Holder | Complete the existing privacy assessment and App Store Connect declarations for the exact candidate; a required-reason manifest pass is insufficient. |
| Signed archive and distribution export | UNRUN for this candidate | Build a clean sealed archive/export; verify source SHA, signatures, entitlements, profile scope, architecture, and artifact digests. No new signing credentials were configured here. |
| Exact-build screenshots/reviewer path | UNRUN for this candidate | Produce all five truthful native screenshots and verify the offline reviewer path on the exact artifact. |
| Agreements, commerce, review/account metadata | OPEN, Account Holder | Complete owner-only choices and agreements; do not infer them from repository metadata. |
| Upload, processing, App Store review/manual release | UNRUN; not authorized by this record | Submit only after all applicable gates and explicit submission authorization. TestFlight remains optional. |

The [release runbook](../operations/app-store-release-readiness.md),
[physical qualification runbook](../operations/mobile-physical-qualification.md),
and [App Privacy assessment](../app-store/harcmobile-app-privacy-assessment.md)
remain authoritative for execution details. Existing historical evidence stays
bound to its original version, source, hardware, and artifact.

## Configuration-test CI assessment

The 15 hosted configuration tests are suitable for a bounded iOS Simulator lane:
use an explicit available iPhone destination, two build workers, one test
simulator, exact-source `HARC_BUILD_SHA`, a timeout, and retained `.xcresult`/logs.
Schedule that lane after the Mac validation job (`needs: build`) so heavy jobs do
not overlap. It can cover packaging/manifest regressions but cannot qualify
physical microphone, codec, network, privacy-owner, archive, or submission gates.

No CI lane is added by this evidence correction. A follow-up should first select
an available runtime deterministically on the hosted Xcode image and measure a
cold two-worker build before choosing its deadline. Do not name a developer's
local simulator UDID in CI or make simulator success a submission-ready signal.
