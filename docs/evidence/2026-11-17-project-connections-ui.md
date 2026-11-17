# Project Connections UI qualification (PR211)

Scope: separate stacked graph branch, not release candidate 0.14.23 (79).

## Verified

- App and UI-test targets build-for-testing passed on Mac mini with ad-hoc
  diagnostic signing and an isolated diagnostic bundle identifier.
- Manual Computer Use of the compiled app in fresh synthetic scratch Libraries:
  - Host fixture exposes Connections; standalone fixture does not.
  - Dark and light sheet layouts rendered legibly without clipped controls.
  - Yes reports one changed relationship and honest batch-complete wording.
  - Undo restores the review card.
  - Open recording dismisses the sheet, clears an intentionally nonmatching
    Library search and selects the canonical fixture source with waveform visible.
  - Escape and Done dismiss the sheet; reopening works.
- Accessibility tree exposes descriptive recording/project-specific action names.
- Previous focused checks at 498cc34 passed: 13 presentation tests and 18 Store
  test functions, including Host binding, lease revocation and deferred pagination.

## Isolation

The DEBUG-only fixture requires UI-test mode and a scratch root normalized to
`/tmp/harc-app-ui-*`. It owns a real Store Host writer lease with a synthetic
identity in that scratch database. It does not create keys, start network
listeners, use the owner's production Library or alter the release candidate.
The fixture lease is disabled on termination. Manual diagnostic apps were quit
when verification finished.

## Not qualified

Local XCTest did not execute test methods: its runner failed with
`Timed out while enabling automation mode`. No permissions or security settings
were changed to work around this. Added dark/light/source/Undo/dismissal and
non-Host-entry tests must execute successfully in CI; build success is not a
UI-test pass. CI's execution verifier requires all three new test selectors.

Manual AX inspection is not a VoiceOver usability pass. Full keyboard traversal,
actual VoiceOver output, production network Host startup, Client/phone RPC,
physical-device behavior and suggestion generation remain unqualified. The
source navigation check uses one synthetic recording, not a large real Library.
