import Foundation
import GRDB
import HarcDomain

public extension RecordingStore {
    /// Stable identity and writer state for this canonical library.
    func libraryMetadata() async throws -> HarcDomain.LibraryMetadata {
        try await db.read { database in
            try Self.readLibraryMetadata(in: database)
        }
    }

    /// Local lookup by the public identity. Network adapters must still map the
    /// result to a path-free domain view before returning it.
    func fetch(canonicalID: CanonicalRecordingID) async throws -> Recording? {
        try await db.read { database in
            try Recording
                .filter(Recording.Columns.canonicalID == canonicalID.description)
                .fetchOne(database)
        }
    }

    /// Snapshot the current cursor and all base rows in one SQLite read
    /// transaction. This is intentionally independent of the change log so a
    /// populated v15 library with a newly empty v16 log remains fully visible.
    func anchoredLibrarySnapshot() async throws -> AnchoredLibrarySnapshot {
        try await db.read { database in
            let metadata = try Self.readLibraryMetadata(in: database)
            let rows = try Recording
                .order(Recording.Columns.canonicalID.asc)
                .fetchAll(database)

            var recordings: [LibraryRecordingSummary] = []
            var tombstones: [RecordingTombstone] = []
            recordings.reserveCapacity(rows.count)
            tombstones.reserveCapacity(rows.count)

            for recording in rows {
                if let deletedAt = recording.deletedAt {
                    tombstones.append(
                        try RecordingTombstone(
                            canonicalID: recording.canonicalID,
                            revision: recording.revision,
                            deletedAt: deletedAt
                        )
                    )
                } else {
                    recordings.append(try Self.pathFreeSummary(for: recording))
                }
            }

            return try AnchoredLibrarySnapshot(
                libraryID: metadata.libraryID,
                anchor: metadata.currentChangeCursor,
                recordings: recordings,
                tombstones: tombstones
            )
        }
    }

    /// Ordered change descriptors after an anchored cursor. Payload detail is
    /// fetched separately by canonical ID so the log never stores paths or a
    /// duplicate serialized Recording model.
    func libraryChanges(
        after cursor: ChangeCursor,
        limit: Int = 500
    ) async throws -> [LibraryChangeDescriptor] {
        let boundedLimit = max(1, min(limit, 1_000))
        let storedCursor = try cursor.signedInt64Value()
        return try await db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT cursor, entity_uuid, revision, operation, changed_at
                    FROM library_changes
                    WHERE entity_type = 'recording' AND cursor > ?
                    ORDER BY cursor
                    LIMIT ?
                    """,
                arguments: [storedCursor, boundedLimit]
            )
            return try rows.map(Self.libraryChange(from:))
        }
    }

    /// Path-free authorized-content candidate. Authorization and field
    /// redaction belong to HarcHost; this store mapping guarantees that local
    /// row IDs and filesystem locations are absent from the DTO itself.
    func recordingDetail(canonicalID: CanonicalRecordingID) async throws -> LibraryRecordingDetail? {
        try await db.read { database in
            guard let recording = try Recording
                .filter(Recording.Columns.canonicalID == canonicalID.description)
                .filter(Recording.Columns.deletedAt == nil)
                .fetchOne(database)
            else { return nil }

            let labels = try recording.speakerNames
                .sorted { $0.key < $1.key }
                .map { index, name in
                    guard let portableIndex = UInt32(exactly: index) else {
                        throw StoreError.invalidData("Speaker index is outside the portable range")
                    }
                    return try SpeakerLabel(speakerIndex: portableIndex, displayName: name)
                }

            return try LibraryRecordingDetail(
                summary: Self.pathFreeSummary(for: recording),
                transcriptText: recording.transcriptText,
                speakerLabels: labels,
                summaryMarkdown: recording.summaryMarkdown,
                actionItemsMarkdown: recording.actionItemsMarkdown,
                notesMarkdown: recording.notesMarkdown,
                discontinuities: []
            )
        }
    }

    /// Insert a host-owned row using immutable producing-device identity.
    /// Replaying the same origin and canonical audio returns the existing row;
    /// binding the origin to different audio is an integrity conflict.
    @discardableResult
    func insertFromOrigin(
        _ recording: Recording,
        originID: OriginRecordingID,
        canonicalPCMHash: CanonicalPCMHash,
        canonicalPCMFrames: UInt64
    ) async throws -> Recording {
        guard canonicalPCMFrames > 0,
              let storedFrames = Int64(exactly: canonicalPCMFrames)
        else {
            throw StoreError.invalidData("Canonical PCM frame count must fit SQLite and be positive")
        }

        do {
            return try await db.write { database in
                if let existing = try Recording
                    .filter(Recording.Columns.originDeviceID == originID.deviceID.rawBytes)
                    .filter(
                        Recording.Columns.originRecordingUUID
                            == originID.recordingUUID.uuidString.lowercased()
                    )
                    .fetchOne(database)
                {
                    guard existing.canonicalPCMHash == canonicalPCMHash,
                          existing.canonicalPCMFrames == canonicalPCMFrames
                    else { throw StoreError.originIdentityConflict }
                    return existing
                }

                var inserted = recording
                let now = Date()
                inserted.id = nil
                // Canonical identity is minted by the authoritative library,
                // never accepted from the producing client or its manifest.
                inserted.canonicalID = .random()
                inserted.originID = originID
                inserted.canonicalPCMHash = canonicalPCMHash
                inserted.canonicalPCMFrames = UInt64(storedFrames)
                inserted.revision = .initial
                // Receipt durability precedes all derived work. A producing
                // client cannot claim that the host has already transcribed,
                // projected, or deleted the recording it is adopting.
                inserted.processing = .pending
                inserted.projection = .pending
                inserted.deletedAt = nil
                inserted.createdAt = now
                inserted.updatedAt = now
                try inserted.insert(database)
                inserted.id = database.lastInsertedRowID
                try Self.appendLibraryChange(
                    in: database,
                    recordingID: inserted.id!,
                    operation: inserted.deletedAt == nil ? .upsert : .tombstone,
                    changedAt: now
                )
                return inserted
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Bind a legacy/local row to the hash of its canonical PCM exactly once.
    /// A repeated identical result is idempotent; a different result is never
    /// allowed to rewrite provenance.
    func setCanonicalPCM(
        id: Int64,
        hash: CanonicalPCMHash,
        totalFrames: UInt64
    ) async throws {
        guard totalFrames > 0, let storedFrames = Int64(exactly: totalFrames) else {
            throw StoreError.invalidData("Canonical PCM frame count must fit SQLite and be positive")
        }
        try await db.write { database in
            guard let existing = try Recording.fetchOne(database, key: id) else {
                throw StoreError.notFound
            }
            if existing.canonicalPCMHash == hash,
               existing.canonicalPCMFrames == totalFrames {
                return
            }
            guard existing.canonicalPCMHash == nil,
                  existing.canonicalPCMFrames == nil
            else { throw StoreError.canonicalPCMHashConflict }

            let now = Date()
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET canonical_pcm_sha256 = ?, canonical_pcm_frames = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [hash.rawBytes, storedFrames, now, id]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: id,
                changedAt: now
            )
        }
    }

    func updateProcessing(
        id: Int64,
        descriptor: ProcessingDescriptor
    ) async throws {
        try await db.write { database in
            guard let existing = try Recording.fetchOne(database, key: id) else {
                throw StoreError.notFound
            }
            guard existing.processing != descriptor else { return }
            let now = Date()
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET processing_state = ?, processing_failure_detail = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    descriptor.state.rawValue,
                    encodeStoredFailure(descriptor.failure),
                    now,
                    id,
                ]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: id,
                changedAt: now
            )
        }
    }

    func updateProjection(
        id: Int64,
        descriptor: ProjectionDescriptor
    ) async throws {
        let storedVersion: Int64?
        if let version = descriptor.version {
            guard let value = Int64(exactly: version.rawValue) else {
                throw StoreError.invalidData("Projection version exceeds SQLite range")
            }
            storedVersion = value
        } else {
            storedVersion = nil
        }

        try await db.write { database in
            guard let existing = try Recording.fetchOne(database, key: id) else {
                throw StoreError.notFound
            }
            guard existing.projection != descriptor else { return }
            let now = Date()
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET projection_state = ?, projection_failure_detail = ?,
                        projection_version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    descriptor.state.rawValue,
                    encodeStoredFailure(descriptor.failure),
                    storedVersion,
                    now,
                    id,
                ]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: id,
                changedAt: now
            )
        }
    }
}

private extension RecordingStore {
    static func readLibraryMetadata(in database: Database) throws -> HarcDomain.LibraryMetadata {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT library_uuid, writer_mode, host_authority_id,
                       host_state_uuid, current_change_cursor
                FROM library_metadata WHERE id = 1
                """
        ) else {
            throw StoreError.invalidData("Canonical library metadata row is missing")
        }
        guard let libraryUUID = UUID(uuidString: row["library_uuid"]),
              let writerMode = LibraryWriterMode(rawValue: row["writer_mode"])
        else {
            throw StoreError.invalidData("Canonical library metadata is invalid")
        }

        let authorityBytes: Data? = row["host_authority_id"]
        let stateString: String? = row["host_state_uuid"]
        let authorityID = try authorityBytes.map(HostAuthorityID.init)
        let stateID: HostStateID?
        if let stateString {
            guard let uuid = UUID(uuidString: stateString) else {
                throw StoreError.invalidData("Host state ID is invalid")
            }
            stateID = HostStateID(uuid)
        } else {
            stateID = nil
        }
        let storedCursor: Int64 = row["current_change_cursor"]
        return try HarcDomain.LibraryMetadata(
            libraryID: LibraryID(libraryUUID),
            writerMode: writerMode,
            hostAuthorityID: authorityID,
            hostStateID: stateID,
            currentChangeCursor: ChangeCursor(signedValue: storedCursor)
        )
    }

    static func pathFreeSummary(for recording: Recording) throws -> LibraryRecordingSummary {
        let audio: CanonicalAudioDescriptor
        if let hash = recording.canonicalPCMHash,
           let frames = recording.canonicalPCMFrames {
            audio = try .available(pcmSHA256: hash, totalFrames: frames)
        } else {
            audio = .unavailablePendingHash
        }
        return try LibraryRecordingSummary(
            canonicalID: recording.canonicalID,
            originID: recording.originID,
            revision: recording.revision,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt,
            title: recording.title,
            suggestedTitle: recording.suggestedTitle,
            tags: recording.tags,
            pinned: recording.pinned,
            canonicalAudio: audio,
            processing: recording.processing,
            projection: recording.projection
        )
    }

    static func libraryChange(from row: Row) throws -> LibraryChangeDescriptor {
        guard let uuid = UUID(uuidString: row["entity_uuid"]),
              let operation = LibraryChangeOperation(rawValue: row["operation"])
        else {
            throw StoreError.invalidData("Library change row is invalid")
        }
        let storedCursor: Int64 = row["cursor"]
        let storedRevision: Int64 = row["revision"]
        let changedAt: Date = row["changed_at"]
        return try LibraryChangeDescriptor(
            cursor: ChangeCursor(signedValue: storedCursor),
            canonicalID: CanonicalRecordingID(uuid),
            revision: EntityRevision(signedValue: storedRevision),
            operation: operation,
            changedAt: changedAt
        )
    }
}
