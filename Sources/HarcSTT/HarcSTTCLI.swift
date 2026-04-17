import Foundation
import HarcCore

@main
struct HarcSTTCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--version") {
            print("harc-stt \(HarcVersion.current)")
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print(Self.helpText)
            return
        }
        FileHandle.standardError.write(Data(
            "harc-stt: daemon mode not yet implemented (see Plan 2). Run with --help.\n".utf8
        ))
        exit(1)
    }

    static let helpText = """
    harc-stt — Harc speech-to-text daemon

    Usage:
      harc-stt              Start daemon (not yet implemented)
      harc-stt --version    Print version and exit
      harc-stt --help       Print this help and exit
    """
}
