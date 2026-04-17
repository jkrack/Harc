import Testing
import Foundation
import Darwin
@testable import HarcSTT

@Suite("SocketServer")
struct SocketServerTests {
    /// `sun_path` is 104 bytes on macOS. `FileManager.default.temporaryDirectory`
    /// can already be ~47 chars (e.g. `/var/folders/.../T/`), leaving too little
    /// room for a UUID-suffixed filename. Use a short `/tmp` path instead.
    private func tempSocketPath() -> String {
        "/tmp/harc-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("start then connect from a client receives a client fd")
    func clientConnects() async throws {
        let path = tempSocketPath()
        let server = try SocketServer(socketPath: path)
        defer { server.shutdown() }

        let acceptTask = Task<Int32, Error> {
            for await clientFd in server.clients {
                return clientFd
            }
            throw CancellationError()
        }

        // Connect from a raw POSIX client
        let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(clientFd >= 0)
        defer { close(clientFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(clientFd, sp, addrLen)
            }
        }
        #expect(connectResult == 0, "connect failed, errno=\(errno)")

        let acceptedFd = try await acceptTask.value
        #expect(acceptedFd >= 0)
        close(acceptedFd)
    }

    @Test("shutdown removes the socket file")
    func shutdownRemovesSocket() throws {
        let path = tempSocketPath()
        let server = try SocketServer(socketPath: path)
        #expect(FileManager.default.fileExists(atPath: path))
        server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
