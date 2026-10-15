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
per pass. Pairing and the closed codec gate remain global stops. Synthetic
composition/queue regressions live in `HarcMobileUploadPreparationTests`.

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

The iOS 18 installation floor is not an inference-hardware floor. Core capture,
protected storage, transfer, playback, and Library access have no device-model
or on-device-inference gate. Future optional mobile inference must use a measured
runtime tier and fall back to the adopted Host without making capture unavailable.
The oldest declared launch iPhone still requires physical qualification.

See:

- [Architecture](../docs/architecture/host-client-architecture.md)
- [Buildout plan](../docs/plans/2026-08-02-host-client-mobile-buildout.md)
- [Normative implementation specification](../docs/specs/2026-08-02-host-client-mobile-implementation-spec.md)
- [Implementation and validation status](../docs/evidence/2026-08-03-host-client-mobile-implementation-status.md)
- [Runtime roles and pairing runbook](../docs/operations/runtime-roles-and-pairing.md)
- [App Store release-readiness runbook](../docs/operations/app-store-release-readiness.md)
- [Mobile privacy-policy source](../docs/privacy/harc-mobile-privacy-policy.md)
