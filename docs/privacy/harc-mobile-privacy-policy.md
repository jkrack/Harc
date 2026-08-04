# Harc Mobile Privacy Policy

**Effective date:** 2026-08-04

Harc is a local-first recording and knowledge-library application. Harc does
not operate a cloud account, relay, analytics, advertising, telemetry, or audio
processing service. The Harc developer cannot access recordings, transcripts,
summaries, or other content stored on a user's iPhone or adopted Host computer.

## Information Harc handles

Harc handles microphone audio only after the user explicitly starts a
recording. It stores a protected durable master on the iPhone. Harc may also
create transfer status, transcript, summary, speaker-label, tag, note, and
library-cache data needed to provide the requested app features.

Harc automatically transfers content only to the Harc Host computer that the
user adopts through the local pairing flow. That Host is owned or controlled by
the user, is authenticated cryptographically, and is not operated by or
accessible to the Harc developer or a third-party processing provider.

## Permissions

- **Microphone:** records audio only after the user taps the recording control.
- **Camera:** scans a short-lived pairing code displayed by the user's Host.
- **Local Network:** discovers and connects to the adopted Host.
- **Background audio:** permits an explicitly started recording to continue
  through ordinary lock and background transitions.

Harc does not request contacts, photo-library, precise-location, advertising,
or tracking permission. It does not include advertising or third-party
analytics SDKs.

## Storage, transfer, and retention

Recordings remain local when the Host or network is unavailable. The iPhone
retains its last durable audio copy until it has persistently verified a signed
receipt proving that the Host committed the canonical audio. The user's Host is
the canonical library owner and controls the retention of committed content.

Harc protects mobile files with iOS Data Protection and excludes capture,
transfer, and cache artifacts from device backup. Removing the app removes its
local app container; it does not delete a recording already committed to the
user's Host.

## User-directed export

Automatic synchronization never targets a cloud provider. A user may
explicitly export one selected local recording through the iOS share sheet.
Before bytes are handed to the selected destination, Harc explains that the
destination is outside the adopted-Host trust boundary. The destination's
privacy practices then apply.

## App Privacy disclosure

For the build described by this policy, the App Store Connect data-collection
answer is **No, we do not collect data from this app**. Apple defines collection
in terms of data transmitted off device in a way accessible to the developer or
third-party partners beyond servicing a real-time request. Harc's automatic
off-device path is the user's own adopted Host, which neither the developer nor
a third-party partner can access.

This answer must be re-reviewed before any build adds developer-accessible
servers, accounts, analytics, advertising, telemetry, crash collection, or
third-party processing.

## Questions

Privacy questions may be sent through the Harc support contact published with
the app. The public support address and the final hosted URL for this policy
must be entered in App Store Connect before external TestFlight or App Store
submission.
