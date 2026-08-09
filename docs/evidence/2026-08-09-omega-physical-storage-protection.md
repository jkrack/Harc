# Omega physical storage-protection evidence

**Date:** 2026-08-09
**Scope:** current-device diagnostic
**Device:** Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6 (23G71), arm64

## Result

A signed hosted application test passed on Omega with one test executed, no
skips, and zero failures. On the physical iPhone filesystem it created
representative application-support artifacts and independently verified both
backup exclusion and the exact Data Protection class after applying each
production policy:

| Artifact policy | Verified protection |
| --- | --- |
| Active canonical master | `NSFileProtectionCompleteUnlessOpen` |
| Finalized/transfer artifact | `NSFileProtectionCompleteUntilFirstUserAuthentication` |
| Transfer database | `NSFileProtectionCompleteUntilFirstUserAuthentication` |
| Library-cache database | `NSFileProtectionComplete` |

Every artifact also round-tripped `NSURLIsExcludedFromBackupKey = true`. The
test uses the production `FoundationHarcMobileCaptureStorageAttributes` and
`FoundationClientStoreStorageAttributes` implementations and removes its
temporary application-support directory after the assertions.

The subsequently completed combined physical regression also passed this test
as part of 30/30 current-device app/UI tests (24 hosted and six UI).

## Command

```bash
xcodebuild \
  -project Harc.xcodeproj \
  -scheme HarcMobile \
  -configuration Debug \
  -destination id=<omega-device-id> \
  -jobs 2 \
  -parallel-testing-enabled NO \
  SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2 \
  DEVELOPMENT_TEAM=<harc-team-id> \
  CODE_SIGN_STYLE=Automatic \
  -only-testing:HarcMobileAppTests/HarcMobileConfigurationTests/testPhysicalStoragePoliciesRoundTripProtectionAndBackupExclusion \
  test
```

## Qualification boundary

This closes the missing real-filesystem round-trip diagnostic on the available
current iPhone. It does not prove behavior while protected data is unavailable,
survival across reboot/first unlock, an installed-build upgrade, or the final
App Store archive. The source tree was not a clean sealed evidence commit, so
the same test and the destructive locked/reboot scenarios must be repeated on
the exact release build before the physical protection gate is promoted to
pass.
