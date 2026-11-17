import Foundation
import Testing
import GRDB
@testable import HarcStore
@testable import HarcUI

@MainActor
@Suite("Project refinement presentation")
struct ProjectRefinementViewModelTests {
    private func fixture(onCommitted: @escaping () -> Void = {}) async throws -> (RecordingStore, ProjectRefinementViewModel) {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(Recording(wavPath: "/tmp/project-ui-\(UUID()).wav", startedAt: Date(),
            title: "Launch planning", transcriptText: "We discussed the Harc launch."))
        let project = try await store.createKnowledgeProject(name: "Harc")
        _ = try await store.proposeProjectMatch(recordingID: rec.id!, projectID: project.id,
            quote: "the Harc launch", generatorID: "fixture")
        let vm = ProjectRefinementViewModel(store: store, onCommitted: onCommitted)
        await vm.load()
        return (store, vm)
    }

    @Test func acceptHasHonestImpactAndUndoReturnsCard() async throws {
        var commits = 0
        let (store, vm) = try await fixture { commits += 1 }
        let card = try #require(vm.cards.first)
        await vm.decide(card, decision: .accepted)
        #expect(vm.cards.isEmpty)
        #expect(vm.confirmations.first?.message == "Added 1 recording to Harc.")
        #expect(commits == 1)
        await vm.decide(card, decision: .accepted)
        #expect(commits == 1)
        await vm.undo(try #require(vm.confirmations.first))
        #expect(vm.cards.count == 1)
        #expect(vm.confirmations.first?.undone == true)
        #expect(vm.statusMessage == "Answer undone.")
        #expect(try await store.confirmedProjectMatches(recordingID: card.review.recordingID).isEmpty)
    }

    @Test func unsureIsAvailableOnlyWhenExplicitlyRevisited() async throws {
        let (_, vm) = try await fixture()
        await vm.decide(try #require(vm.cards.first), decision: .unsure)
        await vm.load()
        #expect(vm.cards.isEmpty)
        await vm.load(deferred: true)
        #expect(vm.cards.count == 1)
        #expect(vm.cards.first?.review.decision == .unsure)
    }

    @Test func failedTransactionShowsNoRewardAndRetryCommitsOnce() async throws {
        var commits = 0
        let (store, vm) = try await fixture { commits += 1 }
        let card = try #require(vm.cards.first)
        let db = await store.uncoordinatedDB
        try await db.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_review BEFORE INSERT ON project_review_events BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        await vm.decide(card, decision: .accepted)
        #expect(vm.errorMessage != nil)
        #expect(vm.confirmations.isEmpty)
        #expect(commits == 0)
        #expect(try await store.projectMatchReview(id: card.id).decision == .pending)
        try await db.write { try $0.execute(sql: "DROP TRIGGER fail_review") }
        await vm.decide(card, decision: .accepted)
        #expect(vm.confirmations.count == 1)
        #expect(commits == 1)
    }

    @Test func staleEvidenceBlocksYesButAllowsDismissal() async throws {
        let (store, vm) = try await fixture()
        let card = try #require(vm.cards.first)
        let db = await store.uncoordinatedDB
        try await db.write { db in
            try db.execute(sql: "UPDATE recordings SET transcript_text = 'Changed' WHERE id = ?", arguments: [card.review.recordingID])
        }
        await vm.load()
        let stale = try #require(vm.cards.first)
        #expect(!stale.evidenceIsCurrent)
        await vm.decide(stale, decision: .accepted)
        #expect(vm.confirmations.isEmpty)
        await vm.decide(stale, decision: .rejected)
        #expect(vm.confirmations.first?.message == "Connection dismissed.")
    }

    @Test func explicitRefreshRequiresAnotherVisibleReview() async throws {
        let (store, vm) = try await fixture()
        let card = try #require(vm.cards.first)
        let db = await store.uncoordinatedDB
        try await db.write { db in
            try db.execute(sql: "UPDATE recordings SET transcript_text = 'We discussed the Harc launch, but delayed it.' WHERE id = ?", arguments: [card.review.recordingID])
        }
        await vm.load()
        await vm.refresh(try #require(vm.cards.first))
        #expect(vm.cards.first?.evidenceIsCurrent == true)
        #expect(vm.cards.first?.review.version != card.review.version)
        #expect(vm.confirmations.isEmpty)
    }

    @Test func inactivePanelCannotSave() async throws {
        let (_, vm) = try await fixture()
        let card = try #require(vm.cards.first)
        vm.deactivate()
        await vm.decide(card, decision: .accepted)
        #expect(vm.confirmations.isEmpty)
    }
    @Test func recreatedPanelRestoresUndoHistory() async throws {
        let (store, first) = try await fixture()
        await first.decide(try #require(first.cards.first), decision: .accepted)
        let reopened = ProjectRefinementViewModel(store: store)
        await reopened.load()
        #expect(reopened.confirmations.count == 1)
        #expect(reopened.statusMessage == nil)
        #expect(reopened.confirmations.first?.canUndo == true)
        await reopened.undo(try #require(reopened.confirmations.first))
        #expect(reopened.cards.count == 1)
    }

    @Test func deferredStaleEvidenceCanBeRefreshedAndAccepted() async throws {
        let (store, vm) = try await fixture()
        let card = try #require(vm.cards.first)
        await vm.decide(card, decision: .unsure)
        let db = await store.uncoordinatedDB
        try await db.write { db in
            try db.execute(sql: "UPDATE recordings SET transcript_text = 'We discussed the Harc launch again.' WHERE id = ?", arguments: [card.review.recordingID])
        }
        await vm.load(deferred: true)
        #expect(vm.cards.first?.evidenceIsCurrent == false)
        await vm.refresh(try #require(vm.cards.first))
        let refreshed = try #require(vm.cards.first)
        #expect(refreshed.review.decision == .pending)
        #expect(refreshed.evidenceIsCurrent)
        await vm.decide(refreshed, decision: .accepted)
        #expect(try await store.confirmedProjectMatches(recordingID: card.review.recordingID).count == 1)
        #expect(try await store.recentProjectReviewHistory().count == 2)
    }

    @Test func disappearingAndReopeningDuringSaveReactivatesAndReloads() async throws {
        let (store, _) = try await fixture()
        let gate = SaveGate()
        let vm = ProjectRefinementViewModel(store: store, beforeApply: { await gate.wait() })
        await vm.load()
        let card = try #require(vm.cards.first)
        let task = Task { await vm.decide(card, decision: .accepted) }
        while !gate.entered { await Task.yield() }
        vm.deactivate()
        await vm.load()
        gate.release()
        await task.value
        await vm.reloadTask?.value
        #expect(vm.cards.isEmpty)
        #expect(vm.confirmations.count == 1)
        #expect(!vm.isSaving)
        await vm.undo(try #require(vm.confirmations.first))
        #expect(vm.cards.count == 1)
    }

    @Test func historyIsNewestFirstWithoutReannouncingOldSuccess() async throws {
        let (store, vm) = try await fixture()
        let card = try #require(vm.cards.first)
        await vm.decide(card, decision: .unsure)
        await vm.load(deferred: true)
        await vm.decide(try #require(vm.cards.first), decision: .accepted)
        #expect(vm.confirmations.first?.receipt.decision == .accepted)
        #expect(vm.confirmations.last?.receipt.decision == .unsure)
        let reopened = ProjectRefinementViewModel(store: store)
        await reopened.load()
        #expect(reopened.confirmations.first?.receipt.decision == .accepted)
        #expect(reopened.statusMessage == nil)
        await reopened.undo(try #require(reopened.confirmations.first))
        #expect(reopened.statusMessage == "Answer undone.")
    }


    @Test func exhaustedBatchDoesNotClaimQueueIsEmpty() async throws {
        let (store, vm) = try await fixture()
        let project = try await store.createKnowledgeProject(name: "Second")
        for index in 0..<4 {
            let recording = try await store.upsert(Recording(wavPath: "/tmp/batch-\(UUID()).wav",
                startedAt: Date(), title: "Extra \(index)", transcriptText: "Second project."))
            _ = try await store.proposeProjectMatch(recordingID: recording.id!, projectID: project.id,
                quote: "Second", generatorID: "fixture")
        }
        await vm.load()
        #expect(vm.cards.count == 3)
        for card in vm.cards { await vm.decide(card, decision: .rejected) }
        #expect(vm.completedBatch)
        await vm.load()
        #expect(vm.cards.count == 2)
        #expect(!vm.completedBatch)
    }

    @Test func revokedHostBeforeCommitDoesNotSaveOrReward() async throws {
        let (store, _) = try await fixture()
        let gate = SaveGate()
        var allowed = true
        var commits = 0
        let vm = ProjectRefinementViewModel(store: store, onCommitted: { commits += 1 },
            beforeApply: { await gate.wait() }, canWrite: { allowed })
        await vm.load()
        let card = try #require(vm.cards.first)
        let task = Task { await vm.decide(card, decision: .accepted) }
        while !gate.entered { await Task.yield() }
        allowed = false
        gate.release()
        await task.value
        #expect(vm.errorMessage != nil)
        #expect(commits == 0)
        #expect(try await store.projectMatchReview(id: card.id).decision == .pending)
    }

    @MainActor
    private final class SaveGate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

}
