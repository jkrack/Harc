import Foundation
import GRDB

/// A passage-level hit: which recording, which chunk, and where in the audio.
public struct ChunkHit: Sendable, Equatable {
    public var recordingID: Int64
    public var ordinal: Int
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var score: Double

    public init(
        recordingID: Int64,
        ordinal: Int,
        text: String,
        startMs: Int,
        endMs: Int,
        score: Double
    ) {
        self.recordingID = recordingID
        self.ordinal = ordinal
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.score = score
    }
}

// MARK: - Vector indexing and retrieval
//
// Built on the `transcript_chunks` table from migration v11, which has been
// live but unwritten since semantic search was cut in v0.3.0's slim-back. The
// schema survived that cut, so this needs no migration.
//
// Similarity is computed in Swift over rows loaded from SQLite rather than
// through a vector extension. That is the same shape `SpeakerSuggestionEngine`
// already uses for voiceprints, it keeps the C extension (and its risk) out of
// the library's storage layer, and at personal-archive scale — thousands of
// chunks, not millions — a linear scan of 256-float vectors is not the
// bottleneck. If the corpus ever outgrows it, an ANN index slots in behind this
// same API.
public extension RecordingStore {

    /// Chunk, embed and store a recording's transcript, replacing any previous
    /// index for it. Marks `chunks_indexed_at` so re-indexing can be skipped.
    @discardableResult
    func indexTranscript(
        recordingID: Int64,
        text: String,
        durationMs: Int? = nil,
        embedder: any TextEmbedder,
        chunker: TranscriptChunker = TranscriptChunker(),
        now: Date = Date()
    ) async throws -> Int {
        let chunks = chunker.chunks(of: text, durationMs: durationMs)
        let vectors = chunks.map { embedder.embed($0.text) }
        let modelID = embedder.modelID
        let stamp = Int(now.timeIntervalSince1970 * 1000)

        return try await db.write { db in
            // Replace wholesale: a re-transcription changes the text under
            // every ordinal, so merging would leave stale passages behind.
            try db.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )
            for (chunk, vector) in zip(chunks, vectors) {
                try db.execute(
                    sql: """
                        INSERT INTO transcript_chunks
                          (recording_id, ordinal, start_ms, end_ms, text,
                           embedding, embedding_model_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        recordingID, chunk.ordinal, chunk.startMs, chunk.endMs,
                        chunk.text, EmbeddingBlob.pack(vector), modelID, stamp,
                    ]
                )
            }
            try db.execute(
                sql: "UPDATE recordings SET chunks_indexed_at = ? WHERE id = ?",
                arguments: [chunks.isEmpty ? nil : stamp, recordingID]
            )
            return chunks.count
        }
    }

    /// Drop a recording's chunk index and clear its indexed marker.
    func clearTranscriptIndex(recordingID: Int64) async throws {
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )
            try db.execute(
                sql: "UPDATE recordings SET chunks_indexed_at = NULL WHERE id = ?",
                arguments: [recordingID]
            )
        }
    }

    /// Recordings that have transcript text but no current chunk index — the
    /// work list for a backfill.
    func recordingsNeedingIndex(limit: Int = 500) async throws -> [Recording] {
        try await db.read { db in
            try Recording.fetchAll(db, sql: """
                SELECT * FROM recordings
                WHERE deleted_at IS NULL
                  AND transcript_text IS NOT NULL
                  AND TRIM(transcript_text) <> ''
                  AND chunks_indexed_at IS NULL
                ORDER BY started_at DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }

    /// Nearest chunks to `query` by cosine similarity.
    ///
    /// Filtered to `embedder.modelID`: vectors from different embedders occupy
    /// unrelated spaces, and comparing them produces confident nonsense.
    func semanticSearch(
        query: String,
        embedder: any TextEmbedder,
        limit: Int = 20,
        minimumScore: Double = 0.05
    ) async throws -> [ChunkHit] {
        let queryVector = embedder.embed(query)
        guard queryVector.contains(where: { $0 != 0 }) else { return [] }
        let modelID = embedder.modelID

        let rows: [ChunkHit] = try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.recording_id, c.ordinal, c.text, c.start_ms, c.end_ms, c.embedding
                FROM transcript_chunks c
                JOIN recordings r ON r.id = c.recording_id
                WHERE c.embedding_model_id = ?
                  AND r.deleted_at IS NULL
                """, arguments: [modelID])

            return rows.compactMap { row -> ChunkHit? in
                guard let blob: Data = row["embedding"] else { return nil }
                let score = embedder.similarity(queryVector, EmbeddingBlob.unpack(blob))
                guard score >= minimumScore else { return nil }
                return ChunkHit(
                    recordingID: row["recording_id"],
                    ordinal: row["ordinal"],
                    text: row["text"] ?? "",
                    startMs: row["start_ms"] ?? 0,
                    endMs: row["end_ms"] ?? 0,
                    score: score
                )
            }
        }

        return Array(rows.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Keyword and vector retrieval fused with Reciprocal Rank Fusion.
    ///
    /// RRF combines by *rank* rather than score, which is what makes the fusion
    /// legitimate here: BM25 and cosine are on incomparable scales, and any
    /// attempt to blend the raw numbers silently lets one dominate. A recording
    /// found by both routes outranks one found by either alone.
    ///
    /// Falls back to whichever side returned results, so an unindexed library
    /// still searches exactly as it does today.
    func hybridSearch(
        query: String,
        embedder: any TextEmbedder,
        limit: Int = 50,
        rrfK: Double = 60
    ) async throws -> [TranscriptHit] {
        let keyword = try await search(query: query)
        let chunks = try await semanticSearch(query: query, embedder: embedder, limit: limit)

        if chunks.isEmpty { return Array(keyword.prefix(limit)) }

        var fused: [Int64: Double] = [:]
        var snippets: [Int64: String] = [:]

        for (rank, hit) in keyword.enumerated() {
            guard let id = hit.recording.id else { continue }
            fused[id, default: 0] += 1.0 / (rrfK + Double(rank + 1))
            snippets[id] = hit.snippet
        }

        // Best-ranked chunk per recording: several passages from one meeting
        // shouldn't let it accumulate rank mass the others can't match.
        var seenRecording = Set<Int64>()
        var chunkRank = 0
        for hit in chunks where !seenRecording.contains(hit.recordingID) {
            seenRecording.insert(hit.recordingID)
            fused[hit.recordingID, default: 0] += 1.0 / (rrfK + Double(chunkRank + 1))
            // Keyword snippets carry <mark> highlighting, so only fall back to
            // raw chunk text where keyword search found nothing.
            if snippets[hit.recordingID] == nil {
                snippets[hit.recordingID] = hit.text
            }
            chunkRank += 1
        }

        if keyword.isEmpty && fused.isEmpty { return [] }

        let byID = Dictionary(
            keyword.compactMap { hit -> (Int64, Recording)? in
                guard let id = hit.recording.id else { return nil }
                return (id, hit.recording)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let ordered = fused.sorted { $0.value > $1.value }.prefix(limit)
        var out: [TranscriptHit] = []
        for (id, score) in ordered {
            let recording: Recording
            if let known = byID[id] {
                recording = known
            } else if let fetched = try await fetch(id: id) {
                recording = fetched
            } else {
                continue
            }
            out.append(TranscriptHit(
                recording: recording,
                snippet: snippets[id] ?? "",
                score: score
            ))
        }
        return out
    }
}
