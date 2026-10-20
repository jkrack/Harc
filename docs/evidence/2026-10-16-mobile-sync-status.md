# Mobile Sync status and recovery navigation

The phone's transfer qualification gate is closed by default. `HarcMobileTransferCoordinator.transfer` checks it before encoding or opening a Host session. The explicit qualification state previously displayed the same generic paused language used for other pending work. Retry does not enable this gate. The coordinator has no user Pause/Resume state.

Host Library metadata refresh and authenticated Host health checks are separate paths. A paused transfer label does not diagnose Library authorization, pairing repair, route availability, or an RPC failure. This change keeps those axes separate and does not change network, trust, encoding, upload, receipt, or qualification policy.

## Change

- Library has a tappable Sync status row, also linked from the existing Host tab.
- Sync details shows transfer availability, pending recording count, the adopted Host and its independently verified connection, plus Host Library status and fixed operation/RPC diagnostics when supplied by the coordinator.
- Qualification explains why new audio remains local and offers local playback/export navigation. It never offers Retry as a fix. Existing local-row retry actions are also hidden while qualification is closed.
- Pairing/security stops lead to Host settings; qualified, connected recoverable work may offer Retry. No Pause/Resume toggle is invented.
- The Library metadata update time is shown only from the coordinator's current successfully refreshed ready state. It is labeled as a metadata update, because the cache timestamp is not a refresh-completion time. Host contact, cached rows, queue emptiness and a transfer receipt without a time do not manufacture a last-sync date.
- Local recording, playback and explicit export access remain available without a paired or reachable Host.

## Validation

- Focused Foundation projection: nine XCTest methods passed natively after review (source SHA-256 `5ea4fa5cd36a6427fae27b3a07ebc1524ca8d1a2cc0e4b060843c07f5b537206`), including gate/Host-state combinations, security and authorization, offline/retry, pending-count transitions and successful-refresh evidence.
- Added selected hosted app tests and a UI navigation/accessibility regression for the Library and Host entry points, a readable status label, a 44-point hit region and local access without a Host or microphone use.
- Local unsigned generic-iOS build-for-testing passed at reviewed code `280caf4c97d70bbbe4a68a5dd2b4767c1a0a5783`, including the app and both test bundles. The app contains that full source stamp, and the qualification define is absent. Two workers were used; minimum free disk was 7.83 GiB. The original invalid SwiftUI Section initializer was corrected; the earlier short-stamp failed run remains diagnostic only.
- [Draft PR #122](https://github.com/jkrack/Harc/pull/122) remains open on `codex/mobile-sync-status`. [CI run 38844699721](https://github.com/jkrack/Harc/actions/runs/38844699721) passed for PR head `83848c152a9139e324fda9b5dc897deaeb2a5c2f`: package, strict I/O, protocol boundary, Mac app/helper and hosted mobile checks. The evidence follow-up changes documentation only.
- No new device installation, Library refresh, recording, playback, permission/credential change, pairing reset, publication or gate enablement is part of this work. Simulator checks do not qualify physical accessibility, codec endurance or phone-to-Host durable sync.

## Hosted validation — October 15, 2026, Pacific

- PR head: `83848c152a9139e324fda9b5dc897deaeb2a5c2f`. CI checked out synthetic merge `742420ed3d158ed62710af6de80d94e7bee2af65`, with the same tree `3b3356b41a661b689a0a28098fc42d7100556df9`. The destination manifest records a clean source tree; the mobile build uses the full checkout SHA.
- [Mac/package job](https://github.com/jkrack/Harc/actions/runs/38844699721/job/116792452633): passed. Swift Testing reports 1,611 tests in 270 suites, with nine declared real-model skips and one opt-in pinned-TLS lifecycle skip. XCTest reports 124 tests, four real-model skips and zero failures. The strict I/O run reports 31 tests in six suites, zero failures. Mac app and embedded helper checks passed.
- [Mobile job](https://github.com/jkrack/Harc/actions/runs/38844699721/job/116807963016): passed on Xcode 26.6 (17F113), arm64 iPhone 17 **simulator**, iOS 26.5 (23F77). The result bundle reports 70 logical tests and 87 case executions passed, zero failures, skips, expected failures or runtime warnings.
- The nine `HarcMobileSyncStatusPresentationTests` passed inside the actual iOS app test module. Both selected UI tests passed: existing offline local Library access, and `testSyncDetailsAreDiscoverableWithoutHostOrRecording` (46.293 seconds). The new test opens Sync from Library and Host, checks its accessible status label and at least 44-point tap region, opens local recordings, and confirms no qualification Retry action. This is functional simulator evidence, not a complete manual accessibility audit.
- Mobile artifact ID: `12025520910`, verified ZIP SHA-256 `07b1168136654c2abf953de04fa749894315c31112b39a50b23d47d5d43d36dd`. Package diagnostic artifact ID: `12023024273`, verified ZIP SHA-256 `73163e7ec7b81263e445f0fac2785a1314bcc3f4307cdc37d8196c3d592de1b2`.
- Local result bundle, extracted test tree, focused results and verified summary: `/tmp/harc-sync-evidence/ci-38844699721/`. Full Mac/mobile job logs and native/build receipts are alongside that directory. UTC date 2026-10-16 in filenames corresponds to October 15 Pacific.

Remaining gaps: manual VoiceOver/large-text and physical behavior of this new screen; a fresh typed result for the user's actual Host Library issue; named-device codec qualification; physical phone upload/durable receipt/Library acceptance; applicable real-model and opt-in security lifecycle checks; release/privacy/submission gates. No physical draft installation, merge or release was performed, and the production upload qualification gate remains closed.
