# HarcMobile App Store Release Readiness

This runbook is the handoff for HarcMobile's first public App Store submission.
TestFlight distribution is optional and is not a release gate. Missing physical
evidence, privacy answers, export-compliance answers, or App Store Connect
metadata still block submission.

Prepared artifacts:

- [submission metadata and App Review copy](../app-store/harcmobile-metadata.md)
- [screenshot plan](../app-store/harcmobile-screenshot-plan.md)
- [exact-build App Privacy assessment](../app-store/harcmobile-app-privacy-assessment.md)
- [current pass/open evidence matrix](../evidence/2026-08-09-harcmobile-app-store-readiness.md)
- [compact-screen simulator diagnostic](../evidence/2026-08-09-harcmobile-se3-compact-simulator.md)
- [Omega physical storage-protection diagnostic](../evidence/2026-08-09-omega-physical-storage-protection.md)
- [Omega physical C7 storage-exhaustion diagnostic](../evidence/2026-08-09-omega-c7-storage-exhaustion.md)
- [Omega physical C5 force-quit recovery diagnostic](../evidence/2026-08-09-omega-c5-force-quit-recovery.md)

## Build and hardware prerequisites

- Use one clean, pushed source commit and record its version/build, archived app
  executable SHA-256, signature CDHash, signing identity, and provisioning
  profile UUID. If retaining an exported IPA, also record that file's SHA-256.
- Keep `TARGETED_DEVICE_FAMILY = 1`; iPad remains outside this release.
- Complete the physical codec gate and freeze the selected lossless codec.
- Complete C1-C7, T1-T7, T2b-T2e, P1, and H1 for the declared launch hardware
  scope, with the repetitions required by the implementation specification.
- Verify microphone consent, the persistent recording banner and Stop control,
  lock/background continuation, accurate post-stop state, VoiceOver, and the
  largest supported Dynamic Type sizes.
- Run client-store upgrade fixtures and an installed-build upgrade without
  losing a protected master, outbox entry, receipt, adoption, or library cursor.
- Run the final signed archive on Omega (`iPhone16,2`) before upload. Do not use
  Omega alone as evidence for an older hardware support claim.
- With the current iOS 18 deployment floor, acquire or borrow the recommended
  physical iPhone XR/iOS 18 qualification target documented in
  `mobile-physical-qualification.md`; do not treat mobile inference as a launch
  requirement or use it to narrow the capture-client floor.
- Acquire or borrow a current non-Pro iPhone 17 on the current iOS release for
  the specification's second named matrix role. Omega is useful additional Pro
  hardware evidence, not a substitute for that role.
- Repeat the physical storage-policy test from the exact archive source, then
  exercise locked, reboot/first-unlock, and installed-upgrade behavior; the
  current Omega round-trip proves the classes are applied but not those state
  transitions.

## Reviewer-accessible path

App Review requires no account or developer LAN access:

1. Launch Harc and select **Library**.
2. Tap **Open Offline Review Sample**. If a Library is already populated, use
   the document-and-magnifying-glass toolbar button.
3. Play the generated eight-second synthetic audio.
4. Review the fixed status, summary, transcript, and metadata sections.
5. Open **Privacy & Data** from the sample or the hand icon on the Host tab.

The sample contains no user data, requests no permission, makes no network
request, and never enters the Library cache or transfer outbox. It demonstrates
the reviewable UI but does not replace physical Host/capture/transfer evidence.

## App Privacy and public policy

Do not carry a prior **No, we do not collect data from this app** answer into a
relay-capable build without re-review. The adopted Host remains the recording
destination and the relay cannot decrypt content, but the infrastructure
provider can observe connection metadata. The Account Holder must verify exact
production logging and retention and answer App Privacy for the uploaded build.

Before submission:

- confirm the public policy remains reachable at the HTTPS URL packaged as
  `HarcPrivacyPolicyURL`, and enter that exact URL in App Store Connect;
- enter monitored support and review-contact email addresses;
- re-audit the final dependency graph and `PrivacyInfo.xcprivacy`;
- record whether Harc Remote is configured in the submitted build;
- document Cloudflare observability, IP-address handling, and retention;
- prove the production deployment has persistent Workers Logs, Traces, and
  per-request exports disabled, or update both the manifest and App Privacy
  answer to disclose every retained type;
- have the Account Holder publish the exact-build App Privacy answer; and
- repeat the review whenever a developer-accessible service or third-party SDK
  is added.

Re-run the production read-back immediately before freezing App Privacy answers:

```bash
cd CloudflareRelay
npm run privacy:deployed:check
npm run privacy:account-logpush:check
```

The 2026-08-09 check passed against Worker version
`6aee297a-49ea-4f92-8dab-3bdad4037976` at 100%, with Logpush disabled, no Tail
Workers, observability disabled, and live health OK. This check does not prove
that records from the superseded sampled configuration have expired; retain
that as an operator closeout item.
An authenticated dashboard query at 15:18 UTC found zero Worker events and zero
traces for `scriptName = "harc-remote-relay"` over the preceding hour. The
distinct staging environment subsequently passed overload, redeployment,
1,000-idle-Host load, active transfer, and pinned-TLS application flows with
persistent observability disabled. A delayed dashboard query after the load
interval returned zero retained staging events and traces. A temporary
aggregate-only observer also passed the named complete-flow redaction exercise,
discarding all header, metadata, and canary values; it was detached and deleted,
and restored staging version `6d537995-70ea-40d0-aed7-4442d93a0efa` passed
privacy, health, and overload. A delayed post-exercise query returned zero
staging Worker events and zero traces. The checked-in staging lifecycle harness
also passed Host-offline behavior, same-route reconnect, a fresh replacement
session, revocation, stale-capability rejection, reauthorization, and final
privacy/health read-back. Records from the
superseded Paid-plan sampled configuration must still be confirmed absent by
2026-08-16. The authenticated Account Holder dashboard showed **No Logpush
jobs** under Account-scoped Logpush on 2026-08-09, closing the current broader
account-export check.
The account audit uses Cloudflare's account Logpush job-list API and deliberately
prints counts only; it fails if any `workers_trace_events` job exists so the
destination's retention must be inspected rather than guessed.

The packaged privacy manifest declares no tracking and no collected data. It
declares `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1`
because Harc uses file timestamps to validate protected recording and transfer
artifacts inside its container. This required-reason declaration is not a
data-collection declaration.

## Export compliance

The generated Info.plist declares `ITSAppUsesNonExemptEncryption = false`. Harc
uses platform and standard open-source cryptography for pinned TLS, pairing, and
signed application objects. The Account Holder must verify the App Store Connect
export-compliance answers against the exact archive and applicable rules. This
runbook is not legal advice.

## App Review notes

Harc has no cloud account or reviewer-accessible content-processing server. The
automatic content destination is a user's approved Host computer. Harc Remote,
when enabled, is a content-blind connection relay. Reviewers are not expected to
reach the developer's LAN; use **Library > Open Offline Review Sample** for a
permission-free offline demonstration. Its audio is generated on device and its
text is fixed bundled content.

To test microphone capture, use **Record > Start Recording** and grant microphone
permission. Harc uses the `audio` background mode only for a recording the user
explicitly starts. Returning to the foreground shows a persistent red Recording
banner, elapsed time, and Stop control. Camera access is requested only for Host
QR scanning. Local Network access is requested only for adopted-Host discovery
and connection.

## Archive, upload, and submission

Run the repository-side preflight before creating an archive:

```bash
./scripts/preflight-harcmobile-app-store.sh
```

It validates the 5 GiB operational floor, source plists and privacy manifest,
privacy and relay URLs, release-facing project settings, final 1024px AppIcon
dimensions/alpha, product-page copy limits, and the public support URL. Open
items fail the command. During preparation, `--report-only` prints the same
findings without a nonzero exit.

After the policy and support files are committed to public `main`, verify the
exact URLs over HTTPS:

```bash
./scripts/preflight-harcmobile-app-store.sh --check-public-urls
```

After capturing the five product-page images, add the screenshot directory:

```bash
./scripts/preflight-harcmobile-app-store.sh \
  --screenshots-dir /path/to/harcmobile-app-store-screenshots
```

This requires the five versioned names in the screenshot plan, exact 1290 by
2796 dimensions, and no alpha channel, and prints a SHA-256 for each image.

After creating the exact candidate archive, run it against those bytes:

```bash
./scripts/preflight-harcmobile-app-store.sh \
  --archive /path/to/HarcMobile.xcarchive
```

The archive check verifies the bundle identity and minimum OS, packaged privacy
URL and manifest contents, relay/export declarations, exact version/build,
iPhone-only platform metadata, final icon name and compiled assets, arm64-only
binary, a valid archive signature/profile, and required entitlements. It does
not require an Apple Distribution identity or reject `get-task-allow` at this
stage: Xcode may repackage and distribution-sign the app during export or
upload.

If you retain a locally exported App Store distribution app, verify that app as
the second signing stage:

```bash
./scripts/preflight-harcmobile-app-store.sh \
  --distribution-app /path/to/export/Payload/Harc.app
```

That check requires the Apple Distribution certificate, a distribution
provisioning profile with debugger attachment disabled, release entitlements,
the exact registered Harc team and application identifier, a future profile
expiration, an App Store-scoped profile rather than a device-bound or
enterprise-wide profile, exact bundle/version/build identity, iPhone-only
metadata, and arm64. Xcode/App Store upload processing remains authoritative
when the direct-upload workflow does not retain an exported app. Neither
preflight replaces the physical, secondary-Mac, relay staging/deployment, or
App Store Connect gates in the evidence matrix.

1. Create the App Store Connect app record and complete the exact name, immutable
   SKU, primary language, bundle ID, user access, content rights, DSA status,
   seller identity, description, keywords, category, age rating, pricing,
   availability, screenshots, support URL, and privacy-policy URL.
2. Archive the exact clean commit and validate the archive's packaged identity.
3. Export or upload for App Store distribution. If retaining a local IPA,
   validate its distribution signing and record the IPA SHA-256; otherwise
   retain the archive preflight output and exact Xcode upload/processing result.
4. Upload with Xcode or Transporter and wait for processing to complete.
5. Inspect every processing warning and the thinned device variants.
6. Select the exact build in the App Store version record.
7. Reconcile App Privacy, export compliance, review contact, and review notes
   against that build.
8. Add the version to an App Review submission and submit it.
9. Use manual release for the first version so approval and publication are
   separate, observable decisions.

Before creating the final archive, confirm the Release settings still resolve
to the intended distributable app:

```bash
xcodebuild \
  -project Harc.xcodeproj \
  -scheme HarcMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -showBuildSettings
```

The inspected candidate must report `SKIP_INSTALL = NO`, `WRAPPER_EXTENSION =
app`, `TARGETED_DEVICE_FAMILY = 1`, bundle ID `com.harc.HarcMobile`, the intended
version/build, and the final `AppIcon`. Treat any mismatch as a stop, not an
upload warning.

## Values requiring account-owner input

- Public privacy-policy URL: prepared; recheck after the release commit is public
- Public support URL with actual monitored contact information: **required**
- Review contact name, phone, and email: **required**
- Exact app-name availability, immutable SKU, user access, content rights, DSA
  status, seller identity, category, age rating, pricing, and regions:
  **required**
- Screenshots and promotional text: **required**
- Exact uploaded version/build, archived executable SHA-256, signature CDHash,
  profile UUID, and processed-build result: **required**
- Exact-build App Privacy and export-compliance answers: **required**
- Named physical-device evidence bundle: **required**

## Apple references

- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Distribute for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Distribution provisioning profile](https://developer.apple.com/help/glossary/distribution-provisioning-profile/)
- [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)
- [Publishing workflow](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/overview-of-publishing-your-app-on-the-app-store)
- [App information fields](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
- [Version metadata and support URL](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Required device capabilities](https://developer.apple.com/documentation/bundleresources/information-property-list/uirequireddevicecapabilities)
