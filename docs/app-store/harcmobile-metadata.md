# HarcMobile App Store metadata

**Prepared:** 2026-08-09
**Primary localization:** English (U.S.)
**Bundle ID:** `com.harc.HarcMobile`

This is the canonical copy deck for the first iPhone submission. Account-holder
decisions are called out explicitly; do not replace them with assumptions when
creating the App Store Connect record.

## App record values

| App Store Connect field | Prepared value or decision |
| --- | --- |
| Platform | iOS |
| Primary language | English (U.S.) |
| Name | `Harc`; exact-name availability must be confirmed when the record is created |
| Bundle ID | `com.harc.HarcMobile` |
| SKU | Recommended immutable internal value: `harc-ios-001`; Account Holder must confirm before creation |
| User access | Account Holder decision based on the App Store Connect team |
| Made for Kids | No |
| Content rights | Harc supplies no third-party content catalog; Account Holder must answer Apple's exact current question |
| License agreement | Apple standard EULA unless the Account Holder deliberately supplies a custom agreement |
| Digital Services Act status | Account Holder/legal decision; cannot be inferred from source code |
| Regulated medical device | No; Harc is a meeting recorder, not a medical device |
| Tax category, price, regions | Account Holder decision |

The SKU cannot be changed after the record is created. A public App Store search
found an existing app titled **Harc - Patasxan**, so neither this deck nor a web
search proves that the exact localized name **Harc** can be reserved. App Store
Connect is authoritative.

## Product page copy

**Name**
Harc

**Subtitle**
Private meeting memory

**Promotional text**
Record meetings on iPhone, keep a protected local copy, and sync securely to the
Harc Host you control—without accounts, ads, or cloud speech processing.

**Description**

Harc is a private, local-first meeting recorder and knowledge library for iPhone
and Mac.

Record on your iPhone even when your network or Harc Host is unavailable. Harc
keeps a protected local master until the Mac you adopt confirms that it has
durably committed the recording. When the Host is reachable, encrypted audio
syncs directly over your local network or through the optional content-blind
Harc Remote relay.

Your Harc Host transcribes, summarizes, and organizes recordings locally on
Apple silicon. Harc has no cloud account, advertising, app-use analytics, or
cloud speech-processing service.

Features include:

- explicit, user-started iPhone recording with a persistent recording indicator;
- durable offline capture and safe retry after Host or network interruption;
- a searchable, host-backed meeting library with transcript and summary detail;
- cryptographic Host pairing and authenticated transfer receipts;
- local playback and explicit, disclosed export through the system share sheet;
- an offline review sample containing no user data; and
- optional Harc Remote reachability without exposing recording content to the
  relay.

Harc for Mac is required for transcription, summaries, and the canonical
host-backed library. Recording and the bundled offline review sample do not
require an account.

**Keywords**
meeting,recorder,transcription,voice,notes,audio,private,offline,summary,speech

**What's New (future updates; not entered for the first version)**
The first iPhone release of Harc: protected mobile recording, secure adopted-Host
sync, offline Library access, and explicit private export.

## URLs

- Support URL: <https://github.com/jkrack/Harc/blob/main/docs/support/harcmobile-support.md>
  — monitored contact: <support@cloudarchitech.com>
- Privacy Policy URL: <https://github.com/jkrack/Harc/blob/main/docs/privacy/harc-mobile-privacy-policy.md>
- Marketing URL, optional: <https://github.com/jkrack/Harc>

The privacy URL above is also packaged in the app. If it changes, update
`HarcPrivacyPolicyURL` in `project.yml`, this file, the public policy, and App
Store Connect in the same release.

## Recommended classification

- Primary category: **Productivity**
- Secondary category: **Utilities**
- Copyright: **2026 CloudArchitech LLC**

The Account Holder must confirm the categories, complete Apple's current age
rating questionnaire, choose pricing and availability, and confirm the seller
name before submission.

## App Review information

**Sign-in required:** No
**Demo account:** Not applicable

**Review notes**

Harc is a companion to a user-controlled Harc Host on Mac. App Review does not
need an account, our LAN, or a Host to inspect the app.

1. Launch Harc and select Library.
2. Tap Open Offline Review Sample. If the Library already contains items, use
   the document-and-magnifying-glass toolbar button.
3. Play the generated eight-second synthetic audio and inspect its fixed
   status, summary, transcript, and metadata.
4. Open Privacy & Data from the sample or from the hand icon on the Host tab.

The sample contains no user data, requests no permission, makes no network
request, and never enters the transfer outbox.

To test capture, select Record, tap Start Recording, and grant microphone
permission. Harc uses the audio background mode only for a recording the user
explicitly starts. Returning to the foreground shows a persistent red Recording
banner, elapsed time, and Stop control. Camera access is only for scanning a
short-lived Host pairing code. Local Network access is only for discovering and
connecting to the Host the user approves.

Harc Remote is an optional, content-blind relay. Inner pinned TLS and
application authentication remain end to end between the iPhone and adopted
Host; the relay cannot decrypt recordings or library content.

## Account-holder decisions still required

- Review contact name, monitored email, and phone number
- Public support page and monitored customer-support contact
- App record creation: exact name availability, immutable SKU, user access,
  content-rights answer, DSA status, and seller identity
- Final category selection, age rating, price, regions, and release mode
- Exact-build App Privacy answers after verifying relay logging and retention
- Exact-build export-compliance answers
- Final version/build selection and copyright confirmation
