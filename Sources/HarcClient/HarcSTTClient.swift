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

    /// Per-IPC-call timeouts, enforced by the kernel (SO_RCVTIMEO) so the
    /// blocking read() itself returns when the daemon goes quiet. What this
    /// protects against: a hung daemon silently blocking the recording-stop
    /// path, the auto-paste flow, or any UI surface that awaits these calls.
    /// (A racing-task-group timeout cannot do this job: a throwing task group
    /// awaits all children before returning, and a child stuck in an
    /// uncancellable read() pins the group open — the caller stays blocked
    /// for exactly as long as the timeout was meant to bound.)
    public static let statusTimeout: Int = 5
    public static let transcribeTimeout: Int = 60
    public static let diarizeTimeout: Int = 300   // 5 min for full-WAV diarize on long meetings
    public static let shutdownTimeout: Int = 5
    /// Dictation clips are a few seconds; a warm daemon transcribes them in
    /// well under a second. Cap tighter than `transcribeTimeout` so a hung
    /// daemon can't leave the dictation flow spinning.
    public static let dictateTimeout: Int = 20

    public func status() async throws -> DaemonStatus {
        let response = try await roundTripWithTimeout(.status, seconds: Self.statusTimeout)
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
        let response = try await roundTripWithTimeout(request, seconds: Self.transcribeTimeout)
        switch response {
        case .result(let r): return r
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    /// Low-latency single-shot transcription for dictation. Skips diarization
    /// and VAD (the daemon also auto-bypasses VAD for short clips) and drops
    /// word timestamps — we only want the text — with a tighter timeout.
    public func dictate(audioPath: String) async throws -> String {
        let request = IPCRequest.transcribe(TranscribeRequest(
            audioPath: audioPath,
            language: "en",
            wantTimestamps: false,
            diarize: false,
            vad: false
        ))
        let response = try await roundTripWithTimeout(request, seconds: Self.dictateTimeout)
        switch response {
        case .result(let r): return r.text
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    public func diarize(audioPath: String) async throws -> DiarizeResult {
        let request = IPCRequest.diarize(DiarizeRequest(audioPath: audioPath))
        let response = try await roundTripWithTimeout(request, seconds: Self.diarizeTimeout)
        switch response {
        case .diarization(let d): return d
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    public func shutdown() async throws {
        _ = try await roundTripWithTimeout(.shutdown, seconds: Self.shutdownTimeout)
    }

    /// Internal (not private) so the timeout behavior itself is testable
    /// with a silent socketpair peer and a short deadline.
    func roundTripWithTimeout(_ request: IPCRequest, seconds: Int) async throws -> IPCResponse {
        try await roundTrip(request, timeoutSeconds: seconds)
    }

    /// Opens a socket (if not using a preconnected fd), sends `request`, reads one response, closes.
    /// The read carries a kernel receive deadline: `read()` returns EAGAIN once
    /// `timeoutSeconds` elapse, which surfaces as `ClientError.timeout` instead
    /// of pinning a thread on a wedged daemon.
    private func roundTrip(_ request: IPCRequest, timeoutSeconds: Int) async throws -> IPCResponse {
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
        try data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < data.count {
                let n = write(fd, rawBuf.baseAddress!.advanced(by: offset), data.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw ClientError.daemonNotReachable("write errno \(errno)")
                }
            }
        }
        // Signal EOF on our write side so the daemon knows the request is complete.
        // Only applies when we own the fd; for preconnected test fds the peer drives it.
        if shouldClose { Darwin.shutdown(fd, SHUT_WR) }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var buf = Data()
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { scratch.deallocate() }
        while !buf.contains(0x0A) {
            // Re-arm the deadline each pass so a slow-drip peer can't extend
            // the total wait past `timeoutSeconds`.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ClientError.timeout(seconds: timeoutSeconds) }
            setReceiveTimeout(fd, seconds: remaining)
            let n = read(fd, scratch, 64 * 1024)
            if n > 0 {
                buf.append(scratch, count: n)
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ClientError.timeout(seconds: timeoutSeconds)
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

    private func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - floor(seconds)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
