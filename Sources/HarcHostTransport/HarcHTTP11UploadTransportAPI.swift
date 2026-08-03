#if canImport(Network)
import Foundation
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
