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
| [Mac Quick Capture](mac-quick-capture.png) | Unobstructed merged title input, microphone selection, system-audio toggle and Start control |
| [Mac recording menu](mac-menu-recording.png) / [saved menu](mac-menu-saved.png) | Fake capture, Stop and save, immediate Today count, and no unrelated recovery warning after cache isolation |
| [iPhone Record](iphone-record.png) | Physical dark appearance, readable host label, Today card and no empty idle accessory capsule |
| [iPhone Search](iphone-search.png) | Search remains usable after Setup dismissal; iOS 26.6 presents the selected Search tab as a search field |
| [iPhone Setup](iphone-setup-unpaired.png) | Unpaired Setup & Sync presentation |

## Validation

- 23 focused simulator tests passed, including playback ownership/reactivation,
  capture presentation, envelope and Live Activity checks. The result-tree
  verifier passed.
- Six recording-destination tests passed after isolating the DEBUG UI-test cache.
  Mac test builds 06 and 07 succeeded. Fresh-root manual checks confirmed that
  unrelated recovery entries are absent and Today updates within one second of
  fake capture stopping, rather than waiting for the 30-second refresh.
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
| `mac/X2-TideMenuBar` | Merged Mac builds 06/07: fake recording, trace, timer, Stop and save, and immediate post-stop count inspected |
| `tide/LiveActivity` | Merged physical iPhone: background activity and Stop passed; actual passcode-locked interaction remains |
| `tide/i1-Record` | Merged physical iPhone: rendering and accessibility passed |
| `tide/i2-Recording` | Merged physical iPhone: real capture, durable-save presentation, stop and recovery passed |
| `tide/i3-Library` | Merged unpaired navigation passed; populated Host Library remains |
| `tide/i4-Detail` | Playback logic tests passed; populated Host detail visual/interaction inspection remains |
| `tide/i5-Setup` | Merged physical unpaired Setup inspected; paired state remains |
| `tide/i6-Pair` | Pairing boundary tests passed; real pairing presentation remains |
| `tide/i7-Search` | Merged physical Search/Setup navigation passed; populated Host results remain |
| `tide/m2-MenuIdle` | Merged idle menu inspected; diagnostic cache isolation repaired and fresh-root readiness, singular count and saved state verified |
| `tide/m4-Devices` | Merged standalone Devices & Sync inspected; paired state remains |
| `tide/m5-Pair` | Pairing boundary tests passed; real pairing presentation remains |
| `tide/m6-Floating` | Merged diagnostic: unobstructed Quick Capture inspected and starts fake recording; compact/expanded Island inspected; Stop hides it and writes synthetic fixture artifacts |

Detailed logs, xcresult paths, manifests and chronological evidence are in
[the implementation plan](../../../plans/2026-10-19-tide-mac-ios.md).
