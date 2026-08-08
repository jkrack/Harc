import Foundation
import GRDB
import HarcDomain
import HarcProtocol
import HarcTransfer

/// Durable, locally cross-checked commit evidence. This read model is
/// intentionally distinct from `ValidatedRecordingReceiptEvidence`: reading a
/// database row does not repeat protobuf parsing or signature verification.
public struct StoredVerifiedRecordingReceipt: Equatable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let exactReceiptObject: OpaqueExactObjectSlot
    public let uploadID: UploadID
    public let originRecordingID: OriginRecordingID
    public let producingDeviceID: DeviceID
    public let exactManifestObject: OpaqueExactObjectSlot
    public let uploadProfileSHA256: UploadProfileSHA256
    public let canonicalPCMSHA256: CanonicalPCMHash
    public let totalCanonicalFrames: UInt64
    public let canonicalFormat: CanonicalPCMFormat
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalRevision: EntityRevision
    public let changeCursor: ChangeCursor
    public let receiptID: UUID
    public let durableCommitTime: Date
    public let processingState: RecordingProcessingState
    public let verifiedAt: Date
}

extension HarcTransferStore {
    /// Atomically turns validator-owned receipt evidence into the only durable
    /// local deletion gate. All authority, installation, attempt, manifest,
    /// profile, and canonical-audio bindings are checked again against SQLite
    /// state before either outbox state or cleanup eligibility changes.
    @discardableResult
    public func persistVerifiedRecordingReceipt(
        _ authenticatedReceipt: HarcAuthenticatedRecordingReceiptV1,
        verifiedAt: Date? = nil
    ) throws -> StoredVerifiedRecordingReceipt {
        let evidence = authenticatedReceipt.evidence
        let timestamp = verifiedAt ?? now()
        let verifiedAtMS = try ClientStoreCoding.milliseconds(timestamp)
        let tuple = AdoptedTrustTuple(
            libraryID: evidence.hostTrust.libraryID,
            hostAuthorityID: evidence.hostTrust.hostAuthorityID
        )

        guard evidence.producingDeviceID == installationDeviceID,
              evidence.originRecordingID.deviceID == installationDeviceID else {
            throw ClientStoreError.captureDeviceMismatch(
                expected: installationDeviceID,
                presented: evidence.producingDeviceID
            )
        }

        return try database.write { db in
            try requireActive(
                tuple,
                authorityPublicKeyX963: evidence.hostTrust.hostAuthorityPublicKeyX963,
                requiredScope: .recordingUploadOwn,
                in: db
            )

            guard let local = try Row.fetchOne(
                db,
                sql: """
                    SELECT u.attempt_json,
                           u.origin_device_id AS attempt_origin_device_id,
                           u.origin_recording_uuid AS attempt_origin_recording_uuid,
                           u.library_id, u.host_authority_id,
                           u.bound_manifest_sha256,
                           u.state AS persisted_attempt_state,
                           fc.finalized_capture_json,
                           ro.upload_id AS outbox_upload_id,
                           ro.state AS persisted_outbox_state,
                           ro.state_machine_json,
                           ro.integrity_block_code,
                           ro.integrity_block_detail
                    FROM upload_attempts u
                    JOIN finalized_captures fc
                      ON fc.origin_device_id = u.origin_device_id
                     AND fc.origin_recording_uuid = u.origin_recording_uuid
                    JOIN recording_outbox ro
                      ON ro.origin_device_id = u.origin_device_id
                     AND ro.origin_recording_uuid = u.origin_recording_uuid
                    WHERE u.upload_id = ?
                    """,
                arguments: [evidence.uploadID.description]
            ) else {
                throw ClientStoreError.missingRow(entity: "upload attempt")
            }

            let capture: FinalizedCapture = try ClientStoreCoding.decode(
                FinalizedCapture.self,
                from: local["finalized_capture_json"],
                field: "finalizedCapture"
            )
            let canonicalCapture = try receiptWireCanonicalCapture(capture)
            var attempt: UploadAttempt = try ClientStoreCoding.decode(
                UploadAttempt.self,
                from: local["attempt_json"],
                field: "uploadAttempt"
            )
            var outbox: RecordingOutboxStateMachine = try ClientStoreCoding.decode(
                RecordingOutboxStateMachine.self,
                from: local["state_machine_json"],
                field: "recordingOutbox"
            )

            try requireVerifiedReceiptBinding(
                (local["attempt_origin_device_id"] as Data) == evidence.originRecordingID.deviceID.rawBytes
                    && (local["attempt_origin_recording_uuid"] as String)
                        == evidence.originRecordingID.recordingUUID.uuidString.lowercased()
                    && capture.originRecordingID == evidence.originRecordingID,
                field: "origin recording"
            )
            try requireVerifiedReceiptBinding(
                (local["outbox_upload_id"] as String?) == evidence.uploadID.description
                    && attempt.uploadID == evidence.uploadID,
                field: "outbox upload"
            )
            try requireVerifiedReceiptBinding(
                (local["library_id"] as String) == tuple.libraryID.description
                    && (local["host_authority_id"] as Data) == tuple.hostAuthorityID.rawBytes
                    && attempt.boundHostTrust == evidence.hostTrust,
                field: "adopted host"
            )
            try requireVerifiedReceiptBinding(
                attempt.ownerDeviceID == installationDeviceID
                    && attempt.originRecordingID == evidence.originRecordingID
                    && capture.producingDeviceID == installationDeviceID,
                field: "installation device"
            )
            try requireVerifiedReceiptBinding(
                attempt.frozenProfile.profileSHA256 == evidence.uploadProfileSHA256,
                field: "upload profile"
            )
            try requireVerifiedReceiptBinding(
                attempt.boundManifest == evidence.exactManifestObject
                    && (local["bound_manifest_sha256"] as Data?)
                        == evidence.signedManifestObjectSHA256.rawBytes
                    && evidence.signedManifestObjectSHA256
                        == evidence.exactManifestObject.objectSHA256,
                field: "exact signed manifest"
            )
            try requireVerifiedReceiptBinding(
                attempt.boundFinalizedCapture?.capture == canonicalCapture
                    && capture.canonicalPCMSHA256 == evidence.canonicalPCMSHA256
                    && capture.totalCanonicalFrames == evidence.totalCanonicalFrames
                    && capture.canonicalFormat == evidence.canonicalFormat,
                field: "canonical audio"
            )
            try requireVerifiedReceiptBinding(
                (local["persisted_attempt_state"] as String) == attempt.status.rawValue
                    && (local["persisted_outbox_state"] as String) == outbox.state.rawValue,
                field: "state machine"
            )
            try requireVerifiedReceiptBinding(
                (local["integrity_block_code"] as String?) == nil
                    && (local["integrity_block_detail"] as String?) == nil,
                field: "local artifact integrity"
            )
            try requireExactManifestRegistryMatch(evidence.exactManifestObject, in: db)

            if let existing = try verifiedRecordingReceipt(
                for: evidence.originRecordingID,
                in: db
            ) {
                guard verifiedReceipt(existing, exactlyMatches: evidence) else {
                    throw ClientStoreError.conflictingVerifiedReceipt(
                        origin: evidence.originRecordingID
                    )
                }
                try requireVerifiedReceiptBinding(
                    attempt.status == .committed
                        && attempt.exactReceipt == evidence.exactReceiptObject
                        && outbox.state == .committed
                        && outbox.exactReceipt == evidence.exactReceiptObject,
                    field: "committed replay"
                )
                try makePersistedCleanupIntentEligible(
                    origin: evidence.originRecordingID,
                    receiptSHA256: evidence.exactReceiptObject.objectSHA256,
                    in: db
                )
                return existing
            }

            if try hasConflictingVerifiedReceiptIdentity(evidence, in: db) {
                throw ClientStoreError.conflictingVerifiedReceipt(
                    origin: evidence.originRecordingID
                )
            }
            try requireVerifiedReceiptBinding(
                attempt.status == .active && outbox.state == .hostCommitPending,
                field: "host-commit-pending transition"
            )

            try persistReceiptExactObject(
                evidence.exactReceiptObject,
                persistedAtMS: verifiedAtMS,
                in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO verified_recording_receipts (
                        origin_device_id, origin_recording_uuid, upload_id,
                        library_id, host_authority_id,
                        authority_public_key_x963, producing_device_id,
                        receipt_object_sha256, exact_receipt_bytes,
                        manifest_object_sha256, upload_profile_sha256,
                        canonical_pcm_sha256, total_canonical_frames,
                        canonical_sample_rate_hz, canonical_channel_count,
                        canonical_pcm_encoding, canonical_recording_id,
                        canonical_revision, change_cursor, receipt_id,
                        durable_commit_time_ms, processing_state, verified_at_ms
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?
                    )
                    """,
                arguments: [
                    evidence.originRecordingID.deviceID.rawBytes,
                    evidence.originRecordingID.recordingUUID.uuidString.lowercased(),
                    evidence.uploadID.description,
                    tuple.libraryID.description,
                    tuple.hostAuthorityID.rawBytes,
                    evidence.hostTrust.hostAuthorityPublicKeyX963,
                    evidence.producingDeviceID.rawBytes,
                    evidence.exactReceiptObject.objectSHA256.rawBytes,
                    evidence.exactReceiptObject.exactBytes,
                    evidence.signedManifestObjectSHA256.rawBytes,
                    evidence.uploadProfileSHA256.rawBytes,
                    evidence.canonicalPCMSHA256.rawBytes,
                    try ClientStoreCoding.sqliteInteger(
                        evidence.totalCanonicalFrames,
                        field: "totalCanonicalFrames"
                    ),
                    Int64(evidence.canonicalFormat.sampleRateHz),
                    Int64(evidence.canonicalFormat.channelCount),
                    evidence.canonicalFormat.encoding.rawValue,
                    evidence.canonicalRecordingID.description,
                    try evidence.canonicalRevision.signedInt64Value(),
                    try evidence.changeCursor.signedInt64Value(),
                    evidence.receiptID.uuidString.lowercased(),
                    try ClientStoreCoding.milliseconds(evidence.durableCommitTime),
                    evidence.processingState.rawValue,
                    verifiedAtMS,
                ]
            )

            try attempt.markCommittedFromAcceptedPublication(
                using: evidence,
                generation: attempt.generation,
                authorizationAcceptedAt: attempt.generationBeganAt,
                committedAt: evidence.durableCommitTime
            )
            try db.execute(
                sql: """
                    UPDATE upload_attempts
                    SET attempt_json = ?, state = ?, terminal_reason = NULL,
                        updated_at_ms = ?
                    WHERE upload_id = ? AND state = 'active'
                    """,
                arguments: [
                    try ClientStoreCoding.encode(attempt),
                    attempt.status.rawValue,
                    verifiedAtMS,
                    evidence.uploadID.description,
                ]
            )
            guard db.changesCount == 1 else {
                throw ClientStoreError.verifiedReceiptBindingMismatch(
                    field: "upload attempt transition"
                )
            }

            try outbox.markCommitted(using: evidence)
            try db.execute(
                sql: """
                    UPDATE recording_outbox
                    SET state = ?, state_machine_json = ?,
                        failure_code = NULL, failure_detail = NULL,
                        updated_at_ms = ?
                    WHERE origin_device_id = ? AND origin_recording_uuid = ?
                      AND upload_id = ? AND state = 'hostCommitPending'
                      AND integrity_block_code IS NULL
                      AND integrity_block_detail IS NULL
                    """,
                arguments: [
                    outbox.state.rawValue,
                    try ClientStoreCoding.encode(outbox),
                    verifiedAtMS,
                    evidence.originRecordingID.deviceID.rawBytes,
                    evidence.originRecordingID.recordingUUID.uuidString.lowercased(),
                    evidence.uploadID.description,
                ]
            )
            guard db.changesCount == 1 else {
                throw ClientStoreError.verifiedReceiptBindingMismatch(
                    field: "recording outbox transition"
                )
            }

            try makePersistedCleanupIntentEligible(
                origin: evidence.originRecordingID,
                receiptSHA256: evidence.exactReceiptObject.objectSHA256,
                in: db
            )
            guard let stored = try verifiedRecordingReceipt(
                for: evidence.originRecordingID,
                in: db
            ) else {
                throw ClientStoreError.missingRow(entity: "verified recording receipt")
            }
            return stored
        }
    }

    public func verifiedRecordingReceipt(
        for origin: OriginRecordingID
    ) throws -> StoredVerifiedRecordingReceipt? {
        try database.read { db in
            try verifiedRecordingReceipt(for: origin, in: db)
        }
    }

    private func requireVerifiedReceiptBinding(
        _ condition: @autoclosure () -> Bool,
        field: String
    ) throws {
        guard condition() else {
            throw ClientStoreError.verifiedReceiptBindingMismatch(field: field)
        }
    }

    private func requireExactManifestRegistryMatch(
        _ manifest: OpaqueExactObjectSlot,
        in db: Database
    ) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT kind, exact_bytes FROM exact_objects
                WHERE object_sha256 = ?
                """,
            arguments: [manifest.objectSHA256.rawBytes]
        ) else {
            throw ClientStoreError.missingRow(entity: "bound exact manifest")
        }
        try requireVerifiedReceiptBinding(
            (row["kind"] as String) == ExactObjectKind.recordingManifestV1.rawValue
                && (row["exact_bytes"] as Data) == manifest.exactBytes,
            field: "exact manifest registry"
        )
    }

    private func persistReceiptExactObject(
        _ receipt: OpaqueExactObjectSlot,
        persistedAtMS: Int64,
        in db: Database
    ) throws {
        guard receipt.kind == .recordingReceiptV1 else {
            throw ClientStoreError.verifiedReceiptBindingMismatch(
                field: "receipt object kind"
            )
        }
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT kind, exact_bytes FROM exact_objects WHERE object_sha256 = ?",
            arguments: [receipt.objectSHA256.rawBytes]
        ) {
            guard (row["kind"] as String) == receipt.kind.rawValue,
                  (row["exact_bytes"] as Data) == receipt.exactBytes else {
                throw ClientStoreError.exactObjectEquivocation
            }
            return
        }
        try db.execute(
            sql: """
                INSERT INTO exact_objects (
                    object_sha256, kind, exact_bytes, persisted_at_ms
                ) VALUES (?, ?, ?, ?)
                """,
            arguments: [
                receipt.objectSHA256.rawBytes,
                receipt.kind.rawValue,
                receipt.exactBytes,
                persistedAtMS,
            ]
        )
    }

    private func hasConflictingVerifiedReceiptIdentity(
        _ evidence: ValidatedRecordingReceiptEvidence,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM verified_recording_receipts
                    WHERE upload_id = ? OR receipt_object_sha256 = ? OR receipt_id = ?
                )
                """,
            arguments: [
                evidence.uploadID.description,
                evidence.exactReceiptObject.objectSHA256.rawBytes,
                evidence.receiptID.uuidString.lowercased(),
            ]
        ) ?? false
    }

    private func makePersistedCleanupIntentEligible(
        origin: OriginRecordingID,
        receiptSHA256: ExactObjectSHA256,
        in db: Database
    ) throws {
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT state, verified_receipt_sha256
                FROM cleanup_intents
                WHERE origin_device_id = ? AND origin_recording_uuid = ?
                """,
            arguments: [
                origin.deviceID.rawBytes,
                origin.recordingUUID.uuidString.lowercased(),
            ]
        ) {
            let state = row["state"] as String
            let storedHash = row["verified_receipt_sha256"] as Data?
            switch state {
            case "awaitingVerifiedReceipt":
                guard storedHash == nil else {
                    throw ClientStoreError.corruptStoredValue(field: "cleanupIntent")
                }
                try db.execute(
                    sql: """
                        UPDATE cleanup_intents
                        SET state = 'eligible', verified_receipt_sha256 = ?
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                          AND state = 'awaitingVerifiedReceipt'
                          AND verified_receipt_sha256 IS NULL
                        """,
                    arguments: [
                        receiptSHA256.rawBytes,
                        origin.deviceID.rawBytes,
                        origin.recordingUUID.uuidString.lowercased(),
                    ]
                )
                guard db.changesCount == 1 else {
                    throw ClientStoreError.corruptStoredValue(field: "cleanupIntent")
                }
            case "eligible":
                guard storedHash == receiptSHA256.rawBytes else {
                    throw ClientStoreError.conflictingVerifiedReceipt(origin: origin)
                }
            default:
                throw ClientStoreError.corruptStoredValue(field: "cleanupIntentState")
            }
        }
    }

    private func verifiedRecordingReceipt(
        for origin: OriginRecordingID,
        in db: Database
    ) throws -> StoredVerifiedRecordingReceipt? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT vr.*,
                       receipt.kind AS receipt_registry_kind,
                       receipt.exact_bytes AS receipt_registry_bytes,
                       manifest.kind AS manifest_registry_kind,
                       manifest.exact_bytes AS manifest_registry_bytes
                FROM verified_recording_receipts vr
                JOIN exact_objects receipt
                  ON receipt.object_sha256 = vr.receipt_object_sha256
                JOIN exact_objects manifest
                  ON manifest.object_sha256 = vr.manifest_object_sha256
                WHERE vr.origin_device_id = ? AND vr.origin_recording_uuid = ?
                """,
            arguments: [
                origin.deviceID.rawBytes,
                origin.recordingUUID.uuidString.lowercased(),
            ]
        ) else { return nil }

        do {
            guard let libraryUUID = UUID(uuidString: row["library_id"] as String),
                  let uploadUUID = UUID(uuidString: row["upload_id"] as String),
                  let originUUID = UUID(uuidString: row["origin_recording_uuid"] as String),
                  let canonicalUUID = UUID(uuidString: row["canonical_recording_id"] as String),
                  let receiptID = UUID(uuidString: row["receipt_id"] as String),
                  let encoding = CanonicalPCMEncoding(
                    rawValue: row["canonical_pcm_encoding"] as String
                  ),
                  let processing = RecordingProcessingState(
                    rawValue: row["processing_state"] as String
                  ),
                  (row["receipt_registry_kind"] as String)
                    == ExactObjectKind.recordingReceiptV1.rawValue,
                  (row["manifest_registry_kind"] as String)
                    == ExactObjectKind.recordingManifestV1.rawValue,
                  (row["receipt_registry_bytes"] as Data)
                    == (row["exact_receipt_bytes"] as Data),
                  let sampleRate = UInt32(
                    exactly: row["canonical_sample_rate_hz"] as Int64
                  ),
                  let channelCount = UInt16(
                    exactly: row["canonical_channel_count"] as Int64
                  ) else {
                throw ClientStoreError.corruptStoredValue(
                    field: "verifiedRecordingReceipt"
                )
            }

            let hostTrust = try RecordingHostTrustBinding(
                libraryID: LibraryID(libraryUUID),
                hostAuthorityID: HostAuthorityID(row["host_authority_id"] as Data),
                hostAuthorityPublicKeyX963: row["authority_public_key_x963"] as Data
            )
            let receiptHash = try ExactObjectSHA256(
                row["receipt_object_sha256"] as Data
            )
            let manifestHash = try ExactObjectSHA256(
                row["manifest_object_sha256"] as Data
            )
            let persistedOrigin = OriginRecordingID(
                deviceID: try DeviceID(row["origin_device_id"] as Data),
                recordingUUID: originUUID
            )
            let format = try CanonicalPCMFormat(
                sampleRateHz: sampleRate,
                channelCount: channelCount,
                encoding: encoding
            )

            return StoredVerifiedRecordingReceipt(
                hostTrust: hostTrust,
                exactReceiptObject: try OpaqueExactObjectSlot(
                    kind: .recordingReceiptV1,
                    exactBytes: row["exact_receipt_bytes"],
                    objectSHA256: receiptHash
                ),
                uploadID: UploadID(uploadUUID),
                originRecordingID: persistedOrigin,
                producingDeviceID: try DeviceID(row["producing_device_id"] as Data),
                exactManifestObject: try OpaqueExactObjectSlot(
                    kind: .recordingManifestV1,
                    exactBytes: row["manifest_registry_bytes"],
                    objectSHA256: manifestHash
                ),
                uploadProfileSHA256: try UploadProfileSHA256(
                    row["upload_profile_sha256"] as Data
                ),
                canonicalPCMSHA256: try CanonicalPCMHash(
                    row["canonical_pcm_sha256"] as Data
                ),
                totalCanonicalFrames: try ClientStoreCoding.unsigned(
                    row["total_canonical_frames"] as Int64,
                    field: "totalCanonicalFrames"
                ),
                canonicalFormat: format,
                canonicalRecordingID: CanonicalRecordingID(canonicalUUID),
                canonicalRevision: try EntityRevision(
                    signedValue: row["canonical_revision"] as Int64
                ),
                changeCursor: try ChangeCursor(
                    signedValue: row["change_cursor"] as Int64
                ),
                receiptID: receiptID,
                durableCommitTime: ClientStoreCoding.date(
                    milliseconds: row["durable_commit_time_ms"] as Int64
                ),
                processingState: processing,
                verifiedAt: ClientStoreCoding.date(
                    milliseconds: row["verified_at_ms"] as Int64
                )
            )
        } catch let error as ClientStoreError {
            throw error
        } catch {
            throw ClientStoreError.corruptStoredValue(
                field: "verifiedRecordingReceipt"
            )
        }
    }

    private func verifiedReceipt(
        _ stored: StoredVerifiedRecordingReceipt,
        exactlyMatches evidence: ValidatedRecordingReceiptEvidence
    ) -> Bool {
        stored.hostTrust == evidence.hostTrust
            && stored.exactReceiptObject == evidence.exactReceiptObject
            && stored.uploadID == evidence.uploadID
            && stored.originRecordingID == evidence.originRecordingID
            && stored.producingDeviceID == evidence.producingDeviceID
            && stored.exactManifestObject == evidence.exactManifestObject
            && stored.uploadProfileSHA256 == evidence.uploadProfileSHA256
            && stored.canonicalPCMSHA256 == evidence.canonicalPCMSHA256
            && stored.totalCanonicalFrames == evidence.totalCanonicalFrames
            && stored.canonicalFormat == evidence.canonicalFormat
            && stored.canonicalRecordingID == evidence.canonicalRecordingID
            && stored.canonicalRevision == evidence.canonicalRevision
            && stored.changeCursor == evidence.changeCursor
            && stored.receiptID == evidence.receiptID
            && stored.durableCommitTime == evidence.durableCommitTime
            && stored.processingState == evidence.processingState
    }
}

private func receiptWireCanonicalCapture(
    _ capture: FinalizedCapture
) throws -> FinalizedCapture {
    func canonicalDate(_ value: Date) throws -> Date {
        ClientStoreCoding.date(
            milliseconds: try ClientStoreCoding.milliseconds(value)
        )
    }

    let discontinuities = try capture.discontinuities.map { discontinuity in
        try CaptureDiscontinuity(
            recordingID: discontinuity.recordingID,
            monotonicTimeNanoseconds:
                discontinuity.monotonicTimeNanoseconds,
            wallTime: canonicalDate(discontinuity.wallTime),
            reason: discontinuity.reason,
            oldRoute: discontinuity.oldRoute,
            newRoute: discontinuity.newRoute,
            affectedFrames: discontinuity.affectedFrames,
            canonicalizationPolicy: discontinuity.canonicalizationPolicy
        )
    }
    return try FinalizedCapture(
        producingDeviceID: capture.producingDeviceID,
        originRecordingID: capture.originRecordingID,
        captureStartedAt: canonicalDate(capture.captureStartedAt),
        captureEndedAt: canonicalDate(capture.captureEndedAt),
        captureStartedMonotonicNanoseconds:
            capture.captureStartedMonotonicNanoseconds,
        captureEndedMonotonicNanoseconds:
            capture.captureEndedMonotonicNanoseconds,
        finalizationReason: capture.finalizationReason,
        canonicalFormat: capture.canonicalFormat,
        totalCanonicalFrames: capture.totalCanonicalFrames,
        totalCanonicalBytes: capture.totalCanonicalBytes,
        canonicalPCMSHA256: capture.canonicalPCMSHA256,
        discontinuities: discontinuities
    )
}
