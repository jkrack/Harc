# iPhone 15 Pro Max HarcMobile 0.13.5 functional checkpoint

**Date:** 2026-08-05

**Status:** Signed physical-device build, install, launch, and upgrade-state
preservation verified; automated microphone test did not execute because
XCTest could not enable device automation mode.

This checkpoint records what was observed on the attached physical phone. It
does not promote an XCTest infrastructure failure into an application failure,
and it does not claim any Section 25.2 capture or transfer scenario passed.

## Build and device identity

- Source checkout: `f8c4ce9435214c4341b2fa71fb20bdce32576605`
- Product source tag: `v0.13.5` at `32251de`
- App: `com.harc.HarcMobile` version `0.13.5` build `50`
- Signing team: `63TNU5M7P4`
- Built-app SHA-256 CDHash: `8779358728fd28eec5b73ae1c10497906c22bffa`
- Device: Omega, iPhone 15 Pro Max (`iPhone16,2`)
- OS: iOS 26.0 (`23A340`)
- Developer Mode: enabled

The exact CoreDevice and device identifiers remain in the local Xcode result
bundle and are intentionally omitted from public repository history.

The Debug device build used two workers and explicit team signing. It installed
over the existing HarcMobile application, launched successfully, and remained
alive after launch before the UI-test runner was introduced.

## Upgrade-state preservation

The physical application container was copied read-only immediately after the
0.13.5 install and normal launch. The preserved adopted-Host route was:

```json
{"host":"jamess-mac-mini.local","port":65215,"serverHostname":"jamess-mac-mini.local"}
```

The transfer store retained one adoption-history row, one trust namespace, and
one grant slot. It contained no finalized captures, recording-outbox rows,
upload attempts, background-task mappings, receipts, cleanup intents, or
transfer conflicts. The library cache retained one cursor, 122 cached
recordings, two tombstones, and no offline mutations or conflicts.

This proves that installing 0.13.5 did not discard the existing Host adoption
or populated mobile library cache. Because there was no capture in this
container snapshot, it is not evidence for capture durability, transfer, or
receipt cleanup.

## Focused microphone UI-test result

The only selected test was:

```text
HarcMobileReleaseReadinessUITests/
  testPhysicalMicrophoneRecordingStartsAndStopsWithoutProcessExit
```

The intended product interaction records for approximately two seconds and
then stops. XCTest never entered the test body. After about 62 seconds the
`HarcMobileUITests-Runner` failed initialization with:

```text
Timed out while enabling automation mode.
```

The authoritative result bundle is:

```text
~/Library/Developer/Xcode/DerivedData/
  Harc-cbxlngmykwqflyealxbcmdryibsj/Logs/Test/
  Test-HarcMobile-2026.08.05_20-30-57--0700.xcresult
```

`xcresulttool` reports the correct physical device and OS, zero passed tests,
one runner-initialization failure, and no test-body result. CoreDeviceService
then failed to initialize for a later read-only device query, so automated
device commands were stopped rather than repeatedly restarting the same
failure path.

## Gate decision

- Physical signed build/install/ordinary launch: **observed**
- Adopted-Host and populated-library upgrade preservation: **observed**
- Physical recording start/stop: **not executed by XCTest; remains open**
- Capture-to-outbox and Host receipt: **not exercised; remains open**
- C1-C7, T1-T7, T2b-T2e, P1, and H1: **remain open unless separately evidenced**
- Shipping codec selection: **remains fail-closed**

The next phone action is a short manual record/stop while the normal 0.13.5 app
is foregrounded, followed by read-only inspection of the resulting capture,
outbox, upload attempt, receipt, and Host canonical-library rows. Long codec
qualification runs should not resume until this short product path is stable
and the phone is in a cool nominal or fair thermal state.
