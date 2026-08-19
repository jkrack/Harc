import Foundation

/// One problem found while reconciling the private Client capture archive.
/// Paths stay private to the app; the UI names only the stable recording id.
public struct ClientRecoverSyncIssue: Equatable, Sendable, Identifiable {
    public let id: String
    public let recording: String
    public let message: String

    public init(id: String, recording: String, message: String) {
        self.id = id
        self.recording = recording
        self.message = message
    }
}

/// Auditable result of one ClientState inventory/reconciliation pass.
public struct ClientRecoverSyncReport: Equatable, Sendable {
    public let mastersFound: Int
    public let sidecarsFound: Int
    public let sidecarsRebuilt: Int
    public let outboxesRepaired: Int
    public let alreadyTracked: Int
    public let retryRequested: Int
    public let alreadyOnHost: Int
    public let securityBlocked: Int
    public let issues: [ClientRecoverSyncIssue]

    public init(
        mastersFound: Int,
        sidecarsFound: Int,
        sidecarsRebuilt: Int,
        outboxesRepaired: Int,
        alreadyTracked: Int,
        retryRequested: Int,
        alreadyOnHost: Int,
        securityBlocked: Int,
        issues: [ClientRecoverSyncIssue]
    ) {
        self.mastersFound = mastersFound
        self.sidecarsFound = sidecarsFound
        self.sidecarsRebuilt = sidecarsRebuilt
        self.outboxesRepaired = outboxesRepaired
        self.alreadyTracked = alreadyTracked
        self.retryRequested = retryRequested
        self.alreadyOnHost = alreadyOnHost
        self.securityBlocked = securityBlocked
        self.issues = issues
    }

    public var headline: String {
        if !issues.isEmpty || securityBlocked > 0 {
            return "Recovery finished with items needing attention"
        }
        if retryRequested > 0 {
            return "Retrying \(retryRequested) recording\(retryRequested == 1 ? "" : "s")"
        }
        if mastersFound > 0, alreadyOnHost == mastersFound {
            return "All Client recordings are on the Host"
        }
        return mastersFound == 0
            ? "No Client recordings found"
            : "Client archive is reconciled"
    }

    public var detail: String {
        var parts = ["Found \(mastersFound) master\(mastersFound == 1 ? "" : "s")"]
        let repaired = sidecarsRebuilt + outboxesRepaired
        if repaired > 0 { parts.append("repaired \(repaired)") }
        if alreadyOnHost > 0 { parts.append("\(alreadyOnHost) on Host") }
        if retryRequested > 0 { parts.append("retry started for \(retryRequested)") }
        if securityBlocked > 0 { parts.append("\(securityBlocked) security blocked") }
        if !issues.isEmpty { parts.append("\(issues.count) need attention") }
        return parts.joined(separator: " • ")
    }
}

public enum ClientRecoverSyncState: Equatable, Sendable {
    case ready
    case running
    case completed(ClientRecoverSyncReport)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
