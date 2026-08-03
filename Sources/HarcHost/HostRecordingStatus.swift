import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcTransfer

/// The two V1 lookup forms accepted by `GetRecordingStatus`.
public enum HostRecordingStatusKey: Equatable, Hashable, Sendable {
    case uploadID(UploadID)
    case originRecordingID(OriginRecordingID)
}

/// Transport-neutral projection of `RecordingIngestStateV1`.
public enum HostRecordingIngestState: String, Codable, CaseIterable, Sendable {
    case receiving
    case manifestVerified
    case assembling
    case audioPublished
    case recordingCommitted
    case receipted
    case processing
    case complete
    case failedRecoverable
    case abandoned
    case expired
    case conflictBlocked
}

/// Authenticated, path-free status returned to a paired upload owner.
public struct HostRecordingStatusResult: Equatable, Sendable {
    public let uploadID: UploadID
    public let originRecordingID: OriginRecordingID
    public let ingestState: HostRecordingIngestState
    public let processing: ProcessingDescriptor?
    public let canonicalRecordingID: CanonicalRecordingID?
    public let canonicalRecordingRevision: EntityRevision?
    public let exactRecordingReceipt: OpaqueExactObjectSlot?

    public init(
        uploadID: UploadID,
        originRecordingID: OriginRecordingID,
        ingestState: HostRecordingIngestState,
        processing: ProcessingDescriptor? = nil,
        canonicalRecordingID: CanonicalRecordingID? = nil,
        canonicalRecordingRevision: EntityRevision? = nil,
        exactRecordingReceipt: OpaqueExactObjectSlot? = nil
    ) throws {
        guard canonicalRecordingRevision == nil || canonicalRecordingID != nil,
              exactRecordingReceipt == nil
                || (canonicalRecordingID != nil && canonicalRecordingRevision != nil),
              exactRecordingReceipt?.kind != .recordingManifestV1,
              exactRecordingReceipt?.kind != .audioBatchAckV1,
              processing == nil || canonicalRecordingID != nil
        else {
            throw HarcHostError.databaseFailure(
                "Recording status carries inconsistent durable evidence."
            )
        }

        switch ingestState {
        case .receiving, .manifestVerified, .abandoned, .expired, .conflictBlocked:
            guard processing == nil,
                  canonicalRecordingID == nil,
                  canonicalRecordingRevision == nil,
                  exactRecordingReceipt == nil
            else {
                throw HarcHostError.databaseFailure(
                    "Pre-publication recording status carries canonical evidence."
                )
            }
        case .assembling:
            guard canonicalRecordingID != nil,
                  canonicalRecordingRevision == nil,
                  exactRecordingReceipt == nil
            else {
                throw HarcHostError.databaseFailure(
                    "Assembling status carries invalid canonical evidence."
                )
            }
        case .audioPublished:
            guard canonicalRecordingID != nil,
                  canonicalRecordingRevision == nil,
                  exactRecordingReceipt == nil
            else {
                throw HarcHostError.databaseFailure(
                    "Published-audio status carries invalid commit evidence."
                )
            }
        case .recordingCommitted:
            guard canonicalRecordingID != nil,
                  canonicalRecordingRevision != nil,
                  exactRecordingReceipt == nil
            else {
                throw HarcHostError.databaseFailure(
                    "Canonical commit status carries invalid receipt evidence."
                )
            }
        case .receipted, .processing, .complete:
            guard canonicalRecordingID != nil,
                  canonicalRecordingRevision != nil,
                  exactRecordingReceipt != nil
            else {
                throw HarcHostError.databaseFailure(
                    "Receipted recording status is missing durable evidence."
                )
            }
        case .failedRecoverable:
            // Recovery can begin at any publication checkpoint. The general
            // dependency guards above permit only the evidence actually made
            // durable before that failure.
            break
        }

        self.uploadID = uploadID
        self.originRecordingID = originRecordingID
        self.ingestState = ingestState
        self.processing = processing
        self.canonicalRecordingID = canonicalRecordingID
        self.canonicalRecordingRevision = canonicalRecordingRevision
        self.exactRecordingReceipt = exactRecordingReceipt
    }
}

extension HarcHostStore {
    /// Resolves and authorizes a status lookup in the same HostDB read. The
    /// paired device must currently retain its own upload scope; lookup keys
    /// never bypass owner authorization.
    public func recordingStatus(
        for key: HostRecordingStatusKey,
        context: AuthenticatedDeviceContext
    ) async throws -> HostRecordingStatusResult {
        try await recordingStatus(for: key, context: context, at: now())
    }

    /// Deterministic `@testable` clock seam.
    func recordingStatus(
        for key: HostRecordingStatusKey,
        context: AuthenticatedDeviceContext,
        at date: Date
    ) async throws -> HostRecordingStatusResult {
        try await repairSecurityRegistryOnReopen()
        let queriedAt = date
        return try await dbQueue.read { db in
            let attempt = try self.resolveRecordingStatusAttempt(key, in: db)
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: queriedAt
            )
            guard let uploadRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM uploads WHERE upload_id = ?",
                arguments: [attempt.uploadID.description]
            ) else {
                throw HarcHostError.uploadNotFound
            }
            try self.validateRecordingStatusUploadRow(uploadRow, attempt: attempt)
            let publicationRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [attempt.uploadID.description]
            )
            return try self.makeRecordingStatus(
                attempt: attempt,
                uploadRow: uploadRow,
                publicationRow: publicationRow,
                in: db,
                at: queriedAt
            )
        }
    }

    nonisolated private func resolveRecordingStatusAttempt(
        _ key: HostRecordingStatusKey,
        in db: Database
    ) throws -> UploadAttempt {
        switch key {
        case .uploadID(let uploadID):
            guard let attempt = try fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            return attempt

        case .originRecordingID(let origin):
            let attempts = try Data.fetchAll(
                db,
                sql: """
                    SELECT attempt_json FROM uploads
                    WHERE origin_device_id = ? AND origin_recording_uuid = ?
                    ORDER BY began_at DESC, upload_id
                    """,
                arguments: [
                    origin.deviceID.rawBytes,
                    origin.recordingUUID.uuidString.lowercased(),
                ]
            ).map { try Self.decode(UploadAttempt.self, from: $0) }
            guard !attempts.isEmpty,
                  attempts.allSatisfy({ $0.originRecordingID == origin })
            else {
                throw HarcHostError.uploadNotFound
            }

            let committed = attempts.filter { $0.status == .committed }
            if committed.count == 1 { return committed[0] }
            guard committed.isEmpty else {
                throw HarcHostError.databaseFailure(
                    "An origin recording has multiple committed uploads."
                )
            }
            guard let newest = attempts.first else {
                throw HarcHostError.uploadNotFound
            }
            if attempts.dropFirst().first?.firstBeganAt == newest.firstBeganAt {
                throw HarcHostError.databaseFailure(
                    "An origin recording has ambiguous latest upload attempts."
                )
            }
            return newest
        }
    }

    nonisolated private func validateRecordingStatusUploadRow(
        _ row: Row,
        attempt: UploadAttempt
    ) throws {
        guard row["upload_id"] as String == attempt.uploadID.description,
              row["owner_device_id"] as Data == attempt.ownerDeviceID.rawBytes,
              row["origin_device_id"] as Data
                == attempt.originRecordingID.deviceID.rawBytes,
              row["origin_recording_uuid"] as String
                == attempt.originRecordingID.recordingUUID.uuidString.lowercased(),
              row["attempt_status"] as String == attempt.status.rawValue,
              row["current_generation"] as Int64
                == (try Self.sqliteInteger(
                    attempt.generation.rawValue,
                    field: "uploadGeneration"
                )),
              HostUploadJournalState(rawValue: row["journal_state"] as String) != nil
        else {
            throw HarcHostError.databaseFailure(
                "Recording status upload columns drifted from the preserved attempt."
            )
        }
    }

    nonisolated private func makeRecordingStatus(
        attempt: UploadAttempt,
        uploadRow: Row,
        publicationRow: Row?,
        in db: Database,
        at date: Date
    ) throws -> HostRecordingStatusResult {
        guard let uploadJournalState = HostUploadJournalState(
            rawValue: uploadRow["journal_state"] as String
        ) else {
            throw HarcHostError.databaseFailure("Unknown upload journal state.")
        }
        guard let publicationRow else {
            return try makePrepublicationRecordingStatus(
                attempt: attempt,
                uploadRow: uploadRow,
                uploadJournalState: uploadJournalState,
                at: date
            )
        }
        return try makePublicationRecordingStatus(
            attempt: attempt,
            uploadRow: uploadRow,
            uploadJournalState: uploadJournalState,
            publicationRow: publicationRow,
            in: db
        )
    }

    nonisolated private func makePrepublicationRecordingStatus(
        attempt: UploadAttempt,
        uploadRow: Row,
        uploadJournalState: HostUploadJournalState,
        at date: Date
    ) throws -> HostRecordingStatusResult {
        guard uploadRow["canonical_recording_id"] as String? == nil,
              uploadRow["publication_relative_path"] as String? == nil,
              uploadRow["receipt_object_sha256"] as Data? == nil,
              uploadRow["exact_receipt_bytes"] as Data? == nil,
              attempt.exactReceipt == nil
        else {
            throw HarcHostError.databaseFailure(
                "Pre-publication upload carries canonical or receipt evidence."
            )
        }

        let state: HostRecordingIngestState
        switch attempt.status {
        case .active:
            if try attempt.leaseState(at: date) == .expired {
                guard uploadJournalState == .receiving
                        || uploadJournalState == .manifestVerified else {
                    throw HarcHostError.databaseFailure(
                        "Expired upload has an invalid journal state."
                    )
                }
                state = .expired
            } else if attempt.boundManifest == nil {
                guard uploadJournalState == .receiving else {
                    throw HarcHostError.databaseFailure(
                        "Receiving upload has an invalid journal state."
                    )
                }
                state = .receiving
            } else {
                guard uploadJournalState == .manifestVerified else {
                    throw HarcHostError.databaseFailure(
                        "Manifest-bound upload has an invalid journal state."
                    )
                }
                state = .manifestVerified
            }
        case .conflictBlocked:
            guard uploadJournalState == .conflictBlocked else {
                throw HarcHostError.databaseFailure(
                    "Conflict-blocked upload has an invalid journal state."
                )
            }
            state = .conflictBlocked
        case .abandoned:
            guard uploadJournalState == .abandoned else {
                throw HarcHostError.databaseFailure(
                    "Abandoned upload has an invalid journal state."
                )
            }
            state = .abandoned
        case .committed:
            throw HarcHostError.databaseFailure(
                "Committed upload is missing its publication journal."
            )
        }
        return try HostRecordingStatusResult(
            uploadID: attempt.uploadID,
            originRecordingID: attempt.originRecordingID,
            ingestState: state
        )
    }

    nonisolated private func makePublicationRecordingStatus(
        attempt: UploadAttempt,
        uploadRow: Row,
        uploadJournalState: HostUploadJournalState,
        publicationRow: Row,
        in db: Database
    ) throws -> HostRecordingStatusResult {
        guard attempt.boundManifest != nil,
              let journalState = HostUploadJournalState(
                rawValue: publicationRow["state"] as String
              ),
              uploadJournalState == journalState,
              publicationRow["upload_id"] as String == attempt.uploadID.description
        else {
            throw HarcHostError.databaseFailure(
                "Publication status is missing or conflicts with its upload."
            )
        }

        guard let legacyQuarantined = publicationRow["legacy_quarantined"] as Int64?
        else {
            throw HarcHostError.databaseFailure(
                "Publication status has no quarantine marker."
            )
        }
        if legacyQuarantined == 1 {
            guard journalState == .failedRecoverable else {
                throw HarcHostError.databaseFailure(
                    "Legacy publication status escaped quarantine."
                )
            }
            return try HostRecordingStatusResult(
                uploadID: attempt.uploadID,
                originRecordingID: attempt.originRecordingID,
                ingestState: .failedRecoverable
            )
        }
        guard legacyQuarantined == 0 else {
            throw HarcHostError.databaseFailure("Invalid publication quarantine flag.")
        }

        let effectiveCheckpoint: HostUploadJournalState
        if journalState == .failedRecoverable {
            guard let resumeRaw = publicationRow["resume_state"] as String?,
                  let resume = HostUploadJournalState(rawValue: resumeRaw),
                  Self.isStatusRecoverablePublicationCheckpoint(resume) else {
                throw HarcHostError.databaseFailure(
                    "Recoverable publication status has no valid resume checkpoint."
                )
            }
            effectiveCheckpoint = resume
        } else {
            effectiveCheckpoint = journalState
        }

        guard let canonicalRaw = publicationRow["canonical_recording_id"] as String?,
              let canonicalUUID = UUID(uuidString: canonicalRaw) else {
            throw HarcHostError.databaseFailure(
                "Publication status has no canonical recording identifier."
            )
        }
        let canonicalID = CanonicalRecordingID(canonicalUUID)
        let revision = try (publicationRow["canonical_revision"] as Int64?).map {
            try EntityRevision(signedValue: $0)
        }
        let preparedReceipt = try validatedPreparedStatusReceipt(
            publicationRow: publicationRow,
            uploadRow: uploadRow,
            uploadID: attempt.uploadID,
            in: db
        )
        let artifactIdentity = try Self.canonicalArtifactIdentity(from: publicationRow)

        let finalizedReceipt: OpaqueExactObjectSlot?
        switch effectiveCheckpoint {
        case .receipted, .processing, .complete:
            guard attempt.status == .committed,
                  let exactReceipt = attempt.exactReceipt,
                  preparedReceipt == exactReceipt,
                  revision != nil,
                  uploadRow["canonical_recording_id"] as String? == canonicalID.description
            else {
                throw HarcHostError.databaseFailure(
                    "Receipted publication status is incomplete."
                )
            }
            finalizedReceipt = exactReceipt
        case .assembling, .temporarySynchronized, .audioRenamed, .audioPublished,
                .recordingCommitted, .receiptPrepared:
            guard attempt.status == .active, attempt.exactReceipt == nil else {
                throw HarcHostError.databaseFailure(
                    "Incomplete publication has terminal upload state."
                )
            }
            finalizedReceipt = nil
        case .receiving, .manifestVerified, .failedRecoverable, .abandoned,
                .conflictBlocked:
            throw HarcHostError.databaseFailure(
                "Publication has an invalid effective checkpoint."
            )
        }

        let mappedState: HostRecordingIngestState
        if journalState == .failedRecoverable {
            mappedState = .failedRecoverable
        } else {
            switch effectiveCheckpoint {
            case .assembling, .temporarySynchronized, .audioRenamed:
                mappedState = .assembling
            case .audioPublished:
                mappedState = .audioPublished
            case .recordingCommitted, .receiptPrepared:
                mappedState = .recordingCommitted
            case .receipted:
                mappedState = .receipted
            case .processing:
                mappedState = .processing
            case .complete:
                mappedState = .complete
            case .receiving, .manifestVerified, .failedRecoverable, .abandoned,
                    .conflictBlocked:
                throw HarcHostError.databaseFailure(
                    "Publication has an unmappable checkpoint."
                )
            }
        }

        switch effectiveCheckpoint {
        case .assembling, .temporarySynchronized, .audioRenamed:
            guard revision == nil, preparedReceipt == nil, artifactIdentity == nil,
                  uploadRow["canonical_recording_id"] as String? == nil else {
                throw HarcHostError.databaseFailure(
                    "Pre-commit publication carries canonical commit evidence."
                )
            }
        case .audioPublished:
            guard revision == nil, preparedReceipt == nil, artifactIdentity != nil,
                  uploadRow["canonical_recording_id"] as String? == nil else {
                throw HarcHostError.databaseFailure(
                    "Published audio carries invalid canonical commit evidence."
                )
            }
        case .recordingCommitted:
            guard revision != nil, preparedReceipt == nil, artifactIdentity != nil,
                  uploadRow["canonical_recording_id"] as String? == canonicalID.description else {
                throw HarcHostError.databaseFailure(
                    "Canonical recording commit evidence is incomplete."
                )
            }
        case .receiptPrepared:
            guard revision != nil, preparedReceipt != nil, artifactIdentity != nil,
                  uploadRow["canonical_recording_id"] as String? == canonicalID.description else {
                throw HarcHostError.databaseFailure(
                    "Prepared receipt evidence is incomplete."
                )
            }
        case .receipted, .processing, .complete:
            guard artifactIdentity != nil else {
                throw HarcHostError.databaseFailure(
                    "Receipted recording is missing canonical artifact identity."
                )
            }
        case .receiving, .manifestVerified, .failedRecoverable, .abandoned,
                .conflictBlocked:
            throw HarcHostError.databaseFailure(
                "Publication has an invalid evidence checkpoint."
            )
        }

        return try HostRecordingStatusResult(
            uploadID: attempt.uploadID,
            originRecordingID: attempt.originRecordingID,
            ingestState: mappedState,
            processing: nil,
            canonicalRecordingID: canonicalID,
            canonicalRecordingRevision: revision,
            exactRecordingReceipt: finalizedReceipt
        )
    }

    nonisolated private func validatedPreparedStatusReceipt(
        publicationRow: Row,
        uploadRow: Row,
        uploadID: UploadID,
        in db: Database
    ) throws -> OpaqueExactObjectSlot? {
        let exactBytes = publicationRow["exact_receipt_bytes"] as Data?
        let hashBytes = publicationRow["receipt_object_sha256"] as Data?
        guard (exactBytes == nil) == (hashBytes == nil) else {
            throw HarcHostError.databaseFailure("Publication receipt slot is partial.")
        }
        guard let exactBytes, let hashBytes else {
            guard uploadRow["exact_receipt_bytes"] as Data? == nil,
                  uploadRow["receipt_object_sha256"] as Data? == nil else {
                throw HarcHostError.databaseFailure(
                    "Upload receipt preceded publication receipt preparation."
                )
            }
            return nil
        }
        guard Data(SHA256.hash(data: exactBytes)) == hashBytes,
              uploadRow["exact_receipt_bytes"] as Data? == exactBytes,
              uploadRow["receipt_object_sha256"] as Data? == hashBytes,
              let bound = try Row.fetchOne(
                db,
                sql: """
                    SELECT exact_bytes, object_sha256 FROM bound_exact_objects
                    WHERE upload_id = ? AND object_kind = ?
                    """,
                arguments: [
                    uploadID.description,
                    ExactObjectKind.recordingReceiptV1.rawValue,
                ]
              ),
              bound["exact_bytes"] as Data == exactBytes,
              bound["object_sha256"] as Data == hashBytes
        else {
            throw HarcHostError.databaseFailure(
                "Durable recording receipt evidence is inconsistent."
            )
        }
        return try OpaqueExactObjectSlot(
            kind: .recordingReceiptV1,
            exactBytes: exactBytes,
            objectSHA256: ExactObjectSHA256(hashBytes)
        )
    }

    nonisolated private static func isStatusRecoverablePublicationCheckpoint(
        _ state: HostUploadJournalState
    ) -> Bool {
        switch state {
        case .assembling, .temporarySynchronized, .audioRenamed, .audioPublished,
                .recordingCommitted, .receiptPrepared:
            true
        default:
            false
        }
    }
}
