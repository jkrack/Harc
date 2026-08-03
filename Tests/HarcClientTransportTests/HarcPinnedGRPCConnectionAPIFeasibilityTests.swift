#if canImport(Network)
import HarcClientTransport
import Testing

@Suite("Pinned gRPC production API feasibility")
struct HarcPinnedGRPCConnectionAPIFeasibilityTests {
    @Test("the public factory owns construction of a pinned bootstrap channel")
    func publicFactoryCompiles() {
        let factory: (
            String,
            Int,
            String?,
            HarcTransportTrustCoordinator
        ) async throws -> HarcPinnedGRPCConnection = HarcPinnedGRPCConnection.connect
        _ = factory

        func requireBootstrapTransport<T: HarcBootstrapRPCTransport>(_: T.Type) {}
        requireBootstrapTransport(HarcPinnedGRPCConnection.self)
    }
}
#endif
