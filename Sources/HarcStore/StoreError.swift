import Foundation

public enum StoreError: Error, LocalizedError, Equatable {
    case databaseOpenFailed(String)
    case migrationFailed(String)
    case notFound
    case originIdentityConflict
    case canonicalPCMHashConflict
    case writerLeaseUnavailable
    case unsafeWriterLeasePath(String)
    case staleHostWriterMarker
    case hostWriterTupleMismatch
    case hostWriterCapabilityRequired
    case canonicalRecordingIdentityConflict
    case canonicalRecordingPathConflict
    case canonicalArtifactIdentityMismatch
    case changeCursorOverflow
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
        case .writerLeaseUnavailable:
            return "Another process currently owns the canonical library writer lease"
        case .unsafeWriterLeasePath(let reason):
            return "The canonical library writer lease path is unsafe: \(reason)"
        case .staleHostWriterMarker:
            return "The library is marked as Host-owned without a matching live writer lease"
        case .hostWriterTupleMismatch:
            return "The canonical library Host identity does not match the requested writer tuple"
        case .hostWriterCapabilityRequired:
            return "A live Host writer capability is required for canonical remote commit"
        case .canonicalRecordingIdentityConflict:
            return "The canonical recording identity is already bound to another recording"
        case .canonicalRecordingPathConflict:
            return "The canonical recording path is already bound to another recording"
        case .canonicalArtifactIdentityMismatch:
            return "The canonical WAV pathname no longer names the validated artifact"
        case .changeCursorOverflow:
            return "The canonical library change cursor exceeded the supported storage range"
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
