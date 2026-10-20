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

`HarcBonjourDiscoveryBrowserV1` is inert until an explicit caller action starts
an `NWBrowser` for `_harc._tcp`. Parsed results remain explicitly untrusted
route candidates until pinned TLS and authenticated host-info verification
succeeds; malformed or extended TXT records fail closed.

Foreground recording transfer reuses the exact pinned gRPC channel which opened
the session. Each RPC carries one canonical `HarcSession` authorization value;
chunk messages and acknowledgements remain bidirectionally streamed with
backpressure instead of being accumulated in memory.

Background callbacks can affect durable transfer state only while their mapped
task is active. Terminal and retired callbacks do not validate against replacement
credentials or report an ACK. Active callbacks retain exact-request, HTTP-response,
current-trust, and signed-ACK checks. Transport obtains an authorization-filtered
mapping snapshot before reading jobs so stale Host work is canceled independently
of current authorized tasks. This never restores a revoked grant or removes a
local master.
