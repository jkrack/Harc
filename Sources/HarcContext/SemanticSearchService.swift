import Foundation
import HarcStore

public struct SemanticTranscriptHit: Sendable, Equatable, Identifiable {
    public var id: String
    public var recording: Recording
    public var chunk: TranscriptChunk
    public var score: Double

    public init(recording: Recording, chunk: TranscriptChunk, score: Double) {
        self.id = "\(recording.id ?? -1):\(chunk.ordinal)"
        self.recording = recording
        self.chunk = chunk
        self.score = score
    }
}

public actor SemanticSearchService {
    private let store: RecordingStore
    private let embedder: any LocalTextEmbedder

    public init(store: RecordingStore, embedder: any LocalTextEmbedder) {
        self.store = store
        self.embedder = embedder
    }

    public func search(
        query rawQuery: String,
        limit: Int = 8,
        minimumScore: Double = 0.0
    ) async throws -> [SemanticTranscriptHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        let queryEmbeddings = try await embedder.embed(texts: [query])
        guard queryEmbeddings.count == 1 else {
            throw SemanticSearchError.embeddingCountMismatch(expected: 1, actual: queryEmbeddings.count)
        }

        let queryVector = try EmbeddingVectorCodec.decode(queryEmbeddings[0])
        guard !queryVector.isEmpty else {
            throw SemanticSearchError.emptyEmbedding
        }

        let chunks = try await store.allTranscriptChunks(embeddingModelID: embedder.modelID)
        var recordingsByID: [Int64: Recording] = [:]
        var hits: [SemanticTranscriptHit] = []

        for chunk in chunks {
            let chunkVector = try EmbeddingVectorCodec.decode(chunk.embedding)
            guard chunkVector.count == queryVector.count else {
                throw SemanticSearchError.dimensionMismatch(
                    expected: queryVector.count,
                    actual: chunkVector.count
                )
            }
            guard let score = cosineSimilarity(queryVector, chunkVector),
                  score >= minimumScore
            else { continue }

            let recordingID = chunk.recordingID
            let recording: Recording
            if let cached = recordingsByID[recordingID] {
                recording = cached
            } else if let fetched = try await store.fetch(id: recordingID) {
                recordingsByID[recordingID] = fetched
                recording = fetched
            } else {
                continue
            }

            hits.append(SemanticTranscriptHit(recording: recording, chunk: chunk, score: score))
        }

        return hits
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.recording.startedAt > rhs.recording.startedAt
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        var dot: Double = 0
        var lhsMagnitude: Double = 0
        var rhsMagnitude: Double = 0

        for idx in lhs.indices {
            let left = Double(lhs[idx])
            let right = Double(rhs[idx])
            dot += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }

        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }
}

public enum SemanticSearchError: Error, Equatable, Sendable {
    case embeddingCountMismatch(expected: Int, actual: Int)
    case emptyEmbedding
    case dimensionMismatch(expected: Int, actual: Int)
}
