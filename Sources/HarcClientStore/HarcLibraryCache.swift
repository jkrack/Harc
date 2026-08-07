import Foundation
import GRDB
import HarcDomain

public struct ClientLibraryCacheState: Equatable, Sendable {
    public let libraryID: LibraryID
    public let changeCursor: ChangeCursor
    public let updatedAt: Date
}

public struct ClientLibraryDelta: Equatable, Sendable {
    public let libraryID: LibraryID
    public let after: ChangeCursor
    public let through: ChangeCursor
    public let recordings: [LibraryRecordingSummary]
    public let tombstones: [RecordingTombstone]

    public init(
        libraryID: LibraryID,
        after: ChangeCursor,
        through: ChangeCursor,
        recordings: [LibraryRecordingSummary],
        tombstones: [RecordingTombstone]
    ) throws {
        guard through >= after else {
            throw ClientStoreError.cursorRollback(stored: after, presented: through)
        }
        guard through > after || (recordings.isEmpty && tombstones.isEmpty) else {
            throw ClientStoreError.corruptStoredValue(field: "nonadvancingLibraryDelta")
        }
        let recordingIDs = recordings.map(\.canonicalID)
        let tombstoneIDs = tombstones.map(\.canonicalID)
        guard Set(recordingIDs).count == recordingIDs.count,
              Set(tombstoneIDs).count == tombstoneIDs.count,
              Set(recordingIDs).isDisjoint(with: tombstoneIDs) else {
            throw ClientStoreError.corruptStoredValue(field: "libraryDelta")
        }
        self.libraryID = libraryID
        self.after = after
        self.through = through
        self.recordings = recordings
        self.tombstones = tombstones
    }
}

public enum OfflineMetadataMutationKind: String, CaseIterable, Sendable {
    case setTitle
    case setTags
    case setPinned
    case setSpeakerLabel
    case assignSpeakerIdentity
    case setNotes
}

public enum OfflineMetadataMutationState: String, CaseIterable, Sendable {
    case queued
    case sending
    case conflicted
    case completed
}

public struct OfflineMetadataMutation: Equatable, Sendable {
    public let operationID: OperationID
    public let libraryID: LibraryID
    public let canonicalRecordingID: CanonicalRecordingID
    public let expectedRevision: EntityRevision
    public let kind: OfflineMetadataMutationKind
    public let exactPayload: Data
    public let state: OfflineMetadataMutationState
    public let createdAt: Date

    public init(
        operationID: OperationID,
        libraryID: LibraryID,
        canonicalRecordingID: CanonicalRecordingID,
        expectedRevision: EntityRevision,
        kind: OfflineMetadataMutationKind,
        exactPayload: Data,
        state: OfflineMetadataMutationState = .queued,
        createdAt: Date
    ) throws {
        guard !exactPayload.isEmpty else {
            throw ClientStoreError.emptyOpaqueBytes(field: "offlineMutationPayload")
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ClientStoreError.corruptStoredValue(field: "offlineMutationCreatedAt")
        }
        self.operationID = operationID
        self.libraryID = libraryID
        self.canonicalRecordingID = canonicalRecordingID
        self.expectedRevision = expectedRevision
        self.kind = kind
        self.exactPayload = exactPayload
        self.state = state
        self.createdAt = createdAt
    }
}

public struct VisibleLibraryConflict: Equatable, Sendable {
    public let conflictID: UUID
    public let operationID: OperationID?
    public let libraryID: LibraryID
    public let canonicalRecordingID: CanonicalRecordingID
    public let expectedRevision: EntityRevision
    public let currentRevision: EntityRevision
    public let currentValue: LibraryRecordingSummary
    public let createdAt: Date
    public let resolvedAt: Date?

    public init(
        conflictID: UUID = UUID(),
        operationID: OperationID?,
        libraryID: LibraryID,
        canonicalRecordingID: CanonicalRecordingID,
        expectedRevision: EntityRevision,
        currentRevision: EntityRevision,
        currentValue: LibraryRecordingSummary,
        createdAt: Date,
        resolvedAt: Date? = nil
    ) throws {
        guard currentValue.canonicalID == canonicalRecordingID,
              currentValue.revision == currentRevision else {
            throw ClientStoreError.corruptStoredValue(field: "libraryConflictCurrentValue")
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              resolvedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw ClientStoreError.corruptStoredValue(field: "libraryConflictDate")
        }
        self.conflictID = conflictID
        self.operationID = operationID
        self.libraryID = libraryID
        self.canonicalRecordingID = canonicalRecordingID
        self.expectedRevision = expectedRevision
        self.currentRevision = currentRevision
        self.currentValue = currentValue
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public final class HarcLibraryCache: @unchecked Sendable {
    // Internal for focused durability/migration verification. The concrete
    // database remains outside the public client-store API.
    let database: ClientStoreDatabase
    private let now: @Sendable () -> Date

    public convenience init(
        rootDirectory: URL,
        storageAttributes: any ClientStoreStorageAttributeApplying = FoundationClientStoreStorageAttributes()
    ) throws {
        let locations = try ClientStoreLocations(rootDirectory: rootDirectory)
        try self.init(
            databaseURL: locations.libraryCacheDatabase,
            storageAttributes: storageAttributes
        )
    }

    public init(
        databaseURL: URL,
        storageAttributes: any ClientStoreStorageAttributeApplying = FoundationClientStoreStorageAttributes(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard databaseURL.lastPathComponent == ClientStoreDatabaseKind.libraryCache.fileName else {
            throw ClientStoreError.unexpectedDatabaseFileName(
                expected: ClientStoreDatabaseKind.libraryCache.fileName,
                actual: databaseURL.lastPathComponent
            )
        }
        database = try ClientStoreDatabase(
            databaseURL: databaseURL,
            policy: .libraryCache,
            attributes: storageAttributes,
            migrator: ClientStoreMigrators.libraryCache()
        )
        self.now = now
    }

    public var databaseURL: URL { database.databaseURL }

    public func state() throws -> ClientLibraryCacheState? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT library_id, change_cursor, updated_at_ms
                    FROM cache_cursor WHERE singleton = 1
                    """
            ) else { return nil }
            guard let libraryUUID = UUID(uuidString: row["library_id"] as String) else {
                throw ClientStoreError.corruptStoredValue(field: "cacheLibraryID")
            }
            return ClientLibraryCacheState(
                libraryID: LibraryID(libraryUUID),
                changeCursor: ChangeCursor(
                    try ClientStoreCoding.unsigned(row["change_cursor"], field: "changeCursor")
                ),
                updatedAt: ClientStoreCoding.date(milliseconds: row["updated_at_ms"])
            )
        }
    }

    /// Replaces an anchored cache in one transaction. Re-adopting another
    /// library clears only this protected cache; it never mutates transfer
    /// trust/history or the host's canonical store.
    public func replace(with snapshot: AnchoredLibrarySnapshot) throws {
        try database.write { db in
            if let current = try cacheState(in: db) {
                if current.libraryID == snapshot.libraryID {
                    if snapshot.anchor < current.changeCursor {
                        throw ClientStoreError.cursorRollback(
                            stored: current.changeCursor,
                            presented: snapshot.anchor
                        )
                    }
                    if snapshot.anchor == current.changeCursor {
                        let currentRecordings = try cachedRecordings(in: db)
                        let currentTombstones = try cachedTombstones(in: db)
                        guard currentRecordings == snapshot.recordings,
                              currentTombstones == snapshot.tombstones else {
                            throw ClientStoreError.snapshotEquivocation(cursor: snapshot.anchor)
                        }
                        return
                    }
                } else {
                    // Offline operations are scoped to their adopted library;
                    // they must never leak into the queue or conflict UI after
                    // switching to a different host library.
                    try db.execute(sql: "DELETE FROM library_conflicts")
                    try db.execute(sql: "DELETE FROM offline_metadata_mutations")
                    try db.execute(sql: "DELETE FROM cached_speaker_recognition_pack")
                }
            }
            try db.execute(sql: "DELETE FROM cached_recordings")
            try db.execute(sql: "DELETE FROM cached_tombstones")

            let nowMS = try ClientStoreCoding.milliseconds(now())
            for recording in snapshot.recordings {
                try insert(recording, libraryID: snapshot.libraryID, cachedAtMS: nowMS, in: db)
            }
            for tombstone in snapshot.tombstones {
                try insert(tombstone, libraryID: snapshot.libraryID, cachedAtMS: nowMS, in: db)
            }
            try persistCursor(
                libraryID: snapshot.libraryID,
                cursor: snapshot.anchor,
                updatedAtMS: nowMS,
                in: db
            )
        }
    }

    /// Applies only the exact next delta boundary. Cursor mismatch never
    /// partially applies records or tombstones.
    public func apply(_ delta: ClientLibraryDelta) throws {
        try database.write { db in
            let current = try cacheState(in: db)
            if let current {
                guard current.libraryID == delta.libraryID else {
                    throw ClientStoreError.wrongLibrary(
                        expected: current.libraryID,
                        presented: delta.libraryID
                    )
                }
                guard current.changeCursor == delta.after else {
                    throw ClientStoreError.cursorMismatch(
                        expected: current.changeCursor,
                        presented: delta.after
                    )
                }
            } else if delta.after != .zero {
                throw ClientStoreError.cursorMismatch(expected: .zero, presented: delta.after)
            }

            let nowMS = try ClientStoreCoding.milliseconds(now())
            for recording in delta.recordings {
                try validateRevision(
                    canonicalID: recording.canonicalID,
                    presentedRevision: recording.revision,
                    presentedPayload: ClientStoreCoding.encode(recording),
                    in: db
                )
                try db.execute(
                    sql: """
                        DELETE FROM cached_tombstones
                        WHERE library_id = ? AND canonical_recording_id = ?
                        """,
                    arguments: [delta.libraryID.description, recording.canonicalID.description]
                )
                try insertOrReplace(
                    recording,
                    libraryID: delta.libraryID,
                    cachedAtMS: nowMS,
                    in: db
                )
            }
            for tombstone in delta.tombstones {
                let payload = try ClientStoreCoding.encode(tombstone)
                try validateRevision(
                    canonicalID: tombstone.canonicalID,
                    presentedRevision: tombstone.revision,
                    presentedPayload: payload,
                    in: db
                )
                try db.execute(
                    sql: """
                        DELETE FROM cached_recordings
                        WHERE library_id = ? AND canonical_recording_id = ?
                        """,
                    arguments: [delta.libraryID.description, tombstone.canonicalID.description]
                )
                try insertOrReplace(
                    tombstone,
                    libraryID: delta.libraryID,
                    cachedAtMS: nowMS,
                    in: db
                )
            }
            try persistCursor(
                libraryID: delta.libraryID,
                cursor: delta.through,
                updatedAtMS: nowMS,
                in: db
            )
        }
    }

    public func recordings() throws -> [LibraryRecordingSummary] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT recording_payload
                    FROM cached_recordings
                    ORDER BY canonical_recording_id
                    """
            )
            return try rows.map {
                try ClientStoreCoding.decode(
                    LibraryRecordingSummary.self,
                    from: $0["recording_payload"],
                    field: "cachedRecording"
                )
            }
        }
    }

    public func recording(
        id: CanonicalRecordingID
    ) throws -> LibraryRecordingSummary? {
        try database.read { db in
            guard let payload = try Data.fetchOne(
                db,
                sql: """
                    SELECT recording_payload FROM cached_recordings
                    WHERE canonical_recording_id = ?
                    """,
                arguments: [id.description]
            ) else { return nil }
            return try ClientStoreCoding.decode(
                LibraryRecordingSummary.self,
                from: payload,
                field: "cachedRecording"
            )
        }
    }

    public func speakerRecognitionPack(
        libraryID: LibraryID
    ) throws -> SpeakerRecognitionPack? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT library_id, pack_payload
                    FROM cached_speaker_recognition_pack
                    WHERE singleton = 1
                    """
            ) else { return nil }
            guard (row["library_id"] as String) == libraryID.description else {
                return nil
            }
            return try ClientStoreCoding.decode(
                SpeakerRecognitionPack.self,
                from: row["pack_payload"],
                field: "speakerRecognitionPack"
            )
        }
    }

    public func persistSpeakerRecognitionPack(
        _ pack: SpeakerRecognitionPack,
        libraryID: LibraryID
    ) throws {
        try database.write { db in
            if let current = try cacheState(in: db), current.libraryID != libraryID {
                throw ClientStoreError.wrongLibrary(
                    expected: current.libraryID,
                    presented: libraryID
                )
            }
            let encodedPack = try ClientStoreCoding.encode(pack)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT pack_revision, pack_payload FROM cached_speaker_recognition_pack WHERE singleton = 1"
            ) {
                let stored = try EntityRevision(
                    signedValue: existing["pack_revision"]
                )
                guard pack.revision >= stored else {
                    throw ClientStoreError.revisionRollback(
                        stored: stored,
                        presented: pack.revision
                    )
                }
                if pack.revision == stored {
                    guard existing["pack_payload"] as Data == encodedPack else {
                        throw ClientStoreError.revisionEquivocation(
                            revision: pack.revision
                        )
                    }
                    return
                }
            }
            try db.execute(sql: """
                INSERT INTO cached_speaker_recognition_pack (
                    singleton, library_id, pack_revision, pack_payload, cached_at_ms
                ) VALUES (1, ?, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    library_id = excluded.library_id,
                    pack_revision = excluded.pack_revision,
                    pack_payload = excluded.pack_payload,
                    cached_at_ms = excluded.cached_at_ms
                """, arguments: [
                    libraryID.description,
                    try pack.revision.signedInt64Value(),
                    encodedPack,
                    try ClientStoreCoding.milliseconds(now()),
                ])
        }
    }

    public func tombstones() throws -> [RecordingTombstone] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT tombstone_payload
                    FROM cached_tombstones
                    ORDER BY canonical_recording_id
                    """
            )
            return try rows.map {
                try ClientStoreCoding.decode(
                    RecordingTombstone.self,
                    from: $0["tombstone_payload"],
                    field: "cachedTombstone"
                )
            }
        }
    }

    public func persistOfflineMutation(_ mutation: OfflineMetadataMutation) throws {
        try database.write { db in
            if let current = try cacheState(in: db), current.libraryID != mutation.libraryID {
                throw ClientStoreError.wrongLibrary(
                    expected: current.libraryID,
                    presented: mutation.libraryID
                )
            }
            let timestamp = try ClientStoreCoding.milliseconds(mutation.createdAt)
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM offline_metadata_mutations WHERE operation_id = ?",
                arguments: [mutation.operationID.description]
            ) {
                let matches =
                    (row["library_id"] as String) == mutation.libraryID.description &&
                    (row["canonical_recording_id"] as String) == mutation.canonicalRecordingID.description &&
                    (row["expected_revision"] as Int64) == mutation.expectedRevision.rawValue &&
                    (row["mutation_kind"] as String) == mutation.kind.rawValue &&
                    (row["exact_payload"] as Data) == mutation.exactPayload
                guard matches else { throw ClientStoreError.exactObjectEquivocation }
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO offline_metadata_mutations (
                        operation_id, library_id, canonical_recording_id,
                        expected_revision, mutation_kind, exact_payload,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    mutation.operationID.description,
                    mutation.libraryID.description,
                    mutation.canonicalRecordingID.description,
                    try mutation.expectedRevision.signedInt64Value(),
                    mutation.kind.rawValue,
                    mutation.exactPayload,
                    mutation.state.rawValue,
                    timestamp,
                    timestamp,
                ]
            )
        }
    }

    public func offlineMutations() throws -> [OfflineMetadataMutation] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM offline_metadata_mutations
                    WHERE state != 'completed'
                    ORDER BY created_at_ms, operation_id
                    """
            )
            return try rows.map { row in
                guard
                    let operationUUID = UUID(uuidString: row["operation_id"] as String),
                    let libraryUUID = UUID(uuidString: row["library_id"] as String),
                    let canonicalUUID = UUID(uuidString: row["canonical_recording_id"] as String),
                    let kind = OfflineMetadataMutationKind(rawValue: row["mutation_kind"] as String),
                    let state = OfflineMetadataMutationState(rawValue: row["state"] as String)
                else {
                    throw ClientStoreError.corruptStoredValue(field: "offlineMutation")
                }
                return try OfflineMetadataMutation(
                    operationID: OperationID(operationUUID),
                    libraryID: LibraryID(libraryUUID),
                    canonicalRecordingID: CanonicalRecordingID(canonicalUUID),
                    expectedRevision: try EntityRevision(signedValue: row["expected_revision"]),
                    kind: kind,
                    exactPayload: row["exact_payload"],
                    state: state,
                    createdAt: ClientStoreCoding.date(milliseconds: row["created_at_ms"])
                )
            }
        }
    }

    public func updateOfflineMutationState(
        operationID: OperationID,
        state: OfflineMetadataMutationState
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE offline_metadata_mutations
                    SET state = ?, updated_at_ms = ?
                    WHERE operation_id = ?
                    """,
                arguments: [
                    state.rawValue,
                    try ClientStoreCoding.milliseconds(now()),
                    operationID.description,
                ]
            )
            guard db.changesCount == 1 else {
                throw ClientStoreError.corruptStoredValue(
                    field: "offlineMutationOperationID"
                )
            }
        }
    }

    public func recordConflict(_ conflict: VisibleLibraryConflict) throws {
        try database.write { db in
            let currentState = try cacheState(in: db)
            if let currentState, currentState.libraryID != conflict.libraryID {
                throw ClientStoreError.wrongLibrary(
                    expected: currentState.libraryID,
                    presented: conflict.libraryID
                )
            }
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM library_conflicts WHERE conflict_id = ?",
                arguments: [conflict.conflictID.uuidString.lowercased()]
            ) {
                guard try decodeLibraryConflict(row) == conflict else {
                    throw ClientStoreError.exactObjectEquivocation
                }
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO library_conflicts (
                        conflict_id, operation_id, library_id,
                        canonical_recording_id, expected_revision,
                        current_revision, current_value_payload,
                        created_at_ms, resolved_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    conflict.conflictID.uuidString.lowercased(),
                    conflict.operationID?.description,
                    conflict.libraryID.description,
                    conflict.canonicalRecordingID.description,
                    try conflict.expectedRevision.signedInt64Value(),
                    try conflict.currentRevision.signedInt64Value(),
                    try ClientStoreCoding.encode(conflict.currentValue),
                    try ClientStoreCoding.milliseconds(conflict.createdAt),
                    try conflict.resolvedAt.map(ClientStoreCoding.milliseconds),
                ]
            )
            if let operationID = conflict.operationID {
                try db.execute(
                    sql: """
                        UPDATE offline_metadata_mutations
                        SET state = 'conflicted', updated_at_ms = ?
                        WHERE operation_id = ?
                        """,
                    arguments: [
                        try ClientStoreCoding.milliseconds(conflict.createdAt),
                        operationID.description,
                    ]
                )
            }
        }
    }

    public func conflicts(includeResolved: Bool = false) throws -> [VisibleLibraryConflict] {
        try database.read { db in
            let predicate = includeResolved ? "" : "WHERE resolved_at_ms IS NULL"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM library_conflicts
                    \(predicate)
                    ORDER BY created_at_ms, conflict_id
                    """
            )
            return try rows.map(decodeLibraryConflict)
        }
    }

    public func resolveConflict(_ conflictID: UUID, at date: Date? = nil) throws {
        let resolvedAt = date ?? now()
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE library_conflicts
                    SET resolved_at_ms = ?
                    WHERE conflict_id = ? AND resolved_at_ms IS NULL
                    """,
                arguments: [
                    try ClientStoreCoding.milliseconds(resolvedAt),
                    conflictID.uuidString.lowercased(),
                ]
            )
            guard db.changesCount == 1 else {
                throw ClientStoreError.corruptStoredValue(
                    field: "libraryConflictID"
                )
            }
        }
    }

    public func refreshStorageAttributes() throws {
        try database.refreshStorageAttributes()
    }

    /// Drops only replaceable Host projections. Durable offline commands and
    /// visible conflicts remain intact and the next refresh starts a new
    /// anchored snapshot.
    public func clearCachedLibraryProjection() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM cached_recordings")
            try db.execute(sql: "DELETE FROM cached_tombstones")
            try db.execute(sql: "DELETE FROM cache_cursor")
            try db.execute(sql: "DELETE FROM cached_speaker_recognition_pack")
        }
    }

    public func checkpoint() throws {
        try database.checkpoint()
    }

    private func cacheState(in db: Database) throws -> ClientLibraryCacheState? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT library_id, change_cursor, updated_at_ms FROM cache_cursor WHERE singleton = 1"
        ) else { return nil }
        guard let libraryUUID = UUID(uuidString: row["library_id"] as String) else {
            throw ClientStoreError.corruptStoredValue(field: "cacheLibraryID")
        }
        return ClientLibraryCacheState(
            libraryID: LibraryID(libraryUUID),
            changeCursor: ChangeCursor(
                try ClientStoreCoding.unsigned(row["change_cursor"], field: "changeCursor")
            ),
            updatedAt: ClientStoreCoding.date(milliseconds: row["updated_at_ms"])
        )
    }

    private func cachedRecordings(in db: Database) throws -> [LibraryRecordingSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT recording_payload FROM cached_recordings
                ORDER BY canonical_recording_id
                """
        )
        return try rows.map {
            try ClientStoreCoding.decode(
                LibraryRecordingSummary.self,
                from: $0["recording_payload"],
                field: "cachedRecording"
            )
        }
    }

    private func cachedTombstones(in db: Database) throws -> [RecordingTombstone] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT tombstone_payload FROM cached_tombstones
                ORDER BY canonical_recording_id
                """
        )
        return try rows.map {
            try ClientStoreCoding.decode(
                RecordingTombstone.self,
                from: $0["tombstone_payload"],
                field: "cachedTombstone"
            )
        }
    }

    private func persistCursor(
        libraryID: LibraryID,
        cursor: ChangeCursor,
        updatedAtMS: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cache_cursor(singleton, library_id, change_cursor, updated_at_ms)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    library_id = excluded.library_id,
                    change_cursor = excluded.change_cursor,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                libraryID.description,
                try cursor.signedInt64Value(),
                updatedAtMS,
            ]
        )
    }

    private func insert(
        _ recording: LibraryRecordingSummary,
        libraryID: LibraryID,
        cachedAtMS: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cached_recordings (
                    library_id, canonical_recording_id, entity_revision,
                    recording_payload, cached_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                libraryID.description,
                recording.canonicalID.description,
                try recording.revision.signedInt64Value(),
                try ClientStoreCoding.encode(recording),
                cachedAtMS,
            ]
        )
    }

    private func insertOrReplace(
        _ recording: LibraryRecordingSummary,
        libraryID: LibraryID,
        cachedAtMS: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cached_recordings (
                    library_id, canonical_recording_id, entity_revision,
                    recording_payload, cached_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(library_id, canonical_recording_id) DO UPDATE SET
                    entity_revision = excluded.entity_revision,
                    recording_payload = excluded.recording_payload,
                    cached_at_ms = excluded.cached_at_ms
                """,
            arguments: [
                libraryID.description,
                recording.canonicalID.description,
                try recording.revision.signedInt64Value(),
                try ClientStoreCoding.encode(recording),
                cachedAtMS,
            ]
        )
    }

    private func insert(
        _ tombstone: RecordingTombstone,
        libraryID: LibraryID,
        cachedAtMS: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cached_tombstones (
                    library_id, canonical_recording_id, entity_revision,
                    tombstone_payload, cached_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                libraryID.description,
                tombstone.canonicalID.description,
                try tombstone.revision.signedInt64Value(),
                try ClientStoreCoding.encode(tombstone),
                cachedAtMS,
            ]
        )
    }

    private func insertOrReplace(
        _ tombstone: RecordingTombstone,
        libraryID: LibraryID,
        cachedAtMS: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cached_tombstones (
                    library_id, canonical_recording_id, entity_revision,
                    tombstone_payload, cached_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(library_id, canonical_recording_id) DO UPDATE SET
                    entity_revision = excluded.entity_revision,
                    tombstone_payload = excluded.tombstone_payload,
                    cached_at_ms = excluded.cached_at_ms
                """,
            arguments: [
                libraryID.description,
                tombstone.canonicalID.description,
                try tombstone.revision.signedInt64Value(),
                try ClientStoreCoding.encode(tombstone),
                cachedAtMS,
            ]
        )
    }

    private func validateRevision(
        canonicalID: CanonicalRecordingID,
        presentedRevision: EntityRevision,
        presentedPayload: Data,
        in db: Database
    ) throws {
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT entity_revision, recording_payload AS payload
                FROM cached_recordings WHERE canonical_recording_id = ?
                UNION ALL
                SELECT entity_revision, tombstone_payload AS payload
                FROM cached_tombstones WHERE canonical_recording_id = ?
                LIMIT 1
                """,
            arguments: [canonicalID.description, canonicalID.description]
        ) {
            let stored = try EntityRevision(signedValue: row["entity_revision"])
            if presentedRevision < stored {
                throw ClientStoreError.revisionRollback(
                    stored: stored,
                    presented: presentedRevision
                )
            }
            if presentedRevision == stored,
               (row["payload"] as Data) != presentedPayload {
                throw ClientStoreError.revisionEquivocation(revision: stored)
            }
        }
    }

    private func decodeLibraryConflict(_ row: Row) throws -> VisibleLibraryConflict {
        guard
            let conflictID = UUID(uuidString: row["conflict_id"] as String),
            let libraryUUID = UUID(uuidString: row["library_id"] as String),
            let canonicalUUID = UUID(uuidString: row["canonical_recording_id"] as String)
        else {
            throw ClientStoreError.corruptStoredValue(field: "libraryConflict")
        }
        let operationID = (row["operation_id"] as String?)
            .flatMap(UUID.init(uuidString:))
            .map(OperationID.init)
        let currentValue = try ClientStoreCoding.decode(
            LibraryRecordingSummary.self,
            from: row["current_value_payload"],
            field: "libraryConflictCurrentValue"
        )
        return try VisibleLibraryConflict(
            conflictID: conflictID,
            operationID: operationID,
            libraryID: LibraryID(libraryUUID),
            canonicalRecordingID: CanonicalRecordingID(canonicalUUID),
            expectedRevision: try EntityRevision(signedValue: row["expected_revision"]),
            currentRevision: try EntityRevision(signedValue: row["current_revision"]),
            currentValue: currentValue,
            createdAt: ClientStoreCoding.date(milliseconds: row["created_at_ms"]),
            resolvedAt: (row["resolved_at_ms"] as Int64?).map(ClientStoreCoding.date)
        )
    }
}
