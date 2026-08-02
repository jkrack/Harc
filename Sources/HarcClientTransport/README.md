# HarcClientTransport

Client-side gRPC Swift 2, HTTPS/background URLSession adapters, Bonjour
discovery, pinned host verification, session management, and connection state
live here.

Background URLs use the DNS-SD `.local` target plus the host's persisted upload
port. Terminal route failures use completion-event Bonjour rediscovery and
idempotently reschedule the same immutable body/capability; route hints never
establish trust.

It depends on protocol, identity, and transfer contracts but does not own the
outbox, cache, receipt persistence, or application UI.
