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
inventory is six services, 25 RPCs, and 28 closed enums whose first and only
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

The contracts carry typed commands and metadata. Canonical user data remains
WAV, structured JSON, and OKF Markdown on the host.

Streaming RPC comments are normative V1 framing contracts. They define the
single first control message, contiguous indexes/offsets, bounded nonempty
frames, resume semantics, half-close EOF, and exact declared length/hash checks.
Adapters must stream into bounded storage and may never allocate from a
peer-supplied offset or declared total.
