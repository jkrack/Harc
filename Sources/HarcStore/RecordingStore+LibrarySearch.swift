import Foundation
import GRDB
import HarcDomain

/// Path-free metadata row used by the Host library-search application service.
/// Transcript-derived fields never enter this projection.
public struct LibraryMetadataSearchRecord: Equatable, Sendable {
    public let summary: LibraryRecordingSummary
    public let speakerLabels: [SpeakerLabel]

    public init(
        summary: LibraryRecordingSummary,
        speakerLabels: [SpeakerLabel]
    ) {
        self.summary = summary
        self.speakerLabels = speakerLabels
    }
}

/// One transcript-protected snippet. Frame ranges are expressed in Harc's
/// canonical 16 kHz timeline; lexical whole-transcript hits use an empty range
/// because the legacy FTS index does not persist word timestamps.
public struct LibraryTranscriptSearchSnippetRecord: Equatable, Sendable {
    public let text: String
    public let frames: CanonicalFrameRange
    public let speakerIndex: UInt32?

    public init(
        text: String,
        frames: CanonicalFrameRange,
        speakerIndex: UInt32? = nil
    ) {
        self.text = text
        self.frames = frames
        self.speakerIndex = speakerIndex
    }
}

/// Path-free transcript search result retained inside the Host boundary.
public struct LibraryTranscriptSearchRecord: Equatable, Sendable {
    public let summary: LibraryRecordingSummary
    public let speakerIndices: Set<UInt32>
    public let score: Double
    public let snippets: [LibraryTranscriptSearchSnippetRecord]

    public init(
        summary: LibraryRecordingSummary,
        speakerIndices: Set<UInt32>,
        score: Double,
        snippets: [LibraryTranscriptSearchSnippetRecord]
    ) {
        self.summary = summary
        self.speakerIndices = speakerIndices
        self.score = score
        self.snippets = snippets
    }
}

public extension RecordingStore {
    /// Returns only fields authorized by `library.metadata.read`. Filtering is
    /// intentionally performed by HarcHost so transports share one contract.
    func libraryMetadataSearchRecords() async throws
        -> [LibraryMetadataSearchRecord]
    {
        try await db.read { database in
            let recordings = try Recording
                .filter(Recording.Columns.deletedAt == nil)
                .fetchAll(database)
            return try recordings.map { recording in
                let labels = try recording.speakerNames
                    .map { key, name -> SpeakerLabel in
                        guard let index = UInt32(exactly: key) else {
                            throw StoreError.invalidData(
                                "A speaker index cannot be represented on the public wire"
                            )
                        }
                        return try SpeakerLabel(
                            speakerIndex: index,
                            displayName: name
                        )
                    }
                    .sorted { $0.speakerIndex < $1.speakerIndex }
                return LibraryMetadataSearchRecord(
                    summary: try Self.pathFreeSummary(for: recording),
                    speakerLabels: labels
                )
            }
        }
    }

    /// FTS5 search projected before leaving HarcStore. The caller may request a
    /// broad bounded candidate set and apply scope-safe typed filters in Host.
    func libraryLexicalTranscriptSearch(
        query: String,
        candidateLimit: Int = 1_000
    ) async throws -> [LibraryTranscriptSearchRecord] {
        let pattern = Self.ftsPattern(from: query)
        guard !pattern.isEmpty else { return [] }
        let boundedLimit = max(1, min(candidateLimit, 1_000))
        return try await db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        recordings.*,
                        snippet(recordings_fts, 0, '<mark>', '</mark>', '…', 24) AS hit_snippet,
                        bm25(recordings_fts) AS hit_rank
                    FROM recordings
                    JOIN recordings_fts ON recordings_fts.rowid = recordings.id
                    WHERE recordings_fts MATCH ?
                      AND recordings.deleted_at IS NULL
                    ORDER BY hit_rank ASC, recordings.canonical_uuid ASC
                    LIMIT ?
                    """,
                arguments: [pattern, boundedLimit]
            )
            return try rows.map { row in
                let recording = try Recording(row: row)
                let snippet: String = row["hit_snippet"] ?? ""
                let rank: Double = row["hit_rank"] ?? 0
                return LibraryTranscriptSearchRecord(
                    summary: try Self.pathFreeSummary(for: recording),
                    speakerIndices: try Self.publicSpeakerIndices(recording),
                    score: -rank,
                    snippets: [
                        LibraryTranscriptSearchSnippetRecord(
                            text: snippet,
                            frames: try CanonicalFrameRange(
                                startFrame: 0,
                                endFrameExclusive: 0
                            )
                        ),
                    ]
                )
            }
        }
    }

    /// Passage-level retrieval over the existing deterministic embedding
    /// index, grouped to one ranked result per recording.
    func librarySemanticTranscriptSearch(
        query: String,
        embedder: any TextEmbedder,
        candidateLimit: Int = 1_000
    ) async throws -> [LibraryTranscriptSearchRecord] {
        let boundedLimit = max(1, min(candidateLimit, 1_000))
        let chunks = try await semanticSearch(
            query: query,
            embedder: embedder,
            limit: boundedLimit
        )
        var chunksByRecording: [Int64: [ChunkHit]] = [:]
        var order: [Int64] = []
        for chunk in chunks {
            if chunksByRecording[chunk.recordingID] == nil {
                order.append(chunk.recordingID)
            }
            chunksByRecording[chunk.recordingID, default: []].append(chunk)
        }

        var results: [LibraryTranscriptSearchRecord] = []
        results.reserveCapacity(order.count)
        for recordingID in order {
            guard let recording = try await fetch(id: recordingID),
                  recording.deletedAt == nil,
                  let recordingChunks = chunksByRecording[recordingID],
                  let best = recordingChunks.first else { continue }
            let snippets = try recordingChunks.prefix(3).map { chunk in
                LibraryTranscriptSearchSnippetRecord(
                    text: chunk.text,
                    frames: try Self.canonicalFrames(
                        startMilliseconds: chunk.startMs,
                        endMilliseconds: chunk.endMs,
                        totalFrames: recording.canonicalPCMFrames
                    )
                )
            }
            results.append(
                LibraryTranscriptSearchRecord(
                    summary: try Self.pathFreeSummary(for: recording),
                    speakerIndices: try Self.publicSpeakerIndices(recording),
                    score: best.score,
                    snippets: snippets
                )
            )
        }
        return results
    }

    private static func publicSpeakerIndices(
        _ recording: Recording
    ) throws -> Set<UInt32> {
        try Set(recording.speakerNames.keys.map { key in
            guard let value = UInt32(exactly: key) else {
                throw StoreError.invalidData(
                    "A speaker index cannot be represented on the public wire"
                )
            }
            return value
        })
    }

    private static func canonicalFrames(
        startMilliseconds: Int,
        endMilliseconds: Int,
        totalFrames: UInt64?
    ) throws -> CanonicalFrameRange {
        let start = max(0, startMilliseconds)
        let end = max(start, endMilliseconds)
        let framesPerMillisecond = UInt64(
            CanonicalPCMFormat.harcV1.sampleRateHz / 1_000
        )
        let rawStart = UInt64(start).multipliedReportingOverflow(
            by: framesPerMillisecond
        )
        let rawEnd = UInt64(end).multipliedReportingOverflow(
            by: framesPerMillisecond
        )
        guard !rawStart.overflow, !rawEnd.overflow else {
            throw StoreError.invalidData(
                "A transcript timestamp exceeds the canonical frame domain"
            )
        }
        let boundedStart = min(rawStart.partialValue, totalFrames ?? .max)
        let boundedEnd = min(
            max(boundedStart, rawEnd.partialValue),
            totalFrames ?? .max
        )
        return try CanonicalFrameRange(
            startFrame: boundedStart,
            endFrameExclusive: boundedEnd
        )
    }
}
