import Foundation
import HarcStore

public actor SemanticIndexer {
    private let store: RecordingStore
    private let embedder: any LocalTextEmbedder

    public init(store: RecordingStore, embedder: any LocalTextEmbedder) {
        self.store = store
        self.embedder = embedder
    }

    public func index(recordingID: Int64, indexedAt: Date = Date()) async throws {
        guard let recording = try await store.fetch(id: recordingID) else {
            throw StoreError.notFound
        }
        guard let transcript = recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty
        else {
            try await store.upsertTranscriptChunks(recordingID: recordingID, chunks: [], indexedAt: indexedAt)
            return
        }

        let prepared = SemanticTranscriptChunker.split(transcript: transcript)
        let embeddings = try await embedder.embed(texts: prepared.map(\.text))
        guard embeddings.count == prepared.count else {
            throw SemanticIndexError.embeddingCountMismatch(expected: prepared.count, actual: embeddings.count)
        }

        let rows = zip(prepared, embeddings).map { chunk, embedding in
            TranscriptChunk(
                recordingID: recordingID,
                ordinal: chunk.ordinal,
                startMs: chunk.startMs,
                endMs: chunk.endMs,
                text: chunk.text,
                embedding: embedding,
                embeddingModelID: embedder.modelID,
                createdAt: indexedAt
            )
        }
        try await store.upsertTranscriptChunks(recordingID: recordingID, chunks: rows, indexedAt: indexedAt)
    }
}

public enum SemanticIndexError: Error, Equatable, Sendable {
    case embeddingCountMismatch(expected: Int, actual: Int)
}
