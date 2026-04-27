import Foundation
import Darwin
import HarcCore

/// Connect-per-request client to the harc-stt daemon. Opens a Unix socket,
/// sends one newline-delimited JSON request, reads one response, closes.
public struct HarcSTTClient: Sendable {
    public static let defaultSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".harc/stt.sock").path
    }()

    private let socketPath: String?
    private let preconnectedFd: Int32?

    public init(socketPath: String = HarcSTTClient.defaultSocketPath) {
        self.socketPath = socketPath
        self.preconnectedFd = nil
    }

    /// Test-only init: skip connect, reuse an already-open fd (e.g. from socketpair).
    public init(connectedFd: Int32) {
        self.socketPath = nil
        self.preconnectedFd = connectedFd
    }

    public func status() async throws -> DaemonStatus {
        let response = try await roundTrip(.status)
        switch response {
        case .status(let s): return s
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    public func transcribe(audioPath: String, diarize: Bool = true, vad: Bool = true) async throws -> TranscribeResult {
        let request = IPCRequest.transcribe(TranscribeRequest(
            audioPath: audioPath,
            language: "en",
            wantTimestamps: true,
            diarize: diarize,
            vad: vad
        ))
        let response = try await roundTrip(request)
        switch response {
        case .result(let r): return r
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    public func diarize(audioPath: String) async throws -> DiarizeResult {
        let request = IPCRequest.diarize(DiarizeRequest(audioPath: audioPath))
        let response = try await roundTrip(request)
        switch response {
        case .diarization(let d): return d
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    public func shutdown() async throws {
        _ = try await roundTrip(.shutdown)
    }

    /// Opens a socket (if not using a preconnected fd), sends `request`, reads one response, closes.
    private func roundTrip(_ request: IPCRequest) async throws -> IPCResponse {
        let fd: Int32
        let shouldClose: Bool
        if let pre = preconnectedFd {
            fd = pre
            shouldClose = false
        } else {
            fd = try connectToDaemon()
            shouldClose = true
        }
        defer { if shouldClose { Darwin.close(fd) } }

        var data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw ClientError.ipcEncodeFailed(error.localizedDescription)
        }
        data.append(0x0A)
        _ = data.withUnsafeBytes { rawBuf in
            write(fd, rawBuf.baseAddress, data.count)
        }
        // Signal EOF on our write side so the daemon knows the request is complete.
        // Only applies when we own the fd; for preconnected test fds the peer drives it.
        if shouldClose { Darwin.shutdown(fd, SHUT_WR) }

        var buf = Data()
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { scratch.deallocate() }
        while !buf.contains(0x0A) {
            let n = read(fd, scratch, 64 * 1024)
            if n > 0 {
                buf.append(scratch, count: n)
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw ClientError.daemonNotReachable("read errno \(errno)")
            }
        }

        let nl = buf.firstIndex(of: 0x0A) ?? buf.endIndex
        do {
            return try JSONDecoder().decode(IPCResponse.self, from: buf.prefix(upTo: nl))
        } catch {
            throw ClientError.ipcDecodeFailed(error.localizedDescription)
        }
    }

    private func connectToDaemon() throws -> Int32 {
        guard let socketPath else {
            throw ClientError.daemonNotReachable("no socket path configured")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.daemonNotReachable("socket() errno \(errno)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(fd, sp, addrLen)
            }
        }
        if status != 0 {
            let err = errno
            Darwin.close(fd)
            throw ClientError.daemonNotReachable("connect() errno \(err)")
        }
        return fd
    }
}
