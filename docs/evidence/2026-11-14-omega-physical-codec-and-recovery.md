# November 14 Omega physical codec and recovery diagnostic

**Disposition:** 31 selected tests passed on a physical iPhone from a clean,
source-identified diagnostic build. This renews physical encoder evidence and
fixture regression coverage. It does not qualify a shipping phone artifact,
ordinary microphone capture, production Host delivery, or App Store submission.

## Exact scope and identity

- Source: main `3e7cef72a512b7a9ded6ec8e66190bf66306c2ad`, after
  [PR #197](https://github.com/jkrack/Harc/pull/197) merged. Its Git tree is
  `0425ff1f763de1f10f8fe4c4f55323a4e20b412d`, identical to tested PR head
  `1ed4a7742b00b3bb1fe5331bc42619b07cd8fd75`.
- [Exact-head CI 43609597330](https://github.com/jkrack/Harc/actions/runs/43609597330)
  reports success for build/package, macOS, mobile-configuration, relay, and
  mobile-diagnostics. Smoke is the configured skip. This is a metadata check of
  that retained run, not a fresh full-suite execution on the phone.
- Phone: Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6 (`23G71`), arm64.
  The xcresult independently identifies the physical iOS destination.
- Build host: Mac mini, macOS 26.6.2, Xcode 27.0 (`27A266a`).
- Diagnostic: `com.harc.HarcMobile.TideDiagnostic`, display name
  **Harc Codec Diagnostic**, version 0.14.21 (76), Debug, development team
  `63TNU5M7P4`. The sealed Info.plist embeds the full source SHA above.
- Existing development profiles were used. No provisioning updates, new
  credentials, security changes, pairing, agreements, or submissions occurred.
- The ordinary `com.harc.HarcMobile` installation remained 0.14.20 (75).
  Its application data and adopted Host were not used or replaced. The separate
  diagnostic app remains installed. The pending Mac 0.14.22 candidate and its
  release worktree were not modified.

The final app passed deep, strict signature verification before and after test
execution. Its complete file inventory, executable digest, and CDHash were
identical across that execution:

| Identity | Value |
| --- | --- |
| Executable SHA-256 | `d723cf99611d9dcf55f279a5b456e1074d21f1b8b52cb1442ba4e038cf5d08d2` |
| CDHash | `03007db0d94041dbcab1cfa9e39cdb43bb776274` |
| App file-inventory SHA-256 | `70e886f181a7c901e2ae41e0e9d3928c4239533d3a8d08301f97c5bd9287c811` |
| Repository source-inventory SHA-256 | `87e4aea007a23b175053bd5040a3dbfb6508acc15191220a110bc5fe770899a9` |

Xcode added only its expected Sparkle 2.10.1 pin at
`ab7d71291238df6e0492143b120c9b696a35f603` and origin-hash churn. The repository
validator verified the declared version range and official tag revision, with
all other pins unchanged. This generated difference was retained in the local
evidence, then excluded from source. The original source snapshot matched after
all tests with no added, removed, or changed files and a clean working tree.
The snapshot itself continues to say **unqualified**.

## Final physical execution

Build and test execution used separate bounded stages, the same six selected
classes, destination, configuration, and products, and tool-selected local build
concurrency. The final `test-without-building` completed successfully at
2026-11-14 17:34 UTC. The sealed summary records **31 passed, zero failed, zero
skipped, and zero expected failures**. `check-xcode-test-results.py` passed with
all 31 named methods explicitly required, not just a nonempty bundle.

| Selected class | Passed | Evidence scope |
| --- | ---: | --- |
| HarcMobileALACPhysicalRegressionTests | 3 | Real iOS encoder/decoder, exact PCM byte count and SHA-256, restart reuse |
| HarcMobileCapturePipelineTests | 4 | Injected route-format and checkpoint/writer-failure handling; no microphone |
| HarcMobileFinalizationRecoveryTests | 4 | Disposable master/outbox fixtures, reopen recovery, registration and deactivation failures |
| HarcMobileLocalLibraryTests | 4 | Disposable local playback visibility, failed/offline/security-blocked sync, missing-master behavior |
| HarcMobilePlaybackSessionTests | 9 | Injected playback ownership, capture precedence and stale completion handling |
| HarcMobileUploadPreparationTests | 7 | Codec selection, frozen retry authority, queue isolation, failure classification and master retention |

The physical ALAC cases cover 20,000 canonical frames, a packet-aligned 204,800
frames, and one full 960,000-frame chunk. Each asserts one artifact, exact
canonical decoded length and frame count, matching SHA-256, and identical
artifacts on a repeated encoding call. These inputs are synthetic PCM, not an
ordinary microphone recording.

Two preliminary runs passed four and 28 tests respectively. An intervening
incremental build re-signed the app, so those runs are retained separately and
are not combined as one artifact's acceptance. The final 31-test run above
repeats all distinct cases on one before/after-verified app. There were no test
failures hidden by this consolidation.

## Preparation checks and retained evidence

Repository App Store preflight passed, including privacy declarations, required
API reasons, entitlements, current version/build, metadata, icon, and the public
privacy/support URL checks. Both public URLs returned HTTP 200; the published
support page contained the configured contact and matching mailto target.
These checks do not audit deployed relay retention or supply owner privacy and
export decisions.

All 61 focused tooling tests passed: 18 mobile privacy/target/stage-budget
regressions, 16 Xcode package-resolution regressions, eight current-candidate
checks, and 19 Xcode execution-gate tests. Internal storage remained above the
5 GiB operational floor, with compiler caches and results on the external SSD.
No user files or caches were deleted.

Local evidence is retained at:

`/Volumes/MacMiniSDD/HarcBuilds/phone-qualification-20261114/evidence/`

It contains the build/execution logs, source snapshot and post-test check,
physical destination identity, final before/after app file inventories, result
summary and test tree, required selectors, execution gate, dependency validation,
and preflight/tooling logs. The sealed final result archive is
`final-physical.xcresult.zip`, SHA-256:

`8aedfa094104542081555011ac8f76bf8357510914505ba47f20adda8396e87f`

No application database, audio recording, keychain material, or identifier-bearing
raw device report is committed or uploaded with this documentation.

## Remaining launch gates

The checked-in CAF/ALAC selection was tested unchanged. No codec qualification
requirement was disabled or redefined. Before calling a phone release qualified,
select its exact signed source/artifact pair and prove an ordinary recording
through the adopted Mac Host: verified durable receipt, complete matching phone
and canonical Host PCM hashes, protected-master retention until verification,
and the phone Library's playback/transcript result. These tests did not contact
a production Host or exercise that round trip.

Physical Data Protection and first-unlock transitions, actual microphone/route
interruptions, process termination, background transfer, two-network/revocation,
required repeated capture/transfer scenarios, spoken VoiceOver, installed upgrade,
current screenshots, archive/export, and owner metadata/privacy/export decisions
remain separate. App Store submission remains **NO-GO** and requires explicit
owner confirmation after the applicable gates pass. Mac Host distribution remains
Sparkle. Issue #105 and secondary-Mac qualification remain separate unless a
specific phone dependency is demonstrated.
