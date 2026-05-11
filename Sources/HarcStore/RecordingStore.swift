import Foundation
import GRDB

/// GRDB-backed store for `Recording` rows. Actor-isolated; all DB access
/// serializes through `dbQueue` (GRDB's `DatabaseQueue` is itself thread-safe
/// but we funnel through the actor for cleaner Swift-6 concurrency semantics).
public actor RecordingStore {
    private let dbQueue: DatabaseQueue

    /// Default database location: `~/Library/Application Support/Harc/Harc.db`.
    public static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Harc/Harc.db")
    }

    /// Factory — opens (or creates) a file-backed DB, runs migrations.
    public static func onDisk(url: URL = defaultURL()) async throws -> RecordingStore {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try SQLiteVec1Support.register()
        let dbq: DatabaseQueue
        do {
            dbq = try DatabaseQueue(path: url.path)
        } catch {
            throw StoreError.databaseOpenFailed(error.localizedDescription)
        }
        do {
            try DatabaseMigrator.harcMigrator().migrate(dbq)
        } catch {
            throw StoreError.migrationFailed(error.localizedDescription)
        }
        return RecordingStore(dbQueue: dbq)
    }

    /// Factory — in-memory DB for tests.
    public static func inMemory() async throws -> RecordingStore {
        try SQLiteVec1Support.register()
        let dbq: DatabaseQueue
        do {
            dbq = try DatabaseQueue()
        } catch {
            throw StoreError.databaseOpenFailed(error.localizedDescription)
        }
        do {
            try DatabaseMigrator.harcMigrator().migrate(dbq)
        } catch {
            throw StoreError.migrationFailed(error.localizedDescription)
        }
        return RecordingStore(dbQueue: dbq)
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Internal accessor for same-module extensions that live in separate files.
    var db: DatabaseQueue { dbQueue }

    /// Public read-only handle for GRDB ValueObservation publishers.
    /// Nonisolated so callers on other actors can set up observation publishers
    /// without an actor hop. `DatabaseQueue` is inherently thread-safe.
    public nonisolated var dbReader: any DatabaseReader { dbQueue }

    // MARK: - CRUD

    /// Insert or update a recording by `wavPath`. Returns the saved row (with id set).
    @discardableResult
    public func upsert(_ recording: Recording) async throws -> Recording {
        do {
            return try await dbQueue.write { db in
                var rec = recording
                rec.updatedAt = Date()
                if let existing = try Recording
                    .filter(Recording.Columns.wavPath == rec.wavPath)
                    .fetchOne(db)
                {
                    rec.id = existing.id
                    rec.createdAt = existing.createdAt
                    rec.chunksIndexedAt = existing.transcriptText == rec.transcriptText
                        ? existing.chunksIndexedAt
                        : nil
                    try rec.update(db)
                } else {
                    rec.createdAt = Date()
                    try rec.insert(db)
                    rec.id = db.lastInsertedRowID
                }
                return rec
            }
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    public func fetchAll(
        includeDeleted: Bool = false,
        pinnedFirst: Bool = true
    ) async throws -> [Recording] {
        try await dbQueue.read { db in
            var request = Recording.all()
            if !includeDeleted {
                request = request.filter(Recording.Columns.deletedAt == nil)
            }
            if pinnedFirst {
                request = request
                    .order(
                        Recording.Columns.pinned.desc,
                        Recording.Columns.startedAt.desc
                    )
            } else {
                request = request.order(Recording.Columns.startedAt.desc)
            }
            return try request.fetchAll(db)
        }
    }

    public func fetchByWavPath(_ wavPath: String) async throws -> Recording? {
        try await dbQueue.read { db in
            try Recording.filter(Recording.Columns.wavPath == wavPath).fetchOne(db)
        }
    }

    /// Fetch a recording by primary key. Returns `nil` if the row was
    /// deleted or never existed.
    public func fetch(id: Int64) async throws -> Recording? {
        try await dbQueue.read { db in
            try Recording.filter(key: id).fetchOne(db)
        }
    }

    public func rename(id: Int64, title: String?) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.title.set(to: title),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    /// Post-process path: set the NLTagger-derived title hint. No `notFound`
    /// throw — the post-process task fires detached and a late update on a
    /// soft-deleted row is benign (store just no-ops).
    public func updateSuggestedTitle(id: Int64, title: String?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recordings SET suggested_title = ?, updated_at = ? WHERE id = ?",
                arguments: [title, Date(), id]
            )
        }
    }

    /// Post-process path: set the NLTagger-derived tags array. Like
    /// `updateSuggestedTitle`, no `notFound` throw — late updates are benign.
    public func updateTags(id: Int64, tags: [String]) async throws {
        let json: String?
        if tags.isEmpty {
            json = nil
        } else if let data = try? JSONEncoder().encode(tags),
                  let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = nil
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recordings SET tags = ?, updated_at = ? WHERE id = ?",
                arguments: [json, Date(), id]
            )
        }
    }

    /// Post-process path: set the per-recording speaker-name overrides.
    /// Empty dict clears the column (stored as NULL). No `notFound` throw —
    /// late updates are benign.
    public func updateSpeakerNames(id: Int64, names: [Int: String]) async throws {
        let json: String?
        if names.isEmpty {
            json = nil
        } else {
            var stringKeyed: [String: String] = [:]
            for (k, v) in names {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { stringKeyed[String(k)] = trimmed }
            }
            if stringKeyed.isEmpty {
                json = nil
            } else if let data = try? JSONEncoder().encode(stringKeyed),
                      let s = String(data: data, encoding: .utf8) {
                json = s
            } else {
                json = nil
            }
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recordings SET speaker_names = ?, updated_at = ? WHERE id = ?",
                arguments: [json, Date(), id]
            )
        }
    }

    // MARK: - Summary

    /// Write a generated summary + action items (markdown-authoritative) +
    /// metadata onto a recording. Throws `StoreError.notFound` if the id
    /// doesn't exist — a queue-time bug worth surfacing, not silently
    /// dropping.
    public func updateSummary(
        id: Int64,
        markdown: String,
        actionItemsMarkdown: String,
        modelID: String,
        generatedAt: Date,
        sourceWordCount: Int
    ) async throws {
        let ms = Int64(generatedAt.timeIntervalSince1970 * 1000)
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.summaryMarkdown.set(to: markdown),
                    Recording.Columns.actionItemsMarkdown.set(to: actionItemsMarkdown),
                    Recording.Columns.summaryModelID.set(to: modelID),
                    Recording.Columns.summaryGeneratedAt.set(to: ms),
                    Recording.Columns.summarySourceWordCount.set(to: sourceWordCount),
                    Recording.Columns.summaryStatusKind.set(to: nil),
                    Recording.Columns.summaryStatusMessage.set(to: nil),
                    Recording.Columns.summaryStatusUpdatedAt.set(to: nil),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    /// Null all five summary columns for a recording.
    public func clearSummary(id: Int64) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.summaryMarkdown.set(to: nil),
                    Recording.Columns.actionItemsMarkdown.set(to: nil),
                    Recording.Columns.summaryModelID.set(to: nil),
                    Recording.Columns.summaryGeneratedAt.set(to: nil),
                    Recording.Columns.summarySourceWordCount.set(to: nil),
                    Recording.Columns.summaryStatusKind.set(to: nil),
                    Recording.Columns.summaryStatusMessage.set(to: nil),
                    Recording.Columns.summaryStatusUpdatedAt.set(to: nil),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    /// Store the last non-successful summarization state for a recording.
    /// This is intentionally row-local so detail views can explain "No summary
    /// yet" after relaunch without relying on the in-memory queue bridge.
    public func updateSummaryStatus(
        id: Int64,
        kind: RecordingSummaryStatusKind,
        message: String,
        updatedAt: Date = Date()
    ) async throws {
        let ms = Int64(updatedAt.timeIntervalSince1970 * 1000)
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.summaryStatusKind.set(to: kind.rawValue),
                    Recording.Columns.summaryStatusMessage.set(to: message),
                    Recording.Columns.summaryStatusUpdatedAt.set(to: ms),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    public func clearSummaryStatus(id: Int64) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.summaryStatusKind.set(to: nil),
                    Recording.Columns.summaryStatusMessage.set(to: nil),
                    Recording.Columns.summaryStatusUpdatedAt.set(to: nil),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    /// Rows with no summary yet — the on-launch catch-up list. Ordered
    /// startedAt DESC, capped at `limit` so a fresh install with a long
    /// pre-existing history doesn't seed hundreds of jobs. Rows without a
    /// usable transcript (missing JSON sidecar, etc.) are tolerated by the
    /// queue worker, which fast-returns success and advances.
    public func unsummarizedRecordings(limit: Int = 20) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.deletedAt == nil)
                .filter(Recording.Columns.summaryMarkdown == nil)
                .order(Recording.Columns.startedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Speaker embeddings

    /// One row from `speaker_embeddings`. Decoupled from HarcVoiceprint's
    /// `SpeakerEmbedding` so `HarcStore` can ship without a dep on the
    /// voiceprint library — callers translate at the boundary.
    public struct SpeakerEmbeddingRow: Sendable, Equatable {
        public let recordingID: Int64
        public let speakerIndex: Int
        public let embedding: Data        // packed Float32
        public let segmentCount: Int
        public let totalMs: Int
        public let embedderKind: String?

        public init(
            recordingID: Int64,
            speakerIndex: Int,
            embedding: Data,
            segmentCount: Int,
            totalMs: Int,
            embedderKind: String? = nil
        ) {
            self.recordingID = recordingID
            self.speakerIndex = speakerIndex
            self.embedding = embedding
            self.segmentCount = segmentCount
            self.totalMs = totalMs
            self.embedderKind = embedderKind
        }
    }

    /// Replace all speaker embeddings for a recording in one transaction —
    /// guarantees we don't have stale rows if a transcript is re-run.
    public func upsertSpeakerEmbeddings(
        recordingID: Int64,
        rows: [SpeakerEmbeddingRow]
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM speaker_embeddings WHERE recording_id = ?",
                arguments: [recordingID]
            )
            for row in rows {
                precondition(row.recordingID == recordingID,
                             "upsertSpeakerEmbeddings: mixed recording ids in batch")
                try db.execute(
                    sql: """
                    INSERT INTO speaker_embeddings
                    (recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        row.recordingID,
                        row.speakerIndex,
                        row.embedding,
                        row.segmentCount,
                        row.totalMs,
                        row.embedderKind,
                    ]
                )
            }
        }
    }

    /// The embedding for a specific (recording, speaker), or `nil` if none
    /// was stored (e.g. the speaker had too little audio to embed reliably).
    public func speakerEmbedding(recordingID: Int64, speakerIndex: Int) async throws -> SpeakerEmbeddingRow? {
        try await dbQueue.read { db in
            if let row = try Row.fetchOne(
                db,
                sql: """
                SELECT recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind
                FROM speaker_embeddings
                WHERE recording_id = ? AND speaker_index = ?
                """,
                arguments: [recordingID, speakerIndex]
            ) {
                return SpeakerEmbeddingRow(
                    recordingID: row["recording_id"],
                    speakerIndex: row["speaker_index"],
                    embedding: row["embedding"],
                    segmentCount: row["segment_count"],
                    totalMs: row["total_ms"],
                    embedderKind: row["embedder_kind"]
                )
            }
            return nil
        }
    }

    /// Every embedding in the store, optionally excluding one recording.
    /// The service layer linearly scans these — acceptable at realistic
    /// library scale (see design doc §4.4).
    public func allSpeakerEmbeddings(
        excludingRecording: Int64? = nil,
        embedderKind: String? = nil
    ) async throws -> [SpeakerEmbeddingRow] {
        try await dbQueue.read { db in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            if let excluded = excludingRecording {
                clauses.append("recording_id != ?")
                args.append(excluded)
            }
            if let kind = embedderKind {
                clauses.append("embedder_kind = ?")
                args.append(kind)
            }
            let where_ = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
                SELECT recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind
                FROM speaker_embeddings
                \(where_)
                """
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SpeakerEmbeddingRow(
                    recordingID: row["recording_id"],
                    speakerIndex: row["speaker_index"],
                    embedding: row["embedding"],
                    segmentCount: row["segment_count"],
                    totalMs: row["total_ms"],
                    embedderKind: row["embedder_kind"]
                )
            }
        }
    }

    // MARK: - Transcript text

    /// Atomically update the stored transcript text. The FTS5 `synchronize`
    /// trigger picks this up automatically so search is consistent post-edit.
    public func updateTranscriptText(id: Int64, text: String) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.transcriptText.set(to: text),
                    Recording.Columns.chunksIndexedAt.set(to: nil),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
            try db.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [id]
            )
            let staleKnowledgeIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM knowledge_chunks WHERE source_kind = ? AND source_id = ?",
                arguments: [KnowledgeSourceKind.recording.rawValue, String(id)]
            )
            if !staleKnowledgeIDs.isEmpty, (try? SQLiteVec1Support.register(on: db)) != nil {
                for knowledgeID in staleKnowledgeIDs {
                    try? db.execute(sql: "DELETE FROM knowledge_vec1 WHERE rowid = ?", arguments: [knowledgeID])
                }
            }
            try db.execute(
                sql: "DELETE FROM knowledge_chunks WHERE source_kind = ? AND source_id = ?",
                arguments: [KnowledgeSourceKind.recording.rawValue, String(id)]
            )
        }
    }

    // MARK: - Semantic transcript chunks

    public func upsertTranscriptChunks(
        recordingID: Int64,
        chunks: [TranscriptChunk],
        indexedAt: Date = Date()
    ) async throws {
        let indexedMs = Int64(indexedAt.timeIntervalSince1970 * 1000)
        try await dbQueue.write { db in
            guard try Recording.filter(key: recordingID).fetchOne(db) != nil else {
                throw StoreError.notFound
            }

            try db.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )

            for chunk in chunks {
                precondition(
                    chunk.recordingID == recordingID,
                    "upsertTranscriptChunks: mixed recording ids in batch"
                )
                let createdMs = Int64(chunk.createdAt.timeIntervalSince1970 * 1000)
                try db.execute(
                    sql: """
                    INSERT INTO transcript_chunks
                    (recording_id, ordinal, start_ms, end_ms, text, embedding, embedding_model_id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.recordingID,
                        chunk.ordinal,
                        chunk.startMs,
                        chunk.endMs,
                        chunk.text,
                        chunk.embedding,
                        chunk.embeddingModelID,
                        createdMs,
                    ]
                )
            }

            try Self.replaceKnowledgeChunks(
                db,
                sourceKind: .recording,
                sourceID: String(recordingID),
                chunks: chunks.map {
                    KnowledgeChunk(
                        sourceKind: .recording,
                        sourceID: String(recordingID),
                        ordinal: $0.ordinal,
                        title: "",
                        text: $0.text,
                        embedding: $0.embedding,
                        embeddingModelID: $0.embeddingModelID,
                        contentHash: $0.text
                    )
                }
            )

            try db.execute(
                sql: "UPDATE recordings SET chunks_indexed_at = ?, updated_at = ? WHERE id = ?",
                arguments: [indexedMs, Date(), recordingID]
            )
        }
    }

    public func upsertKnowledgeChunks(
        sourceKind: KnowledgeSourceKind,
        sourceID: String,
        chunks: [KnowledgeChunk]
    ) async throws {
        try await dbQueue.write { db in
            try Self.replaceKnowledgeChunks(
                db,
                sourceKind: sourceKind,
                sourceID: sourceID,
                chunks: chunks
            )
        }
    }

    public func deleteKnowledgeChunks(
        sourceKind: KnowledgeSourceKind,
        sourceID: String
    ) async throws {
        try await dbQueue.write { db in
            try Self.replaceKnowledgeChunks(
                db,
                sourceKind: sourceKind,
                sourceID: sourceID,
                chunks: []
            )
        }
    }

    public struct KnowledgeVectorHit: Sendable, Equatable, Identifiable {
        public var id: Int64 { chunk.id ?? -1 }
        public var chunk: KnowledgeChunk
        public var distance: Double
        public var score: Double
    }

    public func searchKnowledgeChunks(
        queryEmbedding: Data,
        embeddingModelID: String,
        limit: Int = 8,
        sourceKind: KnowledgeSourceKind? = nil
    ) async throws -> [KnowledgeVectorHit] {
        guard limit > 0 else { return [] }
        return try await dbQueue.read { db in
            try SQLiteVec1Support.register(on: db)
            var sql = """
                SELECT k.id, k.source_kind, k.source_id, k.ordinal, k.title, k.text,
                       k.embedding, k.embedding_model_id, k.content_hash,
                       k.created_at, k.updated_at, v.distance
                FROM knowledge_vec1(?, ?) AS v
                JOIN knowledge_chunks k ON k.id = v.rowid
                WHERE v.embedding_model_id = ?
                """
            var args: [DatabaseValueConvertible] = [
                queryEmbedding,
                #"{"K": \#(limit)}"#,
                embeddingModelID,
            ]
            if let sourceKind {
                sql += " AND v.source_kind = ?"
                args.append(sourceKind.rawValue)
            }
            sql += " LIMIT ?"
            args.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                let chunk = try Self.decodeKnowledgeChunk(row)
                let distance: Double = row["distance"]
                return KnowledgeVectorHit(
                    chunk: chunk,
                    distance: distance,
                    score: max(0, 2 - distance)
                )
            }
        }
    }

    public func knowledgeChunks(
        sourceKind: KnowledgeSourceKind? = nil,
        sourceID: String? = nil
    ) async throws -> [KnowledgeChunk] {
        try await dbQueue.read { db in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            if let sourceKind {
                clauses.append("source_kind = ?")
                args.append(sourceKind.rawValue)
            }
            if let sourceID {
                clauses.append("source_id = ?")
                args.append(sourceID)
            }
            var sql = """
                SELECT id, source_kind, source_id, ordinal, title, text, embedding,
                       embedding_model_id, content_hash, created_at, updated_at
                FROM knowledge_chunks
                """
            if !clauses.isEmpty {
                sql += " WHERE \(clauses.joined(separator: " AND "))"
            }
            sql += " ORDER BY source_kind, source_id, ordinal"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.decodeKnowledgeChunk)
        }
    }

    public func transcriptChunks(
        recordingID: Int64,
        embeddingModelID: String? = nil
    ) async throws -> [TranscriptChunk] {
        try await dbQueue.read { db in
            var clauses = ["recording_id = ?"]
            var args: [DatabaseValueConvertible] = [recordingID]
            if let embeddingModelID {
                clauses.append("embedding_model_id = ?")
                args.append(embeddingModelID)
            }
            let sql = """
                SELECT id, recording_id, ordinal, start_ms, end_ms, text, embedding, embedding_model_id, created_at
                FROM transcript_chunks
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY ordinal ASC
                """
            return try Self.decodeTranscriptChunks(
                Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            )
        }
    }

    public func allTranscriptChunks(
        embeddingModelID: String? = nil
    ) async throws -> [TranscriptChunk] {
        try await dbQueue.read { db in
            var sql = """
                SELECT c.id, c.recording_id, c.ordinal, c.start_ms, c.end_ms, c.text,
                       c.embedding, c.embedding_model_id, c.created_at
                FROM transcript_chunks c
                JOIN recordings r ON r.id = c.recording_id
                WHERE r.deleted_at IS NULL
                """
            var args: [DatabaseValueConvertible] = []
            if let embeddingModelID {
                sql += " AND c.embedding_model_id = ?"
                args.append(embeddingModelID)
            }
            sql += " ORDER BY r.started_at DESC, c.ordinal ASC"
            return try Self.decodeTranscriptChunks(
                Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            )
        }
    }

    public func recordingsNeedingSemanticIndex(limit: Int = 20) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.deletedAt == nil)
                .filter(Recording.Columns.transcriptText != nil)
                .filter(Recording.Columns.chunksIndexedAt == nil)
                .order(Recording.Columns.startedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    private static func decodeTranscriptChunks(_ rows: [Row]) throws -> [TranscriptChunk] {
        rows.map { row in
            let createdMs: Int64 = row["created_at"]
            return TranscriptChunk(
                id: row["id"],
                recordingID: row["recording_id"],
                ordinal: row["ordinal"],
                startMs: row["start_ms"],
                endMs: row["end_ms"],
                text: row["text"],
                embedding: row["embedding"],
                embeddingModelID: row["embedding_model_id"],
                createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
            )
        }
    }

    private static func replaceKnowledgeChunks(
        _ db: Database,
        sourceKind: KnowledgeSourceKind,
        sourceID: String,
        chunks: [KnowledgeChunk]
    ) throws {
        try SQLiteVec1Support.register(on: db)

        let staleIDs = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM knowledge_chunks WHERE source_kind = ? AND source_id = ?",
            arguments: [sourceKind.rawValue, sourceID]
        )
        for id in staleIDs {
            try db.execute(sql: "DELETE FROM knowledge_vec1 WHERE rowid = ?", arguments: [id])
        }
        try db.execute(
            sql: "DELETE FROM knowledge_chunks WHERE source_kind = ? AND source_id = ?",
            arguments: [sourceKind.rawValue, sourceID]
        )

        for chunk in chunks {
            precondition(chunk.sourceKind == sourceKind, "replaceKnowledgeChunks: mixed source kinds")
            precondition(chunk.sourceID == sourceID, "replaceKnowledgeChunks: mixed source ids")
            let createdMs = Int64(chunk.createdAt.timeIntervalSince1970 * 1000)
            let updatedMs = Int64(chunk.updatedAt.timeIntervalSince1970 * 1000)
            try db.execute(
                sql: """
                INSERT INTO knowledge_chunks
                (source_kind, source_id, ordinal, title, text, embedding, embedding_model_id,
                 content_hash, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    chunk.sourceKind.rawValue,
                    chunk.sourceID,
                    chunk.ordinal,
                    chunk.title,
                    chunk.text,
                    chunk.embedding,
                    chunk.embeddingModelID,
                    chunk.contentHash,
                    createdMs,
                    updatedMs,
                ]
            )
            let id = db.lastInsertedRowID
            if isVec1CompatibleEmbedding(chunk.embedding) {
                try db.execute(
                    sql: """
                    INSERT INTO knowledge_vec1(rowid, vector, source_kind, embedding_model_id)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        chunk.embedding,
                        chunk.sourceKind.rawValue,
                        chunk.embeddingModelID,
                    ]
                )
            }
        }
    }

    private static func isVec1CompatibleEmbedding(_ data: Data) -> Bool {
        data.count >= 16 && data.count.isMultiple(of: MemoryLayout<Float>.size)
    }

    private static func decodeKnowledgeChunk(_ row: Row) throws -> KnowledgeChunk {
        let createdMs: Int64 = row["created_at"]
        let updatedMs: Int64 = row["updated_at"]
        let rawKind: String = row["source_kind"]
        guard let sourceKind = KnowledgeSourceKind(rawValue: rawKind) else {
            throw StoreError.readFailed("Unknown knowledge source kind: \(rawKind)")
        }
        return KnowledgeChunk(
            id: row["id"],
            sourceKind: sourceKind,
            sourceID: row["source_id"],
            ordinal: row["ordinal"],
            title: row["title"],
            text: row["text"],
            embedding: row["embedding"],
            embeddingModelID: row["embedding_model_id"],
            contentHash: row["content_hash"],
            createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000.0),
            updatedAt: Date(timeIntervalSince1970: Double(updatedMs) / 1000.0)
        )
    }

    public func setPinned(id: Int64, pinned: Bool) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.pinned.set(to: pinned),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    public func softDelete(id: Int64) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.deletedAt.set(to: Date()),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    public func restore(id: Int64) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.deletedAt.set(to: nil),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    // MARK: - Search (FTS5)

    /// Full-text search over transcript bodies. Returns BM25-ranked hits with
    /// pre-highlighted snippets (matched tokens wrapped in `<mark>…</mark>`).
    /// Empty / whitespace query → `[]`. Excludes soft-deleted rows. Capped at 200.
    public func search(query: String) async throws -> [TranscriptHit] {
        let pattern = Self.ftsPattern(from: query)
        guard !pattern.isEmpty else { return [] }

        return try await dbQueue.read { db in
            let sql = """
                SELECT
                    recordings.*,
                    snippet(recordings_fts, 0, '<mark>', '</mark>', '…', 24) AS hit_snippet,
                    bm25(recordings_fts)                                    AS hit_rank
                FROM recordings
                JOIN recordings_fts ON recordings_fts.rowid = recordings.id
                WHERE recordings_fts MATCH ?
                  AND recordings.deleted_at IS NULL
                ORDER BY hit_rank ASC
                LIMIT 200
                """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern])
            return try rows.map { row in
                let rec = try Recording(row: row)
                let snippet: String = row["hit_snippet"] ?? ""
                let rank: Double = row["hit_rank"] ?? 0
                return TranscriptHit(recording: rec, snippet: snippet, score: -rank)
            }
        }
    }

    /// Sanitise a user query into a safe FTS5 MATCH expression. Splits on any
    /// non-alphanumeric boundary (keeping `-`), prefix-stars every token,
    /// joins with spaces (FTS5's implicit AND). Guarantees no operator injection.
    static func ftsPattern(from raw: String) -> String {
        raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map { "\($0)*" }
            .joined(separator: " ")
    }

    /// Day-starts (local-TZ midnight) for every day in the given month that has
    /// at least one non-deleted recording. Useful for rendering calendar dot
    /// indicators.
    public func daysWithRecordings(inMonthContaining reference: Date) async throws -> Set<Date> {
        let (start, end) = Self.monthBounds(reference)
        let cal = Calendar.current
        let rows = try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.deletedAt == nil)
                .filter(Recording.Columns.startedAt >= start && Recording.Columns.startedAt < end)
                .select(Recording.Columns.startedAt)
                .asRequest(of: Date.self)
                .fetchAll(db)
        }
        return Set(rows.map { cal.startOfDay(for: $0) })
    }

    /// All non-deleted recordings whose `startedAt` falls on the given local day.
    /// Ordered by pinned-first, then most-recent start.
    public func recordings(onDay day: Date) async throws -> [Recording] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            throw StoreError.writeFailed("date math failed")
        }
        return try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.deletedAt == nil)
                .filter(Recording.Columns.startedAt >= start && Recording.Columns.startedAt < end)
                .order(Recording.Columns.pinned.desc, Recording.Columns.startedAt.desc)
                .fetchAll(db)
        }
    }

    /// Calendar-relative first-day-of-month and first-day-of-next-month bounds
    /// for any date in the reference month.
    private static func monthBounds(_ reference: Date) -> (Date, Date) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: reference)
        let start = cal.date(from: comps) ?? reference
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? reference
        return (start, end)
    }

    // MARK: - Observation

    /// AsyncStream that re-emits the full list of (non-deleted, pinned-first)
    /// recordings on any insert/update/delete. Backed by GRDB's ValueObservation.
    public nonisolated func observeAll(pinnedFirst: Bool = true) -> AsyncStream<[Recording]> {
        let (stream, cont) = AsyncStream<[Recording]>.makeStream()
        let obs = ValueObservation.tracking { db -> [Recording] in
            var request = Recording.filter(Recording.Columns.deletedAt == nil)
            if pinnedFirst {
                request = request.order(
                    Recording.Columns.pinned.desc,
                    Recording.Columns.startedAt.desc
                )
            } else {
                request = request.order(Recording.Columns.startedAt.desc)
            }
            return try request.fetchAll(db)
        }

        nonisolated(unsafe) let cancellable = obs.start(
            in: dbQueue,
            onError: { _ in cont.finish() },
            onChange: { value in cont.yield(value) }
        )

        cont.onTermination = { _ in cancellable.cancel() }
        return stream
    }

    /// AsyncStream for a single recording row. Emits nil if the row is
    /// deleted or missing.
    public nonisolated func observe(id: Int64) -> AsyncStream<Recording?> {
        let (stream, cont) = AsyncStream<Recording?>.makeStream()
        let obs = ValueObservation.tracking { db -> Recording? in
            try Recording
                .filter(key: id)
                .filter(Recording.Columns.deletedAt == nil)
                .fetchOne(db)
        }

        nonisolated(unsafe) let cancellable = obs.start(
            in: dbQueue,
            onError: { _ in cont.finish() },
            onChange: { value in cont.yield(value) }
        )

        cont.onTermination = { _ in cancellable.cancel() }
        return stream
    }
}
