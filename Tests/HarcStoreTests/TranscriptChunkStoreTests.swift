import Foundation
import Testing
@testable import HarcStore

@Suite("RecordingStore transcript chunks")
struct TranscriptChunkStoreTests {
    @Test("upsertTranscriptChunks replaces rows and marks recording indexed")
    func upsertTranscriptChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/chunks.wav",
            startedAt: Date(),
            transcriptText: "pricing concerns"
        ))
        let indexedAt = Date(timeIntervalSince1970: 1_800_000_000)

        try await store.upsertTranscriptChunks(
            recordingID: recording.id!,
            chunks: [
                TranscriptChunk(
                    recordingID: recording.id!,
                    ordinal: 0,
                    startMs: 0,
                    endMs: 10_000,
                    text: "pricing concerns",
                    embedding: Data(repeating: 0x01, count: 16),
                    embeddingModelID: "local-test-embedder",
                    createdAt: indexedAt
                ),
            ],
            indexedAt: indexedAt
        )

        let chunks = try await store.transcriptChunks(recordingID: recording.id!)
        let refreshed = try #require(try await store.fetch(id: recording.id!))

        #expect(chunks.count == 1)
        #expect(chunks[0].text == "pricing concerns")
        #expect(chunks[0].embeddingModelID == "local-test-embedder")
        #expect(
            Int(refreshed.chunksIndexedAt!.timeIntervalSince1970 * 1000)
            == Int(indexedAt.timeIntervalSince1970 * 1000)
        )

        try await store.upsertTranscriptChunks(recordingID: recording.id!, chunks: [], indexedAt: indexedAt)
        #expect(try await store.transcriptChunks(recordingID: recording.id!).isEmpty)
        #expect(try await store.knowledgeChunks(sourceKind: .recording, sourceID: String(recording.id!)).isEmpty)
    }

    @Test("upsertTranscriptChunks mirrors valid embeddings into vec1-backed knowledge chunks")
    func transcriptChunksMirrorToKnowledgeVec1() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/vec1.wav",
            startedAt: Date(),
            transcriptText: "Atlas migration plan"
        ))

        try await store.upsertTranscriptChunks(
            recordingID: recording.id!,
            chunks: [
                TranscriptChunk(
                    recordingID: recording.id!,
                    ordinal: 0,
                    startMs: 0,
                    endMs: 0,
                    text: "Atlas migration plan",
                    embedding: Self.vector([1, 0, 0, 0]),
                    embeddingModelID: "local-test-embedder"
                ),
                TranscriptChunk(
                    recordingID: recording.id!,
                    ordinal: 1,
                    startMs: 0,
                    endMs: 0,
                    text: "Unrelated pricing note",
                    embedding: Self.vector([0, 1, 0, 0]),
                    embeddingModelID: "local-test-embedder"
                ),
            ]
        )

        let chunks = try await store.knowledgeChunks(sourceKind: .recording, sourceID: String(recording.id!))
        #expect(chunks.count == 2)

        let hits = try await store.searchKnowledgeChunks(
            queryEmbedding: Self.vector([1, 0, 0, 0]),
            embeddingModelID: "local-test-embedder",
            limit: 1
        )

        #expect(hits.count == 1)
        #expect(hits[0].chunk.id == chunks[0].id)
        #expect(hits[0].chunk.text == "Atlas migration plan")
    }

    @Test("updateTranscriptText clears stale semantic chunks")
    func transcriptEditClearsChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(
            wavPath: "/tmp/edit-clears.wav",
            startedAt: Date(),
            transcriptText: "old pricing concerns"
        ))
        try await store.upsertTranscriptChunks(
            recordingID: recording.id!,
            chunks: [
                TranscriptChunk(
                    recordingID: recording.id!,
                    ordinal: 0,
                    startMs: 0,
                    endMs: 0,
                    text: "old pricing concerns",
                    embedding: Data([1, 2, 3, 4]),
                    embeddingModelID: "local-test-embedder"
                ),
            ]
        )

        try await store.updateTranscriptText(id: recording.id!, text: "new margin discussion")

        let refreshed = try #require(try await store.fetch(id: recording.id!))
        #expect(refreshed.chunksIndexedAt == nil)
        #expect(try await store.transcriptChunks(recordingID: recording.id!).isEmpty)
        #expect(try await store.knowledgeChunks(sourceKind: .recording, sourceID: String(recording.id!)).isEmpty)
    }

    @Test("recordingsNeedingSemanticIndex returns transcript rows with stale index")
    func recordingsNeedingSemanticIndex() async throws {
        let store = try await RecordingStore.inMemory()
        let indexed = try await store.upsert(Recording(
            wavPath: "/tmp/indexed.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptText: "indexed"
        ))
        _ = try await store.upsert(Recording(
            wavPath: "/tmp/unindexed.wav",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcriptText: "needs semantic index"
        ))
        _ = try await store.upsert(Recording(
            wavPath: "/tmp/no-transcript.wav",
            startedAt: Date(timeIntervalSince1970: 1_900_000_000),
            transcriptText: nil
        ))
        try await store.upsertTranscriptChunks(recordingID: indexed.id!, chunks: [])

        let needsIndex = try await store.recordingsNeedingSemanticIndex()

        #expect(needsIndex.map(\.wavPath) == ["/tmp/unindexed.wav"])
    }

    private static func vector(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
