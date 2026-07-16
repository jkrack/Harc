import Testing
import Foundation
import Darwin
import HarcCore
@testable import HarcSTT

/// Keep-warm groundwork: a plain `status` request must reset the daemon's
/// idle clock so a client-side ping can keep the daemon resident without
/// transcribing anything.
@Suite("Daemon idle clock")
struct DaemonIdleClockTests {
    @Test("a status request resets lastActivity")
    func statusResetsIdleClock() async throws {
        let socketPath = "/tmp/harc-idle-\(UUID().uuidString.prefix(8)).sock"

        let daemon = Daemon(socketPath: socketPath, idleTimeout: 600)
        let daemonTask = Task { try await daemon.run() }

        // Wait up to 5s for the socket to appear.
        var waited = 0
        while !FileManager.default.fileExists(atPath: socketPath), waited < 5_000 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 100
        }
        try #require(FileManager.default.fileExists(atPath: socketPath))

        let before = await daemon.lastActivityForTesting

        // Let real time pass so a reset is distinguishable from init time.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Plain status ping — no transcription, no model requirement.
        let response = try roundTrip(.status, socketPath: socketPath)
        guard case .status = response else {
            Issue.record("expected status response, got \(response)")
            return
        }

        let after = await daemon.lastActivityForTesting
        #expect(
            after > before,
            "status request must advance lastActivity (before \(before), after \(after))"
        )
        #expect(after.timeIntervalSince(before) >= 0.2)

        // Shut the daemon down cleanly.
        _ = try? roundTrip(.shutdown, socketPath: socketPath)
        _ = try await withTimeout(seconds: 5) { try await daemonTask.value }
    }

    /// Open a connected socket, send one NDJSON request, read one NDJSON response.
    private func roundTrip(_ request: IPCRequest, socketPath: String) throws -> IPCResponse {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

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
}
