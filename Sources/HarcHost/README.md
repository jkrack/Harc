# HarcHost

Transport-independent host application services will live here: authorization,
pairing coordination, device registry, upload staging and recovery, durable
commit/receipt, library operations, and processing scheduling.

The module mediates access to `HarcStore`; remote clients never receive database
or arbitrary filesystem access. It does not import gRPC, NIO, Bonjour, or
SwiftUI. Loopback tests, gRPC, and HTTPS call the same application services.
The mandatory Host-mode `harc-mcp` local adapter receives only the spec's exact
least-privilege method facade over those services; it never receives host
administration and never falls back to direct database writes while Host mode
owns the library.
