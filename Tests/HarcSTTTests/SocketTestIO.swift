import Foundation
import Darwin
import HarcCore

/// Raw fixture I/O must not occupy the cooperative executor that serves it.
/// Kernel deadlines also make a broken fixture fail instead of hanging the suite.
func onSocketTestThread<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread {
            continuation.resume(with: Result { try operation() })
        }.start()
    }
}

func socketTestRoundTrip(fd: Int32, request: Data) async throws -> IPCResponse {
    try await onSocketTestThread {
        defer { shutdown(fd, SHUT_RDWR) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try request.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        shutdown(fd, SHUT_WR)
        var response = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while !response.contains(0x0A) {
            let count = read(fd, &scratch, scratch.count)
            if count > 0 { response.append(contentsOf: scratch.prefix(count)) }
            else if count == 0 { break }
            else if errno == EINTR { continue }
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let newline = response.firstIndex(of: 0x0A) ?? response.endIndex
        return try JSONDecoder().decode(IPCResponse.self, from: response.prefix(upTo: newline))
    }
}
