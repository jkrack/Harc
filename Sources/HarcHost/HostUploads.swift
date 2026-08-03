import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcTransfer

private enum ManifestBindingDatabaseResult {
    case success(ExactObjectBindingDisposition, [UInt32])
    case conflict(TransferValidationError)
}

extension HarcHostStore {
    public func beginUpload(
        context: AuthenticatedDeviceContext,
        request: BeginHostUploadRequest
    ) async throws -> BeginHostUploadDisposition {
        try await beginUpload(context: context, request: request, at: now())
    }

    /// Deterministic `@testable` seam. Production upload admission always
    /// derives its acceptance time from the store's injected clock.
    func beginUpload(
        context: AuthenticatedDeviceContext,
        request: BeginHostUploadRequest,
        at date: Date
    ) async throws -> BeginHostUploadDisposition {
        try await repairSecurityRegistryOnReopen()
        // Session expiry is host-time authority. Capture metadata in a future
        // wire request must never let a client choose the lease clock.
        let acceptedAt = date
        enum Result {
            case created(UploadAttempt)
            case replay(UploadAttempt)
            case reopened(UploadAttempt)
            case committed(OpaqueExactObjectSlot)
        }

        let result: Result = try await dbQueue.write { db in
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: request.originRecordingID.deviceID,
                at: acceptedAt
            )
            let existing = try self.fetchUploadAttempts(
                in: db,
                ownerDeviceID: context.authenticatedDeviceID
            )
            let decision = try UploadAttemptAdmission.decide(
                proposedUploadID: request.uploadID,
                ownerDeviceID: context.authenticatedDeviceID,
                originRecordingID: request.originRecordingID,
                frozenProfile: request.frozenProfile,
                existingAttempts: existing,
                at: acceptedAt
            )
            let grantExpiry = try self.currentGrantExpiry(
                in: db,
                deviceID: context.authenticatedDeviceID
            )

            switch decision {
            case .create:
                let attempt = try UploadAttempt(
                    uploadID: request.uploadID,
                    ownerDeviceID: context.authenticatedDeviceID,
                    originRecordingID: request.originRecordingID,
                    frozenProfile: request.frozenProfile,
                    beganAt: acceptedAt,
                    grantExpiresAt: grantExpiry
                )
                try self.insertUploadAttempt(attempt, in: db, at: acceptedAt)
                return .created(attempt)

            case .exactReplay(let uploadID):
                guard let attempt = existing.first(where: { $0.uploadID == uploadID }) else {
                    throw HarcHostError.uploadNotFound
                }
                return .replay(attempt)

            case .reopenRequired(let uploadID):
                guard var attempt = existing.first(where: { $0.uploadID == uploadID }) else {
                    throw HarcHostError.uploadNotFound
                }
                try attempt.reopen(at: acceptedAt, grantExpiresAt: grantExpiry)
                try self.updateUploadAttempt(attempt, in: db, at: acceptedAt)
                try self.persistGeneration(attempt, in: db)
                try db.execute(
                    sql: """
                        UPDATE background_capabilities
                        SET state = 'stale-generation', invalidated_at = ?
                        WHERE upload_id = ? AND generation < ? AND invalidated_at IS NULL
                        """,
                    arguments: [
                        Self.unixTime(acceptedAt),
                        attempt.uploadID.description,
                        try Self.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration"),
                    ]
                )
                return .reopened(attempt)

            case .conflictBlocked(_, let reason):
                throw HarcHostError.uploadConflict(reason.rawValue)

            case .abandoned:
                throw HarcHostError.uploadConflict("The upload was explicitly abandoned.")

            case .alreadyCommitted(let receipt):
                return .committed(receipt)
            }
        }

        switch result {
        case .created(let attempt):
            return .created(try await reconciliation(for: attempt.uploadID, context: context, at: acceptedAt))
        case .replay(let attempt):
            return .exactReplay(try await reconciliation(for: attempt.uploadID, context: context, at: acceptedAt))
        case .reopened(let attempt):
            return .reopened(try await reconciliation(for: attempt.uploadID, context: context, at: acceptedAt))
        case .committed(let receipt):
            return .alreadyCommitted(receipt)
        }
    }

    @discardableResult
    public func declareChunks(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        descriptors: [LogicalChunkDescriptor]
    ) async throws -> ChunkDeclarationDisposition {
        try await declareChunks(
            context: context,
            uploadID: uploadID,
            generation: generation,
            descriptors: descriptors,
            at: now()
        )
    }

    /// Deterministic `@testable` seam. Production declaration authorization
    /// always derives its time from the store's injected clock.
    @discardableResult
    func declareChunks(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        descriptors: [LogicalChunkDescriptor],
        at date: Date
    ) async throws -> ChunkDeclarationDisposition {
        try await repairSecurityRegistryOnReopen()
        let declaredAt = date
        enum Result {
            case success(ChunkDeclarationDisposition)
            case conflict(TransferValidationError)
        }
        let result: Result = try await dbQueue.write { db in
            guard var attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: declaredAt
            )
            do {
                let disposition = try attempt.declare(
                    descriptors,
                    generation: generation,
                    at: declaredAt
                )
                try self.updateUploadAttempt(attempt, in: db, at: declaredAt)
                try self.persistDeclarations(attempt.declarations.descriptors, uploadID: uploadID, in: db, at: declaredAt)
                return .success(disposition)
            } catch let error as TransferValidationError {
                if attempt.status == .conflictBlocked {
                    try self.updateUploadAttempt(attempt, in: db, at: declaredAt)
                    try self.insertAuditEvent(
                        in: db,
                        occurredAt: declaredAt,
                        severity: .security,
                        category: "upload-declaration",
                        code: "immutable-descriptor-conflict",
                        deviceID: context.authenticatedDeviceID
                    )
                    try self.pruneAuditEvents(in: db, at: declaredAt)
                }
                return .conflict(error)
            }
        }
        switch result {
        case .success(let disposition): return disposition
        case .conflict(let error): throw error
        }
    }

    public func bindFinalManifestForPrecommit(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        evidence: ValidatedRecordingManifestEvidence
    ) async throws -> HostManifestPrecommitDisposition {
        try await bindFinalManifestForPrecommit(
            context: context,
            uploadID: uploadID,
            generation: generation,
            evidence: evidence,
            at: now()
        )
    }

    /// Deterministic `@testable` seam. Production precommit authorization
    /// always derives its time from the store's injected clock.
    func bindFinalManifestForPrecommit(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        evidence: ValidatedRecordingManifestEvidence,
        at date: Date
    ) async throws -> HostManifestPrecommitDisposition {
        try await repairSecurityRegistryOnReopen()
        let boundAt = date
        let exactManifest = evidence.exactManifestObject
        guard exactManifest.kind == .recordingManifestV1,
              evidence.hostTrust.libraryID == expectedMetadata.libraryID,
              evidence.hostTrust.hostAuthorityID == expectedMetadata.hostAuthorityID,
              evidence.uploadID == uploadID,
              evidence.producingDeviceID == context.authenticatedDeviceID else {
            throw HarcHostError.manifestEvidenceRequired
        }
        let result: ManifestBindingDatabaseResult = try await dbQueue.write { db in
            guard var attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: boundAt
            )
            guard evidence.originRecordingID == attempt.originRecordingID,
                  evidence.uploadProfileSHA256 == attempt.frozenProfile.profileSHA256,
                  evidence.finalizedCapture.capture.originRecordingID == attempt.originRecordingID,
                  let registeredKey = try Data.fetchOne(
                      db,
                      sql: "SELECT public_key_x963 FROM devices WHERE device_id = ?",
                      arguments: [attempt.ownerDeviceID.rawBytes]
                  ),
                  registeredKey == evidence.producingDevicePublicKey.rawBytes else {
                throw HarcHostError.manifestEvidenceRequired
            }
            do {
                let disposition = try attempt.bindFinalManifest(
                    using: evidence,
                    generation: generation,
                    at: boundAt
                )
                try self.updateUploadAttempt(attempt, in: db, at: boundAt)
                try db.execute(
                    sql: """
                        INSERT INTO bound_exact_objects (
                            object_sha256, upload_id, object_kind, exact_bytes, bound_at
                        ) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(upload_id, object_kind) DO NOTHING
                        """,
                    arguments: [
                        exactManifest.objectSHA256.rawBytes,
                        uploadID.description,
                        ExactObjectKind.recordingManifestV1.rawValue,
                        exactManifest.exactBytes,
                        Self.unixTime(boundAt),
                    ]
                )
                let durableIndexes = Set(try UInt32.fetchAll(
                    db,
                    sql: "SELECT chunk_index FROM staged_chunks WHERE upload_id = ? AND status = 'durable'",
                    arguments: [uploadID.description]
                ))
                let missing = attempt.declarations.descriptors
                    .map(\.chunkIndex)
                    .filter { !durableIndexes.contains($0) }
                return .success(disposition, missing)
            } catch let error as TransferValidationError {
                if attempt.status == .conflictBlocked {
                    try self.updateUploadAttempt(attempt, in: db, at: boundAt)
                    try self.insertAuditEvent(
                        in: db,
                        occurredAt: boundAt,
                        severity: .security,
                        category: "upload-manifest",
                        code: "bound-object-conflict",
                        deviceID: context.authenticatedDeviceID
                    )
                    try self.pruneAuditEvents(in: db, at: boundAt)
                }
                return .conflict(error)
            }
        }
        switch result {
        case .success(.bound, let missing): return .bound(missingChunkIndexes: missing)
        case .success(.exactReplay, let missing): return .exactReplay(missingChunkIndexes: missing)
        case .conflict(let error): throw error
        }
    }

    /// PR 3 intentionally stops here. Calling this makes the boundary explicit
    /// instead of manufacturing a receipt-shaped success.
    public nonisolated func commitUploadUnavailableUntilPR5() throws -> Never {
        throw HarcHostError.canonicalCommitUnavailableUntilPR5
    }

    public func abandonUpload(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID
    ) async throws {
        try await abandonUpload(context: context, uploadID: uploadID, at: now())
    }

    /// Deterministic `@testable` seam. Production abandonment authorization
    /// always derives its time from the store's injected clock.
    func abandonUpload(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        at date: Date
    ) async throws {
        try await repairSecurityRegistryOnReopen()
        let abandonedAt = date
        try await dbQueue.write { db in
            guard var attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: abandonedAt
            )
            try attempt.abandon(at: abandonedAt)
            try self.updateUploadAttempt(attempt, in: db, at: abandonedAt)
            try db.execute(
                sql: """
                    UPDATE upload_generations
                    SET terminal_reason = 'abandoned', terminal_at = ?
                    WHERE upload_id = ? AND generation = ?
                    """,
                arguments: [
                    Self.unixTime(abandonedAt),
                    uploadID.description,
                    try Self.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration"),
                ]
            )
            try db.execute(
                sql: """
                    UPDATE background_capabilities
                    SET state = 'abandoned', invalidated_at = ?
                    WHERE upload_id = ? AND invalidated_at IS NULL
                    """,
                arguments: [Self.unixTime(abandonedAt), uploadID.description]
            )
        }
    }

    public func reconciliation(
        for uploadID: UploadID,
        context: AuthenticatedDeviceContext
    ) async throws -> UploadReconciliation {
        try await reconciliation(for: uploadID, context: context, at: now())
    }

    /// Deterministic `@testable` seam. Production reconciliation authorization
    /// always derives its time from the store's injected clock.
    func reconciliation(
        for uploadID: UploadID,
        context: AuthenticatedDeviceContext,
        at date: Date
    ) async throws -> UploadReconciliation {
        try await repairSecurityRegistryOnReopen()
        let reconciledAt = date
        return try await dbQueue.read { db in
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: reconciledAt
            )
            return try self.makeReconciliation(for: attempt, in: db, at: reconciledAt)
        }
    }

    public func incompleteRemoteUploads() async throws -> [IncompleteRemoteUpload] {
        try await incompleteRemoteUploads(at: now())
    }

    /// Deterministic `@testable` seam. Production lease classification always
    /// derives its time from the store's injected clock.
    func incompleteRemoteUploads(at date: Date) async throws -> [IncompleteRemoteUpload] {
        let listedAt = date
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT attempt_json, journal_state, updated_at FROM uploads
                    WHERE attempt_status NOT IN ('abandoned', 'committed')
                    ORDER BY updated_at DESC, upload_id
                    """
            )
            return try rows.compactMap { row in
                let attempt = try Self.decode(UploadAttempt.self, from: row["attempt_json"] as Data)
                let durableCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM staged_chunks WHERE upload_id = ? AND status = 'durable'",
                    arguments: [attempt.uploadID.description]
                ) ?? 0
                let rejectedCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM staged_chunks WHERE upload_id = ? AND status = 'rejected'",
                    arguments: [attempt.uploadID.description]
                ) ?? 0
                let reason: IncompleteRemoteUploadReason
                if attempt.status == .conflictBlocked {
                    reason = .conflictBlocked
                } else if try attempt.leaseState(at: listedAt) == .expired {
                    reason = .expired
                } else if rejectedCount > 0 {
                    reason = .rejectedChunks
                } else if attempt.boundManifest != nil,
                          durableCount < attempt.declarations.descriptors.count {
                    reason = .manifestAwaitingChunks
                } else if (row["journal_state"] as String) == HostUploadJournalState.failedRecoverable.rawValue {
                    reason = .failedRecoverable
                } else {
                    reason = .awaitingChunks
                }
                return IncompleteRemoteUpload(
                    uploadID: attempt.uploadID,
                    ownerDeviceID: attempt.ownerDeviceID,
                    originRecordingID: attempt.originRecordingID,
                    generation: attempt.generation,
                    generationExpiresAt: attempt.generationExpiresAt,
                    declaredChunkCount: attempt.declarations.descriptors.count,
                    durableChunkCount: durableCount,
                    rejectedChunkCount: rejectedCount,
                    reason: reason,
                    updatedAt: Self.date(row["updated_at"] as Double)
                )
            }
        }
    }
}

// MARK: - Persistence helpers

extension HarcHostStore {
    /// Reopen refuses semantic drift between the authoritative attempt blob and
    /// the typed declaration/profile columns used for quota and staging checks.
    /// A restored or manually edited HostDB must not reinterpret bound bytes.
    func validateUploadPersistenceOnReopen() async throws {
        try await dbQueue.read { db in
            let uploadRows = try Row.fetchAll(db, sql: "SELECT * FROM uploads ORDER BY upload_id")
            for row in uploadRows {
                let attempt = try Self.decode(UploadAttempt.self, from: row["attempt_json"] as Data)
                let storedProfile = try Self.decode(FrozenUploadProfile.self, from: row["profile_json"] as Data)
                guard row["upload_id"] as String == attempt.uploadID.description,
                      row["owner_device_id"] as Data == attempt.ownerDeviceID.rawBytes,
                      row["origin_device_id"] as Data == attempt.originRecordingID.deviceID.rawBytes,
                      row["origin_recording_uuid"] as String == attempt.originRecordingID.recordingUUID.uuidString.lowercased(),
                      storedProfile == attempt.frozenProfile,
                      row["profile_sha256"] as Data == attempt.frozenProfile.profileSHA256.rawBytes,
                      row["attempt_status"] as String == attempt.status.rawValue,
                      row["current_generation"] as Int64 == (try Self.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration")),
                      row["generation_expires_at"] as Double == Self.unixTime(attempt.generationExpiresAt),
                      row["bound_manifest_object_sha256"] as Data? == attempt.boundManifest?.objectSHA256.rawBytes,
                      row["exact_manifest_bytes"] as Data? == attempt.boundManifest?.exactBytes else {
                    throw HarcHostError.databaseFailure("Upload typed columns conflict with the preserved attempt object.")
                }

                let declarationRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM chunk_declarations WHERE upload_id = ? ORDER BY chunk_index",
                    arguments: [attempt.uploadID.description]
                )
                guard declarationRows.count == attempt.declarations.descriptors.count else {
                    throw HarcHostError.databaseFailure("Upload declaration count conflicts with the preserved attempt object.")
                }
                for (declarationRow, expected) in zip(declarationRows, attempt.declarations.descriptors) {
                    let stored = try Self.decode(
                        LogicalChunkDescriptor.self,
                        from: declarationRow["descriptor_json"] as Data
                    )
                    guard stored == expected,
                          declarationRow["chunk_index"] as Int64 == Int64(expected.chunkIndex),
                          declarationRow["chunk_id"] as String == expected.chunkID.description,
                          declarationRow["canonical_start_frame"] as Int64 == (try Self.sqliteInteger(expected.canonicalStartFrame, field: "canonicalStartFrame")),
                          declarationRow["canonical_frame_count"] as Int64 == (try Self.sqliteInteger(expected.canonicalFrameCount, field: "canonicalFrameCount")),
                          declarationRow["canonical_end_frame_exclusive"] as Int64 == (try Self.sqliteInteger(expected.canonicalEndFrameExclusive, field: "canonicalEndFrameExclusive")),
                          declarationRow["encoded_byte_length"] as Int64 == (try Self.sqliteInteger(expected.encodedByteLength, field: "encodedByteLength")),
                          declarationRow["encoded_sha256"] as Data == expected.encodedSHA256.rawBytes,
                          declarationRow["canonical_decoded_byte_length"] as Int64 == (try Self.sqliteInteger(expected.canonicalDecodedByteLength, field: "canonicalDecodedByteLength")),
                          declarationRow["canonical_decoded_sha256"] as Data == expected.canonicalDecodedSHA256.rawBytes else {
                        throw HarcHostError.databaseFailure("Typed chunk declaration conflicts with its preserved descriptor.")
                    }
                }
            }
        }
    }

    nonisolated func fetchUploadAttempt(in db: Database, uploadID: UploadID) throws -> UploadAttempt? {
        guard let bytes = try Data.fetchOne(
            db,
            sql: "SELECT attempt_json FROM uploads WHERE upload_id = ?",
            arguments: [uploadID.description]
        ) else { return nil }
        return try Self.decode(UploadAttempt.self, from: bytes)
    }

    nonisolated func fetchUploadAttempts(in db: Database, ownerDeviceID: DeviceID) throws -> [UploadAttempt] {
        try Data.fetchAll(
            db,
            sql: "SELECT attempt_json FROM uploads WHERE owner_device_id = ? ORDER BY created_at, upload_id",
            arguments: [ownerDeviceID.rawBytes]
        ).map { try Self.decode(UploadAttempt.self, from: $0) }
    }

    nonisolated func currentGrantExpiry(in db: Database, deviceID: DeviceID) throws -> Date? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT grant_expires_at FROM devices WHERE device_id = ?",
            arguments: [deviceID.rawBytes]
        ) else { throw HarcHostError.unknownDevice }
        return (row["grant_expires_at"] as Double?).map(Self.date)
    }

    nonisolated func insertUploadAttempt(_ attempt: UploadAttempt, in db: Database, at date: Date) throws {
        let time = Self.unixTime(date)
        try db.execute(
            sql: """
                INSERT INTO uploads (
                    upload_id, owner_device_id, origin_device_id,
                    origin_recording_uuid, profile_json, profile_sha256,
                    attempt_json, attempt_status, journal_state,
                    current_generation, generation_expires_at, block_reason,
                    began_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                attempt.uploadID.description,
                attempt.ownerDeviceID.rawBytes,
                attempt.originRecordingID.deviceID.rawBytes,
                attempt.originRecordingID.recordingUUID.uuidString.lowercased(),
                try Self.encode(attempt.frozenProfile),
                attempt.frozenProfile.profileSHA256.rawBytes,
                try Self.encode(attempt),
                attempt.status.rawValue,
                HostUploadJournalState.receiving.rawValue,
                try Self.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration"),
                Self.unixTime(attempt.generationExpiresAt),
                attempt.blockReason?.rawValue,
                Self.unixTime(attempt.firstBeganAt),
                time,
                time,
            ]
        )
        try persistGeneration(attempt, in: db)
    }

    nonisolated func updateUploadAttempt(_ attempt: UploadAttempt, in db: Database, at date: Date) throws {
        let journalState: HostUploadJournalState
        switch attempt.status {
        case .active:
            journalState = attempt.boundManifest == nil ? .receiving : .manifestVerified
        case .conflictBlocked: journalState = .conflictBlocked
        case .abandoned: journalState = .abandoned
        case .committed: journalState = .receipted
        }
        try db.execute(
            sql: """
                UPDATE uploads SET
                    attempt_json = ?, attempt_status = ?, journal_state = ?,
                    current_generation = ?, generation_expires_at = ?,
                    block_reason = ?, bound_manifest_object_sha256 = ?,
                    exact_manifest_bytes = ?, terminal_reason = ?, terminal_at = ?,
                    updated_at = ?
                WHERE upload_id = ?
                """,
            arguments: [
                try Self.encode(attempt),
                attempt.status.rawValue,
                journalState.rawValue,
                try Self.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration"),
                Self.unixTime(attempt.generationExpiresAt),
                attempt.blockReason?.rawValue,
                attempt.boundManifest?.objectSHA256.rawBytes,
                attempt.boundManifest?.exactBytes,
                attempt.status == .abandoned ? UploadReconciliationTerminalReason.abandoned.rawValue : nil,
                attempt.terminalAt.map(Self.unixTime),
                Self.unixTime(date),
                attempt.uploadID.description,
            ]
        )
        guard db.changesCount == 1 else { throw HarcHostError.uploadNotFound }
    }

    nonisolated func persistGeneration(_ attempt: UploadAttempt, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO upload_generations (
                    upload_id, generation, began_at, expires_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(upload_id, generation) DO UPDATE SET
                    began_at = excluded.began_at,
                    expires_at = excluded.expires_at
                """,
            arguments: [
                attempt.uploadID.description,
                try Self.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration"),
                Self.unixTime(attempt.generationBeganAt),
                Self.unixTime(attempt.generationExpiresAt),
            ]
        )
    }

    nonisolated func persistDeclarations(
        _ descriptors: [LogicalChunkDescriptor],
        uploadID: UploadID,
        in db: Database,
        at date: Date
    ) throws {
        for descriptor in descriptors {
            try db.execute(
                sql: """
                    INSERT INTO chunk_declarations (
                        upload_id, chunk_index, chunk_id, origin_device_id,
                        origin_recording_uuid, canonical_start_frame,
                        canonical_frame_count, canonical_end_frame_exclusive,
                        canonical_sample_rate, canonical_channel_count,
                        canonical_pcm_encoding, codec, container,
                        codec_parameters_json, encoded_byte_length,
                        encoded_sha256, canonical_decoded_byte_length,
                        canonical_decoded_sha256, descriptor_json, declared_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(upload_id, chunk_index) DO NOTHING
                    """,
                arguments: [
                    uploadID.description,
                    Int64(descriptor.chunkIndex),
                    descriptor.chunkID.description,
                    descriptor.originRecordingID.deviceID.rawBytes,
                    descriptor.originRecordingID.recordingUUID.uuidString.lowercased(),
                    try Self.sqliteInteger(descriptor.canonicalStartFrame, field: "canonicalStartFrame"),
                    try Self.sqliteInteger(descriptor.canonicalFrameCount, field: "canonicalFrameCount"),
                    try Self.sqliteInteger(descriptor.canonicalEndFrameExclusive, field: "canonicalEndFrameExclusive"),
                    Int64(descriptor.canonicalFormat.sampleRateHz),
                    Int64(descriptor.canonicalFormat.channelCount),
                    descriptor.canonicalFormat.encoding.rawValue,
                    descriptor.encoding.codec.rawValue,
                    descriptor.encoding.container.rawValue,
                    try Self.encode(descriptor.encoding),
                    try Self.sqliteInteger(descriptor.encodedByteLength, field: "encodedByteLength"),
                    descriptor.encodedSHA256.rawBytes,
                    try Self.sqliteInteger(descriptor.canonicalDecodedByteLength, field: "canonicalDecodedByteLength"),
                    descriptor.canonicalDecodedSHA256.rawBytes,
                    try Self.encode(descriptor),
                    Self.unixTime(date),
                ]
            )
        }
    }

    nonisolated func makeReconciliation(
        for attempt: UploadAttempt,
        in db: Database,
        at date: Date
    ) throws -> UploadReconciliation {
        let stagedRows = try Row.fetchAll(
            db,
            sql: """
                SELECT chunk_index, chunk_id, expected_encoded_sha256,
                       status, rejected_reason
                FROM staged_chunks WHERE upload_id = ? ORDER BY chunk_index
                """,
            arguments: [attempt.uploadID.description]
        )
        var durable: [DurableChunkStatus] = []
        var rejected: [RejectedChunkStatus] = []
        for row in stagedRows {
            let index = UInt32(row["chunk_index"] as Int64)
            guard let chunkUUID = UUID(uuidString: row["chunk_id"] as String) else {
                throw HarcHostError.databaseFailure("Invalid staged chunk UUID.")
            }
            let chunkID = ChunkID(chunkUUID)
            switch row["status"] as String {
            case "durable":
                durable.append(
                    DurableChunkStatus(
                        chunkIndex: index,
                        chunkID: chunkID,
                        encodedSHA256: try EncodedChunkSHA256(row["expected_encoded_sha256"] as Data)
                    )
                )
            case "rejected":
                let reason = RejectedChunkReason(rawValue: row["rejected_reason"] as String? ?? "") ?? .missingBytes
                rejected.append(RejectedChunkStatus(chunkIndex: index, chunkID: chunkID, reason: reason))
            default:
                break
            }
        }

        let terminal: UploadReconciliationTerminalReason?
        switch attempt.status {
        case .abandoned: terminal = .abandoned
        case .conflictBlocked: terminal = .declarationConflict
        case .committed: terminal = .committed
        case .active:
            terminal = try attempt.leaseState(at: date) == .expired ? .expired : nil
        }
        return try UploadReconciliation(
            uploadID: attempt.uploadID,
            ownerDeviceID: attempt.ownerDeviceID,
            originRecordingID: attempt.originRecordingID,
            uploadProfileSHA256: attempt.frozenProfile.profileSHA256,
            generation: attempt.generation,
            generationExpiresAt: attempt.generationExpiresAt,
            declarations: attempt.declarations.descriptors,
            boundManifestObjectSHA256: attempt.boundManifest?.objectSHA256,
            durableChunks: durable,
            rejectedChunks: rejected,
            terminalReason: terminal,
            existingReceipt: attempt.exactReceipt
        )
    }

    public func schemaTableNames() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
    }
}
