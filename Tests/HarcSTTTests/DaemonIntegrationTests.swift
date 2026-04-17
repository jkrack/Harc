import Testing
import Foundation
import Darwin
import HarcCore
@testable import HarcSTT

@Suite("Daemon end-to-end", .tags(.slow))
struct DaemonIntegrationTests {
    @Test("dispatching a transcribe request over the socket returns a result")
    func transcribeOverSocket() async throws {
        let socketPath = "/tmp/harc-integ-\(UUID().uuidString.prefix(8)).sock"

        let daemon = Daemon(socketPath: socketPath, idleTimeout: 600)
        let daemonTask = Task { try await daemon.run() }

        // Wait up to 5s for the socket to appear.
        var waited = 0
        while !FileManager.default.fileExists(atPath: socketPath), waited < 5_000 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 100
        }
        try #require(FileManager.default.fileExists(atPath: socketPath))

        // Build the sockaddr_un once — reused for every connection below.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Helper: open a connected socket, send one NDJSON line, read one NDJSON line back.
        func roundTrip(_ request: IPCRequest) throws -> IPCResponse {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw DaemonError.socketCreationFailed(errno) }
            defer { close(fd) }

            let connResult = withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    connect(fd, sp, addrLen)
                }
            }
            guard connResult == 0 else { throw DaemonError.socketBindFailed(errno) }

            var reqData = try JSONEncoder().encode(request)
            reqData.append(0x0A)
            _ = reqData.withUnsafeBytes { write(fd, $0.baseAddress, reqData.count) }
            shutdown(fd, SHUT_WR)

            var buf = Data()
            let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
            defer { readBuf.deallocate() }
            while !buf.contains(0x0A) {
                let n = read(fd, readBuf, 64 * 1024)
                if n > 0 { buf.append(readBuf, count: n) }
                else if n == 0 { break }
                else if errno == EINTR { continue }
                else { break }
            }

            let nl = buf.firstIndex(of: 0x0A) ?? buf.endIndex
            return try JSONDecoder().decode(IPCResponse.self, from: buf.prefix(upTo: nl))
        }

        // Poll status until modelLoaded == true (up to 3 min for first-run download).
        let modelDeadline = Date().addingTimeInterval(180)
        var modelLoaded = false
        while Date() < modelDeadline {
            if let resp = try? roundTrip(.status),
               case .status(let s) = resp, s.modelLoaded {
                modelLoaded = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        try #require(modelLoaded, "model never reported loaded within 3 min")

        // Send a transcribe request for the fixture
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let req = IPCRequest.transcribe(TranscribeRequest(
            audioPath: url.path, wantTimestamps: true, diarize: false
        ))
        let response = try roundTrip(req)

        if case .result(let r) = response {
            #expect(!r.text.isEmpty)
            #expect(r.words.count > 0)
        } else if case .error(let e) = response {
            Issue.record("got error response: \(e.code): \(e.message)")
        } else {
            Issue.record("unexpected response: \(response)")
        }

        // Shut the daemon down cleanly
        let shutdownFd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(shutdownFd) }
        _ = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(shutdownFd, sp, addrLen)
            }
        }
        var shutdownReq = try JSONEncoder().encode(IPCRequest.shutdown)
        shutdownReq.append(0x0A)
        _ = shutdownReq.withUnsafeBytes { write(shutdownFd, $0.baseAddress, shutdownReq.count) }

        // Daemon should terminate. Give it up to 5s.
        _ = try await withTimeout(seconds: 5) { try await daemonTask.value }
    }
}

/// Small test helper — cancel after N seconds.
func withTimeout<T: Sendable>(seconds: Double, op: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
