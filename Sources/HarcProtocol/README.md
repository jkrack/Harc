# HarcProtocol

Validated domain conversions, protocol-version and capability policy, and the
handwritten service surface will live here. A generated-only `HarcProtocolWire`
target is built from `Protos/` through `GRPCProtobufGenerator`.

This module must not contain host storage or UI behavior. The `.proto` sources
of truth live in `Protos/`; generated Swift is never edited by hand.
