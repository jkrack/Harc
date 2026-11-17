import Foundation
import Testing
import HarcDomain
@testable import HarcStore

@Suite("Bounded Host project-name producer")
struct ProjectMentionProducerTests {
    private func fixture(_ texts: [String]) async throws -> (RecordingStore, [Recording], KnowledgeProject, HostWriterLease, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-producer-\(UUID())")
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("fixture.sqlite"))
        var recordings: [Recording] = []
        for (index, text) in texts.enumerated() {
            recordings.append(try await store.upsert(Recording(wavPath: root.appendingPathComponent("\(index).wav").path,
                startedAt: Date(), transcriptText: text)))
        }
        let project = try await store.createKnowledgeProject(name: "Harc")
        let metadata = try await store.libraryMetadata()
        let lease = try await store.enableHostMode(expectedLibraryID: metadata.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x72, count: 32)), hostStateID: .random())
        return (store, recordings, project, lease, root)
    }

    @Test func literalMentionsRemainPendingAndPreserveContext() async throws {
        let (store, recordings, project, _, root) = try await fixture([
            "Not about Harc; quoted only.", "Harcourt is unrelated.", "éHarc is a larger word.", "Discuss Harc."])
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.prepareProjectMentionProposals(recordingIDs: recordings.compactMap(\.id),
            projectID: project.id, expectedHost: store.libraryMetadata())
        #expect(batch.candidateCount == 2)
        let result = try await store.commitProjectMentionProposals(batch)
        #expect(result.inserted == 2)
        #expect(result.stale == 0)
        let cards = try await store.pendingProjectReviewCards()
        #expect(cards.contains { $0.review.quote == "Not about Harc; quoted only." })
        #expect(cards.allSatisfy { $0.review.decision == .pending && $0.review.generatorID == "literal-project-name-v1" })
        #expect(try await store.confirmedProjectMatches(recordingID: recordings[0].id!).isEmpty)
        #expect(try await store.commitProjectMentionProposals(batch).existing == 2)
    }

    @Test func changedTranscriptCannotRebindEvenWhenQuoteRemains() async throws {
        let (store, recordings, project, _, root) = try await fixture(["Harc " + String(repeating: "a", count: 600)])
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.prepareProjectMentionProposals(recordingIDs: [recordings[0].id!],
            projectID: project.id, expectedHost: store.libraryMetadata())
        var changed = recordings[0]
        changed.transcriptText! += " changed outside excerpt"
        _ = try await store.upsert(changed)
        let result = try await store.commitProjectMentionProposals(batch)
        #expect(result.stale == 1)
        #expect(result.inserted == 0)
    }

    @Test(arguments: [ProjectReviewDecision.rejected, .unsure])
    func neverOverwritesHumanDecision(_ decision: ProjectReviewDecision) async throws {
        let (store, recordings, project, _, root) = try await fixture(["Harc discussed."])
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.prepareProjectMentionProposals(recordingIDs: [recordings[0].id!],
            projectID: project.id, expectedHost: store.libraryMetadata())
        _ = try await store.commitProjectMentionProposals(batch)
        let card = try await store.pendingProjectReviewCards().first!
        _ = try await store.decideProjectMatch(id: card.id, expectedVersion: card.review.version, decision: decision, operationID: UUID())
        #expect(try await store.commitProjectMentionProposals(batch).existing == 1)
        #expect(try await store.projectMatchReview(id: card.id).decision == decision)
    }

    @Test func revokedHostAndOversizedRequestsFailClosed() async throws {
        let (store, recordings, project, lease, root) = try await fixture(["Harc discussed."])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try await store.libraryMetadata()
        await #expect(throws: ProjectRefinementError.invalidEvidence) {
            _ = try await store.prepareProjectMentionProposals(recordingIDs: Array(repeating: recordings[0].id!, count: 26), projectID: project.id, expectedHost: host)
        }
        let batch = try await store.prepareProjectMentionProposals(recordingIDs: [recordings[0].id!], projectID: project.id, expectedHost: host)
        try await store.disableHostMode(lease)
        await #expect(throws: ProjectRefinementError.hostUnavailable) { _ = try await store.commitProjectMentionProposals(batch) }
        #expect(try await store.pendingProjectReviewCards().isEmpty)
    }
    @Test func trashedSourceIsNotProposedOrCommitted() async throws {
        let (store, recordings, project, _, root) = try await fixture(["Harc discussed."])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try await store.libraryMetadata()
        let batch = try await store.prepareProjectMentionProposals(recordingIDs: [recordings[0].id!], projectID: project.id, expectedHost: host)
        try await store.softDelete(id: recordings[0].id!)
        #expect(try await store.commitProjectMentionProposals(batch).stale == 1)
        #expect(try await store.prepareProjectMentionProposals(recordingIDs: [recordings[0].id!], projectID: project.id, expectedHost: host).candidateCount == 0)
    }

    @Test func cancelledCommitWritesNothing() async throws {
        let (store, recordings, project, _, root) = try await fixture(["Harc discussed."])
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.prepareProjectMentionProposals(recordingIDs: [recordings[0].id!], projectID: project.id, expectedHost: store.libraryMetadata())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.commitProjectMentionProposals(batch)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await store.pendingProjectReviewCards().isEmpty)
    }

}
