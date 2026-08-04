# HarcTransfer

Host-neutral finalized-capture metadata, host-bound recording manifests,
independently decodable audio-chunk metadata, receipt domain values, transfer
invariants, upload/outbox state machines, reconciliation, and codec negotiation
live here.

Transport adapters call this shared state machine. gRPC and background HTTPS
must not implement separate definitions of durability or upload completeness.
The module imports neither gRPC nor host/client persistence.

`RecordingManifestEvidenceValidating`, `RecordingReceiptIssuing`, and
`RecordingReceiptEvidenceValidating` are the dependency-injection boundary for
canonical publication and receipt verification. Host code depends only on these
transfer-owned interfaces and opaque exact objects; `HarcProtocol` supplies the
protobuf/signature implementation. Receipt
claims derive origin and audio identity from validated manifest evidence so a
caller cannot assemble mismatched host, upload, manifest, or PCM fields.
