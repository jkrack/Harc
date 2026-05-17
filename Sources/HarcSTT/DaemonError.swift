import Foundation

public enum DaemonError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case audioLoadFailed(String)
    case transcriptionFailed(String)
    case socketCreationFailed(Int32)
    case socketBindFailed(Int32)
    case socketListenFailed(Int32)
    case socketPathTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model not loaded — call loadModels() first"
        case .audioLoadFailed(let reason):
            return "Audio load failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .socketCreationFailed(let errno):
            return "Failed to create socket (errno \(errno))"
        case .socketBindFailed(let errno):
            return "Failed to bind socket (errno \(errno))"
        case .socketListenFailed(let errno):
            return "Failed to listen on socket (errno \(errno))"
        case .socketPathTooLong(let path):
            return "Socket path is too long for AF_UNIX: \(path)"
        }
    }

    /// Maps to an IPCError with a stable code string so clients can switch on it.
    public var ipcCode: String {
        switch self {
        case .modelNotLoaded: return "model_not_loaded"
        case .audioLoadFailed: return "audio_load_failed"
        case .transcriptionFailed: return "transcription_failed"
        case .socketCreationFailed, .socketBindFailed, .socketListenFailed, .socketPathTooLong: return "socket_error"
        }
    }
}
