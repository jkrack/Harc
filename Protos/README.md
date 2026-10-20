# Harc protocol contracts

This directory is the source of truth for Harc's V1 protobuf and gRPC
contracts. It contains exactly seven schemas:

```text
harc_common.proto
harc_identity.proto
harc_pairing.proto
harc_transfer.proto
harc_library.proto
harc_processing.proto
harc_migration.proto
```

All schemas use `proto3`, package `harc.v1`, and Swift prefix `Harc_V1_`. The V1
inventory is six services, 27 RPCs, and 29 closed enums whose first and only
zero value is `*_UNSPECIFIED`. Protobuf maps, database/row identifiers, and host
filesystem paths are forbidden. `http_path` is the single reviewed exception to
the path-shaped-name guard because it is a capability-bound HTTP request target,
not a host path.

The directory is used as the source path for a generated-only
`HarcProtocolWire` target through `GRPCProtobufGenerator`. Handwritten validation
and domain conversions live in `Sources/HarcProtocol` and depend on that target.
`Module.swift` is a declaration-free plugin-discovery sentinel. Generated Swift
is never edited or checked in.

The generator/runtime toolchain is exactly pinned in `Package.swift`:
`grpc-swift-2` 2.4.2, `grpc-swift-protobuf` 2.4.1, and `swift-protobuf` 1.38.1.
`HarcProtocolWire` depends directly on `SwiftProtobuf` because generated message
files import it, as well as on the gRPC Swift Protobuf integration.

Run `scripts/check-harc-protocol-schemas.sh` after every schema or generator
configuration change. It guards the exact file/service/RPC/enum inventory,
package and prefix, generator settings, prohibited wire concepts, and the
reviewed SHA-256 inventory in
`Fixtures/harc-protocol-sources-v1.sha256`. Refreshing those checksums is an
explicit compatibility decision, not a formatting side effect.

`Fixtures/harc-sas-words-v1.txt` is normative protocol input and is copied into
the `HarcProtocol` SwiftPM resource bundle. Its exact SHA-256 and bit-to-index
mapping are frozen; do not regenerate, sort, normalize, or localize it.
`Fixtures/harc-wire-v1-golden.txt` freezes the reviewed exact-wire corpus for all
nine signed registry rows, trust bootstrap/session values, exact containers,
and protobuf compatibility cases.

Schema changes require compatibility fixtures and capability negotiation.
Additive fields are preferred; field numbers and enum values are never reused;
an incompatible semantic change increments the protocol major version.

The 2026-09-05 Library detail addition uses previously unused field 8 for
`capture_needs_review`. It is an advisory presentation field, not a required
capability, authorization input, signed capture field, or completeness receipt.
Older readers may ignore it; newer readers accept its absence. False means no
reported warning, not proof of complete audio. Origin-bound discontinuities
retain their existing validation. The schema inventory refresh is covered by
exact field-8 bytes and absent-field compatibility tests in DomainConversionsTests.

The contracts carry typed commands and metadata. Canonical user data remains
WAV, structured JSON, and OKF Markdown on the host.

The September 7 speaker-evidence extension defines `SpeakerEvidenceSnapshotV1`
and `BoundSpeakerEmbeddingObservationV1`. `SubmitSpeakerObservationRequestV1`
now has additive field 3, `bound_observation`; field 2 remains the legacy form.
Exactly one form is allowed. Bound requests require critical field 3, required
feature `harc.speaker-evidence.v1`, and that feature in the authenticated session's
negotiated capabilities. Older readers must reject the critical/required fields.
A request declaring bound support but carrying only a legacy observation is invalid.

The Host routes bound requests to selected-artifact authentication and transactional
speaker admission. Legacy requests remain pending-review observations without
canonical naming authority. No new RPC or enum value is added. The schema checksum
inventory deliberately records this additive field; generated Swift remains plugin
output only. `SpeakerEvidenceBindingTests` covers negotiation, ambiguity, downgrade
rejection and round trips. Feature advertisement remains disabled. The desktop sender now has a negotiated
bound path, but these schema tests do not qualify deployed transport or accuracy.

Streaming RPC comments are normative V1 framing contracts. They define the
single first control message, contiguous indexes/offsets, bounded nonempty
frames, resume semantics, half-close EOF, and exact declared length/hash checks.
Adapters must stream into bounded storage and may never allocate from a
peer-supplied offset or declared total.

`ProcessingStatusV1.selected_edge_bundle_sha256` is an additive optional field 7.
It identifies the Host's current edge selection after its local retained files are
checked; it carries no filesystem paths. Absence does not authorize legacy numeric
speaker mapping. This is an advisory status snapshot: bound observation admission
must still authenticate exact evidence and recheck selection in its transaction.
The field is returned through both processing status and submission responses.
# Host speaker processing status

`ProcessingStatusV1.host_speaker_outcome` is an additive, optional field on the
existing authenticated own-recording status response. Absence means unknown,
including older Hosts and recordings without a retained outcome. It is not a
substitute for generic processing/projection state or a proof of recognition
accuracy. No filesystem paths or person names are added.

The outcome binds canonical recording/audio, Host producer identity and the exact
Host artifact. It distinguishes disabled diarization from completed diarization,
and inventories missing evidence separately from evaluated clusters. Evaluated
clusters carry the exact evidence digest, decision operation, disposition and
recognition-pack revision. These fields describe a historical evaluation; they
must not silently upgrade a nonmatch or imply current name accuracy.

`validatedHostSpeakerOutcome` validates this response against caller-supplied
recording, origin, audio and Host identity. Callers must obtain those expectations
from the authenticated adoption and durable receipt, not the response itself.
Contradictory edge selection, non-ready status, incomplete evaluation fields,
unknown enum values and duplicate clusters/operations fail validation.

The Host service serializes retained outcomes on both lookup routes. Direct
pinned-TLS and local encrypted-relay tests exercise the new field after replacing
an edge artifact with a Host transcript. The desktop client consumes this outcome for retained outboxes and schedules
status reviews even without local embeddings. Retained-master/sidecar cleanup,
Host re-evaluation and full route-lifecycle qualification remain open. Feature
advertisement and speaker-bearing edge acceptance remain unchanged.
