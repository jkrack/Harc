import Foundation
import Testing
import GRDB
@testable import HarcStore
import HarcVoiceprint
@testable import HarcUI

@Suite("Speaker review refresh")
@MainActor
struct SpeakerReviewRefreshTests {
    private func seed(_ store: RecordingStore, name: String, kind: String = EmbedderKind.wespeakerV2) async throws -> Int64 {
        let row = try await store.upsert(Recording(wavPath: "/tmp/\(UUID())-\(name).wav", startedAt: Date()))
        let id = try #require(row.id)
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        try await store.upsertSpeakerEmbeddings(recordingID: id, rows: [
            .init(recordingID: id, speakerIndex: 0, embedding: EmbeddingBlob.encode(vector),
                  segmentCount: 1, totalMs: 6000, embedderKind: kind)])
        return id
    }

    @Test func linkCorrectionAndUnlinkRefreshOtherRecordings() async throws {
        let store = try await RecordingStore.inMemory()
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        let source = try await seed(store, name: "source")
        let target = try await seed(store, name: "target")
        // A stale suggestion on a different slot in the edited recording must
        // also refresh; the old new-person backfill excluded this whole recording.
        try await store.insertPendingSuggestion(personID: alice, recordingID: source, speakerIndex: 1, score: 0.9)
        var review = await SpeakerSlotReviewBatch.load(recordingID: source, indices: [0], store: store)
        let linked = try await review.link(personID: alice, recordingID: source, speakerIndex: 0, store: store)
        #expect(linked.refreshFailure == nil)
        #expect(try await store.fetchPendingSuggestionsForRecording(source).isEmpty)
        #expect(try await store.fetchPendingSuggestionsForRecording(target).map(\.personID) == [alice])
        review = await SpeakerSlotReviewBatch.load(recordingID: source, indices: [0], store: store)
        _ = try await review.link(personID: bob, recordingID: source, speakerIndex: 0, store: store)
        #expect(try await store.fetchPendingSuggestionsForRecording(target).map(\.personID) == [bob])
        review = await SpeakerSlotReviewBatch.load(recordingID: source, indices: [0], store: store)
        _ = try await review.unlink(recordingID: source, speakerIndex: 0, store: store)
        #expect(try await store.fetchPendingSuggestionsForRecording(target).isEmpty)
    }

    @Test func createAndConfirmRefreshThroughSharedSeams() async throws {
        let store = try await RecordingStore.inMemory()
        let source = try await seed(store, name: "source")
        let target = try await seed(store, name: "target")
        let review = await SpeakerSlotReviewBatch.load(recordingID: source, indices: [0], store: store)
        let created = try await review.createPerson(displayName: "Alice", recordingID: source, speakerIndex: 0, store: store)
        #expect(created.refreshFailure == nil)
        let suggestions = try await store.fetchPendingSuggestionsForRecording(target)
        #expect(suggestions.map(\.personID) == [created.personID])
        // Withhold a third query until confirmation so the confirm seam must refresh it.
        let third = try await seed(store, name: "third")
        let batch = await SpeakerSuggestionReviewBatch.load(suggestions, store: store)
        let confirmed = try await batch.confirm(try #require(suggestions.first), store: store)
        #expect(confirmed.refreshFailure == nil)
        #expect(try await store.fetchPendingSuggestionsForRecording(third).map(\.personID) == [created.personID])
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: target).first?.isUserConfirmed == true)
    }

    @Test func failedRefreshReportsWarningWithoutUndoingEnrollment() async throws {
        let store = try await RecordingStore.inMemory()
        let person = try await store.createPerson(displayName: "Alice")
        let source = try await seed(store, name: "source")
        let target = try await seed(store, name: "target")
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_refresh BEFORE INSERT ON pending_suggestions
                BEGIN SELECT RAISE(ABORT, 'injected refresh failure'); END
                """)
        }
        let review = await SpeakerSlotReviewBatch.load(recordingID: source, indices: [0], store: store)
        let result = try await review.link(personID: person, recordingID: source, speakerIndex: 0, store: store)
        #expect(result.needsLegacyLabel)
        #expect(result.refreshFailure?.action == .refreshSpeakerSuggestions)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: source).first?.personID == person)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: source).first?.isUserConfirmed == true)
        #expect(try await store.fetchPendingSuggestionsForRecording(target).isEmpty)
    }

    @Test func foreignModelPendingSuggestionIsPreservedButMissingQueryClears() async throws {
        let store = try await RecordingStore.inMemory()
        let person = try await store.createPerson(displayName: "Alice")
        let foreign = try await seed(store, name: "foreign", kind: "future_model")
        let missing = try await seed(store, name: "missing")
        try await store.upsertSpeakerEmbeddings(recordingID: missing, rows: [])
        for id in [foreign, missing] {
            try await store.insertPendingSuggestion(personID: person, recordingID: id, speakerIndex: 0, score: 0.9)
        }
        let before = try await store.fetchPendingSuggestionsForRecording(foreign)
        let result = await SpeakerReviewMutationResult.refreshed(store: store, needsLegacyLabel: false)
        #expect(result.refreshFailure == nil)
        #expect(try await store.fetchPendingSuggestionsForRecording(foreign) == before)
        #expect(try await store.fetchPendingSuggestionsForRecording(missing).isEmpty)
    }
}
