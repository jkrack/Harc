import Foundation
import Testing
import HarcStore
@testable import HarcContext

@Suite("Semantic indexer")
struct SemanticIndexerTests {
    @Test("chunker creates bounded transcript chunks")
    func chunkerCreatesBoundedChunks() {
        let sentence = "Sarah raised pricing concerns for the enterprise tier."
        let transcript = Array(repeating: sentence, count: 80).joined(separator: " ")

        let chunks = SemanticTranscriptChunker.split(transcript: transcript, targetWords: 40, maxWords: 60)

        #expect(chunks.count > 1)
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
        #expect(chunks.allSatisfy { !$0.text.isEmpty })
    }

    @Test("indexer writes chunks using injected local embedder")
    func indexerWritesChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let saved = try await store.upsert(Recording(
            wavPath: "/tmp/semantic.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptText: Array(
                repeating: "Sarah raised pricing concerns for the enterprise tier.",
                count: 40
            ).joined(separator: " ")
        ))

        let indexedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await SemanticIndexer(store: store, embedder: FakeLocalTextEmbedder())
            .index(recordingID: saved.id!, indexedAt: indexedAt)

        let chunks = try await store.transcriptChunks(
            recordingID: saved.id!,
            embeddingModelID: "fake-local-embedder"
        )
        let refreshed = try await store.fetch(id: saved.id!)

        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.embeddingModelID == "fake-local-embedder" })
        #expect(chunks.allSatisfy { $0.embedding.count == 16 })
        #expect(
            Int(refreshed!.chunksIndexedAt!.timeIntervalSince1970 * 1000)
            == Int(indexedAt.timeIntervalSince1970 * 1000)
        )
    }

    @Test("indexer rejects embedders that return the wrong count")
    func mismatchedEmbeddingCountThrows() async throws {
        let store = try await RecordingStore.inMemory()
        let saved = try await store.upsert(Recording(
            wavPath: "/tmp/mismatch.wav",
            startedAt: Date(),
            transcriptText: "pricing concerns"
        ))

        await #expect(throws: SemanticIndexError.self) {
            try await SemanticIndexer(store: store, embedder: EmptyEmbedder())
                .index(recordingID: saved.id!)
        }
    }
}

private struct FakeLocalTextEmbedder: LocalTextEmbedder {
    let modelID = "fake-local-embedder"

    func embed(texts: [String]) async throws -> [Data] {
        texts.map { text in
            EmbeddingVectorCodec.encode([
                Float(text.count),
                Float(text.utf8.first ?? 0),
                1,
                0,
            ])
        }
    }
}

private struct EmptyEmbedder: LocalTextEmbedder {
    let modelID = "empty-local-embedder"

    func embed(texts: [String]) async throws -> [Data] {
        []
    }
}
