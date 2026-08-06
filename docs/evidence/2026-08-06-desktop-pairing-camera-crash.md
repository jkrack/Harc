# Desktop pairing camera crash regression

**Date:** 2026-08-06

**Status:** Source fix and focused application regression green; publication
evidence pending Harc 0.13.7 (52).

## Observed failure

Selecting **Scan Host Code** on a Mac Client opened an external Brio/CMIO camera
and terminated Harc with an uncaught `NSInvalidArgumentException` on the
`com.harc.desktop.pairing-camera` queue. The exception came from
`-[AVCaptureMetadataOutput setMetadataObjectTypes:]` when `.qr` was not present
in `availableMetadataObjectTypes`.

This is an Objective-C precondition failure and is not catchable by Swift's
`do`/`catch`. Camera permission was not the cause.

## Root cause and fix

The scanner added its metadata output inside an open
`beginConfiguration()`/`commitConfiguration()` transaction and assigned `.qr`
before that transaction committed. AVFoundation can still report an empty
capability list at that point. An external, virtual, or Continuity camera can
also genuinely omit QR metadata support.

- Input and a fresh metadata output are now attached and committed first.
- Every camera switch removes the prior input and output, preventing a stale
  QR configuration from carrying onto an incompatible device.
- The scanner reads `availableMetadataObjectTypes` only after attachment has
  committed and assigns `.qr` only when the returned list contains `.qr`.
- An unsupported camera is detached from metadata scanning and produces a
  visible instruction to choose another camera or paste the Host pairing link.
- The canonical copy/paste pairing flow remains available and unchanged.

## Validation

| Gate | Result |
| --- | --- |
| App-target compile | The changed scanner and Client pairing controller compiled successfully in the macOS app target. |
| Focused scanner suite | `HarcDesktopPairingScannerTests` passed 4/4, including empty and non-QR capability lists plus a mixed list containing `.qr`. |
| Bounded build | `xcodebuild` used an arm64 macOS destination, two workers, and `SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2`. |
| Source hygiene | `Package.resolved` was restored to the documented Sparkle-free SwiftPM state and `git diff --check` passed. |

The development Mac did not expose a camera through `system_profiler`, so the
physical Brio retry remains a post-release acceptance check on the affected
Mac. The regression prevents the exception-producing setter call whenever the
selected device does not advertise QR support.
