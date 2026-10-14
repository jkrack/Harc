import Foundation
import Darwin

/// Unix domain socket server. Binds to `socketPath`, listens, and yields
/// accepted client file descriptors through `clients`. Not itself an actor.
/// Blocking accept runs on a dedicated thread, never Swift's cooperative
/// executor. A lock protects listener shutdown; the accept thread owns close.
public final class SocketServer: @unchecked Sendable {
    public let socketPath: String
    public let clients: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation
    private var serverFd: Int32
    private let listenerLock = NSLock()
    private var shutdownRequested = false

    public init(socketPath: String) throws {
        self.socketPath = socketPath

        // Ensure parent dir exists (e.g. ~/.harc/)
        let parent = (socketPath as NSString).deletingLastPathComponent
        let parentAlreadyExisted = FileManager.default.fileExists(atPath: parent)
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )
        // The STT daemon accepts sensitive transcript jobs. Keep the socket
        // directory owner-only when we own a Harc-created private directory.
        if !parentAlreadyExisted || parent == Self.defaultSocketParent {
            chmod(parent, 0o700)
        }

        // Remove any stale socket left from a previous run
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw DaemonError.socketPathTooLong(socketPath)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw DaemonError.socketBindFailed(err)
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            throw DaemonError.socketListenFailed(err)
        }

        // poll readiness must never turn into a blocking accept after a race.
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let err = errno
            close(fd)
            throw DaemonError.socketListenFailed(err)
        }

        self.serverFd = fd
        let (stream, cont) = AsyncStream<Int32>.makeStream()
        self.clients = stream
        self.continuation = cont

        Thread { [self] in
            runAcceptLoop(fd: fd)
        }.start()
    }

    private func runAcceptLoop(fd: Int32) {
        defer {
            listenerLock.lock()
            close(fd)
            serverFd = -1
            listenerLock.unlock()
            continuation.finish()
        }
        while isListening {
            var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, 250)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard isListening else { break }
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    accept(fd, sp, &clientAddrLen)
                }
            }
            if clientFd >= 0 {
                // ClientConnection owns blocking reads. Do not let listener
                // nonblocking flags leak into a newly accepted connection.
                let clientFlags = fcntl(clientFd, F_GETFL)
                guard clientFlags >= 0,
                      fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK) == 0 else {
                    close(clientFd)
                    continue
                }
                if Self.isAuthorizedPeer(clientFd), isListening {
                    if case .terminated = continuation.yield(clientFd) {
                        close(clientFd)
                    }
                } else {
                    close(clientFd)
                }
            } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                break
            }
        }
    }

    private var isListening: Bool {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        return !shutdownRequested && serverFd >= 0
    }

    /// Confirms that the accept thread released its listener, not merely that
    /// the consumer stream finished. Used by the shutdown resource regression.
    var listenerHasClosedForTesting: Bool {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        return serverFd < 0
    }

    public func shutdown() {
        listenerLock.lock()
        guard !shutdownRequested else {
            listenerLock.unlock()
            return
        }
        shutdownRequested = true
        // macOS rejects shutdown() on a listening socket with ENOTCONN.
        // The bounded poll wakes the owner to close it without racing fd reuse.
        listenerLock.unlock()
        continuation.finish()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func isAuthorizedPeer(_ fd: Int32) -> Bool {
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else { return false }
        return peerUID == geteuid()
    }

    private static let defaultSocketParent: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".harc", isDirectory: true)
            .path
    }()
}
