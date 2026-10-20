import Testing
import Foundation
import Darwin
import HarcCore
@testable import HarcSTT

@Suite("ClientConnection")
struct ClientConnectionTests {
    /// Helper: returns (serverSideFd, clientSideFd) connected via AF_UNIX socketpair.
    private func makePair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        let ok = pair.withUnsafeMutableBufferPointer { buf -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        try #require(ok == 0, "socketpair failed, errno=\(errno)")
        return (pair[0], pair[1])
    }

    @Test("reads one request, invokes handler, writes the response")
    func singleRequestRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let expectedResponse = IPCResponse.status(
            DaemonStatus(version: "0.1.0", modelLoaded: true, uptimeSeconds: 42)
        )

        let connTask = Task<Void, Error> {
            let conn = ClientConnection(fd: serverFd)
            await conn.serve { request in
                #expect(request == .status)
                return expectedResponse
            }
        }

        let reqData = try JSONEncoder().encode(IPCRequest.status) + Data([0x0A])
        let decoded = try await socketTestRoundTrip(fd: clientFd, request: reqData)
        #expect(decoded == expectedResponse)

        try await connTask.value
    }

    @Test("invalid JSON yields an IPCResponse.error with decode_failed code")
    func invalidJSONYieldsError() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let connTask = Task<Void, Error> {
            let conn = ClientConnection(fd: serverFd)
            await conn.serve { _ in
                Issue.record("handler should not be called for invalid JSON")
                return IPCResponse.status(DaemonStatus(version: "0", modelLoaded: false, uptimeSeconds: 0))
            }
        }

        let junk = Data("not-a-json-object\n".utf8)
        let decoded = try await socketTestRoundTrip(fd: clientFd, request: junk)
        if case .error(let err) = decoded {
            #expect(err.code == "decode_failed")
        } else {
            Issue.record("expected .error response, got: \(decoded)")
        }

        try await connTask.value
    }

    @Test("oversized IPC request is rejected")
    func oversizedRequestYieldsError() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let connTask = Task<Void, Error> {
            let conn = ClientConnection(fd: serverFd)
            await conn.serve { _ in
                Issue.record("handler should not be called for oversized request")
                return IPCResponse.status(DaemonStatus(version: "0", modelLoaded: false, uptimeSeconds: 0))
            }
        }

        let payload = Data(repeating: UInt8(ascii: "x"), count: ClientConnection.maxRequestBytes + 1)
        let decoded = try await socketTestRoundTrip(fd: clientFd, request: payload)
        if case .error(let err) = decoded {
            #expect(err.code == "request_too_large")
        } else {
            Issue.record("expected .error response, got: \(decoded)")
        }

        try await connTask.value
    }
}
