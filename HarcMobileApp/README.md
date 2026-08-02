# HarcMobileApp

This directory will contain the native iOS application target for Harc.

HarcMobile is an adopted, offline-capable client of a Harc host computer. Its
first responsibilities are microphone capture, durable local recovery, pairing,
lossless recording transfer, processing status, and permitted library access.

The directory is intentionally not wired into `project.yml` yet. It becomes a
real application target when the first compilable pairing/capture vertical slice
lands, keeping the existing Mac build unaffected by scaffolding. The first
shipping target is iPhone-only; iPad support follows its separate UI/device gate.

See:

- [Architecture](../docs/architecture/host-client-architecture.md)
- [Buildout plan](../docs/plans/2026-08-02-host-client-mobile-buildout.md)
- [Normative implementation specification](../docs/specs/2026-08-02-host-client-mobile-implementation-spec.md)
