import Foundation
import Darwin
import HarcCore

/// Top-level daemon actor. Owns socket server, transcriber, diarizer, and
/// idle/shutdown state. Call `run()` from `@main`; it returns when the
/// daemon has shut down.
public actor Daemon {
    public static let defaultSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".harc/stt.sock").path
    }()

    public static let defaultIdleTimeout: TimeInterval = 30 * 60

    private let socketPath: String
    private let idleTimeout: TimeInterval
    private let transcriber: Transcriber
    private let diarizer: Diarizer
    private let startedAt: Date
    private var lastActivity: Date
    private var shutdownRequested = false

    public init(
        socketPath: String = Daemon.defaultSocketPath,
        idleTimeout: TimeInterval = Daemon.defaultIdleTimeout,
        asrEngine: Transcriber.ASREngine = .v2
    ) {
        self.socketPath = socketPath
        self.idleTimeout = idleTimeout
        self.transcriber = Transcriber(engine: asrEngine)
        self.diarizer = Diarizer()
        self.startedAt = Date()
        self.lastActivity = Date()
    }

    public func run() async throws {
        let server = try SocketServer(socketPath: socketPath)
        FileHandle.standardError.write(Data(
            "harc-stt: listening on \(socketPath)\n".utf8
        ))

        // Pre-load models in the background so first transcribe doesn't block.
        Task.detached { [transcriber] in
            do {
                try await transcriber.loadModels()
                FileHandle.standardError.write(Data("harc-stt: ASR model loaded\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-stt: ASR model load failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        Task.detached { [diarizer] in
            do {
                try await diarizer.loadModels()
                FileHandle.standardError.write(Data("harc-stt: diarizer model loaded\n".utf8))
            } catch {
                // Diarizer is optional — log but don't fail the daemon.
                FileHandle.standardError.write(Data(
                    "harc-stt: diarizer load failed (diarization will return empty): \(error.localizedDescription)\n".utf8
                ))
            }
        }

        let idleTask = Task.detached { [self] in
            await self.monitorIdle(server: server)
        }

        let handler = RequestHandler(
            transcriber: transcriber,
            diarizer: diarizer,
            version: HarcVersion.current,
            startedAt: startedAt
        )

        for await clientFd in server.clients {
            recordActivity()
            Task.detached { [handler, self] in
                let conn = ClientConnection(fd: clientFd)
                let wasShutdown = await conn.serve { request in
                    await self.recordActivity()
                    return await handler.handle(request)
                }
                if wasShutdown {
                    await self.requestShutdown()
                    server.shutdown()
                }
            }
            if shutdownRequested { break }
        }

        idleTask.cancel()
        server.shutdown()
    }

    private func recordActivity() {
        lastActivity = Date()
    }

    /// Test hook: the last time the daemon saw client activity (connection
    /// accept or any request, including `status`). Drives the idle timeout.
    var lastActivityForTesting: Date { lastActivity }

    private func requestShutdown() {
        shutdownRequested = true
    }

    private func monitorIdle(server: SocketServer) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            let idle = Date().timeIntervalSince(lastActivity)
            if idle >= idleTimeout {
                FileHandle.standardError.write(Data(
                    "harc-stt: idle timeout (\(Int(idle))s), shutting down\n".utf8
                ))
                shutdownRequested = true
                server.shutdown()
                break
            }
        }
    }
}
