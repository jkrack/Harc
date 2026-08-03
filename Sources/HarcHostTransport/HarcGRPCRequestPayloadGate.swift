#if canImport(Network)
import GRPCCore
import HarcProtocol
import NIOCore
import NIOHTTP2

package enum HarcGRPCRequestPayloadGateError: Error, Equatable, Sendable {
    case missingInitialPath
    case duplicateInitialPath
    case compressedRequestMessage
    case requestMessageTooLarge(limit: Int, declared: Int)
    case inboundFileRegion
    case truncatedRequestMessage
}

/// Enforces Harc's method-specific gRPC request ceilings from the five-byte
/// gRPC message prefix before `GRPCServerStreamHandler` buffers or decodes the
/// protobuf payload. The transport's global ceiling is the audio maximum; this
/// gate preserves the smaller control ceiling on every non-audio method.
package enum HarcGRPCRequestPayloadGate {
    package static let maximumControlPayloadBytes = 1 * 1_024 * 1_024
    package static let maximumAudioPayloadBytes = 5 * 1_024 * 1_024

    private static let uploadChunksPath = "/\(Harc_V1_RecordingTransferService.Method.UploadChunks.descriptor.fullyQualifiedMethod)"

    package static func maximumPayloadBytes(for path: String) -> Int {
        path == uploadChunksPath
            ? maximumAudioPayloadBytes
            : maximumControlPayloadBytes
    }
}

/// One instance belongs to one HTTP/2 request stream.
final class HarcGRPCRequestPayloadGateHandler:
    ChannelInboundHandler, RemovableChannelHandler
{
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = HTTP2Frame.FramePayload

    private var maximumPayloadBytes: Int?
    private var prefixBytes: [UInt8] = []
    private var remainingMessageBytes = 0
    private var receivedInitialHeaders = false
    private var rejected = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        let payload = unwrapInboundIn(data)
        do {
            switch payload {
            case .headers(let headers):
                if !receivedInitialHeaders {
                    let paths = headers.headers[":path"]
                    guard !paths.isEmpty else {
                        throw HarcGRPCRequestPayloadGateError.missingInitialPath
                    }
                    guard paths.count == 1 else {
                        throw HarcGRPCRequestPayloadGateError.duplicateInitialPath
                    }
                    receivedInitialHeaders = true
                    maximumPayloadBytes = HarcGRPCRequestPayloadGate
                        .maximumPayloadBytes(for: paths[0])
                } else if headers.endStream {
                    try requireMessageBoundary()
                }

            case .data(let frame):
                guard let maximumPayloadBytes else {
                    throw HarcGRPCRequestPayloadGateError.missingInitialPath
                }
                switch frame.data {
                case .byteBuffer(var buffer):
                    try inspect(
                        &buffer,
                        maximumPayloadBytes: maximumPayloadBytes
                    )
                case .fileRegion:
                    // TLS request bodies cannot legitimately arrive as a
                    // sendfile-backed region. Never bypass prefix inspection.
                    throw HarcGRPCRequestPayloadGateError.inboundFileRegion
                }
                if frame.endStream { try requireMessageBoundary() }

            default:
                break
            }
            context.fireChannelRead(data)
        } catch {
            rejected = true
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    private func inspect(
        _ buffer: inout ByteBuffer,
        maximumPayloadBytes: Int
    ) throws {
        while buffer.readableBytes > 0 {
            if remainingMessageBytes > 0 {
                let consumed = min(
                    remainingMessageBytes,
                    buffer.readableBytes
                )
                buffer.moveReaderIndex(forwardBy: consumed)
                remainingMessageBytes -= consumed
                continue
            }

            let needed = 5 - prefixBytes.count
            let count = min(needed, buffer.readableBytes)
            prefixBytes.append(
                contentsOf: buffer.readBytes(length: count) ?? []
            )
            guard prefixBytes.count == 5 else { continue }

            guard prefixBytes[0] == 0 else {
                throw HarcGRPCRequestPayloadGateError
                    .compressedRequestMessage
            }
            let declared = Int(prefixBytes[1]) << 24
                | Int(prefixBytes[2]) << 16
                | Int(prefixBytes[3]) << 8
                | Int(prefixBytes[4])
            prefixBytes.removeAll(keepingCapacity: true)
            guard declared <= maximumPayloadBytes else {
                throw HarcGRPCRequestPayloadGateError
                    .requestMessageTooLarge(
                        limit: maximumPayloadBytes,
                        declared: declared
                    )
            }
            remainingMessageBytes = declared
        }
    }

    private func requireMessageBoundary() throws {
        guard prefixBytes.isEmpty, remainingMessageBytes == 0 else {
            throw HarcGRPCRequestPayloadGateError.truncatedRequestMessage
        }
    }
}
#endif
