import Foundation
import HarcCore

/// Finds the harc-stt binary and spawns it if the socket isn't alive.
/// Idempotent: `ensureRunning()` is safe to call repeatedly.
public actor DaemonLauncher {
    private let binaryURL: URL?
    private let socketPath: String
    private let logPath: String
    private var process: Process?

    public init(
        binaryURL: URL? = nil,
        socketPath: String = HarcSTTClient.defaultSocketPath
    ) {
        self.binaryURL = binaryURL
        self.socketPath = socketPath

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.logPath = caches.appendingPathComponent("Harc/daemon.log").path
    }

    /// Ensures the daemon is running and responsive. Returns the socket path.
    public func ensureRunning() async throws -> String {
        // If the socket exists and a `status` call works, we're done.
        if FileManager.default.fileExists(atPath: socketPath) {
            let client = HarcSTTClient(socketPath: socketPath)
            if (try? await client.status()) != nil {
                return socketPath
            }
        }

        // Spawn the daemon.
        let bin = try resolveBinaryURL()

        // Ensure log directory exists.
        let parent = (logPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: Data())
        }
        let logHandle = FileHandle(forWritingAtPath: logPath)
        _ = try? logHandle?.seekToEnd()

        let p = Process()
        p.executableURL = bin
        p.standardError = logHandle ?? FileHandle(forWritingAtPath: "/dev/null")
        p.standardOutput = logHandle ?? FileHandle(forWritingAtPath: "/dev/null")
        do {
            try p.run()
        } catch {
            throw ClientError.daemonLaunchFailed("run: \(error.localizedDescription)")
        }
        self.process = p

        // Wait up to 60s for the socket to appear and respond to status.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                let client = HarcSTTClient(socketPath: socketPath)
                if (try? await client.status()) != nil {
                    return socketPath
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        }
        throw ClientError.daemonLaunchFailed("timed out waiting for socket \(socketPath)")
    }

    public func stop() async {
        guard let p = process else { return }
        p.terminate()
        self.process = nil
    }

    /// Resolves the harc-stt binary location.
    /// Precedence: explicit `binaryURL` init arg → env var HARC_STT_BINARY →
    /// Bundle.main `Contents/MacOS/harc-stt` → `.build/debug/harc-stt`
    /// (SwiftPM test layout).
    private func resolveBinaryURL() throws -> URL {
        if let binaryURL {
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
                throw ClientError.daemonLaunchFailed("binary not executable: \(binaryURL.path)")
            }
            return binaryURL
        }
        if let envPath = ProcessInfo.processInfo.environment["HARC_STT_BINARY"] {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let main = Bundle.main.bundlePath + "/Contents/MacOS/harc-stt"
        if FileManager.default.isExecutableFile(atPath: main) {
            return URL(fileURLWithPath: main)
        }
        // SwiftPM test fallback: find by walking up from the test bundle's path.
        // Tests run from .build/<config>/PkgTests.xctest; the harc-stt binary sits at .build/<config>/harc-stt.
        let testBundlePath = Bundle(for: Self.Token.self).bundlePath
        let candidate = (testBundlePath as NSString).deletingLastPathComponent + "/harc-stt"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw ClientError.daemonLaunchFailed("harc-stt binary not found (tried main bundle and \(candidate))")
    }

    /// Marker class used only for `Bundle(for:)` lookups inside tests.
    private final class Token {}
}
