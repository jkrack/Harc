import Foundation
import Darwin
import HarcCore

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

        installSignalHandlers()

        let daemon = Daemon()
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
      harc-stt              Start daemon on ~/.harc/stt.sock (idle timeout 30 min)
      harc-stt --version    Print version and exit
      harc-stt --help       Print this help and exit
    """

    /// Install simple SIGTERM/SIGINT handlers that remove the socket and exit.
    /// Using `signal(3)` keeps this pre-Swift-concurrency-safe; the handler
    /// does only async-signal-safe work.
    static func installSignalHandlers() {
        let cleanupAndExit: @convention(c) (Int32) -> Void = { _ in
            let home = getenv("HOME").flatMap { String(cString: $0) } ?? "/tmp"
            let path = (home as NSString).appendingPathComponent(".harc/stt.sock")
            unlink(path)
            _exit(0)
        }
        signal(SIGTERM, cleanupAndExit)
        signal(SIGINT, cleanupAndExit)
    }
}
