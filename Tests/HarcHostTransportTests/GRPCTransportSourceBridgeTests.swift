#if canImport(Network)
import Foundation
@testable import HarcHostTransport
import NIOEmbedded
import NIOHPACK
import NIOHTTP2
import Testing

@Suite("gRPC transport source bridge")
struct GRPCTransportSourceBridgeTests {
    @Test("reserved client metadata is replaced once and scrubbed from trailers")
    func reservedMetadataReplacement() throws {
        let token = Data(repeating: 0xA3, count: 64)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HarcGRPCTransportSourceMetadataHandler(token: token)
        )
        defer { _ = try? channel.finish() }

        var initial = HPACKHeaders()
        initial.add(name: ":method", value: "POST")
        initial.add(
            name: HarcGRPCTransportSourceBridge.metadataKey,
            value: Data(repeating: 0x01, count: 64).base64EncodedString()
        )
        initial.add(
            name: HarcGRPCTransportSourceBridge.metadataKey,
            value: Data(repeating: 0x02, count: 64).base64EncodedString()
        )
        try channel.writeInbound(
            HTTP2Frame.FramePayload.headers(.init(headers: initial))
        )

        let readInitial: HTTP2Frame.FramePayload? = try channel.readInbound(
            as: HTTP2Frame.FramePayload.self
        )
        let forwardedInitial = try #require(readInitial)
        guard case .headers(let initialHeaders) = forwardedInitial else {
            Issue.record("Expected an initial headers payload")
            return
        }
        #expect(
            initialHeaders.headers[
                HarcGRPCTransportSourceBridge.metadataKey
            ] == [token.base64EncodedString()]
        )

        var trailers = HPACKHeaders()
        trailers.add(
            name: HarcGRPCTransportSourceBridge.metadataKey,
            value: "client-controlled"
        )
        trailers.add(name: "x-test-trailer", value: "preserved")
        try channel.writeInbound(
            HTTP2Frame.FramePayload.headers(
                .init(headers: trailers, endStream: true)
            )
        )

        let readTrailers: HTTP2Frame.FramePayload? = try channel.readInbound(
            as: HTTP2Frame.FramePayload.self
        )
        let forwardedTrailers = try #require(readTrailers)
        guard case .headers(let trailerHeaders) = forwardedTrailers else {
            Issue.record("Expected a trailer headers payload")
            return
        }
        #expect(
            trailerHeaders.headers[
                HarcGRPCTransportSourceBridge.metadataKey
            ].isEmpty
        )
        #expect(trailerHeaders.headers["x-test-trailer"] == ["preserved"])
    }
}
#endif
