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

    /// Full-text search across title and transcript_text. Empty query returns fetchAll().
    public func search(
        query: String,
        includeDeleted: Bool = false
    ) async throws -> [Recording] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await fetchAll(includeDeleted: includeDeleted)
        }

        return try await dbQueue.read { db in
            // Wrap in an FTS5 pattern that does prefix matching per token.
            let tokens = trimmed
                .split(separator: " ")
                .map { "\($0)*" }
                .joined(separator: " ")

            let sql: String
            if includeDeleted {
                sql = """
                    SELECT recordings.* FROM recordings
                    JOIN recordings_fts ON recordings_fts.rowid = recordings.id
                    WHERE recordings_fts MATCH ?
                    ORDER BY recordings.pinned DESC, recordings.started_at DESC
                """
            } else {
                sql = """
                    SELECT recordings.* FROM recordings
                    JOIN recordings_fts ON recordings_fts.rowid = recordings.id
                    WHERE recordings_fts MATCH ? AND recordings.deleted_at IS NULL
                    ORDER BY recordings.pinned DESC, recordings.started_at DESC
                """
            }

            return try Recording.fetchAll(db, sql: sql, arguments: [tokens])
        }
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
