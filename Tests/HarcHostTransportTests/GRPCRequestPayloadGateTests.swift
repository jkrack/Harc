#if canImport(Network)
import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP2
import Testing
@testable import HarcHostTransport

@Suite("gRPC method-aware request payload gate")
struct GRPCRequestPayloadGateTests {
    @Test("only UploadChunks receives the frozen 5 MiB audio ceiling")
    func methodLimits() {
        #expect(
            HarcGRPCRequestPayloadGate.maximumPayloadBytes(
                for: "/harc.v1.RecordingTransferService/UploadChunks"
            ) == 5 * 1_024 * 1_024
        )
        #expect(
            HarcGRPCRequestPayloadGate.maximumPayloadBytes(
                for: "/harc.v1.RecordingTransferService/BeginUpload"
            ) == 1 * 1_024 * 1_024
        )
        #expect(
            HarcGRPCRequestPayloadGate.maximumPayloadBytes(
                for: "/unknown.Service/UnknownMethod"
            ) == 1 * 1_024 * 1_024
        )
    }

    @Test("fragmented prefixes and consecutive control messages pass")
    func fragmentedMessagesPass() throws {
        let channel = try makeChannel(
            path: "/harc.v1.HostInfoService/GetHostInfo"
        )
        defer { _ = try? channel.finish() }

        try channel.writeInbound(dataFrame([0]))
        try channel.writeInbound(dataFrame([0, 0, 0, 2, 0xAA]))
        try channel.writeInbound(dataFrame([0xBB, 0, 0, 0, 0, 0]))

        #expect(try channel.readInbound(as: HTTP2Frame.FramePayload.self) != nil)
        #expect(try channel.readInbound(as: HTTP2Frame.FramePayload.self) != nil)
        #expect(try channel.readInbound(as: HTTP2Frame.FramePayload.self) != nil)
    }

    @Test("control oversize is rejected from its prefix before body buffering")
    func controlOversizeRejected() throws {
        let channel = try makeChannel(
            path: "/harc.v1.RecordingTransferService/BeginUpload"
        )
        defer { _ = try? channel.finish() }

        let declared = HarcGRPCRequestPayloadGate.maximumControlPayloadBytes + 1
        #expect(throws: HarcGRPCRequestPayloadGateError.self) {
            try channel.writeInbound(prefixFrame(declaredLength: declared))
        }
        #expect(!channel.isActive)
    }

    @Test("UploadChunks admits above-control sizes but rejects above 5 MiB")
    func audioMethodCeiling() throws {
        let accepted = try makeChannel(
            path: "/harc.v1.RecordingTransferService/UploadChunks"
        )
        defer { _ = try? accepted.finish() }
        try accepted.writeInbound(
            prefixFrame(
                declaredLength:
                    HarcGRPCRequestPayloadGate.maximumControlPayloadBytes + 1
            )
        )
        #expect(
            try accepted.readInbound(as: HTTP2Frame.FramePayload.self) != nil
        )

        let rejected = try makeChannel(
            path: "/harc.v1.RecordingTransferService/UploadChunks"
        )
        defer { _ = try? rejected.finish() }
        #expect(throws: HarcGRPCRequestPayloadGateError.self) {
            try rejected.writeInbound(
                prefixFrame(
                    declaredLength:
                        HarcGRPCRequestPayloadGate.maximumAudioPayloadBytes + 1
                )
            )
        }
        #expect(!rejected.isActive)
    }

    @Test("compressed, missing-path, and truncated requests fail closed")
    func malformedRequestsFailClosed() throws {
        let compressed = try makeChannel(path: "/test.Service/Method")
        defer { _ = try? compressed.finish() }
        #expect(throws: HarcGRPCRequestPayloadGateError.self) {
            try compressed.writeInbound(
                dataFrame([1, 0, 0, 0, 0])
            )
        }

        let missingPath = EmbeddedChannel(
            handler: HarcGRPCRequestPayloadGateHandler()
        )
        defer { _ = try? missingPath.finish() }
        #expect(throws: HarcGRPCRequestPayloadGateError.self) {
            try missingPath.writeInbound(
                HTTP2Frame.FramePayload.headers(
                    .init(headers: HPACKHeaders())
                )
            )
        }

        let truncated = try makeChannel(path: "/test.Service/Method")
        defer { _ = try? truncated.finish() }
        #expect(throws: HarcGRPCRequestPayloadGateError.self) {
            try truncated.writeInbound(
                dataFrame([0, 0, 0, 0, 2, 0xAA], endStream: true)
            )
        }
    }

    private func makeChannel(path: String) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(
            handler: HarcGRPCRequestPayloadGateHandler()
        )
        var headers = HPACKHeaders()
        headers.add(name: ":method", value: "POST")
        headers.add(name: ":path", value: path)
        try channel.writeInbound(
            HTTP2Frame.FramePayload.headers(.init(headers: headers))
        )
        _ = try channel.readInbound(as: HTTP2Frame.FramePayload.self)
        return channel
    }

    private func prefixFrame(declaredLength: Int) -> HTTP2Frame.FramePayload {
        dataFrame([
            0,
            UInt8((declaredLength >> 24) & 0xFF),
            UInt8((declaredLength >> 16) & 0xFF),
            UInt8((declaredLength >> 8) & 0xFF),
            UInt8(declaredLength & 0xFF),
        ])
    }

    private func dataFrame(
        _ bytes: [UInt8],
        endStream: Bool = false
    ) -> HTTP2Frame.FramePayload {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return .data(
            .init(data: .byteBuffer(buffer), endStream: endStream)
        )
    }
}
#endif
