import Foundation

/// Presentation inputs describe observed state, never permission to transfer.
struct HarcMobileSyncStatusPresentation: Equatable {
    enum Host: Equatable {
        case unpaired, checking, connected, unavailable, repairRequired
    }

    enum Transfer: Equatable {
        case preparing, idle, working, waitingForPairing
        case qualificationRequired, retryNeeded, securityBlocked, receiptVerified
    }

    enum Reason: Equatable {
        case preparing, qualificationRequired, unpaired, checking, offline
        case securityBlocked, retryNeeded, working, waiting, nothingPending, receiptVerified
    }

    enum Action: Equatable {
        case none, hostSettings, localRecordings, retryTransfers
    }

    let reason: Reason
    let title: String
    let detail: String
    let pendingCount: Int
    let action: Action
    let qualificationNotice: String?

    static let qualificationExplanation =
        "This build keeps audio transfers off until transfer safety checks are complete. "
        + "Recordings remain on this iPhone for playback and export. Retry cannot enable transfers."

    static func make(
        host: Host,
        transfer: Transfer,
        codecQualified: Bool,
        pendingCount: Int
    ) -> Self {
        let pending = max(0, pendingCount)
        func status(_ reason: Reason, _ title: String, _ detail: String, _ action: Action) -> Self {
            Self(reason: reason, title: title, detail: detail, pendingCount: pending,
                 action: action, qualificationNotice: codecQualified ? nil : qualificationExplanation)
        }
        if transfer == .preparing {
            return status(.preparing, "Preparing sync status", "Local recordings remain available on this iPhone.", .none)
        }
        if host == .repairRequired || transfer == .securityBlocked {
            return status(.securityBlocked, "Host access needs attention",
                          "Transfer stopped for a security or authorization check. Review Host access before trying again. Local recordings remain protected.", .hostSettings)
        }
        if !codecQualified || transfer == .qualificationRequired {
            return status(.qualificationRequired, "Transfers not enabled in this build",
                          qualificationExplanation, .localRecordings)
        }
        if host == .unpaired || transfer == .waitingForPairing {
            return status(.unpaired, "Pair a Host to sync",
                          "Local recording, playback and export work without a Host. Pair with your Mac to use its Library and permitted transfers.", .hostSettings)
        }
        if transfer == .working {
            return status(.working, "Transfer in progress",
                          "Keep the local recording until the Host returns a verified durable receipt.", .none)
        }
        if pending == 0 {
            if transfer == .receiptVerified {
                return status(.receiptVerified, "Transfer verified on Host",
                              "A verified durable receipt was received. No recordings are currently waiting to transfer.", .localRecordings)
            }
            return status(.nothingPending, "No recordings waiting to transfer",
                          "Local recordings remain available on this iPhone. Host Library status is shown separately below.", .localRecordings)
        }
        if host == .unavailable {
            return status(.offline, "Waiting for your Host",
                          "The adopted Host could not be reached. Open Harc on your Mac and check the connection. Recordings remain on this iPhone.", .hostSettings)
        }
        if host == .checking {
            return status(.checking, "Checking Host connection",
                          "Harc is verifying the adopted Host before transfer.", .none)
        }
        if transfer == .retryNeeded {
            return status(.retryNeeded, "Transfer needs another attempt",
                          "The transfer did not complete. Your recording remains on this iPhone.", .retryTransfers)
        }
        return status(.waiting, "Recordings waiting to transfer",
                      "Your recordings remain on this iPhone until the Host verifies receipt.", .retryTransfers)
    }
}

struct HarcMobileSyncLibraryEvidence: Equatable {
    enum State: Equatable {
        case preparing, unpaired, accessNotGranted, refreshing
        case ready(completedAt: Date?), offline, failed, cancelled
    }

    enum Action: Equatable { case none, hostSettings, refresh }

    let lastSuccessfulRefresh: Date?
    let action: Action

    init(_ state: State) {
        switch state {
        case .preparing, .refreshing:
            lastSuccessfulRefresh = nil
            action = .none
        case .unpaired, .accessNotGranted:
            lastSuccessfulRefresh = nil
            action = .hostSettings
        case .ready(let date):
            lastSuccessfulRefresh = date
            action = .refresh
        case .offline, .failed, .cancelled:
            lastSuccessfulRefresh = nil
            action = .refresh
        }
    }
}

enum HarcMobileSyncAccessibilityID {
    static let libraryStatus = "harc.mobile.library.sync-status"
    static let hostStatusLink = "harc.mobile.host.sync-status"
    static let detail = "harc.mobile.sync.detail"
    static let transferStatus = "harc.mobile.sync.transfer-status"
    static let pendingCount = "harc.mobile.sync.pending-count"
    static let host = "harc.mobile.sync.host"
    static let library = "harc.mobile.sync.library"
    static let localRecordings = "harc.mobile.sync.local-recordings"
    static let retryTransfers = "harc.mobile.sync.retry-transfers"
}
