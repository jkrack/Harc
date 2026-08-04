#if os(macOS)
import Darwin
import Foundation
import HarcHost
import HarcIPCSystem

public actor HarcLocalMCPIPCClient: HarcMCPToolCalling {
    private let socketURL: URL
    private let authorizer: any MCPPeerAuthorizing

    public init(
        socketURL: URL = HarcLocalMCPIPCServer.defaultSocketURL(),
        authorizer: any MCPPeerAuthorizing
    ) {
        self.socketURL = socketURL
        self.authorizer = authorizer
    }

    public func call(_ request: HarcMCPToolRequest) async -> HarcMCPToolResponse {
        let socketURL = socketURL
        let authorizer = authorizer
        return await Task.detached {
            do {
                return try Self.perform(
                    request,
                    socketURL: socketURL,
                    authorizer: authorizer
                )
            } catch {
                return HarcMCPToolResponse(
                    text: "Host-mode MCP is unavailable. Open the signed Harc app and try again.",
                    isError: true
                )
            }
        }.value
    }

    private static func perform(
        _ request: HarcMCPToolRequest,
        socketURL: URL,
        authorizer: any MCPPeerAuthorizing
    ) throws -> HarcMCPToolResponse {
        guard HarcMCPToolService.allowedToolNames.contains(request.name) else {
            throw HarcLocalMCPIPCError.invalidToolName
        }
        var descriptor = Int32(-1)
        let result = socketURL.path.withCString {
            harc_ipc_connect($0, &descriptor)
        }
        guard result == 0 else {
            throw HarcLocalMCPIPCError.systemCall(
                operation: "connect",
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }
        try authorizer.authorize(
            peerOnConnectedSocket: descriptor,
            expectedIdentifier: "com.harc.Harc"
        )
        let clientNonce = HarcLocalMCPFrameCodec.randomNonce()
        try HarcLocalMCPFrameCodec.write(
            HarcLocalMCPClientHello(
                magic: HarcLocalMCPIPCProtocol.magic,
                version: HarcLocalMCPIPCProtocol.version,
                nonce: clientNonce
            ),
            to: descriptor
        )
        let serverHello = try HarcLocalMCPFrameCodec.read(
            HarcLocalMCPServerHello.self,
            from: descriptor
        )
        guard serverHello.magic == HarcLocalMCPIPCProtocol.magic,
              serverHello.selectedVersion == HarcLocalMCPIPCProtocol.version,
              serverHello.clientNonce == clientNonce,
              serverHello.serverNonce.count == HarcLocalMCPIPCProtocol.nonceLength
        else { throw HarcLocalMCPIPCError.nonceMismatch }
        let requestID = UUID()
        try HarcLocalMCPFrameCodec.write(
            HarcLocalMCPRequestEnvelope(
                requestID: requestID,
                request: request
            ),
            to: descriptor
        )
        let response = try HarcLocalMCPFrameCodec.read(
            HarcLocalMCPResponseEnvelope.self,
            from: descriptor
        )
        guard response.requestID == requestID else {
            throw HarcLocalMCPIPCError.responseMismatch
        }
        return response.response
    }
}
#endif
