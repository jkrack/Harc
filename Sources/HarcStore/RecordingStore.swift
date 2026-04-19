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
}
