# Desktop pairing camera crash and readiness regressions

**Date:** 2026-08-06

**Status:** Harc 0.13.7 (52) prevented the Objective-C crash. Its physical Brio
follow-up exposed a false unsupported result and black preview. The readiness
follow-up is source-fixed, app-target green, signed, notarized, and release-
verified for Harc 0.13.8 (53), with publication and the affected-Mac retry
pending.

## Observed failure

Selecting **Scan Host Code** on a Mac Client opened an external Brio/CMIO camera
and terminated Harc with an uncaught `NSInvalidArgumentException` on the
`com.harc.desktop.pairing-camera` queue. The exception came from
`-[AVCaptureMetadataOutput setMetadataObjectTypes:]` when `.qr` was not present
in `availableMetadataObjectTypes`.

This is an Objective-C precondition failure and is not catchable by Swift's
`do`/`catch`. Camera permission was not the cause.

## Root cause and fix

The pre-0.13.7 scanner added its metadata output inside an open
`beginConfiguration()`/`commitConfiguration()` transaction and assigned `.qr`
before that transaction committed. AVFoundation can still report an empty
capability list at that point. An external, virtual, or Continuity camera can
also genuinely omit QR metadata support.

- Input and a fresh metadata output are now attached and committed first.
- Every camera switch removes the prior input and output, preventing a stale
  QR configuration from carrying onto an incompatible device.
- The scanner reads `availableMetadataObjectTypes` only after attachment has
  committed and assigns `.qr` only when the returned list contains `.qr`.
- In 0.13.7, an unsupported camera was detached from metadata scanning and produced a
  visible instruction to choose another camera or paste the Host pairing link.
- The canonical copy/paste pairing flow remains available and unchanged.

## Physical Brio follow-up

The affected Mac confirmed that 0.13.7 no longer crashed, but it selected the
Logitech BRIO, showed a black preview, and immediately reported that the camera
did not support QR scanning. The camera continued to work in other apps.

The scanner was still consulting `availableMetadataObjectTypes` before calling
`startRunning()`. For this external camera the attached-but-not-running output
temporarily returned an empty list. Harc interpreted that transient state as a
permanent capability result, removed the output, threw the warning, and never
started the session. The UI therefore named the correct camera while displaying
no video from it.

The 0.13.8 follow-up now:

- attaches the selected input and a fresh metadata output, then starts the
  capture session on the existing serial camera queue;
- treats an empty capability list as transient for up to one second, using
  bounded 50 ms retries after the session is running;
- assigns `.qr` only after the live output advertises it, preserving the
  exception guard from 0.13.7;
- cancels stale readiness retries when the user switches cameras or closes the
  scanner; and
- leaves the selected camera session and preview running if QR is genuinely
  unsupported, so the camera selection remains observable and the paste-link
  fallback stays available.

## Validation

| Gate | Result |
| --- | --- |
| App-target compile | The changed scanner and Client pairing controller compiled successfully in the macOS app target. |
| Focused scanner suite | `HarcDesktopPairingScannerTests` passed 4/4, including empty and non-QR capability lists plus a mixed list containing `.qr`. |
| Bounded build | `xcodebuild` used an arm64 macOS destination, two workers, and `SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2`. |
| Source hygiene | `Package.resolved` was restored to the documented Sparkle-free SwiftPM state and `git diff --check` passed. |

The 0.13.8 focused scanner suite also passed 4/4 in the full macOS app target.
Its readiness regression covers the transient-empty retry, bounded exhaustion,
nonempty unsupported capability, and eventual QR-ready states. The app target
compiled with the selected-camera lifecycle and readiness cancellation logic.

## 0.13.7 release

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

## 0.13.8 release candidate

| Evidence | Value |
| --- | --- |
| Source/version commit | `e157133` |
| Apple notarization | Accepted; submission `29e1824e-019c-45c0-8fa5-642c1c6042d1` |
| Stapled DMG bytes | `64,992,634` |
| Stapled DMG SHA-256 | `f6b2c74cbf257b82d895599a0dbede462d2fd3403985e784e836e308254fd0df` |
| Release ZIP bytes | `62,248,946` |
| Release ZIP SHA-256 | `be28ac6c7906c8c0efe14cc27f3052c8dd4525a1d63d9cab0b7b48884fdc93a1` |
| Sparkle EdDSA signature | `4RR70t0I9oMbJ6RG/4sFiZltISFkPAfc6F8fSPDx7HkJG7jKRrZz+v4xN6IqpZszaDAIh44sUT1W9YwIjl0oDQ==` |

The full post-staple verifier accepted the exact 0.13.8 DMG, including its
outer signature, UDIF checksum, ticket, Gatekeeper assessments, nested-code
signatures, version/build metadata, bundle identifier, and arm64-only app and
helper binaries.

The development Mac did not expose a camera through `system_profiler`, so the
physical Brio preview and QR decode remain post-release acceptance checks on the
affected Mac. The software regression prevents the exception-producing setter
call whenever the selected device does not advertise QR support.
