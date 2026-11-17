# HarcMobileApp

This directory contains the native, iPhone-only iOS application target for
Harc. `project.yml` is the canonical project definition and generates the
`HarcMobile` application plus `HarcMobileAppTests` targets.

HarcMobile is an adopted, offline-capable client of a Harc host computer. Its
first responsibilities are microphone capture, durable local recovery, pairing,
lossless recording transfer, processing status, and permitted library access.

The target includes QR adoption, protected durable microphone capture,
checkpoint recovery, independently decodable lossless chunks, foreground gRPC
and background HTTPS transfer adapters, a receipt-governed outbox, recording
status, and the scoped Host Library cache. Library sync supports snapshots,
deltas, search, detail, verified audio playback, signed metadata mutations, and
explicit conflict handling.

Library always presents device-owned masters in **On This iPhone**, independently
of Host adoption, reachability, search, and transfer progress. Playback uses the
protected local master directly. **Host Library** is a separate cached/remote
section; its failures must not hide local audio. Forgetting a Host retires trust
and the saved route, without deleting captures or their durable outbox records.

Finalization registers the protected master in the outbox before audio-session
deactivation. If the process stops or the store callback fails between file
publication and registration, launch recovery validates the finalized metadata
and WAV and registers one local Library entry. Invalid orphans are reported and
preserved in place without blocking healthy Library entries or new capture;
directory setup and database failures still surface. The existing outbox remains the
idempotency boundary; recovery never manufactures a Host receipt or cleanup
permission. Synthetic fault tests live in `HarcMobileFinalizationRecoveryTests`
and `HarcMobileDurableMasterWriterTests`.

Retries reuse the durable Begin intent's complete profile, upload identity,
chunk descriptors, and protected file paths. A new compatible session does not
re-encode or re-freeze that attempt. Current Host authorization and session
compatibility still apply. The retry queue excludes recordings bound to another
Host and continues past per-recording failures, with each origin attempted once
per pass. The production error adapter reports file/buffer encoding failures as
per-recording retries with saved-audio messaging; they do not change codec
qualification. Pairing, cancellation, and `codecNotQualified` remain global stops.
Synthetic composition/queue regressions live in `HarcMobileUploadPreparationTests`.

Playback surfaces share explicit session ownership. Only the current owner may
deactivate playback, and capture claims priority before requesting microphone
permission through finalization. Row teardown and stale player callbacks must
never deactivate a newer player or the recorder. Test with
`HarcMobilePlaybackSessionTests`; the injected players/session hooks use no audio.

For external review without access to a developer LAN, the Library exposes a
bundled, read-only offline sample. Its synthetic audio is generated on device;
it contains no user data, requests no permission, performs no network operation,
and never enters the client cache or outbox. This is a reviewer path, not a
substitute for physical Host/capture/transfer qualification.

The implementation is not a release claim. Simulator compilation and the
physical-device capture/background-transfer matrix in the normative spec must
be green before App Store submission. TestFlight distribution is optional.
iPad support remains behind its separate UI/device gate.

The iOS 26 installation floor is not an inference-hardware floor. Core capture,
protected storage, transfer, playback, and Library access have no device-model
or on-device-inference gate. Future optional mobile inference must use a measured
runtime tier and fall back to the adopted Host without making capture unavailable.
The exact physical iPhone used for release qualification must be recorded with
its hardware identifier and OS build. No named marketing model is required.

See:

- [Architecture](../docs/architecture/host-client-architecture.md)
- [Buildout plan](../docs/plans/2026-08-02-host-client-mobile-buildout.md)
- [Normative implementation specification](../docs/specs/2026-08-02-host-client-mobile-implementation-spec.md)
- [Implementation and validation status](../docs/evidence/2026-08-03-host-client-mobile-implementation-status.md)
- [Runtime roles and pairing runbook](../docs/operations/runtime-roles-and-pairing.md)
- [App Store release-readiness runbook](../docs/operations/app-store-release-readiness.md)
- [Mobile privacy-policy source](../docs/privacy/harc-mobile-privacy-policy.md)

## Local after-save transcription

New finalized captures queue a read-only Apple SpeechTranscriber preview on a
compatible iPhone. The queue is independent of capture registration, adopted-Host
transfer and codec qualification. Capture and app backgrounding cancel inference;
registered work resumes on foreground/relaunch. Historical recordings are not
bulk-transcribed automatically. A local detail action can request one explicitly.
The first enqueue-to-marker interruption can leave an unrequested preview; the
protected audio/outbox still survives and the detail action retries it.

The native adapter uses only installed speech assets during routine processing.
Missing assets expose a separate, explicit Apple model download action. There is
no cloud recognizer fallback, AppleLLM wrapper or audio upload. Device/language
unavailability degrades transcription only. Model assets can require internet;
Apple manages their retention and updates.

Preview records retain origin, canonical PCM digest, frame count, native engine,
locale and final segment timing, under backup-excluded protected storage. They
never become Host receipts, canonical metadata, speaker identities or training
samples. Host transcript text wins when present; otherwise the phone preview can
be displayed distinctly. User edits and Host transcripts are never concatenated
with or overwritten by this preview.

Validate with HarcMobileLocalTranscriptionTests plus the mobile app build. These
synthetic tests do not qualify Apple model accuracy, physical device availability,
long-running resource use or the physical codec/Host round trip.
