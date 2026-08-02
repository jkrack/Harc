# HarcTransfer

Host-neutral finalized-capture metadata, host-bound recording manifests,
independently decodable audio-chunk metadata, receipt domain values, transfer
invariants, upload/outbox state machines, reconciliation, and codec negotiation
will live here.

Transport adapters call this shared state machine. gRPC and background HTTPS
must not implement separate definitions of durability or upload completeness.
The module imports neither gRPC nor host/client persistence.
