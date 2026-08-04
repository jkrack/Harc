#if os(macOS)
import Darwin
import Foundation
import HarcHost
import HarcIPCSystem

public final class HarcLocalMCPIPCServer: @unchecked Sendable {
    public static func defaultSocketURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harc/IPC/host.sock")
    }

    private let socketURL: URL
    private let service: any HarcMCPToolCalling
    private let authorizer: any MCPPeerAuthorizing
    private let listenerDescriptor: Int32
    private let socketIdentity: HarcIPCSocketIdentity
    private let stateLock = NSLock()
    private var acceptTask: Task<Void, Never>?
    private var stopped = false

    public static func start(
        socketURL: URL = defaultSocketURL(),
        service: any HarcMCPToolCalling,
        authorizer: any MCPPeerAuthorizing
    ) throws -> HarcLocalMCPIPCServer {
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var descriptor = Int32(-1)
        var identity = HarcIPCSocketIdentity()
        let result = socketURL.path.withCString {
            harc_ipc_secure_listen($0, geteuid(), &descriptor, &identity)
        }
        guard result == 0 else {
            throw HarcLocalMCPIPCError.systemCall(
                operation: "listen",
                code: errno
            )
        }
        let server = HarcLocalMCPIPCServer(
            socketURL: socketURL,
            service: service,
            authorizer: authorizer,
            listenerDescriptor: descriptor,
            socketIdentity: identity
        )
        server.acceptTask = Task.detached { [weak server] in
            server?.acceptLoop()
        }
        return server
    }

    private init(
        socketURL: URL,
        service: any HarcMCPToolCalling,
        authorizer: any MCPPeerAuthorizing,
        listenerDescriptor: Int32,
        socketIdentity: HarcIPCSocketIdentity
    ) {
        self.socketURL = socketURL
        self.service = service
        self.authorizer = authorizer
        self.listenerDescriptor = listenerDescriptor
        self.socketIdentity = socketIdentity
    }

    public func shutdown() async {
        let task = stateLock.withLock { () -> Task<Void, Never>? in
            if !stopped {
                stopped = true
                _ = Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
                Darwin.close(listenerDescriptor)
            }
            return acceptTask
        }
        await task?.value
        _ = socketURL.path.withCString {
            harc_ipc_unlink_socket_if_matches(
                $0,
                geteuid(),
                socketIdentity
            )
        }
    }

    deinit {
        stateLock.withLock {
            if !stopped {
                stopped = true
                _ = Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
                Darwin.close(listenerDescriptor)
            }
        }
    }

    private func acceptLoop() {
        while true {
            var descriptor = Int32(-1)
            guard harc_ipc_accept(listenerDescriptor, &descriptor) == 0 else {
                if errno == EINTR { continue }
                return
            }
            handleConnection(descriptor)
            Darwin.close(descriptor)
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        do {
            try authorizer.authorize(
                peerOnConnectedSocket: descriptor,
                expectedIdentifier: "com.harc.Harc.mcp"
            )
            let clientHello = try HarcLocalMCPFrameCodec.read(
                HarcLocalMCPClientHello.self,
                from: descriptor
            )
            guard clientHello.magic == HarcLocalMCPIPCProtocol.magic,
                  clientHello.nonce.count == HarcLocalMCPIPCProtocol.nonceLength
            else { throw HarcLocalMCPIPCError.invalidHello }
            guard clientHello.version == HarcLocalMCPIPCProtocol.version else {
                throw HarcLocalMCPIPCError.unsupportedProtocolVersion
            }
            try HarcLocalMCPFrameCodec.write(
                HarcLocalMCPServerHello(
                    magic: HarcLocalMCPIPCProtocol.magic,
                    selectedVersion: HarcLocalMCPIPCProtocol.version,
                    clientNonce: clientHello.nonce,
                    serverNonce: HarcLocalMCPFrameCodec.randomNonce()
                ),
                to: descriptor
            )
            let envelope = try HarcLocalMCPFrameCodec.read(
                HarcLocalMCPRequestEnvelope.self,
                from: descriptor
            )
            guard HarcMCPToolService.allowedToolNames.contains(
                envelope.request.name
            ) else { throw HarcLocalMCPIPCError.invalidToolName }
            let response = waitForResponse(envelope.request)
            try HarcLocalMCPFrameCodec.write(
                HarcLocalMCPResponseEnvelope(
                    requestID: envelope.requestID,
                    response: response
                ),
                to: descriptor
            )
        } catch {
            // Authentication and framing failures close without parsing or
            // disclosing a protocol error, as required by the local boundary.
        }
    }

    private func waitForResponse(
        _ request: HarcMCPToolRequest
    ) -> HarcMCPToolResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = HarcLocalMCPResponseBox()
        Task {
            let response = await service.call(request)
            responseBox.store(response)
            semaphore.signal()
        }
        semaphore.wait()
        return responseBox.load() ?? HarcMCPToolResponse(
            text: "The local Host did not produce an MCP response.",
            isError: true
        )
    }
}

private final class HarcLocalMCPResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: HarcMCPToolResponse?

    func store(_ response: HarcMCPToolResponse) {
        lock.withLock { self.response = response }
    }

    func load() -> HarcMCPToolResponse? {
        lock.withLock { response }
    }
}
#endif
