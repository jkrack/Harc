import Foundation
import Testing
import GRDB
@testable import HarcStore

@Suite("Evidence-backed project refinement")
struct ProjectRefinementTests {
    private func fixture() async throws -> (RecordingStore, ProjectMatchReview) {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/project-review-\(UUID().uuidString).wav", startedAt: Date(timeIntervalSince1970: 1),
            transcriptText: "We should discuss the Harc launch next week."))
        let project = try await store.createKnowledgeProject(name: "Harc")
        let review = try await store.proposeProjectMatch(recordingID: recording.id!, projectID: project.id,
            quote: "the Harc launch", generatorID: "synthetic-test-v1")
        return (store, review)
    }

    @Test func acceptReplayAndUndo() async throws {
        let (store, review) = try await fixture()
        let op = UUID()
        let receipt = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: op)
        #expect(receipt.newlyLinkedRecordings == 1)
        #expect(try await store.confirmedProjectMatches(recordingID: review.recordingID).count == 1)
        #expect(try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: op) == receipt)
        #expect(try await store.undoProjectMatch(operationID: op) == 1)
        #expect(try await store.undoProjectMatch(operationID: op) == 0)
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: op)
        #expect(try await store.confirmedProjectMatches(recordingID: review.recordingID).isEmpty)
    }

    @Test func alreadyAcceptedHasZeroNewImpactAndUndoPreservesLink() async throws {
        let (store, review) = try await fixture()
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        let accepted = try await store.projectMatchReview(id: review.id)
        let second = try await store.decideProjectMatch(id: review.id, expectedVersion: accepted.version, decision: .accepted, operationID: UUID())
        #expect(second.newlyLinkedRecordings == 0)
        #expect(try await store.undoProjectMatch(operationID: second.operationID) == 0)
        #expect(try await store.confirmedProjectMatches(recordingID: review.recordingID).count == 1)
    }

    @Test(arguments: [ProjectReviewDecision.rejected, .unsure])
    func decisionsSurviveRegeneration(decision: ProjectReviewDecision) async throws {
        let (store, review) = try await fixture()
        let receipt = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: decision, operationID: UUID())
        #expect(receipt.newlyLinkedRecordings == 0)
        let generated = try await store.proposeProjectMatch(recordingID: review.recordingID, projectID: review.project.id,
            quote: "Harc", generatorID: "different-model")
        #expect(generated.decision == decision)
        #expect(generated.id == review.id)
        #expect(try await store.confirmedProjectMatches(recordingID: review.recordingID).isEmpty)
    }

    @Test func staleTranscriptCannotBeAcceptedOrProjected() async throws {
        let (store, review) = try await fixture()
        // A synthetic DB edit avoids transcript projection filesystem effects.
        try await store.db.write { db in
            try db.execute(sql: "UPDATE recordings SET transcript_text = ? WHERE id = ?",
                arguments: ["We canceled the Harc launch.", review.recordingID])
        }
        await #expect(throws: ProjectRefinementError.staleEvidence) {
            try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        }
        #expect(try await store.projectMatchReview(id: review.id).decision == .pending)
    }

    @Test func acceptedLinkBecomesStaleWithoutLosingHistory() async throws {
        let (store, review) = try await fixture()
        let receipt = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        try await store.db.write { db in
            try db.execute(sql: "UPDATE recordings SET transcript_text = 'Changed' WHERE id = ?", arguments: [review.recordingID])
        }
        let links = try await store.confirmedProjectMatches(recordingID: review.recordingID)
        #expect(links.count == 1)
        #expect(links.first?.evidenceIsCurrent == false)
        #expect(try await store.projectMatchReview(id: review.id).decision == .accepted)
        #expect(try await store.undoProjectMatch(operationID: receipt.operationID) == 1)
        #expect(try await store.projectMatchReview(id: review.id).decision == .pending)
    }

    @Test func laterDecisionPreventsOlderUndo() async throws {
        let (store, review) = try await fixture()
        let first = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        let current = try await store.projectMatchReview(id: review.id)
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: current.version, decision: .rejected, operationID: UUID())
        await #expect(throws: ProjectRefinementError.conflict) { try await store.undoProjectMatch(operationID: first.operationID) }
        #expect(try await store.projectMatchReview(id: review.id).decision == .rejected)
    }

    @Test func reusedOperationCannotAuthorizeDifferentDecision() async throws {
        let (store, review) = try await fixture()
        let op = UUID()
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .rejected, operationID: op)
        await #expect(throws: ProjectRefinementError.operationMismatch) {
            try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: op)
        }
    }

    @Test func forgedQuoteIsRejectedAndDeletionCascades() async throws {
        let (store, review) = try await fixture()
        let other = try await store.createKnowledgeProject(name: "Other")
        await #expect(throws: ProjectRefinementError.invalidEvidence) {
            try await store.proposeProjectMatch(recordingID: review.recordingID, projectID: other.id,
                quote: "Never said this", generatorID: "fixture")
        }
        let receipt = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        try await store.db.write { db in
            try db.execute(sql: "DELETE FROM recordings WHERE id = ?", arguments: [review.recordingID])
        }
        await #expect(throws: ProjectRefinementError.missing) { try await store.projectMatchReview(id: review.id) }
        await #expect(throws: ProjectRefinementError.missing) { try await store.undoProjectMatch(operationID: receipt.operationID) }
    }
    @Test func changedProjectSnapshotRequiresNewReview() async throws {
        let (store, review) = try await fixture()
        let renamed = KnowledgeProject(id: review.project.id, name: "Changed meaning", version: UUID())
        try await store.db.write { db in
            try db.execute(sql: "UPDATE knowledge_projects SET payload = ? WHERE id = ?",
                arguments: [try JSONEncoder().encode(renamed), renamed.id.uuidString])
        }
        await #expect(throws: ProjectRefinementError.staleEvidence) {
            try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        }
    }

    @Test func repeatedTapWithNewOperationCannotApplyOldVersion() async throws {
        let (store, review) = try await fixture()
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        await #expect(throws: ProjectRefinementError.conflict) {
            try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .rejected, operationID: UUID())
        }
        #expect(try await store.projectMatchReview(id: review.id).decision == .accepted)
    }

    @Test func softDeletedRecordingsCannotBeSuggestedAcceptedOrProjected() async throws {
        let (store, review) = try await fixture()
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        let accepted = try await store.projectMatchReview(id: review.id)
        try await store.softDelete(id: review.recordingID)
        await #expect(throws: ProjectRefinementError.missing) {
            try await store.decideProjectMatch(id: review.id, expectedVersion: accepted.version,
                decision: .accepted, operationID: UUID())
        }
        #expect(try await store.confirmedProjectMatches(recordingID: review.recordingID).isEmpty)
        await #expect(throws: ProjectRefinementError.missing) {
            try await store.proposeProjectMatch(recordingID: review.recordingID, projectID: review.project.id,
                quote: "Harc", generatorID: "test")
        }
        let other = try await store.createKnowledgeProject(name: "Other")
        await #expect(throws: ProjectRefinementError.missing) {
            try await store.proposeProjectMatch(recordingID: review.recordingID, projectID: other.id,
                quote: "Harc", generatorID: "test")
        }
    }

    @Test func metadataRevisionDoesNotInvalidateTranscriptEvidence() async throws {
        let (store, review) = try await fixture()
        // A general metadata revision changes without changing source text.
        try await store.db.write { db in
            try db.execute(sql: "UPDATE recordings SET title = 'New title', revision = revision + 1 WHERE id = ?", arguments: [review.recordingID])
        }
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .accepted, operationID: UUID())
        #expect(try await store.confirmedProjectMatches(recordingID: review.recordingID).first?.evidenceIsCurrent == true)
    }

    @Test func staleHypothesisCanBeDismissed() async throws {
        let (store, review) = try await fixture()
        try await store.db.write { db in
            try db.execute(sql: "UPDATE recordings SET transcript_text = 'Changed' WHERE id = ?", arguments: [review.recordingID])
        }
        _ = try await store.decideProjectMatch(id: review.id, expectedVersion: review.version, decision: .unsure, operationID: UUID())
        #expect(try await store.projectMatchReview(id: review.id).decision == .unsure)
    }

}
