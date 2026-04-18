import Foundation
import Darwin
import HarcCore

/// Global C string used by the signal handler. Written once before signal
/// registration; never mutated after that, so no synchronisation needed.
private nonisolated(unsafe) var gSocketPath: UnsafeMutablePointer<CChar>? = nil

@main
struct HarcSTTCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--version") {
            print("harc-stt \(HarcVersion.current)")
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print(Self.helpText)
            return
        }

        // Parse optional --socket <path> argument.
        var socketPath = Daemon.defaultSocketPath
        if let idx = args.firstIndex(of: "--socket"), args.indices.contains(idx + 1) {
            socketPath = args[idx + 1]
        }

        installSignalHandlers(socketPath: socketPath)

        let daemon = Daemon(socketPath: socketPath)
        do {
            try await daemon.run()
        } catch {
            FileHandle.standardError.write(Data(
                "harc-stt: daemon exited with error: \(error.localizedDescription)\n".utf8
            ))
            exit(1)
        }
    }

    static let helpText = """
    harc-stt — Harc speech-to-text daemon

    Usage:
      harc-stt                         Start daemon on ~/.harc/stt.sock (idle timeout 30 min)
      harc-stt --socket <path>         Start daemon on a custom socket path
      harc-stt --version               Print version and exit
      harc-stt --help                  Print this help and exit
    """

    /// Install simple SIGTERM/SIGINT handlers that remove the socket and exit.
    /// Using `signal(3)` keeps this async-signal-safe; the handler reads the
    /// pre-set global C string and calls only async-signal-safe functions.
    static func installSignalHandlers(socketPath: String) {
        // Store path in a module-level C string that the signal handler can read.
        gSocketPath = strdup(socketPath)
        let cleanupAndExit: @convention(c) (Int32) -> Void = { _ in
            if let p = gSocketPath { unlink(p) }
            _exit(0)
        }
        signal(SIGTERM, cleanupAndExit)
        signal(SIGINT, cleanupAndExit)
    }
}
