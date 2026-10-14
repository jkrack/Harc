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

    private let service: any HarcMCPToolCalling
    private let authorizer: any MCPPeerAuthorizing
    private let listenerDescriptor: Int32
    private let stateLock = NSLock()
    private let acceptCompletion = HarcLocalMCPAcceptCompletion()
    private var activeClientDescriptor: Int32?
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
            service: service,
            authorizer: authorizer,
            listenerDescriptor: descriptor
        )
        let completion = server.acceptCompletion
        Thread { [weak server, descriptor, socketURL, socketIdentity = identity] in
            defer {
                Darwin.close(descriptor)
                _ = socketURL.path.withCString {
                    harc_ipc_unlink_socket_if_matches($0, geteuid(), socketIdentity)
                }
                completion.finish()
            }
            // Each bounded iteration releases its strong server reference so
            // dropping an idle server still runs deinit and stops its worker.
            while server?.acceptNextConnection() == true { }
        }.start()
        return server
    }

    private init(
        service: any HarcMCPToolCalling,
        authorizer: any MCPPeerAuthorizing,
        listenerDescriptor: Int32
    ) {
        self.service = service
        self.authorizer = authorizer
        self.listenerDescriptor = listenerDescriptor
    }

    public func shutdown() async {
        requestStop()
        // Caller cancellation cannot release resources still owned by the
        // accept worker, or terminate the join for other shutdown callers.
        await acceptCompletion.wait()
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

/// A broadcast join, independent of any waiting task's cancellation. Only
/// the accept thread finishes it, after closing and unlinking its listener.
private final class HarcLocalMCPAcceptCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if completed { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func finish() {
        let pending = lock.withLock {
            completed = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
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
