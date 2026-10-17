# Readiness and private build evidence — October 16, 2026

## Decision and source identity

**Public Sparkle and App Store release: NO-GO.** Main remains
`3f9f090ae4bd1266651ceb94f2a553f10d1de08a` (tree
`d3c8252650a9de44eab48196e91daf21b1463466`). The owner merged
[#122](https://github.com/jkrack/Harc/pull/122) and
[#120](https://github.com/jkrack/Harc/pull/120); no open PRs were found before
this documentation follow-up. No defensible production crypto correction was
validated. The two failing security assertions remain active. This follow-up
updates evidence only, using an isolated SSD worktree; it changes no source,
CI dependency, qualification policy or release feed.

The private candidate is **0.14.14 (69)** at local, unpublished commit
`cbaba907c36f204a536b3d2c0956aa79a42b7afc`, directly based on reviewed main.
Its only committed difference is the two version/build lines in `project.yml`.
Tracked source hashes and the clean checkout were verified after both builds.
Xcode-only Sparkle resolver churn was excluded; Sparkle resolved to 2.10.0 at
`eef1a539a373c1f1a320624b1130fc5de7b2e100`, checked against its official tag.
Other committed dependency pins were preserved.

## Reliability and CI results

[PR #106](https://github.com/jkrack/Harc/pull/106) merged as
`1c632f040ff9114bfca95741a393f1fc2fdb4194`. Its objective was to stop blocking
socket/media work from starving Swift's cooperative executor, bound package
execution, and clean up owned process groups. Its
[exact-head CI 38530460123](https://github.com/jkrack/Harc/actions/runs/38530460123)
passed at `60c3e2c44415428c47d9d7fef3d3e3e970a48091`, including runner lifecycle,
strict executor regression, package tests, Mac app and embedded helper checks.

[Current-main CI 38901509843](https://github.com/jkrack/Harc/actions/runs/38901509843)
checked out exact reviewed main. Schema, bounded-runner lifecycle, release-input
preflight, package compilation and all 31 strict-executor tests passed. The full
Swift Testing run terminated in 14.024 seconds with 1,613 tests / 270 suites
and exactly two retained positive-vector issues: `capturedLowSSignatureInteroperability`
and `capturedTransportSignatureInteroperability`. XCTest reported 124 cases,
four declared skips, zero failures. Mac app/helper and external-construction
checks were skipped after package failure; the dependent mobile job was skipped.
The [P-256 assessment](2026-10-16-p256-main-blocker.md) retains the failure evidence.

Thus #106's original executor/runner objective is satisfied in the tested scope;
current main is still red for a different demonstrated reason. Neither result
qualifies real-model execution, physical recording stop/recovery, issue #105,
codec enablement or durable physical transfer acceptance.

The final merged #122 branch had
[successful CI 38851028283](https://github.com/jkrack/Harc/actions/runs/38851028283)
at head `fca700bb5a0fc4ad938de4b4c46c42ce48b57cff`; the actual synthetic checkout
was `01959cd1187062fb693abc5a888a608e554105b5`, with the same tree
`e5191659d53c35f3539c2042fa70908f91f950f9`. Mobile execution passed 70 logical
tests / 87 case executions, including all nine new Sync status tests and both
selected UI tests, with zero failures/skips/runtime warnings. This was an arm64
**iPhone 17 simulator**, iOS 26.5 (23F77), Xcode 26.6 (17F113), not a physical
phone and not validation of combined main. The
[Sync evidence record](2026-10-16-mobile-sync-status.md) retains artifact identities.
Existing `scripts/test-mobile-configuration.sh` already selects these tests;
`.github/workflows/ci.yml` correctly retains `needs: build`.

## Private artifact receipts

Artifacts and receipts are local on `/Volumes/MacMiniSDD/HarcBuilds/refresh-20261016/`.
These are retained test deliverables, not published downloads.

| Artifact beneath `artifacts/` | Bytes | SHA-256 |
| --- | ---: | --- |
| `mac/Harc-Mac-0.14.14-69-Notarized-Test.dmg` | 66,289,769 | `fbc0de2b368b8bc311d31a0fbc00622b36262a39673ce10c067bebee5e6a8882` |
| `ios/Harc-iOS-0.14.14-69-Test.zip` | 17,991,263 | `9b029e6ed0229c2b4449d1ec47f23b11769db8fcab02b414dfa194cf242f4459` |

The Mac Release app and both Release helpers built through the unchanged release
script. All 13 nested Mach-O architecture/signature checks passed, including
secure timestamps and hardened runtime; installed designated requirement and
entitlements were preserved. With explicit owner authorization, Apple accepted
submission `476c301d-c736-49dd-91d4-1fe20b495fd4`. Stapling and the standard
repository release verifier passed, including Gatekeeper for the DMG and app.
The table hashes the final stapled bytes; the Apple-uploaded pre-staple SHA-256
was `4e6aa4de51cdaaec7b996203b25f1caa7199dee64be7a203ab0043d08a0a74b2`.

Build environment: Xcode 27.0 (27A266a), macOS 26.6.2 (25G83), arm64 M4 Mac mini.
Two workers were enforced. The default SwiftPM helper dependency scanner failed;
an external build environment selected the available native SwiftPM backend for
helpers, which passed. No repository build scripts or signing settings changed.
Earlier failed attempts remain diagnostic evidence, not passing qualification.

The iOS **Debug / Apple Development** app built for physical `iphoneos`, arm64.
Strict signature checks, ZIP CRC and extracted app signature passed. Embedded
version/build/source matched; the development profile bytes matched the prior
baseline artifact. This is not a simulator, App Store archive or TestFlight build.
Neither app was installed, launched or recorded from these artifacts; no fresh
runtime/UI or physical transfer acceptance was executed. The qualification define
remains absent and the codec/upload gate remains closed.

Local evidence is under `evidence/`: `mac-artifact-receipt.json`,
`ios-artifact-receipt.json`, `source-build-manifest.json`,
`post-build-source-verification.json`, `mac-pre-notary-signature-audit.json`,
`mac-final-verification.log`, `apple-notarization-log.json`, and the successful
`mac-release-native-env` / `ios-development` logs and receipts. The
`artifacts/artifact-index.json` records pending installation and publication state.
Both artifact hashes were recomputed against these receipts for this follow-up.

## Device, storage and remaining actions

The last read-only physical readiness check identified **Omega, iPhone 15 Pro Max
(iPhone16,2), iOS 26.6**, wired, paired, connected tunnel, Developer Mode enabled.
This is supplementary Pro hardware, distinct from the hosted simulator and from
the named iPhone XR / non-Pro iPhone 17 codec matrix. Readiness is not evidence of
an installed new build or successful Host Library operation. Installed apps remain
0.14.13 (68), source `0ce24fe5e94090ddcec26fd6c5d6f4c59796f60a`.

Owned rebuildable caches were copied and inventory-verified on the external APFS
2 TB SSD before removing their old copies and preserving original paths as
symlinks. Source, recordings, frozen fixture inputs and unique evidence were
retained. Internal free space recovered from roughly 2.7 to 8.5 GiB; build guards
retained at least 6 GiB. Cache migration receipts are under `HarcBuilds/` on that
SSD. No further cleanup was needed for this documentation work.

- **James:** the existing private-install choice and idle-app confirmation remain
  pending and untouched. No installation is inferred from notarization approval.
- **Codex + James, after an authorized update:** inspect the typed Host Library
  operation/RPC result through Sync details without recording. Transfer-paused
  copy alone does not establish a Library-read failure or its cause.
- **Codex + James:** separately arrange unchanged-vector cross-OS validation or
  authorize Apple escalation/security-reviewed provider scope. No Apple report,
  credential/security change or new dependency has been made.
- **Codex + James for hardware:** complete all four named-device three-hour codec
  cells, then sealed-source durable phone → Host → Library acceptance. No capture
  was started and no thresholds or gate were bypassed in this follow-up.
- **James + Codex:** finish manual VoiceOver/large-text, privacy/retention/owner
  disclosures, exact archive and submission acceptance in the
  [launch plan](../plans/2026-10-14-iphone-companion-launch.md). Accounts, agreements,
  App Store actions and public release remain unperformed.

Documentation validation: relative Markdown links, exact source/receipt hashes,
changed-file scope and `git diff --check`. No new compilation or test execution
is claimed for this documentation-only follow-up; the dated results above retain
their original source and environment limits.
