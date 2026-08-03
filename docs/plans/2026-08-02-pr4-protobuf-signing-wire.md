# PR 4 — Protobuf and signing wire contracts

**Status:** Complete

**Date:** 2026-08-02

**Normative source:**
[Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

## Slice boundary

PR 4 activates `HarcProtocolWire` and `HarcProtocol`. It freezes the seven
protobuf schemas, generated gRPC service descriptors, exact non-protobuf
security encodings, signed-object registry, domain conversions, and
compatibility/golden fixtures. It does not open a socket, start Bonjour, issue a
production TLS certificate, publish canonical audio, or change Standalone mode.

The physical codec gate from PR 3 remains open. Protocol messages therefore
carry the negotiated codec/container as registered identifiers; this slice does
not select a release codec or make PR 5's decoder decision. Capability policy
requires each composing app to provide its supported encoding set, has no
production codec default, and permits raw canonical PCM only through an
explicit fixture-only opt-in.

## Toolchain and target graph

- `grpc-swift-2` 2.4.2 provides `GRPCCore`.
- `grpc-swift-protobuf` 2.4.1 provides `GRPCProtobuf` and the
  `GRPCProtobufGenerator` build plugin.
- `swift-protobuf` 1.38.1 is a direct `HarcProtocolWire` dependency because
  generated message sources import it.
- `Protos/` is the only schema source. `HarcProtocolWire` contains generated
  DTOs and service descriptors only.
- `HarcProtocol` depends on `HarcProtocolWire`, `HarcDomain`, `HarcIdentity`,
  and `HarcTransfer`; storage, transport listeners, and UI stay out.
- The frozen SAS word list is copied into the `HarcProtocol` SwiftPM resource
  bundle. Production loading verifies the exact SHA-256 before phrase
  derivation; tests and callers do not inject an unverified replacement.

## Schema split

| File | Contract |
| --- | --- |
| `harc_common.proto` | Versions, requirements, public IDs, exact signed-object carrier, canonical formats, errors, common views |
| `harc_identity.proto` | Device grants/revocations, host information, capability negotiation, session challenge/proof |
| `harc_pairing.proto` | Ticket-bound pairing claim/proof/status RPC messages |
| `harc_transfer.proto` | Upload profile, declarations, chunk streaming, reconciliation, manifest/ACK/receipt, background capability |
| `harc_library.proto` | Anchored snapshot, deltas, recording detail/audio, typed search, compare-and-swap metadata mutation |
| `harc_processing.proto` | Signed artifact metadata, bundle entries, client-streaming submission, processing status |
| `harc_migration.proto` | Historical trust export payloads; no remote administration service |

All schemas use `proto3`, package `harc.v1`, and Swift prefix `Harc_V1_`.
Field numbers and enum values are append-only and never reused. No `map` field,
database row ID, or filesystem path is permitted.

## Frozen compatibility decisions

- V1 is protocol major 1. Minor changes are additive. Unsupported majors fail;
  peers select one mutually supported minor.
- `ProtocolRequirementsV1` carries sorted, duplicate-free
  `required_features` and `critical_field_numbers`. Unknown required features or
  a field number marked critical but unknown to the selected minor fail closed.
  Ordinary unknown additive fields may be retained only with their untouched
  containing bytes.
- Registered, extensible identifiers such as codec, container, capability,
  schema, model, and reason identifiers are bounded canonical ASCII strings.
  Closed state machines use protobuf enums with `UNSPECIFIED = 0`, which is
  rejected at the domain boundary.
- UUIDs are 16 RFC 4122 bytes and digests are 32 raw bytes. Generated DTOs do
  not expose host paths or GRDB representations.
- `UploadChunks` is bidirectional streaming so each bounded chunk can receive a
  durable or typed rejection result without waiting for the whole recording.
  `GetAudio` is server streaming. `SubmitOwnArtifact` is client streaming. These
  choices freeze only service shape; transport adapters land in PR 6.
- `GetAudio` and `SubmitOwnArtifact` also carry normative V1 stream-framing
  comments: one first descriptor/begin message, contiguous offsets/indexes,
  bounded nonempty frames, defined resume behavior, half-close as EOF, bounded
  streaming storage, and exact declared length/hash verification. No adapter may
  allocate from a peer-supplied offset or total.
- Snapshot and delta pages contain typed, path-free views. They are not generic
  JSON or opaque database pages.
- Metadata mutation uses a closed typed `oneof`; V1 has no generic patch field
  and no remote delete operation.
- Host transport sets, pairing tickets/transcripts, session transcripts,
  signed-envelope headers, and signed-object framing use the specification's
  independent canonical binary encodings. A protobuf message with a similar
  semantic name never replaces those bytes.
- Public signed-object authentication decodes the registered payload from its
  untouched bytes and derives all envelope mirrors internally, but only after
  the admitted outer signature has been verified. Callers must choose either
  historical-evidence verification or first command acceptance; that assurance
  remains on the authenticated result. First acceptance requires a trusted time
  and a package-minted full registry snapshot bound to the protocol, library,
  authority, device key, active status, grant/epoch, lifetime, and required
  operation scope.
- Portable trust history is provenance only. Validation recursively verifies
  each embedded grant and revocation frame against the exporting authority,
  checks device ID/public-key and library/authority bindings, canonical
  epoch/object-ID ordering, and issuance no later than export. Explicit device,
  object-count, and depth ceilings apply, and each carrier must match its
  expected grant/revocation tuple before nested payload decode. It cannot
  authorize a live grant, session, capability, listener, or processing command.

## Exact-byte and signing rules

1. A protobuf payload intended for signing is serialized once, then the exact
   bytes are hashed, signed, persisted, and transmitted.
2. Verification parses the exact framed object while retaining the original
   payload bytes. It never hashes a decoded-and-reserialized message.
3. The independent envelope header is canonical big-endian bytes. Signatures
   are raw 64-byte P-256 `r || s`, normalized low-S when created and rejected if
   high-S when received.
4. The `(message_type, payload_type, signer class)` tuple must be one of the nine
   V1 registry rows. Every zero, N/A, mirror, expiry, revision, authority, and
   operation constraint is checked before payload interpretation.
5. Framed signed-object identity hashes the complete untouched frame, not only
   the protobuf payload.
6. Ticket, transport-set, transcript, signed-object, audio-batch, and processing-
   bundle decoders are length-first, allocation-bounded, reject trailing bytes,
   and enforce canonical order and uniqueness.
7. An edge-processing artifact becomes usable only through
   `HarcValidatedProcessingSubmissionV1`, which binds authenticated signed
   `ProcessingArtifactV1` metadata to the exact `HARCPB1` body by declared byte
   length and SHA-256, then checks artifact ID, origin recording ID,
   canonical-audio digest, protocol version, and exact coverage equality. The
   caller supplies the canonical recording frame count so every range is
   checked against the published audio extent.

## Bounded-container assumptions

- `HARCAB1` is capped at a 1 MiB protobuf header, 4 MiB per encoded chunk, 64
  entries, and 64 MiB total exact bytes.
- `HARCPB1` is capped at a 1 MiB protobuf header, 16 MiB per entry, eight
  entries, 32 MiB total exact bytes, and 8 MiB of decoded UTF-8 text across all
  typed entries. The 8 MiB decoded-text ceiling is the explicit PR 4 V1 safety
  assumption and requires deliberate compatibility review to change.
- A standalone processing-bundle decode may validate structure before the
  canonical recording length is known, but publication/submission validation
  must supply that frame count and recheck every bounded range.
- Both container creators precompute count and exact total size before append.
  Decoders count repeated header fields directly on the bounded protobuf wire
  before generated parsing. Transcript utterances/words, diarization turns,
  coverage ranges, and summary model revisions have explicit V1 collection
  ceilings and are preflighted before their generated arrays are materialized.

## Validation and compatibility fixtures

- A clean build regenerates all `.pb.swift` and `.grpc.swift` sources through
  the pinned plugin; generated source is never edited or checked in.
- `scripts/check-harc-protocol-schemas.sh` and
  `Protos/Fixtures/harc-protocol-sources-v1.sha256` guard exactly seven schemas,
  six services, 25 RPCs, 28 enum-zero contracts, generator configuration, and
  the ban on maps/database identifiers/host paths (apart from reviewed
  capability-bound `http_path`).
- Focused tests cover every domain conversion, invalid length/value/enum,
  unknown required feature/critical field, unsupported major, canonical order,
  service method inventory, and decoded-control size ceiling.
- The checked-in `Protos/Fixtures/harc-wire-v1-golden.txt` corpus pins all nine
  signed registry rows plus transport set, pairing ticket/URI/transcript/SAS,
  session transcript, exact `HARCAB1`/`HARCPB1` containers, object IDs, low-S
  signatures, and exact payload preservation. Expected bytes are reviewed
  artifacts and are never regenerated inside a test.
- Compatibility fixtures include the current V1.0 payload and an
  additive-unknown-field form of the same message. Unknown optional fields
  survive only through exact-byte forwarding; unknown required or critical
  inputs are rejected.
- Final gates include `swift build --target HarcProtocolWire`, focused protocol
  tests, full Swift tests with isolated reruns for documented load timing, Xcode
  project generation, unsigned macOS arm64 build, generic iOS Simulator builds,
  dependency/import-boundary checks, and `git diff --check`.

## Deferred to later slices

- PR 5: canonical decode/assembly, signed receipt issuance, and publication.
- PR 6: gRPC/HTTPS adapters, pinned TLS, Bonjour, QR controller, sessions, and
  authenticated local IPC.
- PR 7 onward: production iOS capture/outbox, mobile cache/UI, and desktop
  Client mode.
