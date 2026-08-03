#if canImport(Network)
import GRPCNIOTransportHTTP2TransportServices
import NIOCore
import NIOTransportServices
import Network

/// Adapts a process-owned `NWListener` to gRPC Swift's custom HTTP/2 server
/// transport. The host owns listener construction so it can apply Harc's exact
/// TLS policy and attach `_harc._tcp` Bonjour metadata before gRPC starts it.
public struct HarcGRPCNWListenerFactory: HTTP2ServerTransport.ListenerFactory {
    public let eventLoopGroup: any EventLoopGroup

    private let listenerProvider: @Sendable () throws -> NWListener

    public init(
        eventLoopGroup: any EventLoopGroup = NIOTSEventLoopGroup.singletonNIOTSEventLoopGroup,
        listenerProvider: @Sendable @escaping () throws -> NWListener
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.listenerProvider = listenerProvider
    }

    public func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator
    ) async throws -> NIOAsyncChannel<
        HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel,
        Never
    > {
        let listener = try listenerProvider()

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
