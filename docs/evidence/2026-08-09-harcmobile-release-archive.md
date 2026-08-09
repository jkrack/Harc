# HarcMobile exact Release archive and distribution evidence

**Date:** 2026-08-09

**Source commit:** `143ba41ff21c7c6ba6d17b0a2d9dc5285f9ac07f`

**Candidate:** HarcMobile 0.14.1 (56)

## Decision

The exact clean Release archive passes its source, bundle, privacy, signing,
provisioning, entitlement, icon, and architecture gates. The archived app also
installed and launched on the available Omega iPhone. A local App Store Connect
export passes the separate distribution-signature and profile verifier. This
closes archive creation and distribution export; it does not close upload/App
Store processing, the named-device physical matrix, or manual on-device gates.

## Archive identity

- Local retained archive:
  `build/app-store/HarcMobile-0.14.1-56.xcarchive`
- Archive creation: 2026-08-09T15:04:57-0700
- Archive size: 355 MiB
- Archived app size: 19 MiB
- Bundle identifier: `com.harc.HarcMobile`
- Platform/device family: iPhoneOS, iPhone only
- Architecture: arm64
- Signing identity:
  `Apple Development: james@cloudarchitech.com (SQXZUPA7X7)`
- Team: `63TNU5M7P4`
- Signature CDHash: `82e002efbb67016379f7ead5d954ddc4e51809b6`
- Archived executable SHA-256:
  `363addf6eca9f1d3c2165960f84a99b255d95fd85d6dec99c772b1e1f9832f59`
- Provisioning profile UUID: `0d5e90ad-9dd5-42f5-9823-a6cfb5b01626`
- Provisioning profile expiration: 2027-08-05T02:36:17Z

## Archive validation

The keychain-enabled authoritative run of:

```bash
./scripts/preflight-harcmobile-app-store.sh \
  --archive build/app-store/HarcMobile-0.14.1-56.xcarchive \
  --report-only
```

passed every archive-specific check, including:

- archive metadata and exact bundle/version/build identity;
- iOS 18 minimum, iPhone-only family, and arm64-only executable;
- packaged privacy-policy and relay origins;
- non-exempt-encryption, background-audio, Bonjour, and permission declarations;
- privacy manifest tracking/collection/reason declarations;
- compiled `AppIcon` assets;
- strict code-signature verification and the full Apple trust chain;
- complete Data Protection, application identifier, and team entitlements; and
- embedded profile identity, team, UUID, and future expiration.

The repository portion had exactly one owner-input open: replace
`ACCOUNT_HOLDER_MONITORED_SUPPORT_EMAIL` with a monitored support address.

## Exact-app Omega smoke

CoreDevice installed the archived app on Omega, iPhone 15 Pro Max
(`iPhone16,2`) on iOS 26.6. The installed-app query reported bundle
`com.harc.HarcMobile`, version 0.14.1, and build 56. CoreDevice launched it
successfully, and the subsequent process query showed the archived executable
running as PID 1176.

This proves installation and process launch of the exact archive on the
available Pro device. It does not substitute for manual reviewer-path,
microphone, lock/background, VoiceOver, largest-text, upgrade, current non-Pro,
or oldest-supported-device qualification.

## App Store distribution export

Xcode 26.6 exported the archive locally with method `app-store-connect`,
destination `export`, automatic signing, team `63TNU5M7P4`, and build-number
management disabled. No upload was requested.

- Retained IPA: `build/app-store/export-0.14.1-56/Harc.ipa`
- IPA size: 17 MiB
- IPA SHA-256:
  `4ab371aaf2e5d00b9dfcc2b8beeeceda966fbaac67591889b14fe62e8c92fe2d`
- Distribution certificate:
  `Apple Distribution: JAMES ELLIS LANE (63TNU5M7P4)`
- Distribution executable SHA-256:
  `bec74d1914510a0f84a577b748b03bd7573dfb8624869558f819918a829d3b45`
- Distribution signature CDHash:
  `463fca0ae7c3ef3557efb060f45f79eba4bbdc24`
- App Store profile UUID: `0df28cc6-72ff-4af1-a974-5c572dd490de`
- App Store profile expiration: 2027-08-09T22:00:39Z
- App Store profile name:
  `iOS Team Store Provisioning Profile: com.harc.HarcMobile`

The authoritative distribution-app preflight passed every check: Apple
Distribution signature/trust, exact identity/version/build, arm64-only binary,
privacy and icon packaging, App Store-scoped non-enterprise profile, no device
list, `get-task-allow=false`, complete Data Protection, and expected team and
application identifiers.

## Remaining archive-adjacent gates

- Provide the monitored support email and exact App Store Connect owner fields.
- Capture and hash the five exact-build 1290-by-2796 screenshots.
- Complete the named-device physical qualification matrix and manual Omega
  archive behaviors.
- Upload the validated IPA through Xcode's App Store path only after the open
  physical and owner-input gates pass, then capture the exact processing result.
