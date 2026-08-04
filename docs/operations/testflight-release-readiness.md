# HarcMobile TestFlight Release Readiness

This runbook is the handoff for the first external HarcMobile TestFlight build.
It does not turn missing physical evidence or App Store Connect metadata into a
passing gate.

## Build and hardware prerequisites

- Use one clean, pushed source commit and record its version/build and archive
  SHA-256.
- Keep `TARGETED_DEVICE_FAMILY = 1`; iPad remains outside this release.
- Complete the physical codec matrix and freeze the selected lossless codec.
- Complete C1-C7, T1-T7, T2b-T2e, P1, and H1. C1, C2, T1, and T2 require three
  consecutive passes on both named iPhones.
- Verify microphone consent, the persistent in-app recording banner and Stop
  control, lock/background continuation, and accurate post-stop state on both
  named iPhones with VoiceOver and the largest supported Dynamic Type sizes.
- Run the client-store upgrade fixtures and an installed-build upgrade without
  losing a protected master, outbox entry, receipt, adoption, or library cursor.

## Reviewer-accessible path

No account or developer LAN access is required for the bundled review sample:

1. Launch Harc and select **Library**.
2. Tap **Open Offline Review Sample**. If a Library is already populated, use
   the document-and-magnifying-glass toolbar button.
3. Play the generated eight-second synthetic audio.
4. Review the fixed status, summary, transcript, and metadata sections.
5. Open **Privacy & Data** from the sample or the hand icon on the Host tab.

The sample contains no user data, does not request a permission, makes no
network request, and never enters the Library cache or transfer outbox. It is a
read-only review surface, not evidence that Host pairing or physical transfer
passed.

## App Privacy and privacy-policy metadata

For the current architecture, select **No, we do not collect data from this
app**. The only automatic off-device destination is the user's authenticated,
adopted Host, which the developer and third-party partners cannot access. There
are no account, advertising, analytics, telemetry, crash-reporting, or
third-party processing SDKs in the current build.

Before submission:

- publish `docs/privacy/harc-mobile-privacy-policy.md` at a stable public HTTPS
  URL and enter that exact URL in App Store Connect;
- enter a monitored support/feedback email;
- re-audit the final dependency graph and `PrivacyInfo.xcprivacy`;
- confirm the App Privacy answer still matches the exact uploaded build; and
- re-evaluate the answer if any developer-accessible service or third-party SDK
  is added.

The packaged privacy manifest declares no tracking and no collected data. It
also declares `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1`
because Harc uses `stat`/`fstat`/`lstat` to validate the identity, size, and
durability of protected recording and transfer files inside its app container.
That required-reason declaration is not a data-collection declaration.

## Export compliance

The generated iOS Info.plist currently declares
`ITSAppUsesNonExemptEncryption = false`. The build uses platform and standard
open-source cryptography for pinned TLS, pairing, and signed application
objects. The Account Holder must verify the App Store Connect export-compliance
answers against the exact archive and applicable export rules; this runbook is
not legal advice and must not be used to bypass an Apple documentation request.

## TestFlight test information

### Beta app description

HarcMobile is a local-first microphone recorder and client for a user-owned Harc
Host. Recordings remain available on the iPhone while the Host or network is
offline. When paired, Harc transfers independently verifiable lossless audio,
stores a signed durable receipt, and presents the permitted Host Library without
using a Harc-operated cloud service.

### What to test

- Start and stop a local recording, including a lock/background transition.
- Confirm the persistent red recording banner and Stop control remain visible
  whenever the app is foregrounded during capture.
- With no Host, play the protected local master and inspect its retained status.
- Open the offline Review Sample from Library and inspect audio, transcript,
  summary, metadata, and Privacy & Data.
- If using a locally approved Host, scan its QR code, compare all four security
  words, wait for Host approval, and verify transfer/receipt/library status.
- Confirm failures remain explicit and recordings remain local and recoverable.

### Beta App Review notes

Harc has no cloud account or reviewer-accessible developer server. The app's
automatic off-device path is a user's locally approved Host computer, so Apple
reviewers are not expected to reach the developer's LAN. Use Library > Open
Offline Review Sample for a permission-free, offline demonstration of the
completed Library detail experience. Its audio is generated on device and its
text is fixed bundled content; it does not contain user data or exercise the
network.

To test microphone capture, use Record > Start Recording and grant microphone
permission. Harc uses the `audio` background mode only for a recording the user
explicitly starts. Returning to the foreground shows a persistent red Recording
banner, elapsed time, and Stop control. Camera access is requested only when the
reviewer chooses to scan a Host pairing code. Local Network access is requested
only for discovery and connection to an adopted Host.

### Values still requiring account-owner input

- Public privacy policy URL: **required**
- Monitored feedback email: **required**
- Review contact name, phone, and email: **required**
- Exact uploaded version/build and archive SHA-256: **required**
- Named physical-device evidence bundle: **required**
