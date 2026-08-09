# Harc Mobile Privacy Policy

**Effective date:** 2026-08-09

Harc is a local-first recording and knowledge-library application. Harc does
not operate a cloud account, advertising, app-use analytics, or audio processing
service. Harc offers an optional content-blind connection relay for reaching an
adopted Host across networks. The Harc developer and relay provider cannot
decrypt recordings, transcripts, summaries, or other content stored on a user's
iPhone or adopted Host computer.

## Information Harc handles

Harc handles microphone audio only after the user explicitly starts a
recording. It stores a protected durable master on the iPhone. Harc may also
create transfer status, transcript, summary, speaker-label, tag, note, and
library-cache data needed to provide the requested app features.

Harc automatically transfers content only to the Harc Host computer that the
user adopts through the local pairing flow. That Host is owned or controlled by
the user, is authenticated cryptographically, and is not operated by or
accessible to the Harc developer or a third-party processing provider.

## Optional Harc Remote relay

Direct local-network connections are preferred. If the user enables Harc
Remote, Cloudflare Durable Objects forward bounded ciphertext frames between
the client and adopted Host. The inner Harc connection retains pinned TLS and
application-layer authentication; the relay does not receive TLS keys or
plaintext content. Cloudflare necessarily processes minimum connection metadata
such as IP addresses, timing, route identifiers, and byte counts while servicing
the connection. Harc's target production configuration disables persistent
Cloudflare Workers Logs and Traces and exports no request telemetry. A distinct
staging release exercise may temporarily sample coarse operational fields for
named testers to verify reliability and redaction; it is not the production
service used by the App Store build. Harc never uses connection metadata for
advertising or tracking.

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

Cloudflare processes minimum connection metadata in real time when Harc Remote
is enabled. The production Worker is configured not to retain per-request
Workers Logs or Traces. Aggregate service counts used for capacity planning do
not contain recording content, device capabilities, or Harc secrets.

Harc protects mobile files with iOS Data Protection and excludes capture,
transfer, and cache artifacts from device backup. Removing the app removes its
local app container; it does not delete a recording already committed to the
user's Host.

## User-directed export

Automatic synchronization targets only the adopted Host. It may travel through
the optional content-blind relay, but the relay is not a storage or processing
destination. A user may explicitly export one selected local recording through
the iOS share sheet. Before bytes are handed to the selected destination, Harc
explains that the destination is outside the adopted-Host trust boundary. The
destination's privacy practices then apply.

## App Privacy disclosure

The App Store Connect answer is a release gate, not a permanent architectural
claim. Before submitting a relay-capable build, the Account Holder must verify
the exact Cloudflare configuration and retention behavior, including IP address
and operational metadata, then answer App Privacy for that exact build. A
relay-disabled build may use the prior **No, we do not collect data from this
app** answer only after confirming that no developer or third-party partner can
access transmitted data beyond servicing requests in real time.

The production relay was deployed on 2026-08-09 with persistent Workers logs
and traces disabled. The Account Holder must still verify the exact deployed
configuration when answering App Privacy for an iOS submission. If the
production operator enables per-request retention, the privacy manifest, this
policy, and the App Store Connect answer must all change before that
configuration serves an App Store build.

This review must be repeated whenever a build changes relay logging or
retention, developer-accessible servers, accounts, analytics, advertising,
telemetry, crash collection, or third-party processing.

## Questions

Privacy questions may be submitted through the public
[Harc support tracker](https://github.com/jkrack/Harc/issues). This policy's
current public URL is the canonical document in the public Harc repository and
must match the URL packaged in the app and entered in App Store Connect.
Optional TestFlight distribution does not replace this requirement.
