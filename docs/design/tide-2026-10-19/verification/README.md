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
| [Mac compact Island](mac-island-compact.png) / [expanded Island](mac-island-expanded.png) | Merged diagnostic fake capture, advancing timer and expanded Stop/Discard controls |
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

## Coverage of all 14 imported artboards

Implementation is integrated at `e7a016f` on `codex/tide-current-main`.
“Earlier checkpoint” below means the pre-integration Tide build; it does not
establish runtime qualification of the merged app. Tests of unpaired navigation
do not establish rendering of populated Host results.

| Imported artboard | Runtime evidence and remaining check |
| --- | --- |
| `mac/X1-TideLibrary` | Merged Mac: Library, editing/Undo persistence, generated waveform and playback inspected |
| `mac/X2-TideMenuBar` | Earlier checkpoint: fake recording, trace, timer, stop and post-stop inspected; merged capture-surface smoke remains |
| `tide/LiveActivity` | Merged physical iPhone: background activity and Stop passed; actual passcode-locked interaction remains |
| `tide/i1-Record` | Merged physical iPhone: rendering and accessibility passed |
| `tide/i2-Recording` | Merged physical iPhone: real capture, durable-save presentation, stop and recovery passed |
| `tide/i3-Library` | Merged unpaired navigation passed; populated Host Library remains |
| `tide/i4-Detail` | Playback logic tests passed; populated Host detail visual/interaction inspection remains |
| `tide/i5-Setup` | Merged physical unpaired Setup inspected; paired state remains |
| `tide/i6-Pair` | Pairing boundary tests passed; real pairing presentation remains |
| `tide/i7-Search` | Merged physical Search/Setup navigation passed; populated Host results remain |
| `tide/m2-MenuIdle` | Earlier checkpoint: idle/post-stop inspected; merged capture-surface smoke remains |
| `tide/m4-Devices` | Merged standalone Devices & Sync inspected; paired state remains |
| `tide/m5-Pair` | Pairing boundary tests passed; real pairing presentation remains |
| `tide/m6-Floating` | Merged diagnostic: Quick Capture starts fake recording; compact/expanded Island inspected; Stop hides it and writes synthetic fixture artifacts. Quick Capture screenshot is obscured by the XCTest authorization dialog, so unobstructed visual inspection remains |

Detailed logs, xcresult paths, manifests and chronological evidence are in
[the implementation plan](../../../plans/2026-10-19-tide-mac-ios.md).
