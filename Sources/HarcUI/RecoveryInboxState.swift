import Foundation
import HarcStore

public struct RecoveryInboxRowState: Identifiable, Equatable, Sendable {
    public var artifact: RecoveryArtifact

    public var id: String { artifact.id }
    public var title: String { artifact.title }
    public var sourcePath: String { artifact.sourceURL.path }

    public var detail: String {
        if let lastError = artifact.lastError, !lastError.isEmpty {
            return lastError
        }
        return artifact.detail
    }

    public var statusText: String {
        switch artifact.status {
        case .pending: return "Pending"
        case .recovering: return "Recovering"
        case .recovered: return "Recovered"
        case .skipped: return "Skipped"
        case .discarded: return "Discarded"
        case .failed: return "Failed"
        }
    }

    public var canRecover: Bool {
        artifact.status == .pending || artifact.status == .failed || artifact.status == .skipped
    }

    public var canReveal: Bool {
        artifact.status != .recovering
    }

    public var canDiscard: Bool {
        artifact.status == .pending || artifact.status == .failed || artifact.status == .skipped
    }

    public var isVisible: Bool {
        artifact.status != .discarded
    }
}

public enum RecoveryInboxModel {
    public static func rows(for artifacts: [RecoveryArtifact]) -> [RecoveryInboxRowState] {
        artifacts
            .map(RecoveryInboxRowState.init(artifact:))
            .filter(\.isVisible)
    }

    public static func unresolvedCount(in artifacts: [RecoveryArtifact]) -> Int {
        artifacts.filter { artifact in
            switch artifact.status {
            case .pending, .recovering, .failed, .skipped:
                return true
            case .recovered, .discarded:
                return false
            }
        }.count
    }
}
