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

The implementation is not a release claim. Simulator compilation and the
physical-device capture/background-transfer matrix in the normative spec must
be green before TestFlight. iPad support remains behind its separate UI/device
gate.

See:

- [Architecture](../docs/architecture/host-client-architecture.md)
- [Buildout plan](../docs/plans/2026-08-02-host-client-mobile-buildout.md)
- [Normative implementation specification](../docs/specs/2026-08-02-host-client-mobile-implementation-spec.md)
- [Implementation and validation status](../docs/evidence/2026-08-03-host-client-mobile-implementation-status.md)
- [Runtime roles and pairing runbook](../docs/operations/runtime-roles-and-pairing.md)
