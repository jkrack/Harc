import Foundation
import HarcCore

/// Finds the harc-stt binary and spawns it if the socket isn't alive.
/// Idempotent: `ensureRunning()` is safe to call repeatedly.
public actor DaemonLauncher {
    private let binaryURL: URL?
    private let socketPath: String
    private let logPath: String
    /// Raw ASR engine name forwarded to the daemon as `--asr-engine`
    /// (nil = daemon default, v2). Validated daemon-side — an unknown
    /// value falls back to v2 there rather than failing the launch.
    private let asrEngine: String?
    private var process: Process?
    private var lifecycleGeneration: UInt64 = 0

    public init(
        binaryURL: URL? = nil,
        socketPath: String = HarcSTTClient.defaultSocketPath,
        asrEngine: String? = nil,
        logURL: URL? = nil
    ) {
        self.binaryURL = binaryURL
        self.socketPath = socketPath
        self.asrEngine = asrEngine

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.logPath = (logURL ?? caches.appendingPathComponent("Harc/daemon.log")).path
    }

    /// Ensures the daemon is running and responsive. Returns the socket path.
    public func ensureRunning() async throws -> String {
        try Task.checkCancellation()
        let generation = lifecycleGeneration
        // A status response can suspend this actor. Recheck cancellation and
        // stop generation before either accepting it or spawning a process.
        if FileManager.default.fileExists(atPath: socketPath) {
            let client = HarcSTTClient(socketPath: socketPath)
            let status = try? await client.status()
            try checkStartup(generation: generation)
            if status != nil { return socketPath }
        }

        // No suspension between checking ownership and registering the child:
        // concurrent callers share an in-flight launch, even before its socket
        // exists. Cancelling one waiter does not terminate another's daemon.
        let child: Process
        if let existing = process, existing.isRunning {
            child = existing
        } else {
            child = try launchProcess()
            process = child
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try checkStartup(generation: generation)
            guard child.isRunning else {
                throw ClientError.daemonLaunchFailed(
                    "exited before becoming responsive (status \(child.terminationStatus))"
                )
            }
            if FileManager.default.fileExists(atPath: socketPath) {
                let client = HarcSTTClient(socketPath: socketPath)
                let status = try? await client.status()
                try checkStartup(generation: generation)
                if status != nil { return socketPath }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ClientError.daemonLaunchFailed("timed out waiting for socket \(socketPath)")
    }

    private func checkStartup(generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == lifecycleGeneration else { throw CancellationError() }
    }

    private func launchProcess() throws -> Process {
        let bin = try resolveBinaryURL()
        let parent = (logPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: Data())
        }
        let logHandle = FileHandle(forWritingAtPath: logPath)
        defer { try? logHandle?.close() }
        _ = try? logHandle?.seekToEnd()

        let child = Process()
        child.executableURL = bin
        var arguments = ["--socket", socketPath]
        if let asrEngine { arguments += ["--asr-engine", asrEngine] }
        child.arguments = arguments
        child.standardError = logHandle ?? FileHandle.nullDevice
        child.standardOutput = logHandle ?? FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            throw ClientError.daemonLaunchFailed("run: \(error.localizedDescription)")
        }
        return child
    }

    public func stop() async {
        lifecycleGeneration &+= 1
        guard let child = process else { return }
        if child.isRunning { child.terminate() }
        process = nil
    }

    /// Stops the speech daemon at application termination. The IPC request is
    /// intentionally sent even when this launcher did not create the process:
    /// after an app update or crash, a healthy daemon can outlive its original
    /// parent and be inherited by the next Harc launch. `stop()` remains the
    /// fallback for the process owned by this launcher when IPC is unavailable.
    public func shutdownDaemon(
        client: HarcSTTClient = HarcSTTClient()
    ) async {
        try? await client.shutdown()
        await stop()
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
