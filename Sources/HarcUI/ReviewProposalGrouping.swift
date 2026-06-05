import Foundation
import HarcContext

struct ReviewProposalBucket: Identifiable, Equatable {
    var id: String
    var title: String
    var proposals: [WikiReviewProposal]
    var systemImage: String
    var count: Int { proposals.count }
}

struct ReviewProposalGrouping: Equatable {
    var buckets: [ReviewProposalBucket]

    var pendingCount: Int {
        buckets.first(where: { $0.id == "pending" })?.count ?? 0
    }

    var approvedCount: Int {
        buckets.first(where: { $0.id == "approved" })?.count ?? 0
    }

    var dismissedCount: Int {
        buckets.first(where: { $0.id == "dismissed" })?.count ?? 0
    }

    var failedCount: Int {
        buckets.first(where: { $0.id == "failed" })?.count ?? 0
    }

    var totalCount: Int {
        buckets.reduce(0) { $0 + $1.count }
    }

    static func make(from proposals: [WikiReviewProposal]) -> ReviewProposalGrouping {
        let sorted = proposals.sorted {
            if $0.status != $1.status {
                return statusRank($0.status) < statusRank($1.status)
            }
            if $0.impact != $1.impact {
                return impactRank($0.impact) < impactRank($1.impact)
            }
            return $0.createdAt > $1.createdAt
        }

        let pending = sorted.filter { $0.status == .pending || $0.status == .edited }
        let approved = sorted.filter { $0.status == .approved }
        let dismissed = sorted.filter { $0.status == .dismissed }
        let failed = sorted.filter { $0.status == .failed }

        return ReviewProposalGrouping(buckets: [
            ReviewProposalBucket(id: "pending", title: "Pending", proposals: pending, systemImage: "tray.full"),
            ReviewProposalBucket(id: "approved", title: "Approved", proposals: approved, systemImage: "checkmark.circle"),
            ReviewProposalBucket(id: "failed", title: "Needs Attention", proposals: failed, systemImage: "exclamationmark.triangle"),
            ReviewProposalBucket(id: "dismissed", title: "Dismissed", proposals: dismissed, systemImage: "xmark.circle"),
        ].filter { !$0.proposals.isEmpty })
    }

    private static func statusRank(_ status: WikiReviewProposalStatus) -> Int {
        switch status {
        case .edited: return 0
        case .pending: return 1
        case .failed: return 2
        case .approved: return 3
        case .dismissed: return 4
        }
    }

    private static func impactRank(_ impact: WikiReviewProposalImpact) -> Int {
        switch impact {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}
