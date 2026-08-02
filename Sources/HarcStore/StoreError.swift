import Foundation

public enum StoreError: Error, LocalizedError, Equatable {
    case databaseOpenFailed(String)
    case migrationFailed(String)
    case notFound
    case originIdentityConflict
    case canonicalPCMHashConflict
    case revisionConflict(expected: UInt64, actual: UInt64)
    case revisionOverflow
    case invalidData(String)
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let reason):
            return "Failed to open database: \(reason)"
        case .migrationFailed(let reason):
            return "Database migration failed: \(reason)"
        case .notFound:
            return "Recording not found"
        case .originIdentityConflict:
            return "The origin recording identity is already bound to different audio"
        case .canonicalPCMHashConflict:
            return "The recording is already bound to a different canonical PCM hash"
        case .revisionConflict(let expected, let actual):
            return "Recording revision conflict: expected \(expected), found \(actual)"
        case .revisionOverflow:
            return "Recording revision exceeded the supported storage range"
        case .invalidData(let reason):
            return reason
        case .readFailed(let reason):
            return "Database read failed: \(reason)"
        case .writeFailed(let reason):
            return "Database write failed: \(reason)"
        }
    }
}
