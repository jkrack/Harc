# Harc protocol contracts

This directory is the future source of truth for Harc's versioned protobuf and
gRPC contracts.

Planned files:

```text
harc_common.proto
harc_identity.proto
harc_pairing.proto
harc_transfer.proto
harc_library.proto
harc_processing.proto
harc_migration.proto
```

`Fixtures/harc-sas-words-v1.txt` is already normative protocol input. Its exact
SHA-256 and 11-bit index mapping are frozen in the implementation specification;
do not regenerate, sort, normalize, or localize it.

The directory is used as the source path for a generated-only
`HarcProtocolWire` target through `GRPCProtobufGenerator`. Handwritten validation
and domain conversions live in `Sources/HarcProtocol` and depend on that target.
Generated Swift is never edited by hand. A clean-checkout CI job verifies that
generation succeeds deterministically.

`HarcProtocolWire` depends directly on the `SwiftProtobuf` runtime as well as
the gRPC Swift Protobuf integration; generated message files import it directly.

Schema changes require compatibility fixtures and capability negotiation.
Additive fields are preferred; field numbers and enum values are never reused;
an incompatible semantic change increments the protocol major version.

The contracts carry typed commands and metadata. Canonical user data remains
WAV, structured JSON, and OKF Markdown on the host.
