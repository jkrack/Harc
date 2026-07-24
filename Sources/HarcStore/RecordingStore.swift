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
        await reprojectOKF(id: id)
    }

    /// Regenerate the recording's canonical `.md` artifact after a mutation
    /// that changes projected content. Best-effort: the DB write already
    /// succeeded; a projection failure logs and moves on.
    private func reprojectOKF(id: Int64) async {
        guard let rec = try? await fetch(id: id) else { return }
        OKFProjection.write(recording: rec)
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
        await reprojectOKF(id: id)
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
        await reprojectOKF(id: id)
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
        await reprojectOKF(id: id)
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
        await reprojectOKF(id: id)
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
        await reprojectOKF(id: id)
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
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
        await reprojectOKF(id: id)
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
