# Desktop pairing camera crash regression

**Date:** 2026-08-06

**Status:** Fixed, tested, notarized, published, and live through Sparkle in Harc
0.13.7 (52). Physical Brio behavior remains the affected-Mac acceptance check.

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

## Release candidate

| Evidence | Value |
| --- | --- |
| Source/version commit | `70d4a16` |
| Apple notarization | Accepted; submission `ed99c978-3137-4614-bc79-cc5c763ccb6a` |
| Stapled DMG bytes | `64,993,876` |
| Stapled DMG SHA-256 | `8f6fcfd439f61a13f399582c488be243508301fc2be8b8e05974e75c00b53d80` |
| Release ZIP bytes | `62,250,561` |
| Release ZIP SHA-256 | `2add1d45c65d31270d7b3dd7a484e122bf0b8bdb1268d315ab03367626c690a3` |
| Sparkle EdDSA signature | `6BhOd9XR0yWgFBnJ63r000UclPWteTsacmaIAx1EGolTPTm3mle9bs6tphnk2cLQ4c+RGPOzM8ofA/3mZzviAw==` |
| Release | <https://github.com/jkrack/Harc/releases/tag/v0.13.7> |

`scripts/verify-release.sh` accepted the exact stapled DMG using the normal
macOS trust boundary. It verified the outer signature, UDIF checksum, stapled
ticket, Gatekeeper assessment, mounted application and nested signatures,
version/build, bundle identifier, and arm64-only application/helper binaries.
GitHub's server-side byte counts and SHA-256 digests matched both exact local
assets. The remote `v0.13.7` tag resolves to source commit `70d4a16`, and the
live raw `main` appcast exposes 0.13.7 (52) first with the recorded signature,
length, and release URL.

The exact published DMG was mounted and its application revalidated before
installation. It replaced 0.13.6 (51) only after Harc and its helpers exited
normally. `/Applications/Harc.app` then passed Developer ID and Gatekeeper
verification, reported 0.13.7 (52), and launched with `harc-stt` as a child of
the main Harc process. The prior application bundle remains recoverable at
`/private/tmp/Harc-0.13.6-build51-backup.app` for this boot session.

The development Mac did not expose a camera through `system_profiler`, so the
physical Brio retry remains a post-release acceptance check on the affected
Mac. The regression prevents the exception-producing setter call whenever the
selected device does not advertise QR support.
