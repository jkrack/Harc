# HarcMobile current-candidate readiness

**Updated:** 2026-10-15
**Candidate configuration:** HarcMobile 0.14.13 (68), iOS 26+, iPhone only
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

### Combined baseline and development update, 2026-10-15

- Merged main is `0ef6054cfcc099eda1e70c053eee687f71456ff5` from
  [PR #114](https://github.com/jkrack/Harc/pull/114). Its tree
  `a58f78b4fd53d1d8680bf26b7080149e35c3bdd0` equals reviewed head
  `0c97d9ab15521b3790c1ea16ecb70be6e914bee5`. The PR CI merge commit
  `ca0a5c343cf9ed32172876beafdc2db273ac628d` has that same tree.
- [Merged-main CI 38656169200](https://github.com/jkrack/Harc/actions/runs/38656169200)
  completed successfully: package/protocol validation, macOS app and embedded
  helpers, then the sequential mobile configuration job. The
  [PR mobile job](https://github.com/jkrack/Harc/actions/runs/38620539335/job/116077257021)
  retained explicit results for all 28 selected tests: 15 configuration,
  four local Library, eight playback-session ownership, and one Library UI
  test; zero failures and zero skips. The destination was an arm64 **iPhone 17
  Simulator, iOS 26.5 (23F77)**. Both previously failing local Library transfer
  fixtures passed after validator-backed synthetic adoption; all eight
  ownership tests executed and passed. These are simulator software results.
- Local build-only validation at reviewed head passed generic iOS
  `build-for-testing` and the macOS app build including both embedded helpers.
  A temporary source copy and compiler-environment overrides enforced two
  workers and aligned nested helper toolchains. The scoped bootstrap and
  transport-trust regression executed 42 tests in four suites successfully.
  This is development-build evidence, not final archive/distribution evidence.
- The signed development artifact is HarcMobile **0.14.13 (68)**,
  `com.harc.HarcMobile`, embedded source
  `0c97d9ab15521b3790c1ea16ecb70be6e914bee5`, Apple Development team
  `63TNU5M7P4`. ZIP SHA-256:
  `b3f660e4c42b35203fb420902f204a1f9faf67197c13396723effa5ad0bd9c6f`.
  The existing development profile expires 2027-08-05 and permits debugger
  attachment; it is not an App Store distribution profile. The extracted
  artifact passed strict signature verification before installation.
- With James's explicit approval, that artifact updated **Omega, iPhone 15 Pro
  Max (`iPhone16,2`), iOS 26.6 (23G71)** from 0.14.10 (65) to 0.14.13 (68).
  Metadata-only listings before/after retained all 33 capture-directory files,
  including 15 WAV masters and 15 capture sidecars, with unchanged sizes,
  modification times, ownership and permissions. No missing/new capture files
  appeared. Harc was not launched, and audio contents were not read or played.
  First-launch migration, UI visibility, playback, export, recording, and the
  rest of installed-upgrade acceptance remain unrun.
- Local supporting receipts are under `/tmp/harc-final-macos-validation/`,
  `/tmp/harc-final-development/`, `/tmp/harc-ci-38620539335-mobile/`, and
  `/tmp/harc-omega-update/`. These temporary paths are supporting engineering
  records, not durable release qualification bundles. Retain/redact and seal
  the required evidence before declaring a release candidate.

### Preparation audit, 2026-10-15

- The signed development artifact above contains five `PrivacyInfo.xcprivacy`
  files: the app, GRDB, SwiftProtobuf, NIOSSL and NIOPosix bundles. All five
  declare no tracking and empty collected-data lists. The app manifest equals
  source and declares exactly FileTimestamp/C617.1 and UserDefaults/CA92.1;
  NIOPosix separately declares FileTimestamp/0A2A.1. The packaged privacy-policy
  URL, relay origin and `ITSAppUsesNonExemptEncryption = false` match source.
  This is a packaged-declaration audit at `0c97d9a`, not a complete runtime API
  audit, deployed-retention read-back or an Account Holder privacy/export answer.
- The earlier artifact-check exception hardcoded Sparkle 2.9.6, while
  `project.yml` declares `from: 2.9.4`. That requirement permits stable versions
  below 3.0.0. Xcode's 2.10.0 resolution at
  `eef1a539a373c1f1a320624b1130fc5de7b2e100` matches the upstream 2.10.0 tag;
  the committed SwiftPM lockfile still intentionally excludes Sparkle.
  The preflight correction derives the allowed range from the checked-in
  declaration and admits exactly one official-source, versioned Sparkle pin
  whose revision matches the exact official version tag, plus generated
  `originHash` churn. Annotated tags use their peeled commit. A noninteractive
  lookup to the fixed official source is bounded to 15 seconds; absent or
  ambiguous tags, malformed responses, mismatched revisions and resolver
  failure all reject the exception. Other pins, revisions, URLs, schema and
  lockfile fields must remain unchanged. Unknown requirement forms fail closed.
  No dependency requirement or committed pin changes in this correction.
- Focused regressions exercise accepted current/historical resolutions and
  rejection of other dependency drift, invalid/duplicate Sparkle pins,
  out-of-range versions, unknown project requirements and malformed metadata,
  plus controlled official tag mappings, well-formed SHA mismatches, annotated
  tags, absent/ambiguous tags and resolver failure.
  They run with the current-candidate identification regressions in CI.
- Source/public-URL preflight passed after a bounded recheck: privacy and support
  URLs both returned HTTP 200 and the published support contact matched source.
  An initial support request returned HTTP 503 and failed the gate; that failure
  was retained rather than waived. Retain the full final preflight exit status
  and output with this correction's commit. No archive, distribution export or
  screenshot bundle
  was supplied to this audit, so those artifact checks remain open.

### Earlier source-scoped history

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
- An earlier inventory from another Mac listed only simulators. The later Mac
  mini inventory and approved Omega update above are separate observations;
  neither inventory establishes physical qualification.

Before sealing a combined candidate, merge/review its prerequisite changes and
rerun applicable checks on that exact clean, pushed source. Preserve manifests,
logs, result bundles, hardware/OS identity, and artifact digests together.

## Current-candidate gates

| Gate | Current status | Required closure |
| --- | --- | --- |
| Candidate version/build identification | Identified only | Match source 0.14.13 (68); choose a clean pushed source commit before artifact qualification. |
| Repository input preflight | Source inputs and public URLs passed during preparation | `xcodegen generate` and source/public-URL preflight passed in the isolated readiness checkout. Repeat on the clean committed candidate and retain its exit status. This does not close the gates below. |
| Packaged iPhone configuration/privacy assertions | Combined-source simulator CI pass | All 15 configuration tests passed with the 28 selected mobile tests above. Repeat on the sealed release artifact and retain its packaged manifest. |
| Package, Mac app, embedded helpers | Combined main CI pass | Main `0ef6054` passed both CI jobs; local macOS/helper validation also passed at its identical reviewed tree. Repeat affected gates after source changes and retain exact release-artifact identity. Keep Mac distribution on Sparkle. |
| Physical codec matrix | UNRUN for this candidate | Execute all specified real-time cells on both named qualification roles; Pro/simulator results do not substitute for them. Keep production codec activation fail-closed. |
| C/T/P/H capture and transfer matrix | UNRUN for this candidate | Perform the specified repetitions, durable-prefix/receipt/recovery checks, and actual phone-to-Mac-to-Library round trip. |
| Physical UI/accessibility/protection/upgrade | Update installation and file-metadata preservation observed only | First launch, migrations, UI/playback/export, VoiceOver/largest text, lock/reboot, interruption, storage and remaining upgrade acceptance are UNRUN. Execute the full physical cases with provenance. |
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

## Configuration-test CI coverage

The hosted lane now executes 28 selected mobile tests, including the 15 configuration tests:
use an explicit available iPhone destination, two build workers, one test
simulator, exact-source `HARC_BUILD_SHA`, a timeout, and retained `.xcresult`/logs.
Schedule that lane after the Mac validation job (`needs: build`) so heavy jobs do
not overlap. It can cover packaging/manifest regressions but cannot qualify
physical microphone, codec, network, privacy-owner, archive, or submission gates.

The checked-in workflow selects an available iPhone runtime deterministically,
bounds execution, retains result bundles and runs after the Mac job. Keep the
local simulator UDID out of CI configuration. Simulator success does not close
physical or submission gates.
