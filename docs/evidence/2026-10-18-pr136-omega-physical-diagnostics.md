# PR #136 Omega physical diagnostics — October 18, 2026

## Decision and source identity

This is **supplementary diagnostic evidence**, not release qualification and
not an App Store GO decision.

The physical runs used reviewed head
`d3d67a3d70b4d56cf2607db294603ec802d4e39b`. PR
[#136](https://github.com/jkrack/Harc/pull/136) merged that head as
`3afdccf7d69278288fd9f574c61b133fdf4a600d`; both commits have tree
`6880fde1b8d2c9b34f2a1942fc42baf375270b04`. The qualification wrapper's
source-file manifest SHA-256 was
`c196f2ae13fb086096fd5ee68f049ab4c5f0cc0eb59a64bcbad3b28f7398995f`.

The change lets the physical HarcMobile UI qualification wrapper place a new,
isolated DerivedData directory on an explicitly selected volume. It requires
an absolute non-existing path with at least 8 GiB free and records the path in
the qualification receipt. Canonical recordings, databases and user data are
not moved.

Exact-head [CI run 39177518324](https://github.com/jkrack/Harc/actions/runs/39177518324)
passed package/protocol/relay validation, the macOS app build and UI regression,
embedded helper checks, and the bounded iOS Simulator configuration lane. The
post-merge main run is a separate result and was still in progress when this
record was authored.

The repository script regression suite was also rerun from the merge tree:
127 tests passed with zero failures in 21.69 seconds. The process-lifecycle
cases require ordinary process inspection; a restricted sandbox run was
discarded rather than represented as a source failure.

## Environment

- Mac: Apple silicon Mac mini, Xcode 27.0 (`27A266a`)
- build storage: `/Volumes/MacMiniSDD`, with approximately 1.8 TiB free
- phone: Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6 (`23G71`)
- connection: wired, paired, booted, Developer Mode enabled
- Developer Disk Image: Xcode build `27A266a`, compatible and usable
- app configuration: development-signed HarcMobile 0.14.16 (71)

Omega is supplementary Pro hardware. It does not replace either named launch
role: iPhone SE (2nd generation) on iOS 26 or the current non-Pro iPhone 17 on
current iOS.

## Physical app-test execution

The first whole-bundle diagnostic produced no per-case starts before it was
bounded and stopped. The same exact binary was then executed in small,
observable class groups. Every HarcMobile app test passed on Omega:

| Result bundle | Scope | Passed | Failed | Skipped |
| --- | --- | ---: | ---: | ---: |
| `HarcMobileConfigAndLibrary.xcresult` | configuration and local Library | 19 | 0 | 0 |
| `HarcMobileRecoveryAndUpload.xcresult` | finalization recovery and upload preparation | 10 | 0 | 0 |
| `HarcMobileRemainingXCTest.xcresult` | remaining XCTest classes | 53 | 0 | 0 |
| `HarcMobileLibraryRefreshSwiftTesting.xcresult` | Library refresh Swift Testing suite | 12 | 0 | 0 |
| **Unique total** | **all HarcMobile app tests** | **94** | **0** | **0** |

An additional one-test result, `HarcMobileBackgroundModeFocused.xcresult`,
passed the background-mode configuration check and is a duplicate of the 94,
not a 95th unique test.

The physical logs exposed test-fixture warnings from removing temporary SQLite
directories while their stores were still open. All assertions passed, the
paths were test-owned temporary directories, and no Harc recording or production
database was involved. Those warnings require a separate test-lifecycle cleanup;
they are not silently treated as a product pass.

## Physical UI automation result

The UI qualification wrapper made three bounded attempts. Each launched the
UI runner and then failed before any Harc UI assertion:

```text
Timed out while enabling automation mode.
```

Each receipt recorded `xcode_status=65`, one runner-startup pseudo-test, zero
passed tests, `runner_startup_only=1`, and
`retryable_automation_startup=1`. A later isolated minimal UI test reproduced
the same timeout. Omega reported unlocked at that retry, while ordinary
app-hosted XCTest and Swift Testing attached and passed.

Device Hub also reported that screen interaction with Omega is unavailable
from this Xcode 27 installation unless the phone is running iOS 27 or later.
Because the Developer Disk Image is otherwise usable, this is evidence of an
Xcode/CoreDevice automation-startup compatibility boundary, not evidence that
the Harc UI passed or failed. A qualifying rerun requires either Xcode 26.6 for
this iOS 26.6 phone or an applicable physical iOS 27 device. No phone OS or
security setting was changed.

## Durable-state observation

A metadata-only phone audit copied no audio. It found 13 finalized captures:

- 12 `localOnly`
- one `failedRecoverable` with `background-upload-failed`
- zero verified recording receipts
- zero cleanup intents
- zero transfer conflicts

All 13 protected masters remain on the phone. The Host transfer log found the
13 entries eligible for retry and then stopped at the production
`codecNotQualified` gate. This is intended fail-closed behavior until the full
named-device codec matrix passes; the qualification define was not enabled.

The phone and Host each retain the same completed/accepted background batch
identity with a durable acknowledgment. Its upload remains active/receiving
without a verified recording receipt. This observation does not prove a
completed phone-to-Host-to-Library round trip, but it does prove that Harc did
not delete the last durable phone copies while completion remained unverified.

## Retained evidence

Local evidence is retained on the external SSD under:

- `HarcBuilds/physical-qualification/20261018-pr136-omega-ui-evidence/`
- `HarcBuilds/physical-qualification/20261018-pr136-omega-state-metadata/`

The retained material includes source identity/status, source-file hashes,
device identity, qualification and per-attempt receipts, Xcode logs, result
bundles, source/public-URL preflight output, and metadata-only phone/Host state.
It is local engineering evidence, not a public release artifact.

## Gates that remain open

- all four three-hour codec cells on both named phone roles
- repeated C1/C2/T1/T2 and the remaining C/T/P/H physical matrix
- successful physical UI, VoiceOver and largest-text execution
- durable phone to Host to Library publication with verified receipt and safe cleanup
- real secondary-Mac Client qualification
- two unrelated physical networks, relay recovery and visible revocation
- exact archive/export, screenshots, App Store owner declarations and submission

The checked-in
[physical qualification runbook](../operations/mobile-physical-qualification.md)
and [current-candidate register](harcmobile-current-candidate-readiness.md)
remain authoritative for closing those gates.
