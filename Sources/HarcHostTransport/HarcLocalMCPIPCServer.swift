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
    private let acceptCompletion: AsyncStream<Void>
    private let acceptCompletionContinuation: AsyncStream<Void>.Continuation
    private var activeClientDescriptor: Int32?
    private var stopped = false
    private var socketCleanupCompleted = false

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
        let listenerFlags = fcntl(descriptor, F_GETFL)
        guard listenerFlags >= 0,
              fcntl(descriptor, F_SETFL, listenerFlags | O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            _ = socketURL.path.withCString {
                harc_ipc_unlink_socket_if_matches($0, geteuid(), identity)
            }
            throw HarcLocalMCPIPCError.systemCall(operation: "fcntl", code: code)
        }
        let server = HarcLocalMCPIPCServer(
            socketURL: socketURL,
            service: service,
            authorizer: authorizer,
            listenerDescriptor: descriptor,
            socketIdentity: identity
        )
        let completion = server.acceptCompletionContinuation
        Thread { [weak server, descriptor] in
            defer {
                Darwin.close(descriptor)
                completion.finish()
            }
            // Each bounded iteration releases its strong server reference so
            // dropping an idle server still runs deinit and stops its worker.
            while server?.acceptNextConnection() == true { }
        }.start()
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
        let (completion, continuation) = AsyncStream<Void>.makeStream()
        self.acceptCompletion = completion
        self.acceptCompletionContinuation = continuation
    }

    public func shutdown() async {
        requestStop()
        for await _ in acceptCompletion { }
        let shouldUnlink = stateLock.withLock {
            guard !socketCleanupCompleted else { return false }
            socketCleanupCompleted = true
            return true
        }
        guard shouldUnlink else { return }
        _ = socketURL.path.withCString {
            harc_ipc_unlink_socket_if_matches($0, geteuid(), socketIdentity)
        }
    }

    deinit { requestStop() }

    private func requestStop() {
        stateLock.withLock {
            stopped = true
            if let descriptor = activeClientDescriptor {
                _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            }
        }
        // macOS cannot shutdown a listening socket. The worker's bounded poll
        // notices stop and closes its own fd before releasing shutdown waiters.
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }

    private func acceptNextConnection() -> Bool {
        guard !isStopped else { return false }
        var readiness = pollfd(fd: listenerDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&readiness, 1, 250)
        if ready == 0 { return true }
        if ready < 0 { return errno == EINTR }
        guard !isStopped else { return false }

        var descriptor = Int32(-1)
        guard harc_ipc_accept(listenerDescriptor, &descriptor) == 0 else {
            return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            return !isStopped
        }
        let shouldHandle = stateLock.withLock {
            guard !stopped else { return false }
            activeClientDescriptor = descriptor
            return true
        }
        if shouldHandle { handleConnection(descriptor) }
        stateLock.withLock {
            activeClientDescriptor = nil
            Darwin.close(descriptor)
        }
        return !isStopped
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
