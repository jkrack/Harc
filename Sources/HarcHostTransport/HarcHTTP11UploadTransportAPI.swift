#if canImport(Network)
import Foundation
import HarcHost
import Network
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOTransportServices

/// Compile-time boundary for the separate background-upload HTTP/1.1 adapter.
/// Routing, limits, authorization, and listener lifecycle are added by PR 6's
/// transport implementation rather than shared with the gRPC HTTP/2 listener.
public enum HarcHTTP11UploadTransportAPI {
    public typealias RequestHead = HTTPRequestHead
    public typealias ResponseHead = HTTPResponseHead

    public static let requiredALPN = HarcTLSListenerProtocol.backgroundUploadHTTP1.rawValue

    /// Creates the independent TLS 1.3/http/1.1 listener by consuming the
    /// resident generation's upload-role lease at bind time.
    package static func makeListener(
        lease: HostTransportListenerLease,
        port: NWEndpoint.Port
    ) async throws -> NWListener {
        let material = try await lease.consume(for: .backgroundUpload)
        let parameters = try await HarcNetworkTLS13Policy.serverParameters(
            material: material,
            protocol: .backgroundUploadHTTP1
        )
        return try NWListener(using: parameters, on: port)
    }

    public static func listenerBootstrap(
        eventLoopGroup: any EventLoopGroup
    ) -> NIOTSListenerBootstrap {
        NIOTSListenerBootstrap(group: eventLoopGroup)
    }

    public static func data(copyingReadableBytes buffer: ByteBuffer) -> Data {
        buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) ?? Data()
    }
}
#endif
