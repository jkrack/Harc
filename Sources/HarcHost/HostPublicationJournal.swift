import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcStore
import HarcTransfer

private struct StoredPublicationPlan: Sendable {
    let attempt: UploadAttempt
    let capture: ChunkedFinalizedCapture
    let checkpoint: HostUploadJournalState
    let canonicalRecordingID: CanonicalRecordingID
    let publicationRelativePath: String
    let temporaryName: String
    let staged: [(LogicalChunkDescriptor, String)]
    let authorizedDeviceID: DeviceID
    let authorizedGrantID: GrantID
    let authorizedGrantEpoch: GrantEpoch
    let acceptedUploadGeneration: UploadGeneration
    let authorizationAcceptedAt: Date
    let exactPersistedReceipt: OpaqueExactObjectSlot?
    let receiptID: UUID?
    let canonicalRevision: EntityRevision?
    let changeCursor: ChangeCursor?
    let durableCommitTime: Date?
    let canonicalArtifactIdentity: HostCanonicalArtifactIdentity?
}

private enum StoredPublicationPreparation: Sendable {
    case work(StoredPublicationPlan)
    case alreadyReceipted(OpaqueExactObjectSlot)
}

private struct StoredManifestValidationInputs: Sendable {
    let attempt: UploadAttempt
    let hostTrust: RecordingHostTrustBinding
    let exactManifest: OpaqueExactObjectSlot
    let producingDevicePublicKey: P256X963PublicKey
}

extension HarcHostStore {
    func prepareCanonicalPublication(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> HostCanonicalPublicationPreparation {
        try await repairSecurityRegistryOnReopen()
        let acceptedAt = now()
        try Self.requireFinitePublicationDate(acceptedAt, field: "authorization acceptance")
        let stored: StoredPublicationPreparation = try await dbQueue.write { db in
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            try self.requireUploadProfile(
                expectedUploadProfileSHA256,
                for: attempt
            )
            let authorized = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: acceptedAt
            )
            if attempt.status == .committed {
                guard let receipt = attempt.exactReceipt else {
                    throw HarcHostError.databaseFailure(
                        "A committed upload is missing its exact receipt."
                    )
                }
                return .alreadyReceipted(receipt)
            }
            do {
                try attempt.requireActive(generation: generation, at: acceptedAt)
            } catch TransferValidationError.staleUploadGeneration(let expected, let actual) {
                throw HarcHostError.staleUploadGeneration(expected: expected, actual: actual)
            }
            let plan = try self.loadOrCreatePublicationPlan(
                in: db,
                attempt: attempt,
                acceptedContext: authorized,
                acceptedGeneration: generation,
                acceptedAt: acceptedAt
            )
            return .work(plan)
        }
        switch stored {
        case .work(let plan): return .work(try materializePublicationWork(plan))
        case .alreadyReceipted(let receipt): return .alreadyReceipted(receipt)
        }
    }

    /// Recovery uses the immutable authorization snapshot recorded before any
    /// filesystem side effect. A vanished client session or later grant expiry
    /// cannot strand already accepted audio between rename and receipt.
    func canonicalPublicationForRecovery(
        uploadID: UploadID
    ) async throws -> HostCanonicalPublicationPreparation {
        try await repairSecurityRegistryOnReopen()
        let stored: StoredPublicationPreparation = try await dbQueue.write { db in
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            if attempt.status == .committed {
                guard let receipt = attempt.exactReceipt else {
                    throw HarcHostError.databaseFailure(
                        "A committed upload is missing its exact receipt."
                    )
                }
                return .alreadyReceipted(receipt)
            }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ) else { throw HarcHostError.publicationRecoveryRequired("missing publication plan") }
            try Self.requireRecoverablePublicationRow(row)
            let plan = try self.decodePublicationPlan(row, attempt: attempt, in: db)
            return .work(try self.restoreRecoverableCheckpoint(plan, in: db))
        }
        switch stored {
        case .work(let plan): return .work(try materializePublicationWork(plan))
        case .alreadyReceipted(let receipt): return .alreadyReceipted(receipt)
        }
    }

    /// Re-authenticate the exact device-signed manifest from durable bytes.
    /// Recovery never trusts the decoded `UploadAttempt` alone and never needs
    /// a live client session: the registered device key and host trust tuple
    /// are read from the durable host database, then interpreted by the
    /// injected HarcTransfer validation boundary.
    func validateBoundManifest(
        uploadID: UploadID,
        using validator: any RecordingManifestEvidenceValidating
    ) async throws -> ValidatedRecordingManifestEvidence {
        try await repairSecurityRegistryOnReopen()
        let inputs: StoredManifestValidationInputs = try await dbQueue.read { db in
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            guard let boundManifest = attempt.boundManifest,
                  let hostTrust = attempt.boundHostTrust,
                  boundManifest.kind == .recordingManifestV1,
                  hostTrust.libraryID == self.expectedMetadata.libraryID,
                  hostTrust.hostAuthorityID == self.expectedMetadata.hostAuthorityID,
                  let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT object_sha256, object_kind, exact_bytes
                        FROM bound_exact_objects
                        WHERE upload_id = ? AND object_kind = ?
                        """,
                    arguments: [
                        uploadID.description,
                        ExactObjectKind.recordingManifestV1.rawValue,
                    ]
                  ),
                  let storedHash = row["object_sha256"] as Data?,
                  let storedKind = row["object_kind"] as String?,
                  let exactBytes = row["exact_bytes"] as Data?,
                  storedKind == ExactObjectKind.recordingManifestV1.rawValue,
                  storedHash == boundManifest.objectSHA256.rawBytes,
                  exactBytes == boundManifest.exactBytes,
                  Data(SHA256.hash(data: exactBytes)) == storedHash,
                  let publicKeyBytes = try Data.fetchOne(
                    db,
                    sql: "SELECT public_key_x963 FROM devices WHERE device_id = ?",
                    arguments: [attempt.ownerDeviceID.rawBytes]
                  )
            else {
                throw HarcHostError.publicationRecoveryRequired(
                    "bound manifest bytes or producing-device key are missing"
                )
            }
            let publicKey = try P256X963PublicKey(publicKeyBytes)
            guard publicKey.deviceID == attempt.ownerDeviceID else {
                throw HarcHostError.publicationRecoveryRequired(
                    "producing-device key no longer matches the upload owner"
                )
            }
            return StoredManifestValidationInputs(
                attempt: attempt,
                hostTrust: hostTrust,
                exactManifest: boundManifest,
                producingDevicePublicKey: publicKey
            )
        }

        let evidence = try validator.validateRecordingManifest(
            exactSignedManifestBytes: inputs.exactManifest.exactBytes,
            hostTrust: inputs.hostTrust,
            producingDevicePublicKey: inputs.producingDevicePublicKey
        )
        guard evidence.hostTrust == inputs.hostTrust,
              evidence.exactManifestObject == inputs.exactManifest,
              evidence.uploadID == inputs.attempt.uploadID,
              evidence.producingDeviceID == inputs.attempt.ownerDeviceID,
              evidence.originRecordingID == inputs.attempt.originRecordingID,
              evidence.uploadProfileSHA256 == inputs.attempt.frozenProfile.profileSHA256,
              evidence.finalizedCapture == inputs.attempt.boundFinalizedCapture
        else {
            throw HarcHostError.manifestEvidenceRequired
        }
        return evidence
    }

    func recoverableCanonicalPublicationIDs() async throws -> [UploadID] {
        try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT upload_id FROM publication_journal
                    WHERE state != 'complete' AND legacy_quarantined = 0
                    ORDER BY created_at, upload_id
                    """
            ).map { raw in
                guard let uuid = UUID(uuidString: raw) else {
                    throw HarcHostError.databaseFailure("Publication journal has an invalid upload ID.")
                }
                return UploadID(uuid)
            }
        }
    }

    func markPublicationCheckpoint(
        uploadID: UploadID,
        expected: Set<HostUploadJournalState>,
        next: HostUploadJournalState,
        at date: Date
    ) async throws {
        try Self.requireFinitePublicationDate(date, field: "publication checkpoint")
        guard !expected.isEmpty else {
            throw HarcHostError.databaseFailure("A publication checkpoint needs a predecessor.")
        }
        guard expected.contains(next) || Self.isForwardPublicationCheckpoint(from: expected, to: next) else {
            throw HarcHostError.databaseFailure("Invalid publication checkpoint request.")
        }
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, legacy_quarantined FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ) else { throw HarcHostError.publicationRecoveryRequired("missing publication checkpoint") }
            try Self.requireRecoverablePublicationRow(row)
            guard let rawState = row["state"] as String?,
                  let current = HostUploadJournalState(rawValue: rawState)
            else { throw HarcHostError.publicationRecoveryRequired("missing publication checkpoint") }
            if current == next { return }
            guard expected.contains(current) else {
                throw HarcHostError.publicationCheckpointConflict(
                    expected: expected.map(\.rawValue).sorted(),
                    actual: current.rawValue
                )
            }

            var assignments = "state = ?, resume_state = NULL, last_error_code = NULL, updated_at = ?"
            switch next {
            case .temporarySynchronized:
                assignments += ", temporary_synchronized_at = ?"
            case .audioRenamed:
                assignments += ", audio_renamed_at = ?"
            case .audioPublished:
                assignments += ", audio_directory_synchronized_at = ?"
            default:
                break
            }
            let checkpointTime = Self.unixTime(date)
            if next == .temporarySynchronized || next == .audioRenamed || next == .audioPublished {
                try db.execute(
                    sql: "UPDATE publication_journal SET \(assignments) WHERE upload_id = ?",
                    arguments: [next.rawValue, checkpointTime, checkpointTime, uploadID.description]
                )
            } else {
                try db.execute(
                    sql: "UPDATE publication_journal SET \(assignments) WHERE upload_id = ?",
                    arguments: [next.rawValue, checkpointTime, uploadID.description]
                )
            }
            guard db.changesCount == 1 else {
                throw HarcHostError.publicationRecoveryRequired("checkpoint update was lost")
            }
            try db.execute(
                sql: "UPDATE uploads SET journal_state = ?, updated_at = ? WHERE upload_id = ?",
                arguments: [next.rawValue, checkpointTime, uploadID.description]
            )
            guard db.changesCount == 1 else { throw HarcHostError.uploadNotFound }
        }
    }

    func markPublicationFailedRecoverable(
        uploadID: UploadID,
        errorCode: String,
        at date: Date
    ) async throws {
        try Self.requireFinitePublicationDate(date, field: "recoverable publication failure")
        let boundedCode = String(
            errorCode.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(128)
        )
        guard !boundedCode.isEmpty else {
            throw HarcHostError.databaseFailure("A recoverable publication failure needs an error code.")
        }
        let failedAt = Self.unixTime(date)
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, resume_state, legacy_quarantined FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ) else { throw HarcHostError.publicationRecoveryRequired("missing publication checkpoint") }
            try Self.requireRecoverablePublicationRow(row)
            guard let rawState = row["state"] as String?,
                  let current = HostUploadJournalState(rawValue: rawState)
            else { throw HarcHostError.publicationRecoveryRequired("missing publication checkpoint") }
            if current == .receipted || current == .processing || current == .complete { return }
            let resumeRaw = current == .failedRecoverable
                ? row["resume_state"] as String?
                : current.rawValue
            guard let resumeRaw,
                  let resume = HostUploadJournalState(rawValue: resumeRaw),
                  Self.isRecoverablePublicationCheckpoint(resume)
            else {
                throw HarcHostError.publicationRecoveryRequired("invalid recovery checkpoint")
            }
            try db.execute(
                sql: """
                    UPDATE publication_journal
                    SET state = 'failedRecoverable', resume_state = ?,
                        last_error_code = ?, retry_count = retry_count + 1,
                        updated_at = ?
                    WHERE upload_id = ?
                    """,
                arguments: [resume.rawValue, boundedCode, failedAt, uploadID.description]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.publicationRecoveryRequired("recoverable failure update was lost")
            }
            try db.execute(
                sql: "UPDATE uploads SET journal_state = 'failedRecoverable', updated_at = ? WHERE upload_id = ?",
                arguments: [failedAt, uploadID.description]
            )
            guard db.changesCount == 1 else { throw HarcHostError.uploadNotFound }
        }
    }
}

private extension HarcHostStore {
    nonisolated func loadOrCreatePublicationPlan(
        in db: Database,
        attempt: UploadAttempt,
        acceptedContext: AuthorizedDeviceContext,
        acceptedGeneration: UploadGeneration,
        acceptedAt: Date
    ) throws -> StoredPublicationPlan {
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
            arguments: [attempt.uploadID.description]
        ) {
            try Self.requireRecoverablePublicationRow(row)
            let plan = try decodePublicationPlan(row, attempt: attempt, in: db)
            guard plan.acceptedUploadGeneration == acceptedGeneration,
                  plan.authorizedDeviceID == acceptedContext.authenticatedDeviceID
            else {
                throw HarcHostError.publicationCheckpointConflict(
                    expected: [String(acceptedGeneration.rawValue)],
                    actual: String(plan.acceptedUploadGeneration.rawValue)
                )
            }
            return try restoreRecoverableCheckpoint(plan, in: db)
        }

        guard let capture = attempt.boundFinalizedCapture,
              let manifest = attempt.boundManifest,
              let trust = attempt.boundHostTrust,
              acceptedContext.authenticatedDeviceID == attempt.ownerDeviceID,
              trust.libraryID == expectedMetadata.libraryID,
              trust.hostAuthorityID == expectedMetadata.hostAuthorityID
        else { throw HarcHostError.manifestEvidenceRequired }
        try Self.requireFinitePublicationDate(acceptedAt, field: "authorization acceptance")
        try validateAuthorizationSnapshot(
            in: db,
            attempt: attempt,
            authorizedDeviceID: acceptedContext.authenticatedDeviceID,
            authorizedGrantID: acceptedContext.grantID,
            authorizedGrantEpoch: acceptedContext.grantEpoch,
            acceptedGeneration: acceptedGeneration,
            acceptedAt: acceptedAt
        )
        try capture.validate(against: attempt.frozenProfile)
        let staged = try durableStagedRows(for: attempt, in: db)
        let canonicalRecordingID = CanonicalRecordingID.random()
        let relativePath = try HostCanonicalPublicationPaths.relativeWAVPath(
            captureStartedAt: capture.capture.captureStartedAt,
            canonicalRecordingID: canonicalRecordingID
        )
        let temporaryName = ".harc-\(UUID().uuidString.lowercased()).partial"
        let layout = try HostCanonicalWAVLayout(totalFrames: capture.capture.totalCanonicalFrames)
        let journalArguments: StatementArguments = [
            attempt.uploadID.description,
            temporaryName,
            canonicalRecordingID.description,
            capture.capture.canonicalPCMSHA256.rawBytes,
            try Self.sqliteInteger(capture.capture.totalCanonicalFrames, field: "canonicalFrameCount"),
            Self.unixTime(acceptedAt),
            relativePath,
            acceptedContext.authenticatedDeviceID.rawBytes,
            acceptedContext.grantID.description,
            try Self.sqliteInteger(acceptedContext.grantEpoch.rawValue, field: "grantEpoch"),
            try Self.sqliteInteger(acceptedGeneration.rawValue, field: "uploadGeneration"),
            Self.unixTime(acceptedAt),
            manifest.objectSHA256.rawBytes,
            try Self.sqliteInteger(layout.fileByteCount, field: "canonicalWAVByteLength"),
            Self.unixTime(acceptedAt),
        ]
        try db.execute(
            sql: """
                INSERT INTO publication_journal (
                    upload_id, state, host_generated_temporary_name,
                    canonical_recording_id, canonical_pcm_sha256,
                    canonical_frame_count, updated_at,
                    publication_relative_path, resume_state,
                    authorized_device_id, authorized_grant_id,
                    authorized_grant_epoch, accepted_upload_generation,
                    authorized_at, signed_manifest_object_sha256,
                    canonical_wav_byte_length, retry_count, created_at
                ) VALUES (?, 'assembling', ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                """,
            arguments: journalArguments
        )
        guard db.changesCount == 1 else {
            throw HarcHostError.databaseFailure("Canonical publication plan insertion was lost.")
        }
        try db.execute(
            sql: "UPDATE uploads SET journal_state = 'assembling', updated_at = ? WHERE upload_id = ?",
            arguments: [Self.unixTime(acceptedAt), attempt.uploadID.description]
        )
        guard db.changesCount == 1 else { throw HarcHostError.uploadNotFound }
        return StoredPublicationPlan(
            attempt: attempt,
            capture: capture,
            checkpoint: .assembling,
            canonicalRecordingID: canonicalRecordingID,
            publicationRelativePath: relativePath,
            temporaryName: temporaryName,
            staged: staged,
            authorizedDeviceID: acceptedContext.authenticatedDeviceID,
            authorizedGrantID: acceptedContext.grantID,
            authorizedGrantEpoch: acceptedContext.grantEpoch,
            acceptedUploadGeneration: acceptedGeneration,
            authorizationAcceptedAt: acceptedAt,
            exactPersistedReceipt: nil,
            receiptID: nil,
            canonicalRevision: nil,
            changeCursor: nil,
            durableCommitTime: nil,
            canonicalArtifactIdentity: nil
        )
    }

    nonisolated func decodePublicationPlan(
        _ row: Row,
        attempt: UploadAttempt,
        in db: Database
    ) throws -> StoredPublicationPlan {
        try Self.requireRecoverablePublicationRow(row)
        guard let capture = attempt.boundFinalizedCapture,
              let manifest = attempt.boundManifest,
              let trust = attempt.boundHostTrust,
              trust.libraryID == expectedMetadata.libraryID,
              trust.hostAuthorityID == expectedMetadata.hostAuthorityID,
              manifest.kind == .recordingManifestV1,
              Data(SHA256.hash(data: manifest.exactBytes)) == manifest.objectSHA256.rawBytes,
              let canonicalRaw = row["canonical_recording_id"] as String?,
              let canonicalUUID = UUID(uuidString: canonicalRaw),
              canonicalUUID != Self.zeroUUID,
              let temporaryName = row["host_generated_temporary_name"] as String?,
              Self.isSafePublicationTemporaryName(temporaryName),
              let relativePath = row["publication_relative_path"] as String?,
              let rawState = row["state"] as String?,
              let state = HostUploadJournalState(rawValue: rawState),
              let storedFrames = row["canonical_frame_count"] as Int64?,
              let storedManifestHash = row["signed_manifest_object_sha256"] as Data?,
              let storedAudioHash = row["canonical_pcm_sha256"] as Data?,
              let storedWAVLength = row["canonical_wav_byte_length"] as Int64?,
              let authorizedDeviceBytes = row["authorized_device_id"] as Data?,
              let authorizedGrantRaw = row["authorized_grant_id"] as String?,
              let authorizedGrantUUID = UUID(uuidString: authorizedGrantRaw),
              authorizedGrantUUID != Self.zeroUUID,
              let authorizedGrantEpochRaw = row["authorized_grant_epoch"] as Int64?,
              let acceptedGenerationRaw = row["accepted_upload_generation"] as Int64?,
              let authorizationTime = row["authorized_at"] as Double?
        else { throw HarcHostError.publicationRecoveryRequired("incomplete publication plan") }

        let canonicalID = CanonicalRecordingID(canonicalUUID)
        try HostCanonicalPublicationPaths.validatePersistedRelativeWAVPath(
            relativePath,
            canonicalRecordingID: canonicalID
        )
        let layout = try HostCanonicalWAVLayout(totalFrames: capture.capture.totalCanonicalFrames)
        guard storedManifestHash == manifest.objectSHA256.rawBytes,
              storedAudioHash == capture.capture.canonicalPCMSHA256.rawBytes,
              try Self.unsigned(storedFrames, field: "canonicalFrameCount")
                    == capture.capture.totalCanonicalFrames,
              try Self.unsigned(storedWAVLength, field: "canonicalWAVByteLength")
                    == layout.fileByteCount
        else { throw HarcHostError.publicationRecoveryRequired("publication plan drift") }

        let authorizedDeviceID: DeviceID
        let authorizedGrantEpoch: GrantEpoch
        let acceptedGeneration: UploadGeneration
        do {
            authorizedDeviceID = try DeviceID(authorizedDeviceBytes)
            authorizedGrantEpoch = try GrantEpoch(
                Self.unsigned(authorizedGrantEpochRaw, field: "authorizedGrantEpoch")
            )
            acceptedGeneration = try UploadGeneration(
                Self.unsigned(acceptedGenerationRaw, field: "acceptedUploadGeneration")
            )
        } catch {
            throw HarcHostError.publicationRecoveryRequired("invalid authorization snapshot")
        }
        let authorizedGrantID = GrantID(authorizedGrantUUID)
        let authorizationAcceptedAt = Self.date(authorizationTime)
        try Self.requireFinitePublicationDate(
            authorizationAcceptedAt,
            field: "stored authorization acceptance"
        )
        guard authorizedDeviceID == attempt.ownerDeviceID else {
            throw HarcHostError.publicationRecoveryRequired("publication owner drift")
        }
        try validateAuthorizationSnapshot(
            in: db,
            attempt: attempt,
            authorizedDeviceID: authorizedDeviceID,
            authorizedGrantID: authorizedGrantID,
            authorizedGrantEpoch: authorizedGrantEpoch,
            acceptedGeneration: acceptedGeneration,
            acceptedAt: authorizationAcceptedAt
        )

        let effectiveCheckpoint = try Self.effectivePublicationCheckpoint(from: row, state: state)
        let artifactIdentity = try Self.canonicalArtifactIdentity(from: row)

        let receiptBytes: Data? = row["exact_receipt_bytes"]
        let receiptHash: Data? = row["receipt_object_sha256"]
        let exactReceipt: OpaqueExactObjectSlot?
        switch (receiptBytes, receiptHash) {
        case (nil, nil): exactReceipt = nil
        case let (.some(bytes), .some(hash)):
            guard Data(SHA256.hash(data: bytes)) == hash else {
                throw HarcHostError.publicationRecoveryRequired("receipt digest drift")
            }
            exactReceipt = try OpaqueExactObjectSlot(
                kind: .recordingReceiptV1,
                exactBytes: bytes,
                objectSHA256: ExactObjectSHA256(hash)
            )
        default:
            throw HarcHostError.publicationRecoveryRequired("partial receipt journal")
        }

        let receiptID: UUID?
        if let raw: String = row["receipt_id"] {
            guard let value = UUID(uuidString: raw), value != Self.zeroUUID else {
                throw HarcHostError.publicationRecoveryRequired("invalid receipt ID")
            }
            receiptID = value
        } else { receiptID = nil }
        let revision = try (row["canonical_revision"] as Int64?).map {
            try EntityRevision(signedValue: $0)
        }
        let cursor = try (row["change_cursor"] as Int64?).map {
            try ChangeCursor(signedValue: $0)
        }
        let commitTime = try (row["durable_commit_at"] as Double?).map {
            try Self.canonicalCommitDate(unixSeconds: $0)
        }
        let expectedWAVByteCount = try Self.unsigned(
            storedWAVLength,
            field: "canonicalWAVByteLength"
        )
        guard (revision == nil) == (cursor == nil),
              (revision == nil) == (commitTime == nil),
              (exactReceipt == nil) == (receiptID == nil),
              exactReceipt == nil || revision != nil,
              Self.publicationCheckpointRequiresCanonicalCommit(effectiveCheckpoint)
                    == (revision != nil),
              Self.publicationCheckpointRequiresReceipt(effectiveCheckpoint)
                    == (exactReceipt != nil),
              Self.publicationCheckpointRequiresArtifactIdentity(effectiveCheckpoint)
                    == (artifactIdentity != nil),
              artifactIdentity == nil
                    || artifactIdentity?.fileByteCount
                        == expectedWAVByteCount
        else { throw HarcHostError.publicationRecoveryRequired("partial canonical commit journal") }

        let staged: [(LogicalChunkDescriptor, String)]
        if effectiveCheckpoint == .assembling {
            staged = try durableStagedRows(for: attempt, in: db)
        } else {
            staged = []
        }

        return StoredPublicationPlan(
            attempt: attempt,
            capture: capture,
            checkpoint: state,
            canonicalRecordingID: canonicalID,
            publicationRelativePath: relativePath,
            temporaryName: temporaryName,
            staged: staged,
            authorizedDeviceID: authorizedDeviceID,
            authorizedGrantID: authorizedGrantID,
            authorizedGrantEpoch: authorizedGrantEpoch,
            acceptedUploadGeneration: acceptedGeneration,
            authorizationAcceptedAt: authorizationAcceptedAt,
            exactPersistedReceipt: exactReceipt,
            receiptID: receiptID,
            canonicalRevision: revision,
            changeCursor: cursor,
            durableCommitTime: commitTime,
            canonicalArtifactIdentity: artifactIdentity
        )
    }

    nonisolated func restoreRecoverableCheckpoint(
        _ plan: StoredPublicationPlan,
        in db: Database
    ) throws -> StoredPublicationPlan {
        guard plan.checkpoint == .failedRecoverable else { return plan }
        guard let rawResume = try String.fetchOne(
            db,
            sql: "SELECT resume_state FROM publication_journal WHERE upload_id = ?",
            arguments: [plan.attempt.uploadID.description]
        ), let resume = HostUploadJournalState(rawValue: rawResume),
              Self.isRecoverablePublicationCheckpoint(resume)
        else { throw HarcHostError.publicationRecoveryRequired("invalid recovery checkpoint") }
        let restoredAt = now()
        try Self.requireFinitePublicationDate(restoredAt, field: "publication recovery")
        try db.execute(
            sql: """
                UPDATE publication_journal
                SET state = ?, resume_state = NULL, last_error_code = NULL, updated_at = ?
                WHERE upload_id = ? AND state = 'failedRecoverable'
                """,
            arguments: [resume.rawValue, Self.unixTime(restoredAt), plan.attempt.uploadID.description]
        )
        guard db.changesCount == 1 else {
            throw HarcHostError.publicationRecoveryRequired("recovery checkpoint update was lost")
        }
        try db.execute(
            sql: "UPDATE uploads SET journal_state = ?, updated_at = ? WHERE upload_id = ?",
            arguments: [
                resume.rawValue,
                Self.unixTime(restoredAt),
                plan.attempt.uploadID.description,
            ]
        )
        guard db.changesCount == 1 else { throw HarcHostError.uploadNotFound }
        return StoredPublicationPlan(
            attempt: plan.attempt,
            capture: plan.capture,
            checkpoint: resume,
            canonicalRecordingID: plan.canonicalRecordingID,
            publicationRelativePath: plan.publicationRelativePath,
            temporaryName: plan.temporaryName,
            staged: plan.staged,
            authorizedDeviceID: plan.authorizedDeviceID,
            authorizedGrantID: plan.authorizedGrantID,
            authorizedGrantEpoch: plan.authorizedGrantEpoch,
            acceptedUploadGeneration: plan.acceptedUploadGeneration,
            authorizationAcceptedAt: plan.authorizationAcceptedAt,
            exactPersistedReceipt: plan.exactPersistedReceipt,
            receiptID: plan.receiptID,
            canonicalRevision: plan.canonicalRevision,
            changeCursor: plan.changeCursor,
            durableCommitTime: plan.durableCommitTime,
            canonicalArtifactIdentity: plan.canonicalArtifactIdentity
        )
    }

    nonisolated func durableStagedRows(
        for attempt: UploadAttempt,
        in db: Database
    ) throws -> [(LogicalChunkDescriptor, String)] {
        guard attempt.declarations.status == .closed,
              attempt.boundManifest != nil,
              attempt.boundFinalizedCapture != nil
        else { throw HarcHostError.manifestEvidenceRequired }
        var result: [(LogicalChunkDescriptor, String)] = []
        result.reserveCapacity(attempt.declarations.descriptors.count)
        for descriptor in attempt.declarations.descriptors {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM staged_chunks WHERE upload_id = ? AND chunk_index = ?",
                arguments: [attempt.uploadID.description, Int64(descriptor.chunkIndex)]
            ), row["status"] as String == "durable",
               row["object_deleted_at"] as Double? == nil,
               row["chunk_id"] as String == descriptor.chunkID.description,
               row["expected_encoded_length"] as Int64
                    == (try Self.sqliteInteger(descriptor.encodedByteLength, field: "encodedLength")),
               row["persisted_encoded_length"] as Int64?
                    == (try Self.sqliteInteger(descriptor.encodedByteLength, field: "persistedLength")),
               row["expected_encoded_sha256"] as Data == descriptor.encodedSHA256.rawBytes,
               row["persisted_encoded_sha256"] as Data? == descriptor.encodedSHA256.rawBytes,
               let relativePath: String = row["generated_relative_path"]
            else { throw HarcHostError.incompleteCanonicalUpload }
            result.append((descriptor, relativePath))
        }
        return result
    }

    nonisolated func materializePublicationWork(
        _ plan: StoredPublicationPlan
    ) throws -> HostCanonicalPublicationWork {
        HostCanonicalPublicationWork(
            attempt: plan.attempt,
            capture: plan.capture,
            checkpoint: plan.checkpoint,
            canonicalRecordingID: plan.canonicalRecordingID,
            publicationRelativePath: plan.publicationRelativePath,
            temporaryName: plan.temporaryName,
            stagedChunks: plan.staged.map { descriptor, relativePath in
                HostDurableStagedChunk(
                    descriptor: descriptor,
                    relativePath: relativePath
                )
            },
            authorizedDeviceID: plan.authorizedDeviceID,
            authorizedGrantID: plan.authorizedGrantID,
            authorizedGrantEpoch: plan.authorizedGrantEpoch,
            acceptedUploadGeneration: plan.acceptedUploadGeneration,
            authorizationAcceptedAt: plan.authorizationAcceptedAt,
            exactPersistedReceipt: plan.exactPersistedReceipt,
            receiptID: plan.receiptID,
            canonicalRevision: plan.canonicalRevision,
            changeCursor: plan.changeCursor,
            durableCommitTime: plan.durableCommitTime,
            canonicalArtifactIdentity: plan.canonicalArtifactIdentity
        )
    }

    nonisolated func validateAuthorizationSnapshot(
        in db: Database,
        attempt: UploadAttempt,
        authorizedDeviceID: DeviceID,
        authorizedGrantID: GrantID,
        authorizedGrantEpoch: GrantEpoch,
        acceptedGeneration: UploadGeneration,
        acceptedAt: Date
    ) throws {
        do {
            guard authorizedDeviceID == attempt.ownerDeviceID else {
                throw HarcHostError.publicationRecoveryRequired("publication owner drift")
            }
            try attempt.requireActive(generation: acceptedGeneration, at: acceptedAt)

            guard let generationRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT began_at, expires_at, terminal_at
                    FROM upload_generations
                    WHERE upload_id = ? AND generation = ?
                    """,
                arguments: [
                    attempt.uploadID.description,
                    try Self.sqliteInteger(acceptedGeneration.rawValue, field: "uploadGeneration"),
                ]
            ), let beganAt = generationRow["began_at"] as Double?,
                  let expiresAt = generationRow["expires_at"] as Double?,
                  beganAt.isFinite,
                  expiresAt.isFinite,
                  beganAt <= Self.unixTime(acceptedAt),
                  Self.unixTime(acceptedAt) < expiresAt
            else {
                throw HarcHostError.publicationRecoveryRequired(
                    "accepted upload generation is not durably attributable"
                )
            }
            if let terminalAt = generationRow["terminal_at"] as Double? {
                guard terminalAt.isFinite,
                      Self.unixTime(acceptedAt) <= terminalAt
                else {
                    throw HarcHostError.publicationRecoveryRequired(
                        "accepted upload generation terminated before authorization"
                    )
                }
            }

            guard let grantRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT device_id, claims_json, exact_grant_bytes,
                           issued_at, expires_at
                    FROM grants
                    WHERE grant_id = ? AND grant_epoch = ?
                    """,
                arguments: [
                    authorizedGrantID.description,
                    try Self.sqliteInteger(authorizedGrantEpoch.rawValue, field: "grantEpoch"),
                ]
            ), let grantDevice = grantRow["device_id"] as Data?,
                  let claimsBytes = grantRow["claims_json"] as Data?,
                  let exactGrantBytes = grantRow["exact_grant_bytes"] as Data?,
                  !exactGrantBytes.isEmpty,
                  let storedIssuedAt = grantRow["issued_at"] as Double?,
                  storedIssuedAt.isFinite
            else {
                throw HarcHostError.publicationRecoveryRequired(
                    "accepted grant is not durably attributable"
                )
            }
            let claims = try Self.decode(DeviceGrantClaims.self, from: claimsBytes)
            let storedExpiresAt = grantRow["expires_at"] as Double?
            guard grantDevice == authorizedDeviceID.rawBytes,
                  claims.libraryID == expectedMetadata.libraryID,
                  claims.hostAuthorityID == expectedMetadata.hostAuthorityID,
                  claims.deviceID == authorizedDeviceID,
                  claims.devicePublicKey.deviceID == authorizedDeviceID,
                  claims.grantID == authorizedGrantID,
                  claims.grantEpoch == authorizedGrantEpoch,
                  claims.scopes.contains(.recordingUploadOwn),
                  Self.samePublicationTimestamp(
                    storedIssuedAt,
                    Self.unixTime(claims.issuedAt)
                  ),
                  claims.issuedAt <= acceptedAt,
                  Self.optionalPublicationTimestamp(
                    storedExpiresAt,
                    equals: claims.expiresAt.map(Self.unixTime)
                  ),
                  claims.expiresAt.map { acceptedAt < $0 } ?? true
            else {
                throw HarcHostError.publicationRecoveryRequired(
                    "accepted grant snapshot drifted"
                )
            }
        } catch let error as HarcHostError {
            throw error
        } catch {
            throw HarcHostError.publicationRecoveryRequired(
                "invalid durable authorization snapshot"
            )
        }
    }

    static func requireRecoverablePublicationRow(_ row: Row) throws {
        guard let quarantineFlag = row["legacy_quarantined"] as Int64? else {
            throw HarcHostError.publicationRecoveryRequired("missing publication quarantine marker")
        }
        if quarantineFlag == 1 {
            throw HarcHostError.publicationRecoveryRequired(
                "legacy publication is quarantined"
            )
        }
        guard quarantineFlag == 0 else {
            throw HarcHostError.publicationRecoveryRequired("invalid publication quarantine marker")
        }
    }

    static func effectivePublicationCheckpoint(
        from row: Row,
        state: HostUploadJournalState
    ) throws -> HostUploadJournalState {
        guard state == .failedRecoverable else { return state }
        guard let rawResume = row["resume_state"] as String?,
              let resume = HostUploadJournalState(rawValue: rawResume),
              isRecoverablePublicationCheckpoint(resume)
        else {
            throw HarcHostError.publicationRecoveryRequired("invalid recovery checkpoint")
        }
        return resume
    }

    static func isRecoverablePublicationCheckpoint(_ state: HostUploadJournalState) -> Bool {
        switch state {
        case .assembling,
             .temporarySynchronized,
             .audioRenamed,
             .audioPublished,
             .recordingCommitted,
             .receiptPrepared:
            true
        default:
            false
        }
    }

    static func publicationCheckpointRequiresCanonicalCommit(
        _ state: HostUploadJournalState
    ) -> Bool {
        switch state {
        case .recordingCommitted, .receiptPrepared, .receipted, .processing, .complete:
            true
        default:
            false
        }
    }

    static func publicationCheckpointRequiresArtifactIdentity(
        _ state: HostUploadJournalState
    ) -> Bool {
        switch state {
        case .audioPublished,
             .recordingCommitted,
             .receiptPrepared,
             .receipted,
             .processing,
             .complete:
            true
        default:
            false
        }
    }

    static func publicationCheckpointRequiresReceipt(_ state: HostUploadJournalState) -> Bool {
        switch state {
        case .receiptPrepared, .receipted, .processing, .complete:
            true
        default:
            false
        }
    }

    static func requireFinitePublicationDate(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.databaseFailure("\(field) must be finite.")
        }
    }

    static func canonicalCommitDate(unixSeconds: Double) throws -> Date {
        guard unixSeconds.isFinite, unixSeconds > 0 else {
            throw HarcHostError.publicationRecoveryRequired("invalid canonical commit time")
        }
        let milliseconds = (unixSeconds * 1_000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= 1,
              milliseconds <= Double(Int64.max)
        else {
            throw HarcHostError.publicationRecoveryRequired("invalid canonical commit time")
        }
        let canonicalSeconds = Double(Int64(milliseconds)) / 1_000
        guard samePublicationTimestamp(unixSeconds, canonicalSeconds) else {
            throw HarcHostError.publicationRecoveryRequired(
                "canonical commit time is not millisecond-quantized"
            )
        }
        return Self.date(canonicalSeconds)
    }

    static func samePublicationTimestamp(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= 0.000_000_5
    }

    static func optionalPublicationTimestamp(_ lhs: Double?, equals rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (.some(lhs), .some(rhs)): samePublicationTimestamp(lhs, rhs)
        default: false
        }
    }

    static func isSafePublicationTemporaryName(_ value: String) -> Bool {
        guard value.hasPrefix(".harc-"),
              value.hasSuffix(".partial"),
              value.count <= 96
        else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7a)
                || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == 0x2d
                || $0 == 0x2e
        }
    }

    static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))

    static func isForwardPublicationCheckpoint(
        from expected: Set<HostUploadJournalState>,
        to next: HostUploadJournalState
    ) -> Bool {
        let order: [HostUploadJournalState] = [
            .assembling,
            .temporarySynchronized,
            .audioRenamed,
            .audioPublished,
            .recordingCommitted,
            .receiptPrepared,
            .receipted,
            .processing,
            .complete,
        ]
        guard let nextIndex = order.firstIndex(of: next) else { return false }
        return expected.contains { state in
            order.firstIndex(of: state).map { $0 + 1 == nextIndex } ?? false
        }
    }
}
