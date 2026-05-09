import Foundation
import Testing
import HarcStore
@testable import HarcContext

@Suite("Semantic search service")
struct SemanticSearchServiceTests {
    @Test("codec round trips float vectors")
    func codecRoundTripsFloatVectors() throws {
        let vector: [Float] = [1.0, -0.25, 0.5, 42.0]

        let decoded = try EmbeddingVectorCodec.decode(EmbeddingVectorCodec.encode(vector))

        #expect(decoded == vector)
    }

    @Test("search ranks transcript chunks with local embeddings")
    func searchRanksTranscriptChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let pricing = try await store.upsert(Recording(
            wavPath: "/tmp/pricing.wav",
            startedAt: Date(timeIntervalSince1970: 2),
            transcriptText: "Sarah raised pricing concerns."
        ))
        let roadmap = try await store.upsert(Recording(
            wavPath: "/tmp/roadmap.wav",
            startedAt: Date(timeIntervalSince1970: 3),
            transcriptText: "The roadmap depends on margin work."
        ))

        try await store.upsertTranscriptChunks(recordingID: pricing.id!, chunks: [
            chunk(recordingID: pricing.id!, text: "Sarah raised pricing concerns.", vector: [1, 0, 0]),
        ])
        try await store.upsertTranscriptChunks(recordingID: roadmap.id!, chunks: [
            chunk(recordingID: roadmap.id!, text: "The roadmap depends on margin work.", vector: [0, 1, 0]),
        ])

        let hits = try await SemanticSearchService(store: store, embedder: KeywordEmbedder())
            .search(query: "pricing concern", limit: 2)

        #expect(hits.map(\.recording.wavPath).first == "/tmp/pricing.wav")
        #expect(hits.first?.chunk.text == "Sarah raised pricing concerns.")
        #expect((hits.first?.score ?? 0) > 0.99)
    }

    @Test("context pack builder can use semantic chunks before FTS fallback")
    func contextPackBuilderUsesSemanticChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/semantic-context.wav",
            startedAt: Date(),
            transcriptText: "This transcript does not contain the natural query term.",
            summaryMarkdown: "Pricing risk needs owner follow-up.",
            actionItemsMarkdown: "- Sarah to review enterprise pricing."
        ))
        try await store.upsertTranscriptChunks(recordingID: recording.id!, chunks: [
            chunk(
                recordingID: recording.id!,
                text: "Sarah raised pricing concerns for enterprise buyers.",
                vector: [1, 0, 0]
            ),
        ])

        let semanticSearch = SemanticSearchService(store: store, embedder: KeywordEmbedder())
        let pack = try await ContextPackBuilder(store: store, semanticSearch: semanticSearch)
            .build(query: "pricing concern", limit: 4)

        #expect(pack.blocks.contains { $0.text.contains("enterprise buyers") })
        #expect(pack.blocks.contains { $0.kind == .summary })
        #expect(pack.blocks.contains { $0.kind == .actionItems })
    }

    @Test("search rejects mismatched vector dimensions")
    func searchRejectsMismatchedDimensions() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/bad-vector.wav",
            startedAt: Date(),
            transcriptText: "pricing"
        ))
        try await store.upsertTranscriptChunks(recordingID: recording.id!, chunks: [
            chunk(recordingID: recording.id!, text: "pricing", vector: [1, 0]),
        ])

        await #expect(throws: SemanticSearchError.self) {
            try await SemanticSearchService(store: store, embedder: KeywordEmbedder())
                .search(query: "pricing")
        }
    }

    private func chunk(recordingID: Int64, text: String, vector: [Float]) -> TranscriptChunk {
        TranscriptChunk(
            recordingID: recordingID,
            ordinal: 0,
            startMs: 0,
            endMs: 0,
            text: text,
            embedding: EmbeddingVectorCodec.encode(vector),
            embeddingModelID: "keyword-local-embedder"
        )
    }
}

private struct KeywordEmbedder: LocalTextEmbedder {
    let modelID = "keyword-local-embedder"

    func embed(texts: [String]) async throws -> [Data] {
        texts.map { text in
            let lowercased = text.lowercased()
            if lowercased.contains("pricing") {
                return EmbeddingVectorCodec.encode([1, 0, 0])
            }
            if lowercased.contains("margin") || lowercased.contains("roadmap") {
                return EmbeddingVectorCodec.encode([0, 1, 0])
            }
            return EmbeddingVectorCodec.encode([0, 0, 1])
        }
    }
}
