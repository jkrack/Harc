/// HarcProtocol is the supported protocol surface for transport adapters.
/// Re-exporting the generated-only module lets those adapters conform to the
/// generated gRPC services without adding a forbidden direct dependency on
/// HarcProtocolWire. Codec validation and domain conversion remain owned here.
@_exported import HarcProtocolWire
