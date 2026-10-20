# Tide diagnostic verification — October 20, 2026

These screenshots show the current-main integration, not a public release.
The Mac uses an isolated synthetic library and a generated 90-second tone.
The physical iPhone screenshots come from the separate Harc Tide Test app on
Omega. They show unpaired operation. Production apps and libraries were not
replaced, and no Sparkle update was published.

| Screenshot | What it verifies |
| --- | --- |
| [Mac Library](mac-library.png) | Restored selection, generated waveform, playback position, editable transcript, summary and notes layout |
| [Mac Devices & Sync](mac-devices-standalone.png) | Standalone pane rendering and local-storage explanation |
| [iPhone Record](iphone-record.png) | Physical dark appearance, readable host label, Today card and no empty idle accessory capsule |
| [iPhone Search](iphone-search.png) | Search remains usable after Setup dismissal; iOS 26.6 presents the selected Search tab as a search field |
| [iPhone Setup](iphone-setup-unpaired.png) | Unpaired Setup & Sync presentation |

## Validation

- 23 focused simulator tests passed, including playback ownership/reactivation,
  capture presentation, envelope and Live Activity checks. The result-tree
  verifier passed.
- The Mac app and test bundles build successfully. All 69 app tests in 19 suites
  passed, including pinned-TLS transfer and pairing-boundary checks.
- macOS UI automation timed out before executing UI cases in both the full run
  and a focused retry. Those runs are not passing UI qualification.
- Manual Mac checks verified Library and Settings rendering, actual generated
  tone playback and pause, transcript replacement/autosave, Undo and Redo, and
  persistence of undone text across relaunch. This exposed and verified a fix
  for Undo returning to the initially loaded text after another edit autosaved.
- Physical iPhone suite: 15 passed, 1 opt-in screenshot skip, 1 failed assertion
  about the Search tab button. The corrected case passed a fresh focused run,
  and its result-tree verifier passed. Real recording, force-quit recovery,
  storage-exhaustion recovery, background Live Activity stop, and accessibility
  passed in the full run.

## Remaining boundaries

- Actual passcode-locked Stop remains a manual physical check. Notification
  Center/background Stop is verified and is not the same test.
- Paired Host-backed Library/detail/results and both platforms' paired-device
  screens still need runtime verification. The outstanding canonical-Host
  pairing/transfer request has not been approved.
- iOS 26.0 retains the native accessory fallback; explicit visibility is used
  on iOS 26.1 and later and verified on Omega.
- These are dirty-tree diagnostic builds. Exact release source binding,
  notarization, publication and production installation are separate gates.

Detailed logs, xcresult paths, manifests and chronological evidence are in
[the implementation plan](../../../plans/2026-10-19-tide-mac-ios.md).
