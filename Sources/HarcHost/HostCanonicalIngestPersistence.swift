import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcStore
import HarcTransfer

enum HostPublicationSidecarKind: Sendable {
    case manifest
    case receipt
}

struct HostReceiptProcessingWork: Sendable {
    let uploadID: UploadID
    let state: HostUploadJournalState
    let canonicalRecordingID: CanonicalRecordingID
    let publicationRelativePath: String
    let temporaryName: String
    let exactReceipt: OpaqueExactObjectSlot
    let canonicalPCMHash: CanonicalPCMHash
    let canonicalPCMFrames: UInt64
    let canonicalArtifactIdentity: HostCanonicalArtifactIdentity
}

extension HarcHostStore {
    /// Atomically binds the exact descriptor-derived WAV identity to the first
    /// durable published-audio checkpoint. No later phase may infer identity
    /// from the mutable pathname.
    func persistPublishedCanonicalArtifact(
        uploadID: UploadID,
        identity: HostCanonicalArtifactIdentity,
        at date: Date
    ) async throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.databaseFailure(
                "artifact publication must be finite."
            )
        }
        let deviceNumber = Self.canonicalArtifactUInt64Bytes(identity.deviceNumber)
        let inodeNumber = Self.canonicalArtifactUInt64Bytes(identity.inodeNumber)
        let linkCount = Self.canonicalArtifactUInt64Bytes(identity.linkCount)
        let fileByteCount = Self.canonicalArtifactUInt64Bytes(identity.fileByteCount)
        let ownerUserID = Int64(identity.ownerUserID)
        let posixMode = Int64(identity.posixMode)
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ), let state = HostUploadJournalState(rawValue: row["state"] as String),
                  let expectedWAVByteCount: Int64 = row["canonical_wav_byte_length"],
                  try Self.unsigned(
                    expectedWAVByteCount,
                    field: "canonicalWAVByteLength"
                  ) == identity.fileByteCount
            else {
                throw HarcHostError.databaseFailure(
                    "Canonical artifact publication metadata is incomplete."
                )
            }

            if state == .audioRenamed {
                guard try Self.canonicalArtifactIdentity(from: row) == nil else {
                    throw HarcHostError.databaseFailure(
                        "Canonical artifact identity preceded its publication checkpoint."
                    )
                }
                let publishedAt = Self.unixTime(date)
                try db.execute(
                    sql: """
                        UPDATE publication_journal
                        SET state = 'audioPublished',
                            canonical_artifact_device_number = ?,
                            canonical_artifact_inode_number = ?,
                            canonical_artifact_owner_user_id = ?,
                            canonical_artifact_posix_mode = ?,
                            canonical_artifact_link_count = ?,
                            canonical_artifact_file_byte_count = ?,
                            canonical_artifact_change_time_seconds = ?,
                            canonical_artifact_change_time_nanoseconds = ?,
                            audio_directory_synchronized_at = ?,
                            resume_state = NULL, last_error_code = NULL,
                            updated_at = ?
                        WHERE upload_id = ? AND state = 'audioRenamed'
                        """,
                    arguments: [
                        deviceNumber,
                        inodeNumber,
                        ownerUserID,
                        posixMode,
                        linkCount,
                        fileByteCount,
                        identity.changeTimeSeconds,
                        identity.changeTimeNanoseconds,
                        publishedAt,
                        publishedAt,
                        uploadID.description,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw HarcHostError.databaseFailure(
                        "Canonical artifact publication transition was lost."
                    )
                }
            } else {
                guard state == .audioPublished,
                      try Self.canonicalArtifactIdentity(from: row) == identity
                else {
                    throw HarcHostError.publicationCheckpointConflict(
                        expected: [HostUploadJournalState.audioRenamed.rawValue],
                        actual: state.rawValue
                    )
                }
            }

            try db.execute(
                sql: """
                    UPDATE uploads
                    SET journal_state = 'audioPublished', updated_at = ?
                    WHERE upload_id = ?
                      AND journal_state IN ('audioRenamed', 'audioPublished')
                    """,
                arguments: [Self.unixTime(date), uploadID.description]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure(
                    "Upload artifact publication checkpoint was lost."
                )
            }
        }
    }

    func persistCanonicalCommitLinkage(
        uploadID: UploadID,
        canonicalRecordingID: CanonicalRecordingID,
        publicationRelativePath: String,
        artifactIdentity: HostCanonicalArtifactIdentity,
        result: HostCanonicalRecordingCommitResult,
        at date: Date
    ) async throws {
        guard result.canonicalID == canonicalRecordingID else {
            throw HarcHostError.databaseFailure("Canonical commit identity drift.")
        }
        let revision = try result.revision.signedInt64Value()
        let cursor = try result.changeCursor.signedInt64Value()
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ), let state = HostUploadJournalState(rawValue: row["state"] as String),
                  row["canonical_recording_id"] as String == canonicalRecordingID.description,
                  row["publication_relative_path"] as String == publicationRelativePath,
                  try Self.canonicalArtifactIdentity(from: row) == artifactIdentity
            else {
                throw HarcHostError.databaseFailure("Canonical publication linkage is missing or drifted.")
            }

            let storedRevision: Int64? = row["canonical_revision"]
            let storedCursor: Int64? = row["change_cursor"]
            let storedCommitTime: Double? = row["durable_commit_at"]
            if state == .audioPublished {
                guard storedRevision == nil, storedCursor == nil, storedCommitTime == nil else {
                    throw HarcHostError.databaseFailure("Canonical publication linkage is partial.")
                }
                try db.execute(
                    sql: """
                        UPDATE publication_journal
                        SET state = 'recordingCommitted', canonical_revision = ?,
                            change_cursor = ?, durable_commit_at = ?,
                            last_error_code = NULL, resume_state = NULL, updated_at = ?
                        WHERE upload_id = ? AND state = 'audioPublished'
                        """,
                    arguments: [
                        revision,
                        cursor,
                        Self.unixTime(result.durableCommitTime),
                        Self.unixTime(date),
                        uploadID.description,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw HarcHostError.databaseFailure("Canonical linkage transition was lost.")
                }
            } else {
                guard Self.isAtOrAfterCanonicalCommit(state),
                      storedRevision == revision,
                      storedCursor == cursor,
                      storedCommitTime == Self.unixTime(result.durableCommitTime)
                else {
                    throw HarcHostError.databaseFailure("Canonical commit replay conflicts with its journal.")
                }
            }

            try db.execute(
                sql: """
                    UPDATE uploads
                    SET canonical_recording_id = ?, publication_relative_path = ?,
                        publication_linked_at = COALESCE(publication_linked_at, ?),
                        journal_state = CASE
                            WHEN journal_state IN ('receipted', 'processing', 'complete')
                                THEN journal_state
                            ELSE 'recordingCommitted'
                        END,
                        updated_at = ?
                    WHERE upload_id = ?
                      AND (canonical_recording_id IS NULL OR canonical_recording_id = ?)
                      AND (publication_relative_path IS NULL OR publication_relative_path = ?)
                    """,
                arguments: [
                    canonicalRecordingID.description,
                    publicationRelativePath,
                    Self.unixTime(date),
                    Self.unixTime(date),
                    uploadID.description,
                    canonicalRecordingID.description,
                    publicationRelativePath,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure("Upload publication linkage conflicts.")
            }
        }
    }

    func persistPreparedPublicationReceipt(
        uploadID: UploadID,
        receiptID: UUID,
        exactReceipt: OpaqueExactObjectSlot,
        evidence: ValidatedRecordingReceiptEvidence,
        at date: Date
    ) async throws {
        guard exactReceipt.kind == .recordingReceiptV1,
              exactReceipt == evidence.exactReceiptObject,
              evidence.uploadID == uploadID,
              evidence.receiptID == receiptID,
              Data(SHA256.hash(data: exactReceipt.exactBytes))
                == exactReceipt.objectSHA256.rawBytes
        else {
            throw HarcHostError.databaseFailure("Issued receipt evidence is inconsistent.")
        }
        let revision = try evidence.canonicalRevision.signedInt64Value()
        let cursor = try evidence.changeCursor.signedInt64Value()
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ), let state = HostUploadJournalState(rawValue: row["state"] as String),
                  row["canonical_recording_id"] as String
                    == evidence.canonicalRecordingID.description,
                  row["canonical_revision"] as Int64? == revision,
                  row["change_cursor"] as Int64? == cursor,
                  row["durable_commit_at"] as Double?
                    == Self.unixTime(evidence.durableCommitTime)
            else {
                throw HarcHostError.databaseFailure("Receipt claims do not match canonical linkage.")
            }

            let storedBytes: Data? = row["exact_receipt_bytes"]
            let storedHash: Data? = row["receipt_object_sha256"]
            let storedReceiptID: String? = row["receipt_id"]
            if state == .recordingCommitted {
                guard storedBytes == nil, storedHash == nil, storedReceiptID == nil else {
                    throw HarcHostError.databaseFailure("Prepared receipt journal is partial.")
                }
                try db.execute(
                    sql: """
                        UPDATE publication_journal
                        SET state = 'receiptPrepared', receipt_id = ?,
                            exact_receipt_bytes = ?, receipt_object_sha256 = ?,
                            last_error_code = NULL, resume_state = NULL, updated_at = ?
                        WHERE upload_id = ? AND state = 'recordingCommitted'
                        """,
                    arguments: [
                        receiptID.uuidString.lowercased(),
                        exactReceipt.exactBytes,
                        exactReceipt.objectSHA256.rawBytes,
                        Self.unixTime(date),
                        uploadID.description,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw HarcHostError.databaseFailure("Prepared receipt transition was lost.")
                }
            } else {
                guard Self.isAtOrAfterReceiptPreparation(state),
                      storedBytes == exactReceipt.exactBytes,
                      storedHash == exactReceipt.objectSHA256.rawBytes,
                      storedReceiptID == receiptID.uuidString.lowercased()
                else {
                    throw HarcHostError.databaseFailure("Prepared receipt replay conflicts.")
                }
            }

            try db.execute(
                sql: """
                    INSERT INTO bound_exact_objects (
                        object_sha256, upload_id, object_kind, exact_bytes, bound_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(upload_id, object_kind) DO NOTHING
                    """,
                arguments: [
                    exactReceipt.objectSHA256.rawBytes,
                    uploadID.description,
                    ExactObjectKind.recordingReceiptV1.rawValue,
                    exactReceipt.exactBytes,
                    Self.unixTime(date),
                ]
            )
            guard let bound = try Row.fetchOne(
                db,
                sql: """
                    SELECT object_sha256, exact_bytes FROM bound_exact_objects
                    WHERE upload_id = ? AND object_kind = ?
                    """,
                arguments: [uploadID.description, ExactObjectKind.recordingReceiptV1.rawValue]
            ), bound["object_sha256"] as Data == exactReceipt.objectSHA256.rawBytes,
                  bound["exact_bytes"] as Data == exactReceipt.exactBytes
            else {
                throw HarcHostError.databaseFailure("Exact receipt registry conflicts.")
            }

            try db.execute(
                sql: """
                    UPDATE uploads
                    SET receipt_object_sha256 = ?, exact_receipt_bytes = ?,
                        journal_state = CASE
                            WHEN journal_state IN ('receipted', 'processing', 'complete')
                                THEN journal_state
                            ELSE 'receiptPrepared'
                        END,
                        updated_at = ?
                    WHERE upload_id = ?
                      AND (receipt_object_sha256 IS NULL OR receipt_object_sha256 = ?)
                      AND (exact_receipt_bytes IS NULL OR exact_receipt_bytes = ?)
                    """,
                arguments: [
                    exactReceipt.objectSHA256.rawBytes,
                    exactReceipt.exactBytes,
                    Self.unixTime(date),
                    uploadID.description,
                    exactReceipt.objectSHA256.rawBytes,
                    exactReceipt.exactBytes,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure("Upload receipt persistence conflicts.")
            }
        }
    }

    func markPublicationSidecarSynchronized(
        uploadID: UploadID,
        kind: HostPublicationSidecarKind,
        at date: Date
    ) async throws {
        let column: String
        switch kind {
        case .manifest: column = "manifest_sidecar_synchronized_at"
        case .receipt: column = "receipt_sidecar_synchronized_at"
        }
        try await dbQueue.write { db in
            guard let stateRaw = try String.fetchOne(
                db,
                sql: "SELECT state FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ), let state = HostUploadJournalState(rawValue: stateRaw),
                  Self.isAtOrAfterReceiptPreparation(state)
            else {
                throw HarcHostError.databaseFailure("A sidecar preceded durable receipt preparation.")
            }
            try db.execute(
                sql: "UPDATE publication_journal SET \(column) = COALESCE(\(column), ?), updated_at = ? WHERE upload_id = ?",
                arguments: [Self.unixTime(date), Self.unixTime(date), uploadID.description]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure("Sidecar checkpoint was lost.")
            }
        }
    }

    func finalizePreparedPublicationReceipt(
        uploadID: UploadID,
        evidence: ValidatedRecordingReceiptEvidence,
        at date: Date
    ) async throws {
        try await dbQueue.write { db in
            guard var attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID),
                  let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                    arguments: [uploadID.description]
                  ), let state = HostUploadJournalState(rawValue: row["state"] as String),
                  let acceptedGenerationValue: Int64 = row["accepted_upload_generation"],
                  let authorizationTime: Double = row["authorized_at"],
                  let manifestSidecarTime: Double = row["manifest_sidecar_synchronized_at"],
                  let receiptSidecarTime: Double = row["receipt_sidecar_synchronized_at"],
                  manifestSidecarTime.isFinite,
                  receiptSidecarTime.isFinite
            else {
                throw HarcHostError.databaseFailure("Prepared receipt is incomplete.")
            }
            let exactBytes: Data? = row["exact_receipt_bytes"]
            let exactHash: Data? = row["receipt_object_sha256"]
            guard exactBytes == evidence.exactReceiptObject.exactBytes,
                  exactHash == evidence.exactReceiptObject.objectSHA256.rawBytes,
                  row["receipt_id"] as String?
                    == evidence.receiptID.uuidString.lowercased(),
                  row["canonical_recording_id"] as String
                    == evidence.canonicalRecordingID.description
            else {
                throw HarcHostError.databaseFailure("Prepared receipt evidence drifted.")
            }

            if state == .receiptPrepared {
                let generation = try UploadGeneration(
                    Self.unsigned(acceptedGenerationValue, field: "acceptedUploadGeneration")
                )
                try attempt.markCommittedFromAcceptedPublication(
                    using: evidence,
                    generation: generation,
                    authorizationAcceptedAt: Self.date(authorizationTime),
                    committedAt: date
                )
                try self.updateUploadAttempt(attempt, in: db, at: date)
                try db.execute(
                    sql: """
                        UPDATE uploads
                        SET terminal_reason = 'committed', terminal_at = ?,
                            receipt_object_sha256 = ?, exact_receipt_bytes = ?,
                            journal_state = 'receipted', updated_at = ?
                        WHERE upload_id = ?
                        """,
                    arguments: [
                        Self.unixTime(date),
                        evidence.exactReceiptObject.objectSHA256.rawBytes,
                        evidence.exactReceiptObject.exactBytes,
                        Self.unixTime(date),
                        uploadID.description,
                    ]
                )
                try db.execute(
                    sql: """
                        UPDATE upload_generations
                        SET terminal_reason = 'committed', terminal_at = ?
                        WHERE upload_id = ? AND generation = ?
                        """,
                    arguments: [Self.unixTime(date), uploadID.description, acceptedGenerationValue]
                )
                try db.execute(
                    sql: """
                        UPDATE publication_journal
                        SET state = 'receipted', resume_state = NULL,
                            last_error_code = NULL, updated_at = ?
                        WHERE upload_id = ? AND state = 'receiptPrepared'
                        """,
                    arguments: [Self.unixTime(date), uploadID.description]
                )
                guard db.changesCount == 1 else {
                    throw HarcHostError.databaseFailure("Receipt finalization transition was lost.")
                }
            } else {
                guard state == .receipted || state == .processing || state == .complete,
                      attempt.status == .committed,
                      attempt.exactReceipt == evidence.exactReceiptObject
                else {
                    throw HarcHostError.databaseFailure("Receipt finalization replay conflicts.")
                }
            }
        }
    }

    func receiptProcessingWork(uploadID: UploadID) async throws -> HostReceiptProcessingWork? {
        try await dbQueue.read { db -> HostReceiptProcessingWork? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            ), let state = HostUploadJournalState(rawValue: row["state"] as String),
                  state == .receipted || state == .processing || state == .complete
            else { return nil }
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID),
                  attempt.status == .committed,
                  let exactReceipt = attempt.exactReceipt,
                  let canonicalRaw: String = row["canonical_recording_id"],
                  let canonicalUUID = UUID(uuidString: canonicalRaw),
                  let relativePath: String = row["publication_relative_path"],
                  let temporaryName: String = row["host_generated_temporary_name"],
                  let canonicalPCMHashBytes: Data = row["canonical_pcm_sha256"],
                  let canonicalPCMFramesValue: Int64 = row["canonical_frame_count"],
                  let artifactIdentity = try Self.canonicalArtifactIdentity(from: row),
                  row["exact_receipt_bytes"] as Data? == exactReceipt.exactBytes,
                  row["receipt_object_sha256"] as Data?
                    == exactReceipt.objectSHA256.rawBytes
            else {
                throw HarcHostError.databaseFailure("Receipted processing work is incomplete.")
            }
            let canonicalPCMFrames = try Self.unsigned(
                canonicalPCMFramesValue,
                field: "canonicalFrameCount"
            )
            let layout = try HostCanonicalWAVLayout(totalFrames: canonicalPCMFrames)
            guard artifactIdentity.fileByteCount == layout.fileByteCount else {
                throw HarcHostError.databaseFailure(
                    "Processing artifact length drifted from its canonical frame count."
                )
            }
            return HostReceiptProcessingWork(
                uploadID: uploadID,
                state: state,
                canonicalRecordingID: CanonicalRecordingID(canonicalUUID),
                publicationRelativePath: relativePath,
                temporaryName: temporaryName,
                exactReceipt: exactReceipt,
                canonicalPCMHash: try CanonicalPCMHash(canonicalPCMHashBytes),
                canonicalPCMFrames: canonicalPCMFrames,
                canonicalArtifactIdentity: artifactIdentity
            )
        }
    }

    func receiptProcessingWork(
        originRecordingID: OriginRecordingID,
        expectedReceipt: OpaqueExactObjectSlot
    ) async throws -> HostReceiptProcessingWork? {
        let rawUploadIDs = try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT upload_id FROM uploads
                    WHERE origin_device_id = ?
                      AND origin_recording_uuid = ?
                      AND attempt_status = ?
                      AND exact_receipt_bytes = ?
                    ORDER BY upload_id
                    """,
                arguments: [
                    originRecordingID.deviceID.rawBytes,
                    originRecordingID.recordingUUID.uuidString.lowercased(),
                    UploadAttemptStatus.committed.rawValue,
                    expectedReceipt.exactBytes,
                ]
            )
        }
        guard rawUploadIDs.count == 1,
              let rawUploadID = rawUploadIDs.first,
              let uuid = UUID(uuidString: rawUploadID)
        else {
            if rawUploadIDs.isEmpty { return nil }
            throw HarcHostError.databaseFailure(
                "A committed origin has ambiguous receipt ownership."
            )
        }
        let work = try await receiptProcessingWork(uploadID: UploadID(uuid))
        guard work?.exactReceipt == expectedReceipt else {
            throw HarcHostError.databaseFailure(
                "The committed origin receipt drifted from its publication journal."
            )
        }
        return work
    }

    func markPublicationProcessingScheduled(uploadID: UploadID, at date: Date) async throws {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT p.state, u.attempt_status, p.exact_receipt_bytes,
                           u.exact_receipt_bytes AS upload_receipt_bytes
                    FROM publication_journal p
                    JOIN uploads u ON u.upload_id = p.upload_id
                    WHERE p.upload_id = ?
                    """,
                arguments: [uploadID.description]
            ), let state = HostUploadJournalState(rawValue: row["state"] as String),
                  row["attempt_status"] as String == UploadAttemptStatus.committed.rawValue,
                  let receipt: Data = row["exact_receipt_bytes"],
                  receipt == row["upload_receipt_bytes"] as Data?
            else {
                throw HarcHostError.databaseFailure("Processing cannot precede a durable receipt.")
            }
            if state == .processing || state == .complete { return }
            guard state == .receipted else {
                throw HarcHostError.databaseFailure("Processing schedule has an invalid predecessor.")
            }
            try db.execute(
                sql: """
                    UPDATE publication_journal
                    SET state = 'processing', processing_scheduled_at = ?, updated_at = ?
                    WHERE upload_id = ? AND state = 'receipted'
                    """,
                arguments: [Self.unixTime(date), Self.unixTime(date), uploadID.description]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure("Processing checkpoint was lost.")
            }
            try db.execute(
                sql: "UPDATE uploads SET journal_state = 'processing', updated_at = ? WHERE upload_id = ?",
                arguments: [Self.unixTime(date), uploadID.description]
            )
        }
    }
}

extension HarcHostStore {
    static func canonicalArtifactUInt64Bytes(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func canonicalArtifactUInt64(
        _ bytes: Data,
        field: String
    ) throws -> UInt64 {
        guard bytes.count == MemoryLayout<UInt64>.size else {
            throw HarcHostError.publicationRecoveryRequired(
                "invalid \(field) artifact identity field"
            )
        }
        return bytes.reduce(into: UInt64(0)) { value, byte in
            value = (value << 8) | UInt64(byte)
        }
    }

    static func canonicalArtifactIdentity(
        from row: Row
    ) throws -> HostCanonicalArtifactIdentity? {
        let deviceNumber: Data? = row["canonical_artifact_device_number"]
        let inodeNumber: Data? = row["canonical_artifact_inode_number"]
        let ownerUserID: Int64? = row["canonical_artifact_owner_user_id"]
        let posixMode: Int64? = row["canonical_artifact_posix_mode"]
        let linkCount: Data? = row["canonical_artifact_link_count"]
        let fileByteCount: Data? = row["canonical_artifact_file_byte_count"]
        let changeTimeSeconds: Int64? = row["canonical_artifact_change_time_seconds"]
        let changeTimeNanoseconds: Int64? = row[
            "canonical_artifact_change_time_nanoseconds"
        ]
        let presentCount = [
            deviceNumber != nil,
            inodeNumber != nil,
            ownerUserID != nil,
            posixMode != nil,
            linkCount != nil,
            fileByteCount != nil,
            changeTimeSeconds != nil,
            changeTimeNanoseconds != nil,
        ].filter { $0 }.count
        guard presentCount != 0 else { return nil }
        guard presentCount == 8,
              let deviceNumber,
              let inodeNumber,
              let ownerUserID,
              let owner = UInt32(exactly: ownerUserID),
              let posixMode,
              let mode = UInt32(exactly: posixMode),
              let linkCount,
              let fileByteCount,
              let changeTimeSeconds,
              let changeTimeNanoseconds
        else {
            throw HarcHostError.publicationRecoveryRequired(
                "partial canonical artifact identity"
            )
        }
        do {
            return try HostCanonicalArtifactIdentity(
                deviceNumber: canonicalArtifactUInt64(
                    deviceNumber,
                    field: "deviceNumber"
                ),
                inodeNumber: canonicalArtifactUInt64(
                    inodeNumber,
                    field: "inodeNumber"
                ),
                ownerUserID: owner,
                posixMode: mode,
                linkCount: canonicalArtifactUInt64(
                    linkCount,
                    field: "linkCount"
                ),
                fileByteCount: canonicalArtifactUInt64(
                    fileByteCount,
                    field: "fileByteCount"
                ),
                changeTimeSeconds: changeTimeSeconds,
                changeTimeNanoseconds: changeTimeNanoseconds
            )
        } catch {
            throw HarcHostError.publicationRecoveryRequired(
                "invalid canonical artifact identity"
            )
        }
    }

    static func isAtOrAfterCanonicalCommit(_ state: HostUploadJournalState) -> Bool {
        switch state {
        case .recordingCommitted, .receiptPrepared, .receipted, .processing, .complete:
            true
        default:
            false
        }
    }

    static func isAtOrAfterReceiptPreparation(_ state: HostUploadJournalState) -> Bool {
        switch state {
        case .receiptPrepared, .receipted, .processing, .complete:
            true
        default:
            false
        }
    }
}
