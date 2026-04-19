import Testing
import Foundation
@testable import HarcStore

@Suite("RecordingStore.updateTranscriptText")
struct RecordingStoreTranscriptTextTests {
    @Test("updates transcript_text and bumps updatedAt")
    func updates() async throws {
        let store = try await RecordingStore.inMemory()
        let initial = Recording(
            wavPath: "/tmp/a.wav",
            startedAt: Date(),
            transcriptText: "original"
        )
        let saved = try await store.upsert(initial)
        let beforeUpdate = try #require(try await store.fetchByWavPath("/tmp/a.wav"))
        try? await Task.sleep(nanoseconds: 10_000_000)  // ensure updated_at moves forward

        try await store.updateTranscriptText(id: saved.id!, text: "edited version")

        let after = try #require(try await store.fetchByWavPath("/tmp/a.wav"))
        #expect(after.transcriptText == "edited version")
        #expect(after.updatedAt > beforeUpdate.updatedAt)
    }

    @Test("edited text becomes searchable via FTS (triggers reindex)")
    func searchReflectsEdit() async throws {
        let store = try await RecordingStore.inMemory()
        let saved = try await store.upsert(Recording(
            wavPath: "/tmp/a.wav",
            startedAt: Date(),
            transcriptText: "alpha"
        ))
        try await store.updateTranscriptText(id: saved.id!, text: "bravo")
        let hits = try await store.search(query: "bravo")
        #expect(hits.count == 1)
        let alphaHits = try await store.search(query: "alpha")
        #expect(alphaHits.isEmpty)
    }

    @Test("notFound when id doesn't exist")
    func notFound() async throws {
        let store = try await RecordingStore.inMemory()
        await #expect(throws: StoreError.self) {
            try await store.updateTranscriptText(id: 999, text: "x")
        }
    }
}
