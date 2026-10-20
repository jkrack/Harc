#if os(macOS)
import Darwin
import Foundation
import HarcHost
import HarcHostTransport
import HarcIPCSystem
import HarcTestSupport
import Testing

@Suite(
    "Authenticated local MCP IPC",
    .serialized,
    .processWideSystemResource
)
struct LocalMCPIPCIntegrationTests {
    @Test("nonce hello and allowlisted request round-trip through the Host facade")
    func roundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorizer = AcceptingPeerAuthorizer()
        let service = CapturingToolService()
        let server = try HarcLocalMCPIPCServer.start(
            socketURL: fixture.socketURL,
            service: service,
            authorizer: authorizer
        )
        defer { Task { await server.shutdown() } }
        let client = HarcLocalMCPIPCClient(
            socketURL: fixture.socketURL,
            authorizer: authorizer
        )

        let request = HarcMCPToolRequest(
            name: "list_recent",
            arguments: ["limit": .int(3)]
        )
        let response = await client.call(request)

        #expect(response == HarcMCPToolResponse(text: "captured:list_recent", isError: false))
        #expect(await service.lastRequest() == request)
        #expect(authorizer.expectedIdentifiers() == [
            "com.harc.Harc",
            "com.harc.Harc.mcp",
        ])
        await server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    @Test("idle listener leaves the executor available and shutdown permits immediate restart")
    func idleListenerAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try HarcLocalMCPIPCServer.start(
            socketURL: fixture.socketURL,
            service: CapturingToolService(),
            authorizer: AcceptingPeerAuthorizer()
        )
        defer { Task { await server.shutdown() } }
        await Task.yield()
        await server.shutdown()
        let replacement = try HarcLocalMCPIPCServer.start(
            socketURL: fixture.socketURL,
            service: CapturingToolService(),
            authorizer: AcceptingPeerAuthorizer()
        )
        await server.shutdown()
        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        await replacement.shutdown()
        #expect(!FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    @Test("shutdown interrupts a silent accepted peer instead of waiting on its frame deadline")
    func shutdownInterruptsSilentPeer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorizer = AcceptingPeerAuthorizer()
        let server = try HarcLocalMCPIPCServer.start(
            socketURL: fixture.socketURL,
            service: CapturingToolService(),
            authorizer: authorizer
        )
        defer { Task { await server.shutdown() } }
        var descriptor = Int32(-1)
        try #require(fixture.socketURL.path.withCString {
            harc_ipc_connect($0, &descriptor)
        } == 0)
        defer { Darwin.close(descriptor) }
        let deadline = ContinuousClock.now + .seconds(5)
        while authorizer.expectedIdentifiers().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(authorizer.expectedIdentifiers() == ["com.harc.Harc.mcp"])
        let began = ContinuousClock.now
        await server.shutdown()
        #expect(ContinuousClock.now - began < .seconds(2))
    }

    @Test("cancelled and concurrent shutdown callers join an in-flight service before unlinking")
    func cancelledShutdownJoinsWorker() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = GatedToolService()
        let server = try HarcLocalMCPIPCServer.start(
            socketURL: fixture.socketURL, service: service,
            authorizer: AcceptingPeerAuthorizer()
        )
        defer { Task { await service.release(); await server.shutdown() } }
        let client = HarcLocalMCPIPCClient(
            socketURL: fixture.socketURL,
            authorizer: AcceptingPeerAuthorizer()
        )
        let request = Task { await client.call(HarcMCPToolRequest(name: "list_recent", arguments: nil)) }
        var entered = service.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        final class Completions: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func record() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let completions = Completions()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await server.shutdown()
            completions.record()
        }
        let concurrent = Task {
            await server.shutdown()
            completions.record()
        }
        // The failed client proves requestStop has interrupted its socket;
        // the service remains gated, so the accept worker cannot be finished.
        #expect((await request.value).isError)
        try await Task.sleep(for: .milliseconds(50))
        #expect(completions.value == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        await service.release()
        await cancelled.value
        await concurrent.value
        #expect(completions.value == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    @Test("a live resident listener owns the socket path exclusively")
    func rejectsLiveDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try HarcLocalMCPIPCServer.start(
            socketURL: fixture.socketURL,
            service: CapturingToolService(),
            authorizer: AcceptingPeerAuthorizer()
        )
        defer { Task { await first.shutdown() } }

        #expect(throws: (any Error).self) {
            try HarcLocalMCPIPCServer.start(
                socketURL: fixture.socketURL,
                service: CapturingToolService(),
                authorizer: AcceptingPeerAuthorizer()
            )
        }
        await first.shutdown()
    }

    @Test("a current-user stale socket is replaced only after refused probe")
    func replacesStaleSocket() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var staleDescriptor = Int32(-1)
        var staleIdentity = HarcIPCSocketIdentity()
        #expect(fixture.socketURL.path.withCString {
            harc_ipc_secure_listen(
                $0,
                geteuid(),
                &staleDescriptor,
                &staleIdentity
            )
        } == 0)
        Darwin.close(staleDescriptor)

        let server = try HarcLocalMCPIPCServer.start(
            socketURL: fixture.socketURL,
            service: CapturingToolService(),
            authorizer: AcceptingPeerAuthorizer()
        )
        await server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    @Test("symlinks and non-socket entries fail closed")
    func rejectsUnsafeEntries() throws {
        let nonSocket = try Fixture()
        defer { nonSocket.remove() }
        try Data("not a socket".utf8).write(to: nonSocket.socketURL)
        #expect(throws: (any Error).self) {
            try HarcLocalMCPIPCServer.start(
                socketURL: nonSocket.socketURL,
                service: CapturingToolService(),
                authorizer: AcceptingPeerAuthorizer()
            )
        }

        let symlink = try Fixture()
        defer { symlink.remove() }
        let target = symlink.root.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: symlink.socketURL,
            withDestinationURL: target
        )
        #expect(throws: (any Error).self) {
            try HarcLocalMCPIPCServer.start(
                socketURL: symlink.socketURL,
                service: CapturingToolService(),
                authorizer: AcceptingPeerAuthorizer()
            )
        }
    }

    @Test("a stale socket with broadened file mode fails closed")
    func rejectsWrongSocketMode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var descriptor = Int32(-1)
        var identity = HarcIPCSocketIdentity()
        #expect(fixture.socketURL.path.withCString {
            harc_ipc_secure_listen($0, geteuid(), &descriptor, &identity)
        } == 0)
        Darwin.close(descriptor)
        #expect(chmod(fixture.socketURL.path, 0o644) == 0)

        #expect(throws: (any Error).self) {
            try HarcLocalMCPIPCServer.start(
                socketURL: fixture.socketURL,
                service: CapturingToolService(),
                authorizer: AcceptingPeerAuthorizer()
            )
        }
    }
}

private struct Fixture {
    let root: URL
    let socketURL: URL

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "harc-mcp-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        socketURL = root.appendingPathComponent("host.sock")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor GatedToolService: HarcMCPToolCalling {
    nonisolated let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<HarcMCPToolResponse, Never>?
    func call(_ request: HarcMCPToolRequest) async -> HarcMCPToolResponse {
        await withCheckedContinuation {
            continuation = $0
            entered.continuation.yield()
        }
    }
    func release() {
        continuation?.resume(returning: HarcMCPToolResponse(text: "released", isError: false))
        continuation = nil
    }
}

private actor CapturingToolService: HarcMCPToolCalling {
    private var captured: HarcMCPToolRequest?

    func call(_ request: HarcMCPToolRequest) async -> HarcMCPToolResponse {
        captured = request
        return HarcMCPToolResponse(
            text: "captured:\(request.name)",
            isError: false
        )
    }

    func lastRequest() -> HarcMCPToolRequest? { captured }
}

private final class AcceptingPeerAuthorizer: MCPPeerAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String] = []

    func authorize(
        peerOnConnectedSocket descriptor: Int32,
        expectedIdentifier: String
    ) throws {
        lock.withLock { identifiers.append(expectedIdentifier) }
    }

    func expectedIdentifiers() -> [String] {
        lock.withLock { identifiers.sorted() }
    }
}
#endif
