import Foundation

public enum AudioError: Error, LocalizedError, Equatable {
    case micPermissionDenied
    case systemAudioPermissionDenied
    case audioEngineFailed(String)
    case systemAudioStreamFailed(String)
    case fileWriteFailed(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone access denied. Grant permission in System Settings → Privacy & Security → Microphone."
        case .systemAudioPermissionDenied:
            return "Screen recording access denied. Grant permission in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .audioEngineFailed(let reason):
            return "Audio engine failure: \(reason)"
        case .systemAudioStreamFailed(let reason):
            return "System audio capture failed: \(reason)"
        case .fileWriteFailed(let reason):
            return "Audio file write failed: \(reason)"
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        }
    }
}
