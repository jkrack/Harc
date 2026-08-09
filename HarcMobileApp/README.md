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
