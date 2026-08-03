# HarcProtocol

`HarcProtocol` is the handwritten validation and exact-wire layer above the
generated-only `HarcProtocolWire` target. Its current responsibilities are:

- fail-closed protobuf/domain conversions, protocol requirements, version
  compatibility, and canonical capability negotiation;
- exact independent binary codecs for transport sets, pairing tickets and
  transcripts, session transcripts, `HARCSO1` signed objects, `HARCAB1` audio
  batches, and `HARCPB1` processing bundles;
- the nine-row V1 signed-object registry and public authentication path, which
  verifies the admitted outer signature before payload interpretation and then
  derives all envelope mirror bindings from the untouched payload bytes;
- separate authentication purposes for already-durable historical evidence and
  first acceptance of an expiring command; the resulting assurance is retained
  so historical evidence cannot enter a live command API;
- first-command acceptance bound to a package-minted, complete active registry
  snapshot: protocol, library, authority, device key, grant/epoch, lifetime,
  status, and the operation's required scope are all checked;
- recursive validation of portable trust history, including every embedded
  signed grant/revocation, device-key binding, canonical order, and export-time
  bound, with explicit object/depth ceilings and expected-type admission before
  nested decode. Historical evidence never grants live authority;
- allocation-safe exact-container creation and decode: total size and count are
  preflighted before append, top-level repeated fields are wire-counted before
  generated protobuf parsing, and nested processing collections have explicit
  ceilings;
- binding authenticated `ProcessingArtifactV1` metadata to one exact
  `HARCPB1` body by byte length, SHA-256, artifact ID, origin recording ID,
  canonical-audio digest, protocol version, and coverage; and
- validating exact device-signed recording manifests into transfer-owned
  evidence, issuing exact host-signed pending-processing receipts, and
  validating those receipts against the pinned host plus every manifest/audio
  binding before producing cleanup-authorizing evidence; and
- loading the frozen pairing SAS dictionary from the SwiftPM resource bundle
  and verifying its exact protocol hash before use.

Capability policy deliberately has no production codec default. The composing
app must supply its supported lossless encodings, and raw canonical PCM remains
an explicit fixture-only opt-in, so this target cannot close the still-open
physical-device codec qualification gate by accident.

The `.proto` sources and schema generator configuration live in `Protos/`.
`Protos/Fixtures/harc-wire-v1-golden.txt` is the checked-in interoperability
corpus for exact bytes, while `scripts/check-harc-protocol-schemas.sh` and the
schema checksum inventory guard the frozen V1 surface.

This module must not open listeners, implement gRPC transport adapters, own host
storage, or contain UI behavior. Generated Swift is never edited by hand.
