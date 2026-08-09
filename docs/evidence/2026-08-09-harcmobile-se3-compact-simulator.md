# HarcMobile compact-screen simulator evidence

**Date:** 2026-08-09
**Scope:** diagnostic compatibility only
**Destination:** iPhone SE (3rd generation), 375 x 667 points, iOS Simulator
26.5, arm64

## Result

HarcMobile passed its complete Xcode test action on a temporary iPhone SE
(3rd generation) simulator:

- 23 hosted application tests passed;
- two simulator-applicable release-readiness UI tests passed;
- the physical-microphone UI test was correctly skipped;
- total: 25 passed, one skipped, zero failures.

The UI automation reached the Record entry and its local-handling disclosure,
then reached the offline review sample and Privacy & Data surface on the compact
375 x 667-point viewport.

A second focused UI run set the simulator to
`accessibility-extra-extra-extra-large`, the largest simulator Dynamic Type
setting. Both applicable UI tests passed, the physical-microphone test was
correctly skipped, and there were zero failures. The offline review sample's
audio control and Privacy & Data surface remained reachable by scrolling.

## Command

```bash
xcodebuild \
  -project Harc.xcodeproj \
  -scheme HarcMobile \
  -configuration Debug \
  -destination id=<temporary-se3-simulator-udid> \
  -jobs 2 \
  -parallel-testing-enabled NO \
  SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2 \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  -resultBundlePath <temporary-result-path> \
  test
```

Normal simulator ad-hoc signing is required. Disabling signing removes the
simulated Keychain entitlement and produces `OSStatus -34018`, which is a test
configuration failure rather than a Harc readiness result.

## Hardening found during qualification

The Record UI test now explicitly selects the Record tab before asserting its
content. This prevents state restored from the preceding Library test from
making the test order-dependent. The release-metadata test also distinguishes
the simulator product from device products: Xcode injects the arm64 required-
device capability into device products, so that assertion remains active on
physical hardware while the simulator asserts the key is absent.

The compact accessibility run also found that controls below the initial
viewport must be reached by scrolling when text is maximized. The release UI
test now scrolls to the review-sample audio and Privacy & Data controls before
asserting them, preserving the compact-screen regression at large text sizes.

## Qualification boundary

This result is useful evidence for compact-screen layout, application bootstrap,
Keychain-backed local state, the offline reviewer path, and test isolation. It
does **not** establish an oldest-supported physical iPhone, codec performance,
thermal behavior, microphone/background capture, Data Protection, VoiceOver,
physical Dynamic Type behavior, or any C/T/P/H physical matrix cell. The
largest-text simulator result is a useful layout diagnostic, not the required
exact-build physical accessibility qualification. Production codec selection
remains fail-closed until the sealed-build physical matrix passes.
