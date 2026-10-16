# Mobile Sync status and recovery navigation

The phone's transfer qualification gate is closed by default. `HarcMobileTransferCoordinator.transfer` checks it before encoding or opening a Host session. The explicit qualification state previously displayed the same generic paused language used for other pending work. Retry does not enable this gate. The coordinator has no user Pause/Resume state.

Host Library metadata refresh and authenticated Host health checks are separate paths. A paused transfer label does not diagnose Library authorization, pairing repair, route availability, or an RPC failure. This change keeps those axes separate and does not change network, trust, encoding, upload, receipt, or qualification policy.

## Change

- Library has a tappable Sync status row, also linked from the existing Host tab.
- Sync details shows transfer availability, pending recording count, the adopted Host and its independently verified connection, plus Host Library status and fixed operation/RPC diagnostics when supplied by the coordinator.
- Qualification explains why new audio remains local and offers local playback/export navigation. It never offers Retry as a fix. Existing local-row retry actions are also hidden while qualification is closed.
- Pairing/security stops lead to Host settings; qualified, connected recoverable work may offer Retry. No Pause/Resume toggle is invented.
- A successful Library refresh time is shown only from the coordinator's current ready state and actual completed timestamp. Host contact, cached rows, queue emptiness and a transfer receipt without a time do not manufacture a last-sync date.
- Local recording, playback and explicit export access remain available without a paired or reachable Host.

## Validation

- Focused Foundation projection: nine XCTest methods passed natively, including gate/Host-state combinations, security and authorization, offline/retry, pending-count transitions and successful-refresh evidence.
- Added selected hosted app tests and a UI navigation/accessibility regression for the Library and Host entry points, a readable status label, a 44-point hit region and local access without a Host or microphone use.
- Local unsigned iOS build-for-testing ended with exit 65: `HarcMobileSyncDetailView.swift:58` uses the string-title `Section` form with a footer closure; this requires an explicit header closure. App/test-bundle compilation has not passed. This diagnostic run used a short source stamp, so it is not sealed build provenance. See the launch plan's current handoff section for the full code SHA and local log paths.
- Exact-head hosted results and runtime UI validation remain pending. No new draft PR has been created or branch pushed at handoff.
- No new device installation, Library refresh, recording, playback, permission/credential change, pairing reset, publication or gate enablement is part of this work. Simulator checks do not qualify physical accessibility, codec endurance or phone-to-Host durable sync.
