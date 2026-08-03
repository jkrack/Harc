#if canImport(Network)
import GRPCNIOTransportHTTP2TransportServices
import HarcHost
import NIOCore
import NIOTransportServices
import Network

/// Adapts a process-owned `NWListener` to gRPC Swift's custom HTTP/2 server
/// transport. The host owns listener construction so it can apply Harc's exact
/// TLS policy and attach `_harc._tcp` Bonjour metadata before gRPC starts it.
public struct HarcGRPCNWListenerFactory: HTTP2ServerTransport.ListenerFactory {
    public let eventLoopGroup: any EventLoopGroup

    private let listenerProvider: @Sendable () async throws -> NWListener

    /// Only the resident generation controller receives this one-shot lease.
    /// Consumption and current-generation validation happen at listener bind.
    package init(
        lease: HostTransportListenerLease,
        port: NWEndpoint.Port,
        eventLoopGroup: any EventLoopGroup = NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup,
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.listenerProvider = {
            let material = try await lease.consume(for: .grpcControl)
            let parameters = try await HarcNetworkTLS13Policy.serverParameters(
                material: material,
                protocol: .grpcHTTP2
            )
            return try NWListener(using: parameters, on: port)
        }
    }

    /// Compile-only seam for transport unit tests. Production composition
    /// cannot access this unready path outside the module.
    init(
        eventLoopGroup: any EventLoopGroup = NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup,
        unreadyListenerProvider: @Sendable @escaping () throws -> NWListener
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.listenerProvider = { try unreadyListenerProvider() }
    }

    public func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator
    ) async throws -> NIOAsyncChannel<
        HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel,
        Never
    > {
        let listener = try await listenerProvider()

        return try await NIOTSListenerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                listenerConfigurator.configure(channel: channel)
            }
            .withNWListener(listener) { channel in
                connectionConfigurator.configure(
                    channel: channel,
                    tls: .configured(requireALPN: true)
                )
            }
    }
}
#endif
