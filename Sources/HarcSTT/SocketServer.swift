import Foundation
import Darwin

/// Unix domain socket server. Binds to `socketPath`, listens, and yields
/// accepted client file descriptors through `clients`. Not itself an actor —
/// all state mutation happens on a single internal `Task` so the type is
/// `Sendable` by construction of the async stream.
public final class SocketServer: @unchecked Sendable {
    public let socketPath: String
    public let clients: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation
    private var serverFd: Int32
    private var acceptTask: Task<Void, Never>?

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

        self.serverFd = fd
        let (stream, cont) = AsyncStream<Int32>.makeStream()
        self.clients = stream
        self.continuation = cont

        self.acceptTask = Task.detached { [weak self] in
            await self?.runAcceptLoop()
        }
    }

    private func runAcceptLoop() async {
        while !Task.isCancelled {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    accept(serverFd, sp, &clientAddrLen)
                }
            }
            if clientFd >= 0 {
                if Self.isAuthorizedPeer(clientFd) {
                    continuation.yield(clientFd)
                } else {
                    close(clientFd)
                }
            } else if errno == EINTR {
                continue
            } else {
                // EBADF after shutdown() — normal exit.
                break
            }
        }
        continuation.finish()
    }

    public func shutdown() {
        acceptTask?.cancel()
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
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
