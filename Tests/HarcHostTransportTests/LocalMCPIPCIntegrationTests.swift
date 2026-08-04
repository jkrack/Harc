#if os(macOS)
import Darwin
import Foundation
import HarcHost
import HarcHostTransport
import HarcIPCSystem
import Testing

@Suite("Authenticated local MCP IPC", .serialized)
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
