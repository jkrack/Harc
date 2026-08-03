# HarcHostTransport

Host-side gRPC Swift 2 on HTTP/2, a separate narrow SwiftNIO HTTP/1.1 background
upload listener, Bonjour advertisement, pinned TLS, session interception,
mutually audit-token/code-signing-pinned same-UID Unix IPC for the least-privilege `harc-mcp`
method allowlist, limits, and transport-to-domain conversion
live here.

This adapter depends on `HarcHost` and `HarcProtocol`. It makes no canonical
authorization, commit, or library-policy decision itself.

Bonjour publication is generation-scoped and uses `NWListener.Service` on the
same concrete `_harc._tcp` listener consumed by gRPC. Startup waits for the
separate upload listener and DNS-SD registration; withdrawal tombstones the
generation before clearing the service. TXT contains only the strict V1
display/version/capability/upload-port hints and never identity or credentials.
