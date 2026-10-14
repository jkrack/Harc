import Foundation
import Darwin
import HarcCore

/// Serves one client connection over an already-accepted fd. Reads
/// newline-delimited JSON `IPCRequest` messages, invokes the handler, writes
/// each returned `IPCResponse` + `\n`. Closes the fd on exit.
public struct ClientConnection: Sendable {
    public static let maxRequestBytes = 1 * 1024 * 1024

    private let fd: Int32

    public init(fd: Int32) {
        self.fd = fd
    }

    /// Read-dispatch-write loop until EOF or the client sends `.shutdown`.
    /// Returns `true` if the handler processed a `.shutdown` request.
    @discardableResult
    public func serve(handler: @Sendable (IPCRequest) async -> IPCResponse) async -> Bool {
        defer { close(fd) }

        var buffer = Data()
        let decoder = JSONDecoder()

        while true {
            let chunk: Data
            do {
                guard let next = try await HarcBlockingIO.run({ try readChunk() }) else {
                    return false
                }
                chunk = next
            } catch { return false }
            buffer.append(chunk)
            if buffer.count > Self.maxRequestBytes {
                try? await HarcBlockingIO.run {
                    try writeResponse(.error(IPCError(
                        code: "request_too_large",
                        message: "IPC request exceeded \(Self.maxRequestBytes) bytes."
                    )))
                }
                return false
            }

            // Drain as many complete messages as we have.
            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nlIndex)
                buffer.removeSubrange(buffer.startIndex...nlIndex)

                let response: IPCResponse
                let wasShutdown: Bool
                do {
                    let request = try decoder.decode(IPCRequest.self, from: lineData)
                    response = await handler(request)
                    wasShutdown = (request == .shutdown)
                } catch {
                    response = .error(IPCError(
                        code: "decode_failed",
                        message: error.localizedDescription
                    ))
                    wasShutdown = false
                }

                do {
                    try await HarcBlockingIO.run { try writeResponse(response) }
                } catch {
                    // Can't encode response — nothing to do but drop it.
                }

                if wasShutdown { return true }
            }
        }
    }

    private func readChunk() throws -> Data? {
        var chunk = Data(count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                chunk.count = count
                return chunk
            }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeResponse(_ response: IPCResponse) throws {
        var payload = try JSONEncoder().encode(response)
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            var written = 0
            while written < payload.count {
                let w = write(fd, raw.baseAddress!.advanced(by: written), payload.count - written)
                if w <= 0 { break }
                written += w
            }
        }
    }
}
