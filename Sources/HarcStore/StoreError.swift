import Foundation

public enum StoreError: Error, LocalizedError, Equatable {
    case databaseOpenFailed(String)
    case migrationFailed(String)
    case notFound
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let reason):
            return "Failed to open database: \(reason)"
        case .migrationFailed(let reason):
            return "Database migration failed: \(reason)"
        case .notFound:
            return "Recording not found"
        case .writeFailed(let reason):
            return "Database write failed: \(reason)"
        }
    }
}
