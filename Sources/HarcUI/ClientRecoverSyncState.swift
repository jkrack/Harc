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
    public let localLibraryAdded: Int
    public let alreadyInLocalLibrary: Int
    public let transcribedLocally: Int
    public let localTranscriptReused: Int
    public let localRecoveryFailed: Int
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
        localLibraryAdded: Int = 0,
        alreadyInLocalLibrary: Int = 0,
        transcribedLocally: Int = 0,
        localTranscriptReused: Int = 0,
        localRecoveryFailed: Int = 0,
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
        self.localLibraryAdded = localLibraryAdded
        self.alreadyInLocalLibrary = alreadyInLocalLibrary
        self.transcribedLocally = transcribedLocally
        self.localTranscriptReused = localTranscriptReused
        self.localRecoveryFailed = localRecoveryFailed
        self.retryRequested = retryRequested
        self.alreadyOnHost = alreadyOnHost
        self.securityBlocked = securityBlocked
        self.issues = issues
    }

    public var headline: String {
        if localRecoveryFailed > 0 || !issues.isEmpty || securityBlocked > 0 {
            return "Recovery finished with items needing attention"
        }
        if localLibraryAdded > 0 || transcribedLocally > 0 {
            let recovered = localLibraryAdded > 0
                ? localLibraryAdded : transcribedLocally
            return "Recovered \(recovered) recording\(recovered == 1 ? "" : "s") on this Mac"
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
        let localTotal = localLibraryAdded + alreadyInLocalLibrary
        if localTotal > 0 { parts.append("\(localTotal) in local Library") }
        if transcribedLocally > 0 {
            parts.append("transcribed \(transcribedLocally) locally")
        }
        if localTranscriptReused > 0 {
            parts.append("reused \(localTranscriptReused) transcript\(localTranscriptReused == 1 ? "" : "s")")
        }
        if localRecoveryFailed > 0 {
            parts.append("\(localRecoveryFailed) local recover\(localRecoveryFailed == 1 ? "y" : "ies") failed")
        }
        if alreadyOnHost > 0 { parts.append("\(alreadyOnHost) on Host") }
        if retryRequested > 0 { parts.append("Host delivery queued for \(retryRequested)") }
        if securityBlocked > 0 { parts.append("\(securityBlocked) security blocked") }
        if !issues.isEmpty { parts.append("\(issues.count) need attention") }
        return parts.joined(separator: " • ")
    }

    public func includingLocalRecovery(
        added: Int,
        alreadyVisible: Int,
        transcribed: Int,
        transcriptReused: Int,
        failed: Int,
        issues localIssues: [ClientRecoverSyncIssue]
    ) -> ClientRecoverSyncReport {
        ClientRecoverSyncReport(
            mastersFound: mastersFound,
            sidecarsFound: sidecarsFound,
            sidecarsRebuilt: sidecarsRebuilt,
            outboxesRepaired: outboxesRepaired,
            alreadyTracked: alreadyTracked,
            localLibraryAdded: added,
            alreadyInLocalLibrary: alreadyVisible,
            transcribedLocally: transcribed,
            localTranscriptReused: transcriptReused,
            localRecoveryFailed: failed,
            retryRequested: retryRequested,
            alreadyOnHost: alreadyOnHost,
            securityBlocked: securityBlocked,
            issues: issues + localIssues
        )
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
