#if canImport(Network)
import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOTransportServices
import Network

package enum HarcGRPCTransportSourceBridgeError:
    Error, Equatable, Sendable
{
    case missingParentConnectionChannel
    case missingNetworkConnection
    case eventLoopMismatch
}

/// Carries a transport-derived source identity across gRPC Swift's current
/// `ServerContext` gap. The value is created from the accepted
/// `NWConnection.endpoint`, authenticated by the host, and inserted ahead of
/// `GRPCServerStreamHandler`; it is never accepted as client authority.
package enum HarcGRPCTransportSourceBridge {
    package static let metadataKey =
        "x-harc-internal-source-binding-bin"

    package static func initializeStream(
        channel: any Channel,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider
    ) -> EventLoopFuture<Void> {
        guard let connectionChannel = channel.parent else {
            return channel.eventLoop.makeFailedFuture(
                HarcGRPCTransportSourceBridgeError
                    .missingParentConnectionChannel
            )
        }

        return connectionChannel.getOption(NIOTSChannelOptions.connection)
            .flatMapThrowing { connection in
                // NIOHTTP2 stream channels inherit their parent's event loop.
                // Keep the invariant explicit because synchronous insertion is
                // what guarantees this handler precedes gRPC's existing one.
                guard channel.eventLoop.inEventLoop else {
                    throw HarcGRPCTransportSourceBridgeError.eventLoopMismatch
                }
                guard let connection else {
                    throw HarcGRPCTransportSourceBridgeError
                        .missingNetworkConnection
                }
                let token = try sourceBindingProvider
                    .authenticatedTransportSourceToken(
                        for: connection.endpoint
                    )
                try channel.pipeline.syncOperations.addHandler(
                    HarcGRPCTransportSourceMetadataHandler(token: token),
                    position: .first
                )
            }
    }
}

/// Removes every client-supplied value for Harc's reserved key and installs
/// exactly one host-authenticated binary value on the initial request headers.
/// Later header blocks are scrubbed without adding another value.
final class HarcGRPCTransportSourceMetadataHandler:
    ChannelInboundHandler, RemovableChannelHandler
{
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = HTTP2Frame.FramePayload

    private let encodedToken: String
    private var receivedInitialHeaders = false

    init(token: Data) {
        self.encodedToken = token.base64EncodedString()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .headers(var headers) = payload else {
            context.fireChannelRead(data)
            return
        }

        headers.headers.remove(
            name: HarcGRPCTransportSourceBridge.metadataKey
        )
        if !receivedInitialHeaders {
            receivedInitialHeaders = true
            headers.headers.add(
                name: HarcGRPCTransportSourceBridge.metadataKey,
                value: encodedToken,
                indexing: .neverIndexed
            )
        }
        context.fireChannelRead(wrapInboundOut(.headers(headers)))
    }
}
#endif
