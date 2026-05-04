import Testing
import Foundation
@testable import HarcStore
@testable import HarcUI
@testable import HarcVoiceprint

@Suite("SpeakerSuggestionEngine")
@MainActor
struct SpeakerSuggestionEngineTests {

    /// Insert a minimal Recording and return its auto-assigned row ID.
    @discardableResult
    static func seedRecording(in store: RecordingStore, wav: String) async throws -> Int64 {
        let saved = try await store.upsert(Recording(
            wavPath: wav,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        return saved.id!
    }

    @Test("suggestForRecording inserts pending row when embedding matches a Person above threshold")
    func suggestsAboveThreshold() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)

        // Identical embeddings under both recordings → cosine 1.0.
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            RecordingStore.SpeakerEmbeddingRow(
                recordingID: recA, speakerIndex: 0,
                embedding: blob, segmentCount: 4, totalMs: 6000,
                embedderKind: EmbedderKind.wespeakerV2
            )
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            RecordingStore.SpeakerEmbeddingRow(
                recordingID: recB, speakerIndex: 0,
                embedding: blob, segmentCount: 3, totalMs: 4500,
                embedderKind: EmbedderKind.wespeakerV2
            )
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)

        let suggestions = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].personID == sarah)
        #expect(suggestions[0].score >= 0.99)
    }

    @Test("suggestForRecording skips slots already linked")
    func skipsLinkedSlots() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.linkSpeaker(personID: david, recordingID: recB, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        #expect(try await store.fetchPendingSuggestionsForRecording(recB).isEmpty)
    }

    @Test("suggestForRecording skips dismissed (person, recording, speaker) triples")
    func skipsDismissed() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.dismissSuggestion(personID: sarah, recordingID: recB, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        #expect(try await store.fetchPendingSuggestionsForRecording(recB).isEmpty)
    }

    @Test("suggestForNewPerson backfills suggestions across older recordings")
    func newPersonBackfill() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 1, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForNewPerson(personID: sarah, fromRecording: recA, speakerIndex: 0)

        let s = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(s.count == 1)
        #expect(s[0].personID == sarah)
        #expect(s[0].speakerIndex == 1)
    }

    @Test("idempotent — calling suggestForRecording twice doesn't duplicate")
    func idempotent() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        try await engine.suggestForRecording(recordingID: recB)

        let s = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(s.count == 1)
    }
}
