import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcTransfer

public enum HostBackgroundCapabilityAdmissionError: Error, Equatable, Sendable {
    case credentialRejected
    case capabilityUnavailable
    case requestBindingMismatch(field: String)
    case transportSetEpochRejected(minimum: UInt64, served: UInt64)
    case acknowledgementMismatch(field: String)
}

/// Transport-authenticated request facts. The HTTPS adapter owns header and
/// body parsing; this value contains only the exact facts checked by HostDB.
public struct HostBackgroundCapabilityAdmissionRequest: Equatable, Sendable {
    public let opaqueCapabilityCredential: Data
    public let httpMethod: String
    public let httpPath: String
    public let contentLength: UInt64
    public let claimedExactBodySHA256: ImmutableBatchSHA256
    public let servedTransportSetEpoch: UInt64

    public init(
        opaqueCapabilityCredential: Data,
        httpMethod: String,
        httpPath: String,
        contentLength: UInt64,
        claimedExactBodySHA256: ImmutableBatchSHA256,
        servedTransportSetEpoch: UInt64
    ) {
        self.opaqueCapabilityCredential = opaqueCapabilityCredential
        self.httpMethod = httpMethod
        self.httpPath = httpPath
        self.contentLength = contentLength
        self.claimedExactBodySHA256 = claimedExactBodySHA256
        self.servedTransportSetEpoch = servedTransportSetEpoch
    }
}

/// Immutable authorization returned before an HTTP body is staged. It carries
/// no bearer secret. Construction is kept inside HarcHost so transport code can
/// only return a value that passed the database and live-registry checks.
public struct HostBackgroundBatchAdmission: Equatable, Sendable {
    public let batch: ImmutableAudioBatchDescriptor
    public let httpMethod: String
    public let httpPath: String
    public let contentLength: UInt64
    public let exactBodySHA256: ImmutableBatchSHA256
    public let byteCeiling: UInt64
    public let minimumTransportSetEpoch: UInt64
    public let servedTransportSetEpoch: UInt64
    public let capabilityExpiresAt: Date
    public let admittedAt: Date

    fileprivate let capabilityID: UUID
    fileprivate let credentialBindingSHA256: Data
}

public struct HostBackgroundBatchReplay: Equatable, Sendable {
    public let batch: ImmutableAudioBatchDescriptor
    public let exactAcknowledgementBytes: Data
}

public enum HostBackgroundCapabilityAdmissionDisposition: Equatable, Sendable {
    case receiveBody(HostBackgroundBatchAdmission)
    case exactReplay(HostBackgroundBatchReplay)
}

public enum HostBackgroundCapabilityFinalizationDisposition: Equatable, Sendable {
    case accepted(HostBackgroundBatchReplay)
    case exactReplay(HostBackgroundBatchReplay)
}

private struct ParsedBackgroundCapabilityCredential: Sendable {
    private static let bindingDomain = Data(
        "HARC-UPLOAD-CAPABILITY-V1\0".utf8
    )
    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    let capabilityID: UUID
    let bindingSHA256: Data

    init(exactBytes: Data) throws {
        guard exactBytes.count == 48,
              let capabilityID = HostAuthenticationCrypto.uuid(
                from: Data(exactBytes.prefix(16))
              ),
              capabilityID != Self.zeroUUID else {
            throw HostBackgroundCapabilityAdmissionError.credentialRejected
        }
        var input = Self.bindingDomain
        input.append(exactBytes)
        self.capabilityID = capabilityID
        bindingSHA256 = Data(SHA256.hash(data: input))
    }
}

private struct LoadedBackgroundCapability: Sendable {
    let capabilityID: UUID
    let credentialBindingSHA256: Data
    let descriptor: ImmutableAudioBatchDescriptor
    let httpMethod: String
    let httpPath: String
    let byteCeiling: UInt64
    let minimumTransportSetEpoch: UInt64
    let expiresAt: Date
    let exactAcknowledgementBytes: Data?
}

extension HarcHostStore {
    public func admitBackgroundCapability(
        _ request: HostBackgroundCapabilityAdmissionRequest
    ) async throws -> HostBackgroundCapabilityAdmissionDisposition {
        try await admitBackgroundCapability(request, at: now())
    }

    /// Deterministic `@testable` seam. Production admission always uses Host
    /// time and rechecks the same facts again in finalization.
    func admitBackgroundCapability(
        _ request: HostBackgroundCapabilityAdmissionRequest,
        at admittedAt: Date
    ) async throws -> HostBackgroundCapabilityAdmissionDisposition {
        let credential = try ParsedBackgroundCapabilityCredential(
            exactBytes: request.opaqueCapabilityCredential
        )
        try await repairSecurityRegistryOnReopen()
        let loaded = try await dbQueue.read { db in
            try self.loadAndValidateBackgroundCapability(
                in: db,
                capabilityID: credential.capabilityID,
                expectedCredentialBindingSHA256: credential.bindingSHA256,
                rejectCredentialMismatchAsAuthenticationFailure: true,
                httpMethod: request.httpMethod,
                httpPath: request.httpPath,
                contentLength: request.contentLength,
                exactBodySHA256: request.claimedExactBodySHA256,
                servedTransportSetEpoch: request.servedTransportSetEpoch,
                at: admittedAt
            )
        }
        if let exactAcknowledgementBytes = loaded.exactAcknowledgementBytes {
            return .exactReplay(HostBackgroundBatchReplay(
                batch: loaded.descriptor,
                exactAcknowledgementBytes: exactAcknowledgementBytes
            ))
        }
        return .receiveBody(HostBackgroundBatchAdmission(
            batch: loaded.descriptor,
            httpMethod: loaded.httpMethod,
            httpPath: loaded.httpPath,
            contentLength: request.contentLength,
            exactBodySHA256: loaded.descriptor.exactBodySHA256,
            byteCeiling: loaded.byteCeiling,
            minimumTransportSetEpoch: loaded.minimumTransportSetEpoch,
            servedTransportSetEpoch: request.servedTransportSetEpoch,
            capabilityExpiresAt: loaded.expiresAt,
            admittedAt: admittedAt,
            capabilityID: loaded.capabilityID,
            credentialBindingSHA256: loaded.credentialBindingSHA256
        ))
    }

    /// Atomically performs the second live authorization check and records the
    /// already-durable, authority-authenticated ACK. A competing exact accept
    /// returns the first persisted ACK and never overwrites it.
    public func finalizeBackgroundCapabilityAcceptance(
        _ admission: HostBackgroundBatchAdmission,
        observedBodyLength: UInt64,
        observedBodySHA256: ImmutableBatchSHA256,
        acknowledgement: ValidatedBatchAcknowledgementEvidence
    ) async throws -> HostBackgroundCapabilityFinalizationDisposition {
        try await finalizeBackgroundCapabilityAcceptance(
            admission,
            observedBodyLength: observedBodyLength,
            observedBodySHA256: observedBodySHA256,
            acknowledgement: acknowledgement,
            at: now()
        )
    }

    /// Deterministic `@testable` seam. The checked time remains host-owned.
    func finalizeBackgroundCapabilityAcceptance(
        _ admission: HostBackgroundBatchAdmission,
        observedBodyLength: UInt64,
        observedBodySHA256: ImmutableBatchSHA256,
        acknowledgement: ValidatedBatchAcknowledgementEvidence,
        at checkedAt: Date
    ) async throws -> HostBackgroundCapabilityFinalizationDisposition {
        guard observedBodyLength == admission.contentLength,
              observedBodyLength == admission.batch.exactBodyByteLength,
              observedBodyLength <= admission.byteCeiling else {
            throw HostBackgroundCapabilityAdmissionError
                .requestBindingMismatch(field: "contentLength")
        }
        guard observedBodySHA256 == admission.exactBodySHA256,
              observedBodySHA256 == admission.batch.exactBodySHA256 else {
            throw HostBackgroundCapabilityAdmissionError
                .requestBindingMismatch(field: "exactBodySHA256")
        }
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite,
              checkedAt >= admission.admittedAt else {
            throw HostBackgroundCapabilityAdmissionError.capabilityUnavailable
        }

        try await repairSecurityRegistryOnReopen()
        return try await dbQueue.write { db in
            let loaded = try self.loadAndValidateBackgroundCapability(
                in: db,
                capabilityID: admission.capabilityID,
                expectedCredentialBindingSHA256:
                    admission.credentialBindingSHA256,
                rejectCredentialMismatchAsAuthenticationFailure: false,
                httpMethod: admission.httpMethod,
                httpPath: admission.httpPath,
                contentLength: admission.contentLength,
                exactBodySHA256: admission.exactBodySHA256,
                servedTransportSetEpoch: admission.servedTransportSetEpoch,
                at: checkedAt
            )
            guard loaded.descriptor == admission.batch,
                  loaded.byteCeiling == admission.byteCeiling,
                  loaded.minimumTransportSetEpoch
                    == admission.minimumTransportSetEpoch,
                  loaded.expiresAt == admission.capabilityExpiresAt else {
                throw HostBackgroundCapabilityAdmissionError
                    .capabilityUnavailable
            }
            if let exactAcknowledgementBytes = loaded.exactAcknowledgementBytes {
                return .exactReplay(HostBackgroundBatchReplay(
                    batch: loaded.descriptor,
                    exactAcknowledgementBytes: exactAcknowledgementBytes
                ))
            }

            try self.validateBackgroundAcknowledgement(
                acknowledgement,
                for: loaded.descriptor,
                admittedAt: admission.admittedAt,
                checkedAt: checkedAt
            )
            let exactAcknowledgementBytes =
                acknowledgement.exactAcknowledgementObject.exactBytes
            try db.execute(
                sql: """
                    UPDATE upload_batches
                       SET exact_ack_bytes = ?, state = 'accepted',
                           updated_at = ?
                     WHERE batch_id = ?
                       AND exact_ack_bytes IS NULL
                       AND state = 'awaiting-upload'
                    """,
                arguments: [
                    exactAcknowledgementBytes,
                    Self.unixTime(checkedAt),
                    loaded.descriptor.batchID.description,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure(
                    "The background batch acceptance state changed unexpectedly."
                )
            }
            try db.execute(
                sql: """
                    UPDATE background_capabilities
                       SET state = 'accepted'
                     WHERE capability_id = ?
                       AND state = 'issued'
                       AND invalidated_at IS NULL
                    """,
                arguments: [admission.capabilityID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure(
                    "The background capability acceptance state changed unexpectedly."
                )
            }
            return .accepted(HostBackgroundBatchReplay(
                batch: loaded.descriptor,
                exactAcknowledgementBytes: exactAcknowledgementBytes
            ))
        }
    }

    private nonisolated func loadAndValidateBackgroundCapability(
        in db: Database,
        capabilityID: UUID,
        expectedCredentialBindingSHA256: Data,
        rejectCredentialMismatchAsAuthenticationFailure: Bool,
        httpMethod: String,
        httpPath: String,
        contentLength: UInt64,
        exactBodySHA256: ImmutableBatchSHA256,
        servedTransportSetEpoch: UInt64,
        at checkedAt: Date
    ) throws -> LoadedBackgroundCapability {
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HostBackgroundCapabilityAdmissionError.capabilityUnavailable
        }
        let capabilityIDString = capabilityID.uuidString.lowercased()
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT capability.capability_id AS capability_id,
                       capability.upload_id AS capability_upload_id,
                       capability.batch_id AS capability_batch_id,
                       capability.owner_device_id AS capability_owner_device_id,
                       capability.grant_id AS capability_grant_id,
                       capability.grant_epoch AS capability_grant_epoch,
                       capability.generation AS capability_generation,
                       capability.capability_binding_sha256
                            AS credential_binding_sha256,
                       capability.expires_at AS capability_expires_at,
                       capability.invalidated_at AS capability_invalidated_at,
                       capability.state AS capability_state,
                       capability.created_at AS capability_created_at,
                       binding.capability_id AS binding_capability_id,
                       binding.binding_version AS binding_version,
                       binding.library_id AS binding_library_id,
                       binding.host_authority_id AS binding_host_authority_id,
                       binding.minimum_transport_set_epoch AS binding_minimum_epoch,
                       binding.http_method AS binding_http_method,
                       binding.http_path AS binding_http_path,
                       binding.exact_body_sha256 AS binding_body_sha256,
                       binding.exact_body_length AS binding_body_length,
                       binding.byte_ceiling AS binding_byte_ceiling,
                       binding.issued_at AS binding_issued_at,
                       binding.expires_at AS binding_expires_at,
                       batch.upload_id AS batch_upload_id,
                       batch.owner_device_id AS batch_owner_device_id,
                       batch.generation AS batch_generation,
                       batch.descriptor_json AS batch_descriptor_json,
                       batch.body_sha256 AS batch_body_sha256,
                       batch.body_length AS batch_body_length,
                       batch.exact_ack_bytes AS batch_exact_ack_bytes,
                       batch.state AS batch_state
                  FROM background_capabilities AS capability
                  LEFT JOIN background_capability_bindings AS binding
                    ON binding.capability_id = capability.capability_id
                  LEFT JOIN upload_batches AS batch
                    ON batch.batch_id = capability.batch_id
                 WHERE capability.capability_id = ?
                """,
            arguments: [capabilityIDString]
        )
        let storedCredentialBinding =
            (row?["credential_binding_sha256"] as Data?)
            ?? Data(repeating: 0, count: SHA256.Digest.byteCount)
        let credentialMatches = HostAuthenticationCrypto.constantTimeEqual(
            storedCredentialBinding,
            expectedCredentialBindingSHA256
        )
        guard let row, credentialMatches else {
            if rejectCredentialMismatchAsAuthenticationFailure {
                throw HostBackgroundCapabilityAdmissionError
                    .credentialRejected
            }
            throw HostBackgroundCapabilityAdmissionError
                .capabilityUnavailable
        }

        guard row["capability_id"] as String == capabilityIDString,
              let batchIDString = row["capability_batch_id"] as String?,
              row["binding_capability_id"] as String? == capabilityIDString,
              row["binding_version"] as Int64? == 1,
              let libraryIDString = row["binding_library_id"] as String?,
              let libraryUUID = UUID(uuidString: libraryIDString),
              let authorityBytes = row["binding_host_authority_id"] as Data?,
              let ownerBytes = row["capability_owner_device_id"] as Data?,
              let grantIDString = row["capability_grant_id"] as String?,
              let grantUUID = UUID(uuidString: grantIDString),
              let grantEpochValue = row["capability_grant_epoch"] as Int64?,
              let generationValue = row["capability_generation"] as Int64?,
              let capabilityExpiresValue = row["capability_expires_at"] as Double?,
              let capabilityCreatedValue = row["capability_created_at"] as Double?,
              let capabilityState = row["capability_state"] as String?,
              let minimumEpochValue = row["binding_minimum_epoch"] as Int64?,
              let boundMethod = row["binding_http_method"] as String?,
              let boundPath = row["binding_http_path"] as String?,
              let boundBodyBytes = row["binding_body_sha256"] as Data?,
              let boundBodyLengthValue = row["binding_body_length"] as Int64?,
              let byteCeilingValue = row["binding_byte_ceiling"] as Int64?,
              let bindingIssuedValue = row["binding_issued_at"] as Double?,
              let bindingExpiresValue = row["binding_expires_at"] as Double?,
              let batchUploadID = row["batch_upload_id"] as String?,
              let batchOwnerBytes = row["batch_owner_device_id"] as Data?,
              let batchGenerationValue = row["batch_generation"] as Int64?,
              let descriptorBytes = row["batch_descriptor_json"] as Data?,
              let batchBodyBytes = row["batch_body_sha256"] as Data?,
              let batchBodyLengthValue = row["batch_body_length"] as Int64?,
              let batchState = row["batch_state"] as String? else {
            throw HostBackgroundCapabilityAdmissionError
                .capabilityUnavailable
        }

        let libraryID = LibraryID(libraryUUID)
        let authorityID = try HostAuthorityID(authorityBytes)
        let ownerDeviceID = try DeviceID(ownerBytes)
        let grantID = GrantID(grantUUID)
        let grantEpoch = try GrantEpoch(Self.unsigned(
            grantEpochValue,
            field: "backgroundCapability.grantEpoch"
        ))
        let generation = try UploadGeneration(Self.unsigned(
            generationValue,
            field: "backgroundCapability.generation"
        ))
        let minimumEpoch = try Self.unsigned(
            minimumEpochValue,
            field: "backgroundCapability.minimumTransportSetEpoch"
        )
        let boundBodyLength = try Self.unsigned(
            boundBodyLengthValue,
            field: "backgroundCapability.exactBodyLength"
        )
        let byteCeiling = try Self.unsigned(
            byteCeilingValue,
            field: "backgroundCapability.byteCeiling"
        )
        let capabilityExpiresAt = Self.date(capabilityExpiresValue)
        let capabilityCreatedAt = Self.date(capabilityCreatedValue)
        let bindingIssuedAt = Self.date(bindingIssuedValue)
        let bindingExpiresAt = Self.date(bindingExpiresValue)
        let descriptor = try Self.decode(
            ImmutableAudioBatchDescriptor.self,
            from: descriptorBytes
        )
        let boundBodySHA256 = try ImmutableBatchSHA256(boundBodyBytes)
        let exactAcknowledgementBytes = row["batch_exact_ack_bytes"] as Data?

        guard libraryID == expectedMetadata.libraryID,
              authorityID == expectedMetadata.hostAuthorityID,
              bindingIssuedAt == capabilityCreatedAt,
              bindingExpiresAt == capabilityExpiresAt,
              capabilityCreatedAt.timeIntervalSinceReferenceDate.isFinite,
              capabilityExpiresAt.timeIntervalSinceReferenceDate.isFinite,
              checkedAt >= capabilityCreatedAt,
              checkedAt < capabilityExpiresAt,
              row["capability_invalidated_at"] as Double? == nil,
              capabilityState == "issued" || capabilityState == "accepted" else {
            throw HostBackgroundCapabilityAdmissionError
                .capabilityUnavailable
        }

        guard descriptor.batchID.description == batchIDString,
              descriptor.uploadID.description
                == row["capability_upload_id"] as String,
              descriptor.uploadID.description == batchUploadID,
              descriptor.ownerDeviceID == ownerDeviceID,
              descriptor.ownerDeviceID.rawBytes == batchOwnerBytes,
              descriptor.generation == generation,
              batchGenerationValue == generationValue,
              descriptor.exactBodySHA256 == boundBodySHA256,
              descriptor.exactBodySHA256.rawBytes == batchBodyBytes,
              descriptor.exactBodyByteLength == boundBodyLength,
              batchBodyLengthValue == boundBodyLengthValue,
              byteCeiling == boundBodyLength else {
            throw HarcHostError.databaseFailure(
                "Background capability persistence bindings conflict."
            )
        }

        switch (batchState, exactAcknowledgementBytes) {
        case ("awaiting-upload", nil):
            guard capabilityState == "issued" else {
                throw HarcHostError.databaseFailure(
                    "An accepted capability is missing its exact batch ACK."
                )
            }
        case ("accepted", .some(let bytes)):
            guard !bytes.isEmpty, bytes.count <= 1_048_576 else {
                throw HarcHostError.databaseFailure(
                    "The exact background batch ACK has an invalid size."
                )
            }
        default:
            throw HarcHostError.databaseFailure(
                "Background batch state conflicts with its exact ACK."
            )
        }

        guard httpMethod == boundMethod else {
            throw HostBackgroundCapabilityAdmissionError
                .requestBindingMismatch(field: "httpMethod")
        }
        guard httpPath == boundPath else {
            throw HostBackgroundCapabilityAdmissionError
                .requestBindingMismatch(field: "httpPath")
        }
        guard contentLength == boundBodyLength,
              contentLength <= byteCeiling else {
            throw HostBackgroundCapabilityAdmissionError
                .requestBindingMismatch(field: "contentLength")
        }
        guard exactBodySHA256 == boundBodySHA256 else {
            throw HostBackgroundCapabilityAdmissionError
                .requestBindingMismatch(field: "exactBodySHA256")
        }
        guard servedTransportSetEpoch >= minimumEpoch else {
            throw HostBackgroundCapabilityAdmissionError
                .transportSetEpochRejected(
                    minimum: minimumEpoch,
                    served: servedTransportSetEpoch
                )
        }
        let servedEpoch = try Self.sqliteInteger(
            servedTransportSetEpoch,
            field: "servedTransportSetEpoch"
        )
        guard try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM host_transport_sets WHERE epoch = ?",
            arguments: [servedEpoch]
        ) == 1 else {
            throw HostBackgroundCapabilityAdmissionError
                .transportSetEpochRejected(
                    minimum: minimumEpoch,
                    served: servedTransportSetEpoch
                )
        }

        guard let attempt = try fetchUploadAttempt(
            in: db,
            uploadID: descriptor.uploadID
        ) else {
            throw HarcHostError.uploadNotFound
        }
        try requireUploadProfile(
            descriptor.uploadProfileSHA256,
            for: attempt
        )
        _ = try authorizeInDatabase(
            db,
            context: AuthenticatedDeviceContext(
                libraryID: libraryID,
                hostAuthorityID: authorityID,
                authenticatedDeviceID: ownerDeviceID,
                grantID: grantID,
                grantEpoch: grantEpoch
            ),
            requiredScope: .recordingUploadOwn,
            objectOwner: attempt.ownerDeviceID,
            at: checkedAt
        )
        try attempt.requireActive(generation: generation, at: checkedAt)
        let declarations = Dictionary(
            uniqueKeysWithValues: attempt.declarations.descriptors.map {
                ($0.chunkIndex, $0)
            }
        )
        guard attempt.ownerDeviceID == descriptor.ownerDeviceID,
              attempt.originRecordingID == descriptor.originRecordingID,
              descriptor.chunks.allSatisfy({ declarations[$0.chunkIndex] == $0 })
        else {
            throw HarcHostError.databaseFailure(
                "Background batch descriptor conflicts with its live upload."
            )
        }

        return LoadedBackgroundCapability(
            capabilityID: capabilityID,
            credentialBindingSHA256: storedCredentialBinding,
            descriptor: descriptor,
            httpMethod: boundMethod,
            httpPath: boundPath,
            byteCeiling: byteCeiling,
            minimumTransportSetEpoch: minimumEpoch,
            expiresAt: capabilityExpiresAt,
            exactAcknowledgementBytes: exactAcknowledgementBytes
        )
    }

    private nonisolated func validateBackgroundAcknowledgement(
        _ acknowledgement: ValidatedBatchAcknowledgementEvidence,
        for descriptor: ImmutableAudioBatchDescriptor,
        admittedAt: Date,
        checkedAt: Date
    ) throws {
        let expectedChunks = descriptor.chunks.map {
            DurableChunkStatus(
                chunkIndex: $0.chunkIndex,
                chunkID: $0.chunkID,
                encodedSHA256: $0.encodedSHA256
            )
        }
        guard acknowledgement.hostTrust.libraryID
                == expectedMetadata.libraryID,
              acknowledgement.hostTrust.hostAuthorityID
                == expectedMetadata.hostAuthorityID,
              acknowledgement.batchID == descriptor.batchID,
              acknowledgement.uploadID == descriptor.uploadID,
              acknowledgement.ownerDeviceID == descriptor.ownerDeviceID,
              acknowledgement.exactBatchBodySHA256
                == descriptor.exactBodySHA256,
              acknowledgement.durableChunks == expectedChunks,
              acknowledgement.durableAt >= admittedAt,
              acknowledgement.durableAt <= checkedAt,
              acknowledgement.exactAcknowledgementObject.kind
                == .audioBatchAckV1,
              !acknowledgement.exactAcknowledgementObject.exactBytes.isEmpty,
              acknowledgement.exactAcknowledgementObject.exactBytes.count
                <= 1_048_576 else {
            throw HostBackgroundCapabilityAdmissionError
                .acknowledgementMismatch(field: "batchAcknowledgement")
        }
    }
}
