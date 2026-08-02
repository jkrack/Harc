import Foundation
import GRDB

/// Storage-level operations mirrored by `HarcDomain.LibraryChangeOperation`.
/// Keeping the SQL spelling here avoids teaching HarcDomain about GRDB.
enum StoredLibraryChangeOperation: String, Sendable {
    case upsert
    case tombstone
}

extension RecordingStore {
    /// Append the current revision of an already-mutated recording to the
    /// library change log and advance the singleton metadata high-water mark.
    /// The caller must run inside the same database write transaction as the
    /// visible mutation.
    @discardableResult
    static func appendLibraryChange(
        in database: Database,
        recordingID: Int64,
        operation: StoredLibraryChangeOperation? = nil,
        changedAt: Date
    ) throws -> Int64 {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT canonical_uuid, revision, deleted_at FROM recordings WHERE id = ?",
            arguments: [recordingID]
        ) else {
            throw StoreError.notFound
        }

        let canonicalUUID: String = row["canonical_uuid"]
        let revision: Int64 = row["revision"]
        let deletedAt: Date? = row["deleted_at"]
        // A row that is still soft-deleted must remain a tombstone even when
        // maintenance work (for example a legacy PCM-hash backfill) changes
        // another public field. Clients must never be told to fetch an upsert
        // whose current row is intentionally unavailable.
        let resolvedOperation = operation ?? (deletedAt == nil ? .upsert : .tombstone)
        try database.execute(
            sql: """
                INSERT INTO library_changes
                    (entity_type, entity_uuid, revision, operation, changed_at, is_tombstone)
                VALUES ('recording', ?, ?, ?, ?, ?)
                """,
            arguments: [
                canonicalUUID,
                revision,
                resolvedOperation.rawValue,
                changedAt,
                resolvedOperation == .tombstone,
            ]
        )
        let cursor = database.lastInsertedRowID
        try database.execute(
            sql: """
                UPDATE library_metadata
                SET current_change_cursor = ?, updated_at = ?
                WHERE id = 1
                """,
            arguments: [cursor, changedAt]
        )
        guard database.changesCount == 1 else {
            throw StoreError.invalidData("Canonical library metadata row is missing")
        }
        return cursor
    }

    /// Increment a recording revision and append exactly one corresponding
    /// change. This is deliberately explicit rather than trigger-driven so
    /// internal index maintenance can update its private columns without
    /// manufacturing client-visible revisions.
    @discardableResult
    static func bumpRevisionAndAppendLibraryChange(
        in database: Database,
        recordingID: Int64,
        operation: StoredLibraryChangeOperation? = nil,
        changedAt: Date
    ) throws -> Int64 {
        try database.execute(
            sql: """
                UPDATE recordings
                SET revision = revision + 1
                WHERE id = ? AND revision < 9223372036854775807
                """,
            arguments: [recordingID]
        )
        guard database.changesCount == 1 else {
            let exists = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM recordings WHERE id = ?)",
                arguments: [recordingID]
            ) ?? false
            if exists { throw StoreError.revisionOverflow }
            throw StoreError.notFound
        }
        return try appendLibraryChange(
            in: database,
            recordingID: recordingID,
            operation: operation,
            changedAt: changedAt
        )
    }
}
