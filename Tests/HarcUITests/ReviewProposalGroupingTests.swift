import Foundation
import HarcContext
import Testing
@testable import HarcUI

@Suite("Review proposal grouping")
struct ReviewProposalGroupingTests {
    @Test("groups queue proposals into countable buckets")
    func groupsQueueProposalsIntoCountableBuckets() {
        let proposals = [
            proposal(id: "approved", status: .approved),
            proposal(id: "pending-high", status: .pending, impact: .high, createdAt: Date(timeIntervalSince1970: 10)),
            proposal(id: "edited", status: .edited, impact: .low, createdAt: Date(timeIntervalSince1970: 5)),
            proposal(id: "dismissed", status: .dismissed),
            proposal(id: "failed", status: .failed),
        ]

        let grouping = ReviewProposalGrouping.make(from: proposals)

        #expect(grouping.buckets.map(\.id) == ["pending", "approved", "failed", "dismissed"])
        #expect(grouping.pendingCount == 2)
        #expect(grouping.approvedCount == 1)
        #expect(grouping.failedCount == 1)
        #expect(grouping.dismissedCount == 1)
        #expect(grouping.buckets[0].proposals.map(\.id) == ["edited", "pending-high"])
    }

    @Test("sorts pending proposals by impact then recency")
    func sortsPendingByImpactThenRecency() {
        let proposals = [
            proposal(id: "older-medium", status: .pending, impact: .medium, createdAt: Date(timeIntervalSince1970: 1)),
            proposal(id: "newer-low", status: .pending, impact: .low, createdAt: Date(timeIntervalSince1970: 100)),
            proposal(id: "newer-medium", status: .pending, impact: .medium, createdAt: Date(timeIntervalSince1970: 100)),
            proposal(id: "high", status: .pending, impact: .high, createdAt: Date(timeIntervalSince1970: 50)),
        ]

        let pending = ReviewProposalGrouping.make(from: proposals).buckets.first?.proposals.map(\.id)

        #expect(pending == ["high", "newer-medium", "older-medium", "newer-low"])
    }

    private func proposal(
        id: String,
        status: WikiReviewProposalStatus,
        impact: WikiReviewProposalImpact = .medium,
        createdAt: Date = Date(timeIntervalSince1970: 1)
    ) -> WikiReviewProposal {
        WikiReviewProposal(
            id: id,
            kind: .createPage,
            status: status,
            impact: impact,
            title: "Create \(id)",
            summary: "Summary",
            targetSection: .projects,
            targetTitle: id,
            proposedMarkdown: "# \(id)",
            sourceCitations: [],
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
