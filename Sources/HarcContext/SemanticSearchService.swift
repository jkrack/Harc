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

public struct SemanticKnowledgeHit: Sendable, Equatable, Identifiable {
    public var id: String
    public var chunk: KnowledgeChunk
    public var recording: Recording?
    public var note: Note?
    public var externalSource: ContextSource?
    public var score: Double

    public init(
        chunk: KnowledgeChunk,
        recording: Recording? = nil,
        note: Note? = nil,
        externalSource: ContextSource? = nil,
        score: Double
    ) {
        self.id = "\(chunk.sourceKind.rawValue):\(chunk.sourceID):\(chunk.ordinal)"
        self.chunk = chunk
        self.recording = recording
        self.note = note
        self.externalSource = externalSource
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

        let vecHits = (try? await store.searchKnowledgeChunks(
            queryEmbedding: queryEmbeddings[0],
            embeddingModelID: embedder.modelID,
            limit: limit,
            sourceKind: .recording
        )) ?? []
        if !vecHits.isEmpty {
            var recordingsByID: [Int64: Recording] = [:]
            var semanticHits: [SemanticTranscriptHit] = []
            for hit in vecHits {
                guard let recordingID = Int64(hit.chunk.sourceID) else { continue }
                let recording: Recording
                if let cached = recordingsByID[recordingID] {
                    recording = cached
                } else if let fetched = try await store.fetch(id: recordingID) {
                    recordingsByID[recordingID] = fetched
                    recording = fetched
                } else {
                    continue
                }
                semanticHits.append(SemanticTranscriptHit(
                    recording: recording,
                    chunk: TranscriptChunk(
                        id: hit.chunk.id,
                        recordingID: recordingID,
                        ordinal: hit.chunk.ordinal,
                        startMs: 0,
                        endMs: 0,
                        text: hit.chunk.text,
                        embedding: hit.chunk.embedding,
                        embeddingModelID: hit.chunk.embeddingModelID,
                        createdAt: hit.chunk.createdAt
                    ),
                    score: hit.score
                ))
            }
            return semanticHits
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

    public func searchKnowledge(
        query rawQuery: String,
        noteStore: NoteStore? = nil,
        limit: Int = 8
    ) async throws -> [SemanticKnowledgeHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        let queryEmbeddings = try await embedder.embed(texts: [query])
        guard queryEmbeddings.count == 1 else {
            throw SemanticSearchError.embeddingCountMismatch(expected: 1, actual: queryEmbeddings.count)
        }

        let vecHits = (try? await store.searchKnowledgeChunks(
            queryEmbedding: queryEmbeddings[0],
            embeddingModelID: embedder.modelID,
            limit: limit
        )) ?? []

        var recordingsByID: [Int64: Recording] = [:]
        let notesByID: [String: Note]
        if let noteStore {
            notesByID = Dictionary(
                uniqueKeysWithValues: try await noteStore.fetchAll(includeArchived: false).map { ($0.id, $0) }
            )
        } else {
            notesByID = [:]
        }

        var semanticHits: [SemanticKnowledgeHit] = []
        for hit in vecHits {
            switch hit.chunk.sourceKind {
            case .recording:
                guard let recordingID = Int64(hit.chunk.sourceID) else { continue }
                let recording: Recording
                if let cached = recordingsByID[recordingID] {
                    recording = cached
                } else if let fetched = try await store.fetch(id: recordingID) {
                    recordingsByID[recordingID] = fetched
                    recording = fetched
                } else {
                    continue
                }
                semanticHits.append(SemanticKnowledgeHit(chunk: hit.chunk, recording: recording, score: hit.score))
            case .note:
                semanticHits.append(SemanticKnowledgeHit(chunk: hit.chunk, note: notesByID[hit.chunk.sourceID], score: hit.score))
            case .rawFile, .repoFile, .wikiPage:
                semanticHits.append(SemanticKnowledgeHit(
                    chunk: hit.chunk,
                    externalSource: ContextSource(
                        kind: ContextSourceKind(knowledgeKind: hit.chunk.sourceKind),
                        sourceID: hit.chunk.sourceID,
                        title: hit.chunk.title,
                        path: hit.chunk.sourceID
                    ),
                    score: hit.score
                ))
            }
        }
        return semanticHits
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

private extension ContextSourceKind {
    init(knowledgeKind: KnowledgeSourceKind) {
        switch knowledgeKind {
        case .recording: self = .recording
        case .note: self = .note
        case .rawFile: self = .rawFile
        case .repoFile: self = .repoFile
        case .wikiPage: self = .wikiPage
        }
    }
}

public enum SemanticSearchError: Error, Equatable, Sendable {
    case embeddingCountMismatch(expected: Int, actual: Int)
    case emptyEmbedding
    case dimensionMismatch(expected: Int, actual: Int)
}
