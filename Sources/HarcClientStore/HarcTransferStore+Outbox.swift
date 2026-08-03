import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcTransfer

public enum LocalTransferArtifactState: String, CaseIterable, Sendable {
    case present
    case missing
    case integrityMismatch
}

public enum LocalArtifactIntegrityBlockCode: String, CaseIterable, Sendable {
    case immutableChunkMissing
    case immutableChunkMismatch
    case immutableBatchMissing
    case immutableBatchMismatch
}

public struct LocalArtifactIntegrityBlock: Equatable, Sendable {
    public let code: LocalArtifactIntegrityBlockCode
    public let detail: String
}

public struct StoredFinalizedCapture: Equatable, Sendable {
    public let capture: FinalizedCapture
    public let masterFileURL: URL
    public let masterFileState: LocalTransferArtifactState
    public let persistedAt: Date
}

public struct StoredRecordingOutbox: Equatable, Sendable {
    public let finalizedCapture: StoredFinalizedCapture
    public let uploadID: UploadID?
    public let stateMachine: RecordingOutboxStateMachine
    public let integrityBlock: LocalArtifactIntegrityBlock?
    public let updatedAt: Date
}

public struct StoredUploadAttempt: Equatable, Sendable {
    public let trustTuple: AdoptedTrustTuple
    public let attempt: UploadAttempt
    public let updatedAt: Date
}

public struct StoredUploadChunk: Equatable, Sendable {
    public let uploadID: UploadID
    public let descriptor: LogicalChunkDescriptor
    public let encodedFileURL: URL
    public let fileState: LocalTransferArtifactState
    public let stateMachine: ChunkOutboxStateMachine
    public let durableACK: OpaqueExactObjectSlot?
    public let updatedAt: Date
}

public enum BackgroundBatchState: String, CaseIterable, Sendable {
    case readyToSchedule
    case scheduled
    case sending
    case completed
    case needsReschedule
    case failedRecoverable
    case expired
}

/// The exact secret and bindings returned by the future PR 4/6 protocol layer.
/// The transfer store preserves them together before a system task can resume.
public struct OpaqueBackgroundCapability: Equatable, Sendable {
    public let credential: Data
    public let capabilityBindings: Data
    public let expiresAt: Date

    public init(credential: Data, capabilityBindings: Data, expiresAt: Date) throws {
        guard !credential.isEmpty else {
            throw ClientStoreError.emptyOpaqueBytes(field: "backgroundCapabilityCredential")
        }
        guard !capabilityBindings.isEmpty else {
            throw ClientStoreError.emptyOpaqueBytes(field: "backgroundCapabilityBindings")
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ClientStoreError.corruptStoredValue(field: "backgroundCapabilityExpiry")
        }
        self.credential = credential
        self.capabilityBindings = capabilityBindings
        self.expiresAt = expiresAt
    }
}

public struct StoredBackgroundBatch: Equatable, Sendable {
    public let descriptor: ImmutableAudioBatchDescriptor
    public let bodyFileURL: URL
    public let bodyFileState: LocalTransferArtifactState
    public let capability: OpaqueBackgroundCapability
    public let state: BackgroundBatchState
    public let durableACK: OpaqueExactObjectSlot?
    public let updatedAt: Date
}

public struct SystemBackgroundTaskIdentity: Equatable, Hashable, Sendable {
    public static let stableSessionIdentifier = "com.harc.mobile.recording-upload"

    public let sessionIdentifier: String
    public let taskIdentifier: Int

    public init(
        sessionIdentifier: String = Self.stableSessionIdentifier,
        taskIdentifier: Int
    ) throws {
        guard sessionIdentifier == Self.stableSessionIdentifier,
              taskIdentifier >= 0 else {
            throw ClientStoreError.corruptStoredValue(field: "backgroundTaskIdentity")
        }
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
    }
}

public enum BackgroundTaskMappingState: String, CaseIterable, Sendable {
    case persistedBeforeResume
    case observedBySystem
    case missingFromSystem
    case completed
}

public struct StoredBackgroundTaskMapping: Equatable, Sendable {
    public let identity: SystemBackgroundTaskIdentity
    public let batchID: AudioBatchID
    public let state: BackgroundTaskMappingState
    public let updatedAt: Date
}

public struct BackgroundTaskReconciliation: Equatable, Sendable {
    public let batchesToReschedule: [AudioBatchID]
    public let orphanedSystemTasks: [SystemBackgroundTaskIdentity]
    public let matchedTasks: [SystemBackgroundTaskIdentity]
}

public protocol LocalTransferArtifactInspecting: Sendable {
    func fileExists(at url: URL) -> Bool
    func exactFileMatches(
        at url: URL,
        expectedByteCount: UInt64,
        expectedSHA256: Data
    ) -> Bool
}

public extension LocalTransferArtifactInspecting {
    /// Unknown equality fails closed. Test and platform adapters that can
    /// establish exact bytes override this method.
    func exactFileMatches(
        at _: URL,
        expectedByteCount _: UInt64,
        expectedSHA256 _: Data
    ) -> Bool { false }
}

public struct FoundationLocalTransferArtifactInspector: LocalTransferArtifactInspecting {
    public init() {}
    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func exactFileMatches(
        at url: URL,
        expectedByteCount: UInt64,
        expectedSHA256: Data
    ) -> Bool {
        guard expectedSHA256.count == SHA256.Digest.byteCount,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value == expectedByteCount,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                hasher.update(data: bytes)
            }
        } catch {
            return false
        }
        return Data(hasher.finalize()) == expectedSHA256
    }
}

public struct LocalArtifactReconciliation: Equatable, Sendable {
    public let missingMasters: [OriginRecordingID]
    public let missingChunks: [ChunkID]
    public let missingBatches: [AudioBatchID]
    public let mismatchedChunks: [ChunkID]
    public let mismatchedBatches: [AudioBatchID]
}

public struct TransferConflictRecord: Equatable, Sendable {
    public let conflictID: UUID
    public let originRecordingID: OriginRecordingID?
    public let uploadID: UploadID?
    public let code: String
    public let detail: String?
    public let localExactBytes: Data?
    public let remoteExactBytes: Data?
    public let createdAt: Date
    public let resolvedAt: Date?

    public init(
        conflictID: UUID = UUID(),
        originRecordingID: OriginRecordingID?,
        uploadID: UploadID?,
        code: String,
        detail: String? = nil,
        localExactBytes: Data? = nil,
        remoteExactBytes: Data? = nil,
        createdAt: Date,
        resolvedAt: Date? = nil
    ) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !code.isEmpty, code.count <= 128,
              code.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ClientStoreError.corruptStoredValue(field: "transferConflictCode")
        }
        guard detail?.count ?? 0 <= 4_096,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              resolvedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw ClientStoreError.corruptStoredValue(field: "transferConflict")
        }
        self.conflictID = conflictID
        self.originRecordingID = originRecordingID
        self.uploadID = uploadID
        self.code = code
        self.detail = detail
        self.localExactBytes = localExactBytes
        self.remoteExactBytes = remoteExactBytes
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public struct CleanupIntent: Equatable, Sendable {
    public let originRecordingID: OriginRecordingID
    public let requestedAt: Date

    /// PR 3 has no receipt validator, so this is structurally false. PR 5 must
    /// migrate the schema and introduce one atomic verified-receipt API.
    public var isEligible: Bool { false }
}

extension HarcTransferStore {
    @discardableResult
    public func persistFinalizedCapture(
        _ capture: FinalizedCapture,
        masterFileURL: URL,
        persistedAt: Date? = nil
    ) throws -> StoredRecordingOutbox {
        let url = try localFileURL(masterFileURL)
        let timestamp = persistedAt ?? now()
        return try database.write { db in
            let payload = try ClientStoreCoding.encode(capture)
            let origin = capture.originRecordingID
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT finalized_capture_json, master_path
                    FROM finalized_captures
                    WHERE origin_device_id = ? AND origin_recording_uuid = ?
                    """,
                arguments: originArguments(origin)
            ) {
                guard (row["finalized_capture_json"] as Data) == payload,
                      (row["master_path"] as String) == url.path else {
                    throw ClientStoreError.captureAlreadyExistsWithDifferentFacts
                }
                guard let existing = try recordingOutbox(origin, in: db) else {
                    throw ClientStoreError.missingRow(entity: "recording outbox")
                }
                return existing
            }

            let timestampMS = try ClientStoreCoding.milliseconds(timestamp)
            try db.execute(
                sql: """
                    INSERT INTO finalized_captures (
                        origin_device_id, origin_recording_uuid,
                        finalized_capture_json, master_path,
                        master_file_state, persisted_at_ms
                    ) VALUES (?, ?, ?, ?, 'present', ?)
                    """,
                arguments: [
                    origin.deviceID.rawBytes,
                    origin.recordingUUID.uuidString.lowercased(),
                    payload,
                    url.path,
                    timestampMS,
                ]
            )
            let machine = RecordingOutboxStateMachine()
            try db.execute(
                sql: """
                    INSERT INTO recording_outbox (
                        origin_device_id, origin_recording_uuid, upload_id,
                        state, state_machine_json, failure_code,
                        failure_detail, updated_at_ms
                    ) VALUES (?, ?, NULL, ?, ?, NULL, NULL, ?)
                    """,
                arguments: [
                    origin.deviceID.rawBytes,
                    origin.recordingUUID.uuidString.lowercased(),
                    machine.state.rawValue,
                    try ClientStoreCoding.encode(machine),
                    timestampMS,
                ]
            )
            return StoredRecordingOutbox(
                finalizedCapture: StoredFinalizedCapture(
                    capture: capture,
                    masterFileURL: url,
                    masterFileState: .present,
                    persistedAt: timestamp
                ),
                uploadID: nil,
                stateMachine: machine,
                integrityBlock: nil,
                updatedAt: timestamp
            )
        }
    }

    public func recordingOutbox(
        for origin: OriginRecordingID
    ) throws -> StoredRecordingOutbox? {
        try database.read { db in try recordingOutbox(origin, in: db) }
    }

    @discardableResult
    public func updateRecordingOutbox(
        for origin: OriginRecordingID,
        _ transition: (inout RecordingOutboxStateMachine) throws -> Void
    ) throws -> RecordingOutboxStateMachine {
        try database.write { db in
            guard let stored = try recordingOutbox(origin, in: db) else {
                throw ClientStoreError.missingRow(entity: "recording outbox")
            }
            try requireCurrentInstallationOwner(
                stored.finalizedCapture.capture.producingDeviceID
            )
            try requireCurrentInstallationAuthorization(in: db)
            guard stored.integrityBlock == nil else {
                throw ClientStoreError.localArtifactIntegrityBlocked(origin: origin)
            }
            var machine = stored.stateMachine
            try transition(&machine)
            guard machine.state != .committed else {
                throw ClientStoreError.cleanupRequiresFutureVerifiedReceiptTransaction
            }
            try persistRecordingMachine(machine, origin: origin, in: db)
            return machine
        }
    }

    public func persistUploadAttempt(
        _ attempt: UploadAttempt,
        for tuple: AdoptedTrustTuple,
        abandoning priorAttempt: UploadAttempt? = nil,
        updatedAt: Date? = nil
    ) throws {
        guard attempt.status != .committed else {
            throw ClientStoreError.cleanupRequiresFutureVerifiedReceiptTransaction
        }
        try requireCurrentInstallationOwner(attempt.ownerDeviceID)
        let timestamp = updatedAt ?? now()
        try database.write { db in
            try requireActive(
                tuple,
                requiredScope: .recordingUploadOwn,
                in: db
            )
            if let hostTrust = attempt.boundHostTrust {
                let evidenceTuple = AdoptedTrustTuple(
                    libraryID: hostTrust.libraryID,
                    hostAuthorityID: hostTrust.hostAuthorityID
                )
                guard evidenceTuple == tuple else {
                    throw ClientStoreError.inactiveTrustTuple(
                        libraryID: evidenceTuple.libraryID,
                        hostAuthorityID: evidenceTuple.hostAuthorityID
                    )
                }
                try requireActive(
                    tuple,
                    authorityPublicKeyX963: hostTrust.hostAuthorityPublicKeyX963,
                    requiredScope: .recordingUploadOwn,
                    in: db
                )
            }
            guard try finalizedCaptureExists(attempt.originRecordingID, in: db) else {
                throw ClientStoreError.missingRow(entity: "finalized capture")
            }
            guard let outbox = try recordingOutbox(attempt.originRecordingID, in: db) else {
                throw ClientStoreError.missingRow(entity: "recording outbox")
            }
            try requireCurrentInstallationOwner(
                outbox.finalizedCapture.capture.producingDeviceID
            )
            guard outbox.finalizedCapture.capture.producingDeviceID == attempt.ownerDeviceID else {
                throw ClientStoreError.captureDeviceMismatch(
                    expected: attempt.ownerDeviceID,
                    presented: outbox.finalizedCapture.capture.producingDeviceID
                )
            }
            if let replacement = try replacementUploadID(
                forSuperseded: attempt.uploadID,
                in: db
            ) {
                throw ClientStoreError.uploadAttemptSuperseded(
                    uploadID: attempt.uploadID,
                    replacement: replacement
                )
            }
            let isRebinding = outbox.uploadID.map { $0 != attempt.uploadID } ?? false
            let reboundFromUploadID = isRebinding ? outbox.uploadID : nil
            if outbox.integrityBlock != nil,
               !isRebinding,
               attempt.status != .abandoned {
                throw ClientStoreError.localArtifactIntegrityBlocked(
                    origin: attempt.originRecordingID
                )
            }
            if let currentUploadID = outbox.uploadID, isRebinding {
                guard try uploadAttempt(attempt.uploadID, in: db) == nil else {
                    throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
                }
                try authorizeUploadRebind(
                    currentUploadID: currentUploadID,
                    replacement: attempt,
                    explicitlyAbandoned: priorAttempt,
                    at: timestamp,
                    in: db
                )
            } else if priorAttempt != nil {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
            if let manifest = attempt.boundManifest {
                try persistExactObject(manifest, persistedAt: timestamp, in: db)
            }

            let payload = try ClientStoreCoding.encode(attempt)
            let timestampMS = try ClientStoreCoding.milliseconds(timestamp)
            let manifestHash = attempt.boundManifest?.objectSHA256.rawBytes
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM upload_attempts WHERE upload_id = ?",
                arguments: [attempt.uploadID.description]
            ) {
                let existing: UploadAttempt = try ClientStoreCoding.decode(
                    UploadAttempt.self,
                    from: row["attempt_json"],
                    field: "uploadAttempt"
                )
                try existing.validateExactBeginReplay(
                    uploadID: attempt.uploadID,
                    ownerDeviceID: attempt.ownerDeviceID,
                    originRecordingID: attempt.originRecordingID,
                    frozenProfile: attempt.frozenProfile
                )
                guard existing.firstBeganAt == attempt.firstBeganAt,
                      (row["library_id"] as String) == tuple.libraryID.description,
                      (row["host_authority_id"] as Data) == tuple.hostAuthorityID.rawBytes else {
                    throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
                }
                if attempt.generation < existing.generation {
                    throw ClientStoreError.uploadGenerationRollback(
                        stored: existing.generation.rawValue,
                        presented: attempt.generation.rawValue
                    )
                }
                if attempt.generation > existing.generation {
                    let expected = try existing.generation.next()
                    guard attempt.generation == expected else {
                        throw ClientStoreError.uploadGenerationGap(
                            expected: expected.rawValue,
                            presented: attempt.generation.rawValue
                        )
                    }
                }
                try validateUploadProgress(from: existing, to: attempt)
                try db.execute(
                    sql: """
                        UPDATE upload_attempts
                        SET generation = ?, attempt_json = ?, state = ?,
                            expires_at_ms = ?, bound_manifest_sha256 = ?,
                            terminal_reason = ?, updated_at_ms = ?
                        WHERE upload_id = ?
                        """,
                    arguments: [
                        try ClientStoreCoding.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration"),
                        payload,
                        attempt.status.rawValue,
                        try ClientStoreCoding.milliseconds(attempt.generationExpiresAt),
                        manifestHash,
                        attempt.blockReason?.rawValue,
                        timestampMS,
                        attempt.uploadID.description,
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO upload_attempts (
                            upload_id, origin_device_id, origin_recording_uuid,
                            library_id, host_authority_id, generation,
                            attempt_json, state, expires_at_ms,
                            bound_manifest_sha256, terminal_reason, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        attempt.uploadID.description,
                        attempt.originRecordingID.deviceID.rawBytes,
                        attempt.originRecordingID.recordingUUID.uuidString.lowercased(),
                        tuple.libraryID.description,
                        tuple.hostAuthorityID.rawBytes,
                        try ClientStoreCoding.sqliteInteger(attempt.generation.rawValue, field: "uploadGeneration"),
                        payload,
                        attempt.status.rawValue,
                        try ClientStoreCoding.milliseconds(attempt.generationExpiresAt),
                        manifestHash,
                        attempt.blockReason?.rawValue,
                        timestampMS,
                    ]
                )
            }
            if let reboundFromUploadID {
                try persistUploadSupersession(
                    superseded: reboundFromUploadID,
                    replacement: attempt.uploadID,
                    origin: attempt.originRecordingID,
                    at: timestamp,
                    in: db
                )
            }
            if isRebinding {
                var replacementMachine = RecordingOutboxStateMachine()
                try replacementMachine.queue()
                try db.execute(
                    sql: """
                        UPDATE recording_outbox
                        SET upload_id = ?, state = ?, state_machine_json = ?,
                            failure_code = NULL, failure_detail = NULL,
                            integrity_block_code = NULL,
                            integrity_block_detail = NULL,
                            updated_at_ms = ?
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                          AND upload_id != ?
                        """,
                    arguments: [
                        attempt.uploadID.description,
                        replacementMachine.state.rawValue,
                        try ClientStoreCoding.encode(replacementMachine),
                        timestampMS,
                        attempt.originRecordingID.deviceID.rawBytes,
                        attempt.originRecordingID.recordingUUID.uuidString.lowercased(),
                        attempt.uploadID.description,
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE recording_outbox
                        SET upload_id = ?, updated_at_ms = ?
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                          AND (upload_id IS NULL OR upload_id = ?)
                        """,
                    arguments: [
                        attempt.uploadID.description,
                        timestampMS,
                        attempt.originRecordingID.deviceID.rawBytes,
                        attempt.originRecordingID.recordingUUID.uuidString.lowercased(),
                        attempt.uploadID.description,
                    ]
                )
            }
            guard db.changesCount == 1 else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
        }
    }

    public func uploadAttempt(id: UploadID) throws -> StoredUploadAttempt? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM upload_attempts WHERE upload_id = ?",
                arguments: [id.description]
            ) else { return nil }
            guard let libraryUUID = UUID(uuidString: row["library_id"] as String) else {
                throw ClientStoreError.corruptStoredValue(field: "uploadLibraryID")
            }
            return StoredUploadAttempt(
                trustTuple: AdoptedTrustTuple(
                    libraryID: LibraryID(libraryUUID),
                    hostAuthorityID: try HostAuthorityID(row["host_authority_id"] as Data)
                ),
                attempt: try ClientStoreCoding.decode(
                    UploadAttempt.self,
                    from: row["attempt_json"],
                    field: "uploadAttempt"
                ),
                updatedAt: ClientStoreCoding.date(milliseconds: row["updated_at_ms"])
            )
        }
    }

    public func persistEncodedChunk(
        uploadID: UploadID,
        descriptor: LogicalChunkDescriptor,
        encodedFileURL: URL,
        stateMachine: ChunkOutboxStateMachine,
        updatedAt: Date? = nil
    ) throws {
        let fileURL = try localFileURL(encodedFileURL)
        try database.write { db in
            try requireCurrentUploadWithoutIntegrityBlock(uploadID, in: db)
            guard let upload = try uploadAttempt(uploadID, in: db) else {
                throw ClientStoreError.missingRow(entity: "upload attempt")
            }
            guard upload.declarations.descriptors.contains(descriptor) else {
                throw ClientStoreError.missingRow(entity: "immutable chunk declaration")
            }
            let descriptorJSON = try ClientStoreCoding.encode(descriptor)
            let machineJSON = try ClientStoreCoding.encode(stateMachine)
            let timestampMS = try ClientStoreCoding.milliseconds(updatedAt ?? now())
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT descriptor_json, encoded_path, state_machine_json
                    FROM upload_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                    """,
                arguments: [uploadID.description, Int64(descriptor.chunkIndex)]
            ) {
                guard (row["descriptor_json"] as Data) == descriptorJSON,
                      (row["encoded_path"] as String) == fileURL.path,
                      (row["state_machine_json"] as Data) == machineJSON else {
                    throw ClientStoreError.chunkAlreadyExistsWithDifferentFacts
                }
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO upload_chunks (
                        upload_id, chunk_index, chunk_id, descriptor_json,
                        encoded_path, file_state, outbox_state,
                        state_machine_json, durable_ack_sha256, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 'present', ?, ?, NULL, ?)
                    """,
                arguments: [
                    uploadID.description,
                    Int64(descriptor.chunkIndex),
                    descriptor.chunkID.description,
                    descriptorJSON,
                    fileURL.path,
                    stateMachine.state.rawValue,
                    machineJSON,
                    timestampMS,
                ]
            )
        }
    }

    @discardableResult
    public func updateChunkOutbox(
        uploadID: UploadID,
        chunkIndex: UInt32,
        _ transition: (inout ChunkOutboxStateMachine) throws -> Void
    ) throws -> ChunkOutboxStateMachine {
        try database.write { db in
            try requireCurrentUploadWithoutIntegrityBlock(uploadID, in: db)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT state_machine_json FROM upload_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                    """,
                arguments: [uploadID.description, Int64(chunkIndex)]
            ) else {
                throw ClientStoreError.missingRow(entity: "upload chunk")
            }
            var machine: ChunkOutboxStateMachine = try ClientStoreCoding.decode(
                ChunkOutboxStateMachine.self,
                from: row["state_machine_json"],
                field: "chunkOutbox"
            )
            try transition(&machine)
            try persistChunkMachine(machine, uploadID: uploadID, chunkIndex: chunkIndex, in: db)
            return machine
        }
    }

    public func chunks(uploadID: UploadID) throws -> [StoredUploadChunk] {
        try database.read { db in try chunks(uploadID: uploadID, in: db) }
    }

    public func persistExactObject(
        _ object: OpaqueExactObjectSlot,
        persistedAt: Date? = nil
    ) throws {
        try database.write { db in
            try persistExactObject(object, persistedAt: persistedAt ?? now(), in: db)
        }
    }

    public func exactObject(
        sha256: ExactObjectSHA256
    ) throws -> OpaqueExactObjectSlot? {
        try database.read { db in try exactObject(sha256: sha256, in: db) }
    }

    /// Persists a typed host reconciliation and advances only chunk staging
    /// facts that match the immutable local attempt. Even a reconciliation
    /// carrying receipt bytes does not commit the recording or enable cleanup;
    /// PR 5 must validate those bytes against local manifest/audio/trust facts.
    public func applyUploadReconciliation(
        _ reconciliation: UploadReconciliation,
        reconciledAt: Date? = nil
    ) throws {
        try database.write { db in
            try requireCurrentUploadWithoutIntegrityBlock(
                reconciliation.uploadID,
                in: db
            )
            guard let attempt = try uploadAttempt(reconciliation.uploadID, in: db) else {
                throw ClientStoreError.missingRow(entity: "upload attempt")
            }
            guard reconciliation.ownerDeviceID == attempt.ownerDeviceID,
                  reconciliation.originRecordingID == attempt.originRecordingID,
                  reconciliation.uploadProfileSHA256 == attempt.frozenProfile.profileSHA256,
                  reconciliation.generation == attempt.generation,
                  reconciliation.generationExpiresAt == attempt.generationExpiresAt,
                  reconciliation.declarations == attempt.declarations.descriptors,
                  reconciliation.boundManifestObjectSHA256 == attempt.boundManifest?.objectSHA256 else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
            if let receipt = reconciliation.existingReceipt {
                try persistExactObject(
                    receipt,
                    persistedAt: reconciledAt ?? now(),
                    in: db
                )
            }

            let timestampMS = try ClientStoreCoding.milliseconds(reconciledAt ?? now())
            for durable in reconciliation.durableChunks {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT descriptor_json, state_machine_json
                        FROM upload_chunks
                        WHERE upload_id = ? AND chunk_index = ?
                        """,
                    arguments: [reconciliation.uploadID.description, Int64(durable.chunkIndex)]
                ) else {
                    throw ClientStoreError.missingRow(entity: "upload chunk")
                }
                let descriptor: LogicalChunkDescriptor = try ClientStoreCoding.decode(
                    LogicalChunkDescriptor.self,
                    from: row["descriptor_json"],
                    field: "chunkDescriptor"
                )
                guard descriptor.chunkID == durable.chunkID,
                      descriptor.encodedSHA256 == durable.encodedSHA256 else {
                    throw ClientStoreError.chunkAlreadyExistsWithDifferentFacts
                }
                var machine: ChunkOutboxStateMachine = try ClientStoreCoding.decode(
                    ChunkOutboxStateMachine.self,
                    from: row["state_machine_json"],
                    field: "chunkOutbox"
                )
                if machine.state != .durableAtHost {
                    try machine.markDurableAtHost()
                    try persistChunkMachine(
                        machine,
                        uploadID: reconciliation.uploadID,
                        chunkIndex: durable.chunkIndex,
                        in: db,
                        updatedAtMS: timestampMS
                    )
                }
            }
            for rejected in reconciliation.rejectedChunks {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT descriptor_json, state_machine_json
                        FROM upload_chunks
                        WHERE upload_id = ? AND chunk_index = ?
                        """,
                    arguments: [reconciliation.uploadID.description, Int64(rejected.chunkIndex)]
                ) else {
                    throw ClientStoreError.missingRow(entity: "upload chunk")
                }
                let descriptor: LogicalChunkDescriptor = try ClientStoreCoding.decode(
                    LogicalChunkDescriptor.self,
                    from: row["descriptor_json"],
                    field: "chunkDescriptor"
                )
                guard descriptor.chunkID == rejected.chunkID else {
                    throw ClientStoreError.chunkAlreadyExistsWithDifferentFacts
                }
                var machine: ChunkOutboxStateMachine = try ClientStoreCoding.decode(
                    ChunkOutboxStateMachine.self,
                    from: row["state_machine_json"],
                    field: "chunkOutbox"
                )
                if machine.state != .failedRecoverable {
                    try machine.failRecoverably(
                        TransferFailure(
                            code: "host-rejected-chunk",
                            detail: rejected.reason.rawValue
                        ),
                        retryFrom: .ready
                    )
                    try persistChunkMachine(
                        machine,
                        uploadID: reconciliation.uploadID,
                        chunkIndex: rejected.chunkIndex,
                        in: db,
                        updatedAtMS: timestampMS
                    )
                }
            }
            try db.execute(
                sql: """
                    UPDATE upload_attempts
                    SET reconciliation_json = ?, updated_at_ms = ?
                    WHERE upload_id = ?
                    """,
                arguments: [
                    try ClientStoreCoding.encode(reconciliation),
                    timestampMS,
                    reconciliation.uploadID.description,
                ]
            )
        }
    }

    public func lastUploadReconciliation(
        uploadID: UploadID
    ) throws -> UploadReconciliation? {
        try database.read { db in
            guard let payload = try Data.fetchOne(
                db,
                sql: """
                    SELECT reconciliation_json FROM upload_attempts
                    WHERE upload_id = ?
                    """,
                arguments: [uploadID.description]
            ) else { return nil }
            return try ClientStoreCoding.decode(
                UploadReconciliation.self,
                from: payload,
                field: "uploadReconciliation"
            )
        }
    }

    public func persistBackgroundBatch(
        _ descriptor: ImmutableAudioBatchDescriptor,
        bodyFileURL: URL,
        capability: OpaqueBackgroundCapability,
        state: BackgroundBatchState = .readyToSchedule,
        updatedAt: Date? = nil
    ) throws {
        let fileURL = try localFileURL(bodyFileURL)
        try database.write { db in
            try requireCurrentUploadWithoutIntegrityBlock(descriptor.uploadID, in: db)
            guard let attempt = try uploadAttempt(descriptor.uploadID, in: db) else {
                throw ClientStoreError.missingRow(entity: "upload attempt")
            }
            guard descriptor.generation == attempt.generation,
                  descriptor.originRecordingID == attempt.originRecordingID,
                  descriptor.ownerDeviceID == attempt.ownerDeviceID,
                  descriptor.uploadProfileSHA256 == attempt.frozenProfile.profileSHA256,
                  descriptor.chunks.allSatisfy(attempt.declarations.descriptors.contains) else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
            let descriptorJSON = try ClientStoreCoding.encode(descriptor)
            let timestampMS = try ClientStoreCoding.milliseconds(updatedAt ?? now())
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM upload_batches WHERE batch_id = ?",
                arguments: [descriptor.batchID.description]
            ) {
                let capabilityExpiryMS = try ClientStoreCoding.milliseconds(
                    capability.expiresAt
                )
                let exactReplay =
                    (row["descriptor_json"] as Data) == descriptorJSON &&
                    (row["body_path"] as String) == fileURL.path &&
                    (row["opaque_capability_credential"] as Data) == capability.credential &&
                    (row["capability_bindings"] as Data) == capability.capabilityBindings &&
                    (row["capability_expires_at_ms"] as Int64) == capabilityExpiryMS
                guard exactReplay else {
                    throw ClientStoreError.exactObjectEquivocation
                }
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO upload_batches (
                        batch_id, upload_id, generation, descriptor_json,
                        body_path, body_sha256, body_byte_count,
                        opaque_capability_credential, capability_bindings,
                        capability_expires_at_ms, file_state, state,
                        durable_ack_sha256, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'present', ?, NULL, ?)
                    """,
                arguments: [
                    descriptor.batchID.description,
                    descriptor.uploadID.description,
                    try ClientStoreCoding.sqliteInteger(descriptor.generation.rawValue, field: "uploadGeneration"),
                    descriptorJSON,
                    fileURL.path,
                    descriptor.exactBodySHA256.rawBytes,
                    try ClientStoreCoding.sqliteInteger(descriptor.exactBodyByteLength, field: "batchByteCount"),
                    capability.credential,
                    capability.capabilityBindings,
                    try ClientStoreCoding.milliseconds(capability.expiresAt),
                    state.rawValue,
                    timestampMS,
                ]
            )
        }
    }

    public func backgroundBatch(id: AudioBatchID) throws -> StoredBackgroundBatch? {
        try database.read { db in try backgroundBatch(id: id, in: db) }
    }

    /// Persists one authority-authenticated, immutable-descriptor-bound batch
    /// acknowledgement. Staging durability never changes recording commit or
    /// cleanup eligibility.
    public func persistVerifiedBatchACK(
        _ evidence: ValidatedBatchAcknowledgementEvidence,
        persistedAt: Date? = nil
    ) throws {
        try persistVerifiedBatchACK(
            evidence.exactAcknowledgementObject,
            batchID: evidence.batchID,
            durableChunks: evidence.durableChunks,
            persistedAt: persistedAt
        )
    }

    /// Package-only compatibility seam for migration/tests. Production callers
    /// must supply the validator-owned aggregate above so exact bytes and chunk
    /// facts cannot be combined independently.
    package func persistVerifiedBatchACK(
        _ ack: OpaqueExactObjectSlot,
        batchID: AudioBatchID,
        durableChunks: [DurableChunkStatus],
        persistedAt: Date? = nil
    ) throws {
        guard ack.kind == .audioBatchAckV1 else {
            throw ClientStoreError.corruptStoredValue(field: "batchACKKind")
        }
        try database.write { db in
            guard let batch = try backgroundBatch(id: batchID, in: db) else {
                throw ClientStoreError.missingRow(entity: "background batch")
            }
            try requireCurrentUploadWithoutIntegrityBlock(
                batch.descriptor.uploadID,
                in: db
            )
            let descriptorsByIndex = Dictionary(
                uniqueKeysWithValues: batch.descriptor.chunks.map { ($0.chunkIndex, $0) }
            )
            let expectedIndices = batch.descriptor.chunks.map(\.chunkIndex).sorted()
            guard durableChunks.map(\.chunkIndex) == expectedIndices else {
                throw ClientStoreError.chunkAlreadyExistsWithDifferentFacts
            }
            for durable in durableChunks {
                guard let descriptor = descriptorsByIndex[durable.chunkIndex],
                      descriptor.chunkID == durable.chunkID,
                      descriptor.encodedSHA256 == durable.encodedSHA256 else {
                    throw ClientStoreError.chunkAlreadyExistsWithDifferentFacts
                }
            }
            if let existing = batch.durableACK {
                guard existing == ack else { throw ClientStoreError.exactObjectEquivocation }
                return
            }

            let timestamp = persistedAt ?? now()
            let timestampMS = try ClientStoreCoding.milliseconds(timestamp)
            try persistExactObject(ack, persistedAt: timestamp, in: db)
            for durable in durableChunks {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT state_machine_json FROM upload_chunks
                        WHERE upload_id = ? AND chunk_index = ?
                        """,
                    arguments: [
                        batch.descriptor.uploadID.description,
                        Int64(durable.chunkIndex),
                    ]
                ) else {
                    throw ClientStoreError.missingRow(entity: "upload chunk")
                }
                var machine: ChunkOutboxStateMachine = try ClientStoreCoding.decode(
                    ChunkOutboxStateMachine.self,
                    from: row["state_machine_json"],
                    field: "chunkOutbox"
                )
                if machine.state != .durableAtHost {
                    try machine.markDurableAtHost()
                }
                try db.execute(
                    sql: """
                        UPDATE upload_chunks
                        SET outbox_state = ?, state_machine_json = ?,
                            durable_ack_sha256 = ?, updated_at_ms = ?
                        WHERE upload_id = ? AND chunk_index = ?
                        """,
                    arguments: [
                        machine.state.rawValue,
                        try ClientStoreCoding.encode(machine),
                        ack.objectSHA256.rawBytes,
                        timestampMS,
                        batch.descriptor.uploadID.description,
                        Int64(durable.chunkIndex),
                    ]
                )
            }
            try db.execute(
                sql: """
                    UPDATE upload_batches
                    SET durable_ack_sha256 = ?, state = 'completed', updated_at_ms = ?
                    WHERE batch_id = ?
                    """,
                arguments: [
                    ack.objectSHA256.rawBytes,
                    timestampMS,
                    batchID.description,
                ]
            )
        }
    }

    /// Persists the task mapping and marks the immutable batch scheduled in one
    /// transaction. The caller may call `resume()` only after this returns.
    public func persistTaskMappingBeforeResume(
        _ identity: SystemBackgroundTaskIdentity,
        batchID: AudioBatchID,
        updatedAt: Date? = nil
    ) throws {
        try database.write { db in
            guard let batch = try backgroundBatch(id: batchID, in: db) else {
                throw ClientStoreError.missingRow(entity: "background batch")
            }
            try requireCurrentUploadWithoutIntegrityBlock(
                batch.descriptor.uploadID,
                in: db
            )
            let timestampMS = try ClientStoreCoding.milliseconds(updatedAt ?? now())
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT batch_id FROM background_task_mappings
                    WHERE session_identifier = ? AND task_identifier = ?
                    """,
                arguments: [identity.sessionIdentifier, identity.taskIdentifier]
            ) {
                guard (row["batch_id"] as String) == batchID.description else {
                    throw ClientStoreError.exactObjectEquivocation
                }
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO background_task_mappings (
                        session_identifier, task_identifier, batch_id, state, updated_at_ms
                    ) VALUES (?, ?, ?, 'persistedBeforeResume', ?)
                    """,
                arguments: [
                    identity.sessionIdentifier,
                    identity.taskIdentifier,
                    batchID.description,
                    timestampMS,
                ]
            )
            try db.execute(
                sql: "UPDATE upload_batches SET state = 'scheduled', updated_at_ms = ? WHERE batch_id = ?",
                arguments: [timestampMS, batchID.description]
            )
        }
    }

    public func taskMappings() throws -> [StoredBackgroundTaskMapping] {
        try database.read { db in try taskMappings(in: db) }
    }

    /// Compares persisted mappings with the operating system's task list. It
    /// never deletes a mapping, credential, body, or capture during launch.
    public func reconcileBackgroundTasks(
        observedSystemTasks: Set<SystemBackgroundTaskIdentity>,
        reconciledAt: Date? = nil
    ) throws -> BackgroundTaskReconciliation {
        try database.write { db in
            let persisted = try taskMappings(in: db)
            for mapping in persisted where mapping.state != .completed {
                guard let batch = try backgroundBatch(id: mapping.batchID, in: db) else {
                    throw ClientStoreError.missingRow(entity: "background batch")
                }
                try requireCurrentUploadWithoutIntegrityBlock(
                    batch.descriptor.uploadID,
                    in: db
                )
            }
            let persistedByIdentity = Dictionary(uniqueKeysWithValues: persisted.map { ($0.identity, $0) })
            var missingBatchCandidates = Set<AudioBatchID>()
            var observedBatchIDs = Set<AudioBatchID>()
            var matched: [SystemBackgroundTaskIdentity] = []
            let timestampMS = try ClientStoreCoding.milliseconds(reconciledAt ?? now())

            for mapping in persisted {
                if observedSystemTasks.contains(mapping.identity) {
                    matched.append(mapping.identity)
                    observedBatchIDs.insert(mapping.batchID)
                    if mapping.state != .completed {
                        try db.execute(
                            sql: """
                                UPDATE background_task_mappings
                                SET state = 'observedBySystem', updated_at_ms = ?
                                WHERE session_identifier = ? AND task_identifier = ?
                                """,
                            arguments: [
                                timestampMS,
                                mapping.identity.sessionIdentifier,
                                mapping.identity.taskIdentifier,
                            ]
                        )
                    }
                } else if mapping.state != .completed {
                    missingBatchCandidates.insert(mapping.batchID)
                    try db.execute(
                        sql: """
                            UPDATE background_task_mappings
                            SET state = 'missingFromSystem', updated_at_ms = ?
                            WHERE session_identifier = ? AND task_identifier = ?
                            """,
                        arguments: [
                            timestampMS,
                            mapping.identity.sessionIdentifier,
                            mapping.identity.taskIdentifier,
                        ]
                    )
                }
            }

            var batchesToReschedule: [AudioBatchID] = []
            for batchID in missingBatchCandidates.subtracting(observedBatchIDs).sorted() {
                try db.execute(
                    sql: """
                        UPDATE upload_batches
                        SET state = 'needsReschedule', updated_at_ms = ?
                        WHERE batch_id = ? AND state != 'completed'
                        """,
                    arguments: [timestampMS, batchID.description]
                )
                if db.changesCount == 1 {
                    batchesToReschedule.append(batchID)
                }
            }

            let orphaned = observedSystemTasks.filter { persistedByIdentity[$0] == nil }
            return BackgroundTaskReconciliation(
                batchesToReschedule: batchesToReschedule,
                orphanedSystemTasks: orphaned.sorted { lhs, rhs in
                    lhs.taskIdentifier < rhs.taskIdentifier
                },
                matchedTasks: matched.sorted { $0.taskIdentifier < $1.taskIdentifier }
            )
        }
    }

    /// Reconciles missing local files after reopen without deleting rows. A
    /// missing master makes the recording visibly recoverable; missing encoded
    /// chunks/batches preserve immutable declarations and credentials.
    public func reconcileLocalArtifacts(
        inspector: any LocalTransferArtifactInspecting = FoundationLocalTransferArtifactInspector(),
        reconciledAt: Date? = nil
    ) throws -> LocalArtifactReconciliation {
        try database.write { db in
            var missingMasters: [OriginRecordingID] = []
            var missingChunks: [ChunkID] = []
            var missingBatches: [AudioBatchID] = []
            var mismatchedChunks: [ChunkID] = []
            var mismatchedBatches: [AudioBatchID] = []
            var integrityBlocks: [OriginRecordingID: LocalArtifactIntegrityBlock] = [:]
            let timestampMS = try ClientStoreCoding.milliseconds(reconciledAt ?? now())
            let currentUploadIDs = Set(try String.fetchAll(
                db,
                sql: "SELECT upload_id FROM recording_outbox WHERE upload_id IS NOT NULL"
            ))

            let captureRows = try Row.fetchAll(db, sql: "SELECT * FROM finalized_captures")
            for row in captureRows {
                let origin = try decodeOrigin(row)
                let url = URL(fileURLWithPath: row["master_path"] as String)
                let exists = inspector.fileExists(at: url)
                try db.execute(
                    sql: """
                        UPDATE finalized_captures SET master_file_state = ?
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                        """,
                    arguments: [
                        exists ? LocalTransferArtifactState.present.rawValue : LocalTransferArtifactState.missing.rawValue,
                        origin.deviceID.rawBytes,
                        origin.recordingUUID.uuidString.lowercased(),
                    ]
                )
                guard !exists else { continue }
                missingMasters.append(origin)
                if let outbox = try recordingOutbox(origin, in: db),
                   outbox.stateMachine.state != .failedRecoverable,
                   outbox.stateMachine.state != .securityBlocked,
                   outbox.stateMachine.state != .committed {
                    var machine = outbox.stateMachine
                    try machine.failRecoverably(
                        TransferFailure(code: "local-master-missing")
                    )
                    try persistRecordingMachine(machine, origin: origin, in: db, updatedAtMS: timestampMS)
                }
            }

            let chunkRows = try Row.fetchAll(db, sql: "SELECT * FROM upload_chunks")
            for row in chunkRows {
                let uploadIDText = row["upload_id"] as String
                guard currentUploadIDs.contains(uploadIDText) else { continue }
                let fileURL = URL(fileURLWithPath: row["encoded_path"] as String)
                let descriptor: LogicalChunkDescriptor = try ClientStoreCoding.decode(
                    LogicalChunkDescriptor.self,
                    from: row["descriptor_json"],
                    field: "chunkDescriptor"
                )
                let exists = inspector.fileExists(at: fileURL)
                let exact = exists && inspector.exactFileMatches(
                    at: fileURL,
                    expectedByteCount: descriptor.encodedByteLength,
                    expectedSHA256: descriptor.encodedSHA256.rawBytes
                )
                let fileState: LocalTransferArtifactState = !exists
                    ? .missing
                    : (exact ? .present : .integrityMismatch)
                try db.execute(
                    sql: """
                        UPDATE upload_chunks SET file_state = ?
                        WHERE upload_id = ? AND chunk_index = ?
                        """,
                    arguments: [
                        fileState.rawValue,
                        uploadIDText,
                        row["chunk_index"] as Int64,
                    ]
                )
                guard !exact else { continue }
                let code: LocalArtifactIntegrityBlockCode
                if exists {
                    mismatchedChunks.append(descriptor.chunkID)
                    code = .immutableChunkMismatch
                } else {
                    missingChunks.append(descriptor.chunkID)
                    code = .immutableChunkMissing
                }
                integrityBlocks[descriptor.originRecordingID] = LocalArtifactIntegrityBlock(
                    code: code,
                    detail: "chunk:\(descriptor.chunkID.description)"
                )
            }

            let batchRows = try Row.fetchAll(db, sql: "SELECT * FROM upload_batches")
            for row in batchRows {
                let uploadIDText = row["upload_id"] as String
                guard currentUploadIDs.contains(uploadIDText) else { continue }
                let fileURL = URL(fileURLWithPath: row["body_path"] as String)
                let descriptor: ImmutableAudioBatchDescriptor = try ClientStoreCoding.decode(
                    ImmutableAudioBatchDescriptor.self,
                    from: row["descriptor_json"],
                    field: "backgroundBatch"
                )
                let exists = inspector.fileExists(at: fileURL)
                let exact = exists && inspector.exactFileMatches(
                    at: fileURL,
                    expectedByteCount: descriptor.exactBodyByteLength,
                    expectedSHA256: descriptor.exactBodySHA256.rawBytes
                )
                let fileState: LocalTransferArtifactState = !exists
                    ? .missing
                    : (exact ? .present : .integrityMismatch)
                if !exact {
                    let code: LocalArtifactIntegrityBlockCode
                    if exists {
                        mismatchedBatches.append(descriptor.batchID)
                        code = .immutableBatchMismatch
                    } else {
                        missingBatches.append(descriptor.batchID)
                        code = .immutableBatchMissing
                    }
                    integrityBlocks[descriptor.originRecordingID] = LocalArtifactIntegrityBlock(
                        code: code,
                        detail: "batch:\(descriptor.batchID.description)"
                    )
                }
                try db.execute(
                    sql: """
                        UPDATE upload_batches
                        SET file_state = ?, updated_at_ms = ?
                        WHERE batch_id = ?
                        """,
                    arguments: [
                        fileState.rawValue,
                        timestampMS,
                        descriptor.batchID.description,
                    ]
                )
            }

            for (origin, block) in integrityBlocks {
                try persistIntegrityBlock(
                    block,
                    origin: origin,
                    updatedAtMS: timestampMS,
                    in: db
                )
            }
            let priorBlockRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT origin_device_id, origin_recording_uuid
                    FROM recording_outbox
                    WHERE integrity_block_code IS NOT NULL
                    """
            )
            for row in priorBlockRows {
                let origin = try decodeOrigin(row)
                guard integrityBlocks[origin] == nil else { continue }
                try db.execute(
                    sql: """
                        UPDATE recording_outbox
                        SET integrity_block_code = NULL,
                            integrity_block_detail = NULL,
                            updated_at_ms = ?
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                        """,
                    arguments: [
                        timestampMS,
                        origin.deviceID.rawBytes,
                        origin.recordingUUID.uuidString.lowercased(),
                    ]
                )
            }

            return LocalArtifactReconciliation(
                missingMasters: missingMasters.sorted(),
                missingChunks: missingChunks.sorted(),
                missingBatches: missingBatches.sorted(),
                mismatchedChunks: mismatchedChunks.sorted(),
                mismatchedBatches: mismatchedBatches.sorted()
            )
        }
    }

    public func recordTransferConflict(_ conflict: TransferConflictRecord) throws {
        try database.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM transfer_conflicts WHERE conflict_id = ?",
                arguments: [conflict.conflictID.uuidString.lowercased()]
            ) {
                let existing = try decodeTransferConflict(row)
                guard existing == conflict else {
                    throw ClientStoreError.exactObjectEquivocation
                }
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO transfer_conflicts (
                        conflict_id, origin_device_id, origin_recording_uuid,
                        upload_id, code, detail, local_exact_bytes,
                        remote_exact_bytes, created_at_ms, resolved_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    conflict.conflictID.uuidString.lowercased(),
                    conflict.originRecordingID?.deviceID.rawBytes,
                    conflict.originRecordingID?.recordingUUID.uuidString.lowercased(),
                    conflict.uploadID?.description,
                    conflict.code,
                    conflict.detail,
                    conflict.localExactBytes,
                    conflict.remoteExactBytes,
                    try ClientStoreCoding.milliseconds(conflict.createdAt),
                    try conflict.resolvedAt.map(ClientStoreCoding.milliseconds),
                ]
            )
        }
    }

    public func transferConflicts(
        includeResolved: Bool = false
    ) throws -> [TransferConflictRecord] {
        try database.read { db in
            let predicate = includeResolved ? "" : "WHERE resolved_at_ms IS NULL"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM transfer_conflicts
                    \(predicate)
                    ORDER BY created_at_ms, conflict_id
                    """
            )
            return try rows.map(decodeTransferConflict)
        }
    }

    public func requestCleanup(
        for origin: OriginRecordingID,
        requestedAt: Date? = nil
    ) throws -> CleanupIntent {
        let timestamp = requestedAt ?? now()
        return try database.write { db in
            guard try finalizedCaptureExists(origin, in: db) else {
                throw ClientStoreError.missingRow(entity: "finalized capture")
            }
            try db.execute(
                sql: """
                    INSERT INTO cleanup_intents (
                        origin_device_id, origin_recording_uuid,
                        requested_at_ms, state, verified_receipt_sha256
                    ) VALUES (?, ?, ?, 'awaitingVerifiedReceipt', NULL)
                    ON CONFLICT(origin_device_id, origin_recording_uuid) DO NOTHING
                    """,
                arguments: [
                    origin.deviceID.rawBytes,
                    origin.recordingUUID.uuidString.lowercased(),
                    try ClientStoreCoding.milliseconds(timestamp),
                ]
            )
            let persistedMS = try Int64.fetchOne(
                db,
                sql: """
                    SELECT requested_at_ms FROM cleanup_intents
                    WHERE origin_device_id = ? AND origin_recording_uuid = ?
                    """,
                arguments: originArguments(origin)
            )
            guard let persistedMS else {
                throw ClientStoreError.missingRow(entity: "cleanup intent")
            }
            return CleanupIntent(
                originRecordingID: origin,
                requestedAt: ClientStoreCoding.date(milliseconds: persistedMS)
            )
        }
    }

    public func cleanupIntent(for origin: OriginRecordingID) throws -> CleanupIntent? {
        try database.read { db in
            guard let timestamp = try Int64.fetchOne(
                db,
                sql: """
                    SELECT requested_at_ms FROM cleanup_intents
                    WHERE origin_device_id = ? AND origin_recording_uuid = ?
                    """,
                arguments: originArguments(origin)
            ) else { return nil }
            return CleanupIntent(
                originRecordingID: origin,
                requestedAt: ClientStoreCoding.date(milliseconds: timestamp)
            )
        }
    }

    /// Deliberately unavailable until PR 5 can supply validated receipt
    /// evidence and perform receipt/outbox/cleanup changes in one transaction.
    public func makeCleanupEligible(for _: OriginRecordingID) throws -> Never {
        throw ClientStoreError.cleanupRequiresFutureVerifiedReceiptTransaction
    }

    private func localFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ClientStoreError.invalidLocalArtifactURL(url.absoluteString)
        }
        return url.standardizedFileURL
    }

    private func originArguments(_ origin: OriginRecordingID) -> StatementArguments {
        [origin.deviceID.rawBytes, origin.recordingUUID.uuidString.lowercased()]
    }

    private func finalizedCaptureExists(
        _ origin: OriginRecordingID,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM finalized_captures
                    WHERE origin_device_id = ? AND origin_recording_uuid = ?
                )
                """,
            arguments: originArguments(origin)
        ) ?? false
    }

    private func recordingOutbox(
        _ origin: OriginRecordingID,
        in db: Database
    ) throws -> StoredRecordingOutbox? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT fc.*, ro.upload_id, ro.state_machine_json,
                       ro.integrity_block_code, ro.integrity_block_detail,
                       ro.updated_at_ms
                FROM finalized_captures fc
                JOIN recording_outbox ro USING (origin_device_id, origin_recording_uuid)
                WHERE fc.origin_device_id = ? AND fc.origin_recording_uuid = ?
                """,
            arguments: originArguments(origin)
        ) else { return nil }
        guard let fileState = LocalTransferArtifactState(
            rawValue: row["master_file_state"] as String
        ) else {
            throw ClientStoreError.corruptStoredValue(field: "masterFileState")
        }
        let capture: FinalizedCapture = try ClientStoreCoding.decode(
            FinalizedCapture.self,
            from: row["finalized_capture_json"],
            field: "finalizedCapture"
        )
        let uploadID = (row["upload_id"] as String?).flatMap(UUID.init(uuidString:)).map(UploadID.init)
        return StoredRecordingOutbox(
            finalizedCapture: StoredFinalizedCapture(
                capture: capture,
                masterFileURL: URL(fileURLWithPath: row["master_path"]),
                masterFileState: fileState,
                persistedAt: ClientStoreCoding.date(milliseconds: row["persisted_at_ms"])
            ),
            uploadID: uploadID,
            stateMachine: try ClientStoreCoding.decode(
                RecordingOutboxStateMachine.self,
                from: row["state_machine_json"],
                field: "recordingOutbox"
            ),
            integrityBlock: try decodeIntegrityBlock(row),
            updatedAt: ClientStoreCoding.date(milliseconds: row["updated_at_ms"])
        )
    }

    private func persistRecordingMachine(
        _ machine: RecordingOutboxStateMachine,
        origin: OriginRecordingID,
        in db: Database,
        updatedAtMS: Int64? = nil
    ) throws {
        try db.execute(
            sql: """
                UPDATE recording_outbox
                SET state = ?, state_machine_json = ?, failure_code = ?,
                    failure_detail = ?, updated_at_ms = ?
                WHERE origin_device_id = ? AND origin_recording_uuid = ?
                """,
            arguments: [
                machine.state.rawValue,
                try ClientStoreCoding.encode(machine),
                machine.failure?.code,
                machine.failure?.detail,
                updatedAtMS ?? (try ClientStoreCoding.milliseconds(now())),
                origin.deviceID.rawBytes,
                origin.recordingUUID.uuidString.lowercased(),
            ]
        )
    }

    private func persistIntegrityBlock(
        _ block: LocalArtifactIntegrityBlock,
        origin: OriginRecordingID,
        updatedAtMS: Int64,
        in db: Database
    ) throws {
        guard let outbox = try recordingOutbox(origin, in: db) else {
            throw ClientStoreError.missingRow(entity: "recording outbox")
        }
        var machine = outbox.stateMachine
        switch machine.state {
        case .localOnly:
            try machine.queue()
            try machine.beginAuthorization()
            try machine.blockForSecurity(.signatureOrObjectMismatch)
        case .queued:
            try machine.beginAuthorization()
            try machine.blockForSecurity(.signatureOrObjectMismatch)
        case .failedRecoverable:
            try machine.retryRecoverable()
            try machine.beginAuthorization()
            try machine.blockForSecurity(.signatureOrObjectMismatch)
        case .authorizing, .activeUpload, .backgroundScheduled, .hostCommitPending:
            try machine.blockForSecurity(.signatureOrObjectMismatch)
        case .securityBlocked:
            break
        case .committed:
            throw ClientStoreError.cleanupRequiresFutureVerifiedReceiptTransaction
        }
        try db.execute(
            sql: """
                UPDATE recording_outbox
                SET state = ?, state_machine_json = ?,
                    failure_code = NULL, failure_detail = NULL,
                    integrity_block_code = ?, integrity_block_detail = ?,
                    updated_at_ms = ?
                WHERE origin_device_id = ? AND origin_recording_uuid = ?
                """,
            arguments: [
                machine.state.rawValue,
                try ClientStoreCoding.encode(machine),
                block.code.rawValue,
                block.detail,
                updatedAtMS,
                origin.deviceID.rawBytes,
                origin.recordingUUID.uuidString.lowercased(),
            ]
        )
    }

    private func decodeIntegrityBlock(_ row: Row) throws -> LocalArtifactIntegrityBlock? {
        let codeText = row["integrity_block_code"] as String?
        let detail = row["integrity_block_detail"] as String?
        switch (codeText, detail) {
        case (.none, .none):
            return nil
        case (.some(let codeText), .some(let detail)):
            guard let code = LocalArtifactIntegrityBlockCode(rawValue: codeText),
                  !detail.isEmpty else {
                throw ClientStoreError.corruptStoredValue(field: "integrityBlock")
            }
            return LocalArtifactIntegrityBlock(code: code, detail: detail)
        default:
            throw ClientStoreError.corruptStoredValue(field: "integrityBlock")
        }
    }

    private func requireCurrentUploadWithoutIntegrityBlock(
        _ uploadID: UploadID,
        in db: Database
    ) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT u.origin_device_id, u.origin_recording_uuid,
                       u.library_id, u.host_authority_id,
                       ro.upload_id, ro.integrity_block_code,
                       ro.integrity_block_detail
                FROM upload_attempts u
                JOIN recording_outbox ro
                  ON ro.origin_device_id = u.origin_device_id
                 AND ro.origin_recording_uuid = u.origin_recording_uuid
                WHERE u.upload_id = ?
                """,
            arguments: [uploadID.description]
        ) else {
            throw ClientStoreError.missingRow(entity: "upload attempt")
        }
        let origin = try decodeOrigin(row)
        try requireCurrentInstallationOwner(origin.deviceID)
        guard let libraryUUID = UUID(uuidString: row["library_id"] as String) else {
            throw ClientStoreError.corruptStoredValue(field: "uploadLibraryID")
        }
        try requireActive(
            AdoptedTrustTuple(
                libraryID: LibraryID(libraryUUID),
                hostAuthorityID: try HostAuthorityID(row["host_authority_id"] as Data)
            ),
            requiredScope: .recordingUploadOwn,
            in: db
        )
        guard (row["upload_id"] as String?) == uploadID.description else {
            throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
        }
        if let replacement = try replacementUploadID(
            forSuperseded: uploadID,
            in: db
        ) {
            throw ClientStoreError.uploadAttemptSuperseded(
                uploadID: uploadID,
                replacement: replacement
            )
        }
        guard try decodeIntegrityBlock(row) == nil else {
            throw ClientStoreError.localArtifactIntegrityBlocked(origin: origin)
        }
    }

    private func requireCurrentInstallationOwner(_ presented: DeviceID) throws {
        guard presented == installationDeviceID else {
            throw ClientStoreError.captureDeviceMismatch(
                expected: installationDeviceID,
                presented: presented
            )
        }
    }

    private func requireCurrentInstallationAuthorization(in db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT library_id, host_authority_id
                FROM adoption_history
                WHERE ended_at_ms IS NULL
                LIMIT 1
                """
        ) else {
            throw ClientStoreError.noActiveAdoption
        }
        guard let libraryUUID = UUID(uuidString: row["library_id"] as String) else {
            throw ClientStoreError.corruptStoredValue(field: "activeAdoption")
        }
        try requireActive(
            AdoptedTrustTuple(
                libraryID: LibraryID(libraryUUID),
                hostAuthorityID: try HostAuthorityID(row["host_authority_id"] as Data)
            ),
            requiredScope: .recordingUploadOwn,
            in: db
        )
    }

    private func replacementUploadID(
        forSuperseded uploadID: UploadID,
        in db: Database
    ) throws -> UploadID? {
        guard let replacementText = try String.fetchOne(
            db,
            sql: """
                SELECT replacement_upload_id
                FROM upload_attempt_supersessions
                WHERE superseded_upload_id = ?
                """,
            arguments: [uploadID.description]
        ) else { return nil }
        guard let replacementUUID = UUID(uuidString: replacementText) else {
            throw ClientStoreError.corruptStoredValue(field: "uploadSupersession")
        }
        return UploadID(replacementUUID)
    }

    private func persistUploadSupersession(
        superseded: UploadID,
        replacement: UploadID,
        origin: OriginRecordingID,
        at date: Date,
        in db: Database
    ) throws {
        guard superseded != replacement else {
            throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
        }
        try db.execute(
            sql: """
                INSERT INTO upload_attempt_supersessions (
                    superseded_upload_id, replacement_upload_id,
                    origin_device_id, origin_recording_uuid, superseded_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                superseded.description,
                replacement.description,
                origin.deviceID.rawBytes,
                origin.recordingUUID.uuidString.lowercased(),
                try ClientStoreCoding.milliseconds(date),
            ]
        )
    }

    private func uploadAttempt(_ id: UploadID, in db: Database) throws -> UploadAttempt? {
        guard let payload = try Data.fetchOne(
            db,
            sql: "SELECT attempt_json FROM upload_attempts WHERE upload_id = ?",
            arguments: [id.description]
        ) else { return nil }
        return try ClientStoreCoding.decode(
            UploadAttempt.self,
            from: payload,
            field: "uploadAttempt"
        )
    }

    /// Validates and, when supplied, persists an explicit abandonment before
    /// the replacement row and outbox binding are written in the same SQLite
    /// transaction. An expired active lease is also supersedable, but an
    /// active, conflict-blocked, or committed attempt never silently rebinds.
    private func authorizeUploadRebind(
        currentUploadID: UploadID,
        replacement: UploadAttempt,
        explicitlyAbandoned: UploadAttempt?,
        at timestamp: Date,
        in db: Database
    ) throws {
        if let durableReplacement = try replacementUploadID(
            forSuperseded: currentUploadID,
            in: db
        ) {
            throw ClientStoreError.uploadAttemptSuperseded(
                uploadID: currentUploadID,
                replacement: durableReplacement
            )
        }
        guard replacement.status == .active,
              replacement.generation == .initial,
              replacement.firstBeganAt <= timestamp else {
            throw ClientStoreError.uploadRebindNotAllowed(
                current: currentUploadID,
                presented: replacement.uploadID
            )
        }
        guard let stored = try uploadAttempt(currentUploadID, in: db),
              stored.originRecordingID == replacement.originRecordingID,
              stored.ownerDeviceID == replacement.ownerDeviceID else {
            throw ClientStoreError.uploadRebindNotAllowed(
                current: currentUploadID,
                presented: replacement.uploadID
            )
        }

        var superseded = stored
        if let explicitlyAbandoned {
            guard explicitlyAbandoned.uploadID == currentUploadID,
                  explicitlyAbandoned.status == .abandoned,
                  explicitlyAbandoned.generation == stored.generation else {
                throw ClientStoreError.uploadRebindNotAllowed(
                    current: currentUploadID,
                    presented: replacement.uploadID
                )
            }
            try stored.validateExactBeginReplay(
                uploadID: explicitlyAbandoned.uploadID,
                ownerDeviceID: explicitlyAbandoned.ownerDeviceID,
                originRecordingID: explicitlyAbandoned.originRecordingID,
                frozenProfile: explicitlyAbandoned.frozenProfile
            )
            guard explicitlyAbandoned.firstBeganAt == stored.firstBeganAt else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
            try validateUploadProgress(from: stored, to: explicitlyAbandoned)
            superseded = explicitlyAbandoned
            try db.execute(
                sql: """
                    UPDATE upload_attempts
                    SET attempt_json = ?, state = ?, expires_at_ms = ?,
                        terminal_reason = ?, updated_at_ms = ?
                    WHERE upload_id = ?
                    """,
                arguments: [
                    try ClientStoreCoding.encode(explicitlyAbandoned),
                    explicitlyAbandoned.status.rawValue,
                    try ClientStoreCoding.milliseconds(explicitlyAbandoned.generationExpiresAt),
                    explicitlyAbandoned.blockReason?.rawValue,
                    try ClientStoreCoding.milliseconds(timestamp),
                    currentUploadID.description,
                ]
            )
        }

        let replacementBoundary: Date
        switch superseded.status {
        case .abandoned:
            guard let terminalAt = superseded.terminalAt else {
                throw ClientStoreError.corruptStoredValue(field: "abandonedUploadTerminalAt")
            }
            replacementBoundary = terminalAt
        case .active:
            guard try superseded.leaseState(at: timestamp) == .expired else {
                throw ClientStoreError.uploadRebindNotAllowed(
                    current: currentUploadID,
                    presented: replacement.uploadID
                )
            }
            replacementBoundary = superseded.generationExpiresAt
        case .conflictBlocked, .committed:
            throw ClientStoreError.uploadRebindNotAllowed(
                current: currentUploadID,
                presented: replacement.uploadID
            )
        }
        let validReplacementOrdering = superseded.status == .abandoned
            ? replacement.firstBeganAt > replacementBoundary
            : replacement.firstBeganAt >= replacementBoundary
        guard validReplacementOrdering else {
            throw ClientStoreError.uploadRebindNotAllowed(
                current: currentUploadID,
                presented: replacement.uploadID
            )
        }
    }

    private func validateUploadProgress(
        from existing: UploadAttempt,
        to presented: UploadAttempt
    ) throws {
        let persistedDescriptors = existing.declarations.descriptors
        let presentedDescriptors = presented.declarations.descriptors
        guard presentedDescriptors.count >= persistedDescriptors.count,
              Array(presentedDescriptors.prefix(persistedDescriptors.count)) == persistedDescriptors else {
            throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
        }
        if existing.declarations.status != .open {
            guard presented.declarations == existing.declarations else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
        }
        if let manifest = existing.boundManifest {
            guard presented.boundManifest == manifest,
                  presented.boundHostTrust == existing.boundHostTrust,
                  presented.boundFinalizedCapture == existing.boundFinalizedCapture else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
        }
        if let terminalAt = existing.terminalAt {
            guard presented.terminalAt == terminalAt else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
        }

        let permittedStatus: Bool
        switch existing.status {
        case .active:
            permittedStatus = [.active, .conflictBlocked, .abandoned].contains(presented.status)
        case .conflictBlocked:
            permittedStatus = [.conflictBlocked, .abandoned].contains(presented.status)
        case .abandoned:
            permittedStatus = presented.status == .abandoned
        case .committed:
            permittedStatus = false
        }
        guard permittedStatus else {
            throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
        }

        if presented.generation == existing.generation {
            guard presented.generationBeganAt == existing.generationBeganAt,
                  presented.generationExpiresAt == existing.generationExpiresAt else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
        } else {
            // Reopen changes only the lease generation/times. Immutable
            // declarations and any final-manifest binding must survive exactly.
            guard existing.status == .active,
                  presented.status == .active,
                  presented.declarations == existing.declarations,
                  presented.boundHostTrust == existing.boundHostTrust,
                  presented.boundManifest == existing.boundManifest,
                  presented.boundFinalizedCapture == existing.boundFinalizedCapture else {
                throw ClientStoreError.uploadAlreadyExistsWithDifferentFacts
            }
        }
    }

    private func chunks(uploadID: UploadID, in db: Database) throws -> [StoredUploadChunk] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM upload_chunks WHERE upload_id = ? ORDER BY chunk_index",
            arguments: [uploadID.description]
        )
        return try rows.map { row in
            guard let fileState = LocalTransferArtifactState(rawValue: row["file_state"] as String) else {
                throw ClientStoreError.corruptStoredValue(field: "chunkFileState")
            }
            let descriptor: LogicalChunkDescriptor = try ClientStoreCoding.decode(
                LogicalChunkDescriptor.self,
                from: row["descriptor_json"],
                field: "chunkDescriptor"
            )
            let ackHash = try (row["durable_ack_sha256"] as Data?).map(ExactObjectSHA256.init)
            return StoredUploadChunk(
                uploadID: uploadID,
                descriptor: descriptor,
                encodedFileURL: URL(fileURLWithPath: row["encoded_path"]),
                fileState: fileState,
                stateMachine: try ClientStoreCoding.decode(
                    ChunkOutboxStateMachine.self,
                    from: row["state_machine_json"],
                    field: "chunkOutbox"
                ),
                durableACK: try ackHash.flatMap { try exactObject(sha256: $0, in: db) },
                updatedAt: ClientStoreCoding.date(milliseconds: row["updated_at_ms"])
            )
        }
    }

    private func persistChunkMachine(
        _ machine: ChunkOutboxStateMachine,
        uploadID: UploadID,
        chunkIndex: UInt32,
        in db: Database,
        updatedAtMS: Int64? = nil
    ) throws {
        try db.execute(
            sql: """
                UPDATE upload_chunks
                SET outbox_state = ?, state_machine_json = ?, updated_at_ms = ?
                WHERE upload_id = ? AND chunk_index = ?
                """,
            arguments: [
                machine.state.rawValue,
                try ClientStoreCoding.encode(machine),
                updatedAtMS ?? (try ClientStoreCoding.milliseconds(now())),
                uploadID.description,
                Int64(chunkIndex),
            ]
        )
    }

    private func persistExactObject(
        _ object: OpaqueExactObjectSlot,
        persistedAt: Date,
        in db: Database
    ) throws {
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT kind, exact_bytes FROM exact_objects WHERE object_sha256 = ?",
            arguments: [object.objectSHA256.rawBytes]
        ) {
            guard (row["kind"] as String) == object.kind.rawValue,
                  (row["exact_bytes"] as Data) == object.exactBytes else {
                throw ClientStoreError.exactObjectEquivocation
            }
            return
        }
        try db.execute(
            sql: """
                INSERT INTO exact_objects(object_sha256, kind, exact_bytes, persisted_at_ms)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                object.objectSHA256.rawBytes,
                object.kind.rawValue,
                object.exactBytes,
                try ClientStoreCoding.milliseconds(persistedAt),
            ]
        )
    }

    private func exactObject(
        sha256: ExactObjectSHA256,
        in db: Database
    ) throws -> OpaqueExactObjectSlot? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT kind, exact_bytes FROM exact_objects WHERE object_sha256 = ?",
            arguments: [sha256.rawBytes]
        ) else { return nil }
        guard let kind = ExactObjectKind(rawValue: row["kind"] as String) else {
            throw ClientStoreError.corruptStoredValue(field: "exactObjectKind")
        }
        return try OpaqueExactObjectSlot(
            kind: kind,
            exactBytes: row["exact_bytes"],
            objectSHA256: sha256
        )
    }

    private func backgroundBatch(
        id: AudioBatchID,
        in db: Database
    ) throws -> StoredBackgroundBatch? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM upload_batches WHERE batch_id = ?",
            arguments: [id.description]
        ) else { return nil }
        guard
            let fileState = LocalTransferArtifactState(rawValue: row["file_state"] as String),
            let state = BackgroundBatchState(rawValue: row["state"] as String)
        else {
            throw ClientStoreError.corruptStoredValue(field: "backgroundBatchState")
        }
        return StoredBackgroundBatch(
            descriptor: try ClientStoreCoding.decode(
                ImmutableAudioBatchDescriptor.self,
                from: row["descriptor_json"],
                field: "backgroundBatch"
            ),
            bodyFileURL: URL(fileURLWithPath: row["body_path"]),
            bodyFileState: fileState,
            capability: try OpaqueBackgroundCapability(
                credential: row["opaque_capability_credential"],
                capabilityBindings: row["capability_bindings"],
                expiresAt: ClientStoreCoding.date(milliseconds: row["capability_expires_at_ms"])
            ),
            state: state,
            durableACK: try (row["durable_ack_sha256"] as Data?)
                .map(ExactObjectSHA256.init)
                .flatMap { try exactObject(sha256: $0, in: db) },
            updatedAt: ClientStoreCoding.date(milliseconds: row["updated_at_ms"])
        )
    }

    private func taskMappings(in db: Database) throws -> [StoredBackgroundTaskMapping] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM background_task_mappings
                ORDER BY session_identifier, task_identifier
                """
        )
        return try rows.map { row in
            guard
                let batchUUID = UUID(uuidString: row["batch_id"] as String),
                let state = BackgroundTaskMappingState(rawValue: row["state"] as String)
            else {
                throw ClientStoreError.corruptStoredValue(field: "backgroundTaskMapping")
            }
            return StoredBackgroundTaskMapping(
                identity: try SystemBackgroundTaskIdentity(
                    sessionIdentifier: row["session_identifier"],
                    taskIdentifier: row["task_identifier"]
                ),
                batchID: AudioBatchID(batchUUID),
                state: state,
                updatedAt: ClientStoreCoding.date(milliseconds: row["updated_at_ms"])
            )
        }
    }

    private func decodeOrigin(_ row: Row) throws -> OriginRecordingID {
        guard let recordingUUID = UUID(uuidString: row["origin_recording_uuid"] as String) else {
            throw ClientStoreError.corruptStoredValue(field: "originRecordingUUID")
        }
        return OriginRecordingID(
            deviceID: try DeviceID(row["origin_device_id"] as Data),
            recordingUUID: recordingUUID
        )
    }

    private func decodeTransferConflict(_ row: Row) throws -> TransferConflictRecord {
        guard let conflictID = UUID(uuidString: row["conflict_id"] as String) else {
            throw ClientStoreError.corruptStoredValue(field: "transferConflictID")
        }
        let deviceBytes = row["origin_device_id"] as Data?
        let recordingText = row["origin_recording_uuid"] as String?
        let origin: OriginRecordingID?
        switch (deviceBytes, recordingText) {
        case (.none, .none):
            origin = nil
        case (.some(let deviceBytes), .some(let recordingText)):
            guard let recordingUUID = UUID(uuidString: recordingText) else {
                throw ClientStoreError.corruptStoredValue(field: "transferConflictOrigin")
            }
            origin = OriginRecordingID(
                deviceID: try DeviceID(deviceBytes),
                recordingUUID: recordingUUID
            )
        default:
            throw ClientStoreError.corruptStoredValue(field: "transferConflictOrigin")
        }
        let uploadID = (row["upload_id"] as String?)
            .flatMap(UUID.init(uuidString:))
            .map(UploadID.init)
        return try TransferConflictRecord(
            conflictID: conflictID,
            originRecordingID: origin,
            uploadID: uploadID,
            code: row["code"],
            detail: row["detail"],
            localExactBytes: row["local_exact_bytes"],
            remoteExactBytes: row["remote_exact_bytes"],
            createdAt: ClientStoreCoding.date(milliseconds: row["created_at_ms"]),
            resolvedAt: (row["resolved_at_ms"] as Int64?).map(ClientStoreCoding.date)
        )
    }

}
