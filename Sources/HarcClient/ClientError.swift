import Foundation

public enum ClientError: Error, LocalizedError, Equatable {
    case daemonNotReachable(String)
    case daemonLaunchFailed(String)
    case ipcEncodeFailed(String)
    case ipcDecodeFailed(String)
    case transcribeFailed(code: String, message: String)
    case chunkerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .daemonNotReachable(let reason):
            return "Daemon not reachable: \(reason)"
        case .daemonLaunchFailed(let reason):
            return "Failed to launch daemon: \(reason)"
        case .ipcEncodeFailed(let reason):
            return "Failed to encode IPC request: \(reason)"
        case .ipcDecodeFailed(let reason):
            return "Failed to decode IPC response: \(reason)"
        case .transcribeFailed(let code, let message):
            return "Transcription failed [\(code)]: \(message)"
        case .chunkerFailed(let reason):
            return "Audio chunker failed: \(reason)"
        }
    }
}
