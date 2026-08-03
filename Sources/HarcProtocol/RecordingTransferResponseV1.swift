import Foundation
import HarcDomain
import HarcProtocolWire
import HarcTransfer

/// Structural, exact-byte validation of a recording receipt carried by a
/// response. This proves framing, registered type, payload hashing, canonical
/// header structure, and header/payload mirrors. It does not authenticate the
/// host signature; callers still need adopted host trust for that step.
public struct HarcValidatedExactRecordingReceiptV1: Sendable {
    public let exactBytes: Data
    public let objectSHA256: ExactObjectSHA256
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let producingDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let uploadID: UploadID
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalRecordingRevision: EntityRevision
    public let signedManifestObjectSHA256: ExactObjectSHA256
    public let issuedAt: Date

    public var opaqueSlot: OpaqueExactObjectSlot {
        try! OpaqueExactObjectSlot(
            kind: .recordingReceiptV1,
            exactBytes: exactBytes,
            objectSHA256: objectSHA256
        )
    }

    public init(
        exactBytes: Data,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let object = try responseSignedObject(
            exactBytes,
            expectedMessageType: .recordingReceipt,
            expectedPayloadType: .recordingReceipt,
            field: "recordingReceipt",
            compatibility: compatibility
        )
        let exactPayload = try HarcExactProtobufPayload(
            decoding: object.exactPayloadBytes,
            as: Harc_V1_RecordingReceiptV1.self
        )
        let value = exactPayload.message
        let version = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 16),
            field: "recordingReceipt.protocol"
        )
        guard value.hasLibraryID else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.libraryID"
            )
        }
        guard value.hasHostAuthorityID else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.hostAuthorityID"
            )
        }
        guard value.hasProducingDeviceID else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.producingDeviceID"
            )
        }
        guard value.hasOriginRecordingID else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.originRecordingID"
            )
        }
        guard value.hasCanonicalRecordingID else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.canonicalRecordingID"
            )
        }
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.uploadID"
            )
        }
        guard value.hasSignedManifestObjectSha256 else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.signedManifestObjectSHA256"
            )
        }
        guard value.hasCanonicalPcmSha256 else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.canonicalPCMSHA256"
            )
        }
        guard value.totalCanonicalFrames > 0 else {
            throw HarcProtobufConversionError.invalidValue(
                field: "recordingReceipt.totalCanonicalFrames"
            )
        }
        guard value.hasCanonicalFormat else {
            throw HarcProtobufConversionError.missingField(
                "recordingReceipt.canonicalFormat"
            )
        }
        _ = try value.canonicalFormat.domainValue()
        _ = try value.canonicalPcmSha256.validatedBytes(
            field: "recordingReceipt.canonicalPCMSHA256"
        )
        guard value.changeCursor > 0 else {
            throw HarcProtobufConversionError.invalidValue(
                field: "recordingReceipt.changeCursor"
            )
        }
        guard value.hasReceiptID,
              responseNonzeroUUIDBytes(value.receiptID.value) else {
            throw HarcProtobufConversionError.invalidValue(
                field: "recordingReceipt.receiptID"
            )
        }
        guard value.processingState == .recordingProcessingStatePending else {
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "recordingReceipt.processingState",
                rawValue: value.processingState.rawValue
            )
        }

        let libraryID = try value.libraryID.domainValue()
        let hostAuthorityID = try value.hostAuthorityID.domainValue()
        let producingDeviceID = try value.producingDeviceID.domainValue()
        let originRecordingID = try value.originRecordingID.domainValue()
        let uploadID = try value.uploadID.domainValue()
        let canonicalRecordingID = try value.canonicalRecordingID.domainValue()
        guard originRecordingID.deviceID == producingDeviceID else {
            throw HarcProtobufConversionError.inconsistentField(
                "recordingReceipt.producingDeviceID"
            )
        }
        guard canonicalRecordingID.rawValue != HarcSignedEnvelopeV1.zeroUUID else {
            throw HarcProtobufConversionError.invalidValue(
                field: "recordingReceipt.canonicalRecordingID"
            )
        }
        let revision: EntityRevision
        do {
            revision = try EntityRevision(value.canonicalRecordingRevision)
        } catch {
            throw HarcProtobufConversionError.invalidValue(
                field: "recordingReceipt.canonicalRecordingRevision"
            )
        }
        let manifestSHA256 = try ExactObjectSHA256(
            value.signedManifestObjectSha256.validatedBytes(
                field: "recordingReceipt.signedManifestObjectSHA256"
            )
        )
        let issuedAt = try responseDate(
            value.issuedAtUnixMs,
            field: "recordingReceipt.issuedAt"
        )
        guard object.header.protocolVersion == version,
              object.header.libraryID == libraryID,
              object.header.hostAuthorityID == hostAuthorityID,
              object.header.issuedAtUnixMilliseconds == value.issuedAtUnixMs,
              object.header.operationID == uploadID.rawValue else {
            throw HarcProtobufConversionError.inconsistentField(
                "recordingReceipt.signedEnvelope"
            )
        }

        self.exactBytes = exactBytes
        self.objectSHA256 = object.objectID
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.producingDeviceID = producingDeviceID
        self.originRecordingID = originRecordingID
        self.uploadID = uploadID
        self.canonicalRecordingID = canonicalRecordingID
        self.canonicalRecordingRevision = revision
        self.signedManifestObjectSHA256 = manifestSHA256
        self.issuedAt = issuedAt
    }
}

/// Structural exact-byte validation of the transport-set object accompanying
/// a background capability. Signature authentication remains the pinned host
/// trust layer's responsibility.
public struct HarcValidatedExactHostTransportSetV1: Sendable {
    public let exactBytes: Data
    public let objectSHA256: ExactObjectSHA256
    public let transportSet: HostTransportSetV1

    public init(
        exactBytes: Data,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let object = try responseSignedObject(
            exactBytes,
            expectedMessageType: .hostTransportSet,
            expectedPayloadType: .hostTransportSet,
            field: "hostTransportSet",
            compatibility: compatibility
        )
        let transportSet = try HostTransportSetV1.decode(
            object.exactPayloadBytes,
            versionPolicy: compatibility.versionPolicy
        )
        guard object.header.protocolVersion == transportSet.protocolVersion,
              object.header.libraryID == transportSet.libraryID,
              object.header.hostAuthorityID == transportSet.hostAuthorityID,
              object.header.issuedAtUnixMilliseconds
                == transportSet.issuedAtUnixMilliseconds else {
            throw HarcProtobufConversionError.inconsistentField(
                "hostTransportSet.signedEnvelope"
            )
        }
        self.exactBytes = exactBytes
        self.objectSHA256 = object.objectID
        self.transportSet = transportSet
    }
}

public enum HarcBeginUploadResponseDispositionV1: Equatable, Sendable {
    case created
    case exactReplay
    case reopened
    case alreadyCommitted
}

public struct HarcValidatedBeginUploadResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let disposition: HarcBeginUploadResponseDispositionV1
    public let uploadID: UploadID
    public let generation: UploadGeneration?
    public let generationExpiresAt: Date?
    public let uploadProfileSHA256: UploadProfileSHA256
    public let existingCanonicalRecordingID: CanonicalRecordingID?
    public let existingReceipt: HarcValidatedExactRecordingReceiptV1?
    public let reconciliation: HarcValidatedReconcileUploadResponseV1?

    public init(
        _ value: Harc_V1_BeginUploadResponseV1,
        expectedRequest: HarcValidatedBeginUploadRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 9),
            field: "beginUploadResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "beginUploadResponse.uploadID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "beginUploadResponse.uploadProfileSHA256"
            )
        }
        let uploadID = try value.uploadID.domainValue()
        let profileSHA256 = try UploadProfileSHA256(
            value.uploadProfileSha256.validatedBytes(
                field: "beginUploadResponse.uploadProfileSHA256"
            )
        )
        if let expectedRequest {
            guard uploadID == expectedRequest.uploadID else {
                throw HarcProtobufConversionError.inconsistentField(
                    "beginUploadResponse.uploadID"
                )
            }
            guard profileSHA256 == expectedRequest.frozenProfile.profileSHA256 else {
                throw HarcProtobufConversionError.inconsistentField(
                    "beginUploadResponse.uploadProfileSHA256"
                )
            }
        }

        let existingCanonicalID = try value.hasExistingCanonicalRecordingID
            ? value.existingCanonicalRecordingID.domainValue()
            : nil
        let existingReceipt = try value.hasExactExistingReceipt
            ? HarcValidatedExactRecordingReceiptV1(
                exactBytes: value.exactExistingReceipt.framedBytes,
                compatibility: compatibility
            )
            : nil

        let disposition: HarcBeginUploadResponseDispositionV1
        let generation: UploadGeneration?
        let expiresAt: Date?
        let reconciliation: HarcValidatedReconcileUploadResponseV1?
        switch value.disposition {
        case .beginUploadDispositionCreated,
             .beginUploadDispositionExactReplay,
             .beginUploadDispositionReopened:
            guard !value.hasExistingCanonicalRecordingID,
                  !value.hasExactExistingReceipt,
                  value.hasReconciliation else {
                throw HarcProtobufConversionError.inconsistentField(
                    "beginUploadResponse.dispositionEvidence"
                )
            }
            generation = try responseGeneration(
                value.uploadGeneration,
                field: "beginUploadResponse.uploadGeneration"
            )
            expiresAt = try responseDate(
                value.generationExpiresAtUnixMs,
                field: "beginUploadResponse.generationExpiresAt"
            )
            let nested = try HarcValidatedReconcileUploadResponseV1(
                value.reconciliation,
                compatibility: compatibility
            )
            guard nested.uploadID == uploadID,
                  nested.uploadProfileSHA256 == profileSHA256,
                  nested.generation == generation,
                  nested.generationExpiresAt == expiresAt,
                  nested.terminalReason == nil,
                  nested.existingReceipt == nil else {
                throw HarcProtobufConversionError.inconsistentField(
                    "beginUploadResponse.reconciliation"
                )
            }
            reconciliation = nested
            switch value.disposition {
            case .beginUploadDispositionCreated: disposition = .created
            case .beginUploadDispositionExactReplay: disposition = .exactReplay
            case .beginUploadDispositionReopened: disposition = .reopened
            default: preconditionFailure("exhaustive active disposition")
            }

        case .beginUploadDispositionAlreadyCommitted:
            guard value.uploadGeneration == 0,
                  value.generationExpiresAtUnixMs == 0,
                  !value.hasReconciliation,
                  let existingReceipt else {
                throw HarcProtobufConversionError.inconsistentField(
                    "beginUploadResponse.alreadyCommittedEvidence"
                )
            }
            guard existingReceipt.uploadID == uploadID,
                  existingCanonicalID == nil
                    || existingCanonicalID == existingReceipt.canonicalRecordingID else {
                throw HarcProtobufConversionError.inconsistentField(
                    "beginUploadResponse.existingReceipt"
                )
            }
            if let expectedRequest {
                guard existingReceipt.originRecordingID
                        == expectedRequest.originRecordingID else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "beginUploadResponse.existingReceipt.originRecordingID"
                    )
                }
            }
            disposition = .alreadyCommitted
            generation = nil
            expiresAt = nil
            reconciliation = nil

        case .beginUploadDispositionUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "beginUploadResponse.disposition",
                rawValue: value.disposition.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "beginUploadResponse.disposition",
                rawValue: rawValue
            )
        }

        self.protocolVersion = protocolVersion
        self.disposition = disposition
        self.uploadID = uploadID
        self.generation = generation
        self.generationExpiresAt = expiresAt
        self.uploadProfileSHA256 = profileSHA256
        self.existingCanonicalRecordingID = existingCanonicalID
        self.existingReceipt = existingReceipt
        self.reconciliation = reconciliation
    }
}

public enum HarcDeclareChunksResponseDispositionV1: Equatable, Sendable {
    case appended(firstIndex: UInt32, count: UInt32)
    case exactReplay
    case closed
    case conflictBlocked(ChunkDeclarationConflict)
}

public struct HarcValidatedDeclareChunksResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let disposition: HarcDeclareChunksResponseDispositionV1

    public init(
        _ value: Harc_V1_DeclareChunksResponseV1,
        expectedRequest: HarcValidatedDeclareChunksRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 7),
            field: "declareChunksResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "declareChunksResponse.uploadID"
            )
        }
        let uploadID = try value.uploadID.domainValue()
        let generation = try responseGeneration(
            value.uploadGeneration,
            field: "declareChunksResponse.uploadGeneration"
        )
        if let expectedRequest {
            guard uploadID == expectedRequest.uploadID else {
                throw HarcProtobufConversionError.inconsistentField(
                    "declareChunksResponse.uploadID"
                )
            }
            guard generation == expectedRequest.generation else {
                throw HarcProtobufConversionError.inconsistentField(
                    "declareChunksResponse.uploadGeneration"
                )
            }
        }

        let disposition: HarcDeclareChunksResponseDispositionV1
        switch value.disposition {
        case .chunkDeclarationDispositionAppended:
            guard value.hasFirstAppendedIndex,
                  value.hasAppendedCount,
                  value.appendedCount > 0,
                  !value.hasConflict else {
                throw HarcProtobufConversionError.inconsistentField(
                    "declareChunksResponse.appendedEvidence"
                )
            }
            if let expectedRequest {
                guard let offset = expectedRequest.descriptors.firstIndex(
                    where: { $0.chunkIndex == value.firstAppendedIndex }
                ), expectedRequest.descriptors.count - offset
                    == Int(value.appendedCount) else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "declareChunksResponse.appendedRange"
                    )
                }
            }
            disposition = .appended(
                firstIndex: value.firstAppendedIndex,
                count: value.appendedCount
            )

        case .chunkDeclarationDispositionExactReplay:
            try requireNoDeclarationEvidence(value)
            disposition = .exactReplay

        case .chunkDeclarationDispositionClosed:
            try requireNoDeclarationEvidence(value)
            disposition = .closed

        case .chunkDeclarationDispositionConflictBlocked:
            guard !value.hasFirstAppendedIndex,
                  !value.hasAppendedCount,
                  value.hasConflict else {
                throw HarcProtobufConversionError.inconsistentField(
                    "declareChunksResponse.conflictEvidence"
                )
            }
            let conflict = try responseDeclarationConflict(value.conflict)
            if let expectedRequest {
                guard expectedRequest.descriptors.contains(conflict.attempted)
                else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "declareChunksResponse.conflict.attempted"
                    )
                }
            }
            disposition = .conflictBlocked(conflict)

        case .chunkDeclarationDispositionUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "declareChunksResponse.disposition",
                rawValue: value.disposition.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "declareChunksResponse.disposition",
                rawValue: rawValue
            )
        }
        self.protocolVersion = protocolVersion
        self.uploadID = uploadID
        self.generation = generation
        self.disposition = disposition
    }
}

public struct HarcValidatedChunkAcknowledgementV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let durableChunk: DurableChunkStatus
    public let durableAt: Date
}

public enum HarcUploadChunkResponseResultV1: Equatable, Sendable {
    case acknowledgement
    case rejection(RejectedChunkStatus)
}

public struct HarcValidatedUploadChunkResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let result: HarcUploadChunkResponseResultV1
    public let acknowledgement: HarcValidatedChunkAcknowledgementV1?

    public init(
        _ value: Harc_V1_UploadChunkResponseV1,
        expectedRequest: HarcValidatedUploadChunkRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 3),
            field: "uploadChunkResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        switch value.result {
        case .acknowledgement(let value):
            let ackVersion = try responseProtocol(
                value.hasProtocol ? value.protocol : nil,
                compatibility: compatibility,
                knownCriticalFieldNumbers: Set(1 ... 6),
                field: "uploadChunkResponse.acknowledgement.protocol",
                expected: protocolVersion
            )
            guard value.hasUploadID else {
                throw HarcProtobufConversionError.missingField(
                    "uploadChunkResponse.acknowledgement.uploadID"
                )
            }
            guard value.hasUploadProfileSha256 else {
                throw HarcProtobufConversionError.missingField(
                    "uploadChunkResponse.acknowledgement.uploadProfileSHA256"
                )
            }
            guard value.hasDurableChunk else {
                throw HarcProtobufConversionError.missingField(
                    "uploadChunkResponse.acknowledgement.durableChunk"
                )
            }
            let uploadID = try value.uploadID.domainValue()
            let generation = try responseGeneration(
                value.uploadGeneration,
                field: "uploadChunkResponse.acknowledgement.uploadGeneration"
            )
            let profile = try UploadProfileSHA256(
                value.uploadProfileSha256.validatedBytes(
                    field:
                        "uploadChunkResponse.acknowledgement.uploadProfileSHA256"
                )
            )
            let durableChunk = try value.durableChunk.domainValue()
            let durableAt = try responseDate(
                value.durableAtUnixMs,
                field: "uploadChunkResponse.acknowledgement.durableAt"
            )
            if let expectedRequest {
                guard uploadID == expectedRequest.uploadID,
                      generation == expectedRequest.generation,
                      profile == expectedRequest.uploadProfileSHA256,
                      durableChunk.chunkIndex == expectedRequest.chunkIndex,
                      durableChunk.chunkID == expectedRequest.chunkID,
                      durableChunk.encodedSHA256
                        == expectedRequest.encodedSHA256 else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "uploadChunkResponse.acknowledgement.requestBinding"
                    )
                }
            }
            acknowledgement = HarcValidatedChunkAcknowledgementV1(
                protocolVersion: ackVersion,
                uploadID: uploadID,
                generation: generation,
                uploadProfileSHA256: profile,
                durableChunk: durableChunk,
                durableAt: durableAt
            )
            result = .acknowledgement

        case .rejection(let value):
            let rejection = try value.domainValue()
            if let expectedRequest {
                guard rejection.chunkIndex == expectedRequest.chunkIndex,
                      rejection.chunkID == expectedRequest.chunkID else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "uploadChunkResponse.rejection.requestBinding"
                    )
                }
            }
            acknowledgement = nil
            result = .rejection(rejection)

        case nil:
            throw HarcProtobufConversionError.missingField(
                "uploadChunkResponse.result"
            )
        }
        self.protocolVersion = protocolVersion
    }
}

public struct HarcValidatedReconcileUploadResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let ownerDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let uploadProfileSHA256: UploadProfileSHA256
    public let generation: UploadGeneration
    public let generationExpiresAt: Date
    public let declarations: [LogicalChunkDescriptor]
    public let boundManifestObjectSHA256: ExactObjectSHA256?
    public let durableChunks: [DurableChunkStatus]
    public let rejectedChunks: [RejectedChunkStatus]
    public let terminalReason: UploadReconciliationTerminalReason?
    public let existingReceipt: HarcValidatedExactRecordingReceiptV1?
    public let reconciliation: UploadReconciliation

    public init(
        _ value: Harc_V1_ReconcileUploadResponseV1,
        expectedRequest: HarcValidatedReconcileUploadRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 13),
            field: "reconcileUploadResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "reconcileUploadResponse.uploadID"
            )
        }
        guard value.hasOwnerDeviceID else {
            throw HarcProtobufConversionError.missingField(
                "reconcileUploadResponse.ownerDeviceID"
            )
        }
        guard value.hasOriginRecordingID else {
            throw HarcProtobufConversionError.missingField(
                "reconcileUploadResponse.originRecordingID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "reconcileUploadResponse.uploadProfileSHA256"
            )
        }
        guard value.declarations.count <= TransferLimits.declaredChunksPerUpload
        else {
            throw HarcProtobufConversionError.inputTooLarge(
                limit: TransferLimits.declaredChunksPerUpload,
                actual: value.declarations.count
            )
        }

        let uploadID = try value.uploadID.domainValue()
        let ownerDeviceID = try value.ownerDeviceID.domainValue()
        let originRecordingID = try value.originRecordingID.domainValue()
        let profile = try UploadProfileSHA256(
            value.uploadProfileSha256.validatedBytes(
                field: "reconcileUploadResponse.uploadProfileSHA256"
            )
        )
        let generation = try responseGeneration(
            value.uploadGeneration,
            field: "reconcileUploadResponse.uploadGeneration"
        )
        let expiresAt = try responseDate(
            value.generationExpiresAtUnixMs,
            field: "reconcileUploadResponse.generationExpiresAt"
        )
        let declarations = try value.declarations.map { try $0.domainValue() }
        let manifestSHA256 = try value.hasBoundManifestObjectSha256
            ? ExactObjectSHA256(
                value.boundManifestObjectSha256.validatedBytes(
                    field:
                        "reconcileUploadResponse.boundManifestObjectSHA256"
                )
            )
            : nil
        let durableChunks = try value.durableChunks.map {
            try $0.domainValue()
        }
        let rejectedChunks = try value.rejectedChunks.map {
            try $0.domainValue()
        }
        let terminalReason = try responseTerminalReason(value.terminalReason)
        let existingReceipt = try value.hasExactExistingReceipt
            ? HarcValidatedExactRecordingReceiptV1(
                exactBytes: value.exactExistingReceipt.framedBytes,
                compatibility: compatibility
            )
            : nil
        if let expectedRequest {
            guard uploadID == expectedRequest.uploadID else {
                throw HarcProtobufConversionError.inconsistentField(
                    "reconcileUploadResponse.uploadID"
                )
            }
            guard profile == expectedRequest.uploadProfileSHA256 else {
                throw HarcProtobufConversionError.inconsistentField(
                    "reconcileUploadResponse.uploadProfileSHA256"
                )
            }
        }
        if let existingReceipt {
            guard existingReceipt.uploadID == uploadID,
                  existingReceipt.originRecordingID == originRecordingID,
                  terminalReason == .committed,
                  manifestSHA256
                    == existingReceipt.signedManifestObjectSHA256 else {
                throw HarcProtobufConversionError.inconsistentField(
                    "reconcileUploadResponse.existingReceipt"
                )
            }
        }
        let slot = existingReceipt?.opaqueSlot
        let reconciliation: UploadReconciliation
        do {
            reconciliation = try UploadReconciliation(
                uploadID: uploadID,
                ownerDeviceID: ownerDeviceID,
                originRecordingID: originRecordingID,
                uploadProfileSHA256: profile,
                generation: generation,
                generationExpiresAt: expiresAt,
                declarations: declarations,
                boundManifestObjectSHA256: manifestSHA256,
                durableChunks: durableChunks,
                rejectedChunks: rejectedChunks,
                terminalReason: terminalReason,
                existingReceipt: slot
            )
        } catch {
            throw HarcProtobufConversionError.inconsistentField(
                "reconcileUploadResponse.state"
            )
        }

        self.protocolVersion = protocolVersion
        self.uploadID = uploadID
        self.ownerDeviceID = ownerDeviceID
        self.originRecordingID = originRecordingID
        self.uploadProfileSHA256 = profile
        self.generation = generation
        self.generationExpiresAt = expiresAt
        self.declarations = declarations
        self.boundManifestObjectSHA256 = manifestSHA256
        self.durableChunks = durableChunks
        self.rejectedChunks = rejectedChunks
        self.terminalReason = terminalReason
        self.existingReceipt = existingReceipt
        self.reconciliation = reconciliation
    }
}

public enum HarcCommitUploadResponseDispositionV1: Equatable, Sendable {
    case committed
    case exactReplay
}

public struct HarcValidatedCommitUploadResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let disposition: HarcCommitUploadResponseDispositionV1
    public let receipt: HarcValidatedExactRecordingReceiptV1

    public init(
        _ value: Harc_V1_CommitUploadResponseV1,
        expectedRequest: HarcValidatedCommitUploadRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 3),
            field: "commitUploadResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        guard value.hasExactSignedRecordingReceipt else {
            throw HarcProtobufConversionError.missingField(
                "commitUploadResponse.exactSignedRecordingReceipt"
            )
        }
        let receipt = try HarcValidatedExactRecordingReceiptV1(
            exactBytes: value.exactSignedRecordingReceipt.framedBytes,
            compatibility: compatibility
        )
        if let expectedRequest {
            let manifest = try HarcSignedObjectV1.decode(
                expectedRequest.exactSignedRecordingManifest,
                versionPolicy: compatibility.versionPolicy
            )
            guard receipt.uploadID == expectedRequest.uploadID,
                  receipt.signedManifestObjectSHA256 == manifest.objectID else {
                throw HarcProtobufConversionError.inconsistentField(
                    "commitUploadResponse.receipt.requestBinding"
                )
            }
        }
        switch value.disposition {
        case .commitUploadDispositionCommitted:
            disposition = .committed
        case .commitUploadDispositionExactReplay:
            disposition = .exactReplay
        case .commitUploadDispositionUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "commitUploadResponse.disposition",
                rawValue: value.disposition.rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "commitUploadResponse.disposition",
                rawValue: rawValue
            )
        }
        self.protocolVersion = protocolVersion
        self.receipt = receipt
    }
}

public struct HarcValidatedAbandonUploadResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let terminalReason: UploadReconciliationTerminalReason
    public let terminalAt: Date

    public init(
        _ value: Harc_V1_AbandonUploadResponseV1,
        expectedRequest: HarcValidatedAbandonUploadRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 4),
            field: "abandonUploadResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "abandonUploadResponse.uploadID"
            )
        }
        let uploadID = try value.uploadID.domainValue()
        guard let terminalReason = try responseTerminalReason(
            value.terminalReason
        ) else {
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "abandonUploadResponse.terminalReason",
                rawValue: value.terminalReason.rawValue
            )
        }
        if let expectedRequest, uploadID != expectedRequest.uploadID {
            throw HarcProtobufConversionError.inconsistentField(
                "abandonUploadResponse.uploadID"
            )
        }
        self.protocolVersion = protocolVersion
        self.uploadID = uploadID
        self.terminalReason = terminalReason
        self.terminalAt = try responseDate(
            value.terminalAtUnixMs,
            field: "abandonUploadResponse.terminalAt"
        )
    }
}

public enum HarcRecordingIngestStateV1: String, CaseIterable, Sendable {
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

public struct HarcValidatedGetRecordingStatusResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let originRecordingID: OriginRecordingID
    public let ingestState: HarcRecordingIngestStateV1
    public let processing: ProcessingDescriptor?
    public let canonicalRecordingID: CanonicalRecordingID?
    public let canonicalRecordingRevision: EntityRevision?
    public let recordingReceipt: HarcValidatedExactRecordingReceiptV1?

    public init(
        _ value: Harc_V1_GetRecordingStatusResponseV1,
        expectedRequest: HarcValidatedGetRecordingStatusRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 8),
            field: "getRecordingStatusResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "getRecordingStatusResponse.uploadID"
            )
        }
        guard value.hasOriginRecordingID else {
            throw HarcProtobufConversionError.missingField(
                "getRecordingStatusResponse.originRecordingID"
            )
        }
        let uploadID = try value.uploadID.domainValue()
        let originRecordingID = try value.originRecordingID.domainValue()
        let ingestState = try responseIngestState(value.ingestState)
        let processing = try value.hasProcessing
            ? value.processing.domainValue()
            : nil
        let canonicalID = try value.hasCanonicalRecordingID
            ? value.canonicalRecordingID.domainValue()
            : nil
        let revision: EntityRevision?
        if value.hasCanonicalRecordingRevision {
            do {
                revision = try EntityRevision(value.canonicalRecordingRevision)
            } catch {
                throw HarcProtobufConversionError.invalidValue(
                    field:
                        "getRecordingStatusResponse.canonicalRecordingRevision"
                )
            }
        } else {
            revision = nil
        }
        let receipt = try value.hasExactRecordingReceipt
            ? HarcValidatedExactRecordingReceiptV1(
                exactBytes: value.exactRecordingReceipt.framedBytes,
                compatibility: compatibility
            )
            : nil

        if let expectedRequest {
            switch expectedRequest.recordingKey {
            case .uploadID(let expected):
                guard uploadID == expected else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "getRecordingStatusResponse.uploadID"
                    )
                }
            case .originRecordingID(let expected):
                guard originRecordingID == expected else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "getRecordingStatusResponse.originRecordingID"
                    )
                }
            }
        }
        guard revision == nil || canonicalID != nil,
              processing == nil || canonicalID != nil,
              receipt == nil || (canonicalID != nil && revision != nil) else {
            throw HarcProtobufConversionError.inconsistentField(
                "getRecordingStatusResponse.evidence"
            )
        }
        if let receipt {
            guard receipt.uploadID == uploadID,
                  receipt.originRecordingID == originRecordingID,
                  receipt.canonicalRecordingID == canonicalID,
                  receipt.canonicalRecordingRevision == revision else {
                throw HarcProtobufConversionError.inconsistentField(
                    "getRecordingStatusResponse.receipt"
                )
            }
        }
        switch ingestState {
        case .receiving, .manifestVerified, .abandoned, .expired,
             .conflictBlocked:
            guard processing == nil, canonicalID == nil, revision == nil,
                  receipt == nil else {
                throw HarcProtobufConversionError.inconsistentField(
                    "getRecordingStatusResponse.prepublicationEvidence"
                )
            }
        case .assembling, .audioPublished:
            guard processing == nil, canonicalID != nil, revision == nil,
                  receipt == nil else {
                throw HarcProtobufConversionError.inconsistentField(
                    "getRecordingStatusResponse.publicationEvidence"
                )
            }
        case .recordingCommitted:
            guard canonicalID != nil, revision != nil, receipt == nil else {
                throw HarcProtobufConversionError.inconsistentField(
                    "getRecordingStatusResponse.commitEvidence"
                )
            }
        case .receipted, .processing, .complete:
            guard canonicalID != nil, revision != nil, receipt != nil else {
                throw HarcProtobufConversionError.inconsistentField(
                    "getRecordingStatusResponse.receiptEvidence"
                )
            }
        case .failedRecoverable:
            break
        }

        self.protocolVersion = protocolVersion
        self.uploadID = uploadID
        self.originRecordingID = originRecordingID
        self.ingestState = ingestState
        self.processing = processing
        self.canonicalRecordingID = canonicalID
        self.canonicalRecordingRevision = revision
        self.recordingReceipt = receipt
    }
}

public struct HarcValidatedMintBackgroundCapabilityResponseV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let absoluteUploadURL: URL
    public let opaqueCapabilityCredential: Data
    public let issuedAt: Date
    public let expiresAt: Date
    public let byteCeiling: UInt64
    public let minimumTransportSetEpoch: UInt64
    public let exactTransportSet: HarcValidatedExactHostTransportSetV1
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let batchID: AudioBatchID
    public let exactBatchBodySHA256: ImmutableBatchSHA256
    public let httpMethod: String
    public let httpPath: String
    public let expiryWasClamped: Bool

    public init(
        _ value: Harc_V1_MintBackgroundCapabilityResponseV1,
        expectedRequest: HarcValidatedMintBackgroundCapabilityRequestV1? = nil,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try responseProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 15),
            field: "mintBackgroundCapabilityResponse.protocol",
            expected: expectedRequest?.protocolVersion
        )
        guard !value.absoluteUploadURL.isEmpty,
              value.absoluteUploadURL.utf8.count <= 2_048,
              let components = URLComponents(
                string: value.absoluteUploadURL
              ), components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let absoluteURL = components.url else {
            throw HarcProtobufConversionError.invalidValue(
                field: "mintBackgroundCapabilityResponse.absoluteUploadURL"
            )
        }
        guard value.opaqueCapabilityCredential.count == 48 else {
            throw HarcProtobufConversionError.invalidLength(
                field:
                    "mintBackgroundCapabilityResponse.opaqueCapabilityCredential",
                expected: 48,
                actual: value.opaqueCapabilityCredential.count
            )
        }
        guard value.byteCeiling > 0,
              value.byteCeiling <= TransferLimits.backgroundBatchBytes else {
            throw HarcProtobufConversionError.invalidValue(
                field: "mintBackgroundCapabilityResponse.byteCeiling"
            )
        }
        guard value.minimumTransportSetEpoch > 0 else {
            throw HarcProtobufConversionError.invalidValue(
                field:
                    "mintBackgroundCapabilityResponse.minimumTransportSetEpoch"
            )
        }
        guard value.hasExactSignedTransportSet else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapabilityResponse.exactSignedTransportSet"
            )
        }
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapabilityResponse.uploadID"
            )
        }
        guard value.hasBatchID else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapabilityResponse.batchID"
            )
        }
        guard value.hasExactBatchBodySha256 else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapabilityResponse.exactBatchBodySHA256"
            )
        }
        guard value.httpMethod == "PUT" else {
            throw HarcProtobufConversionError.invalidValue(
                field: "mintBackgroundCapabilityResponse.httpMethod"
            )
        }

        let uploadID = try value.uploadID.domainValue()
        let generation = try responseGeneration(
            value.uploadGeneration,
            field: "mintBackgroundCapabilityResponse.uploadGeneration"
        )
        let batchID = try value.batchID.domainValue()
        let bodySHA256 = try ImmutableBatchSHA256(
            value.exactBatchBodySha256.validatedBytes(
                field:
                    "mintBackgroundCapabilityResponse.exactBatchBodySHA256"
            )
        )
        let expectedPath = "/v1/uploads/\(uploadID)/batches/\(batchID)"
        guard value.httpPath == expectedPath,
              components.percentEncodedPath == value.httpPath else {
            throw HarcProtobufConversionError.inconsistentField(
                "mintBackgroundCapabilityResponse.httpPath"
            )
        }
        let issuedAt = try responseDate(
            value.issuedAtUnixMs,
            field: "mintBackgroundCapabilityResponse.issuedAt"
        )
        let expiresAt = try responseDate(
            value.expiresAtUnixMs,
            field: "mintBackgroundCapabilityResponse.expiresAt"
        )
        guard expiresAt > issuedAt else {
            throw HarcProtobufConversionError.inconsistentField(
                "mintBackgroundCapabilityResponse.expiry"
            )
        }
        let exactTransportSet = try HarcValidatedExactHostTransportSetV1(
            exactBytes: value.exactSignedTransportSet.framedBytes,
            compatibility: compatibility
        )
        guard exactTransportSet.transportSet.setEpoch
                >= value.minimumTransportSetEpoch else {
            throw HarcProtobufConversionError.inconsistentField(
                "mintBackgroundCapabilityResponse.minimumTransportSetEpoch"
            )
        }
        if let expectedRequest {
            let requestedExpiry = try responseUnixMilliseconds(
                expectedRequest.requestedExpiresAt,
                field: "mintBackgroundCapabilityResponse.requestedExpiresAt"
            )
            guard uploadID == expectedRequest.uploadID,
                  generation == expectedRequest.generation,
                  batchID == expectedRequest.batchID,
                  bodySHA256 == expectedRequest.exactBatchBodySHA256,
                  value.byteCeiling == expectedRequest.exactBatchBodyLength else {
                throw HarcProtobufConversionError.inconsistentField(
                    "mintBackgroundCapabilityResponse.requestBinding"
                )
            }
            if value.expiryWasClamped {
                guard value.expiresAtUnixMs < requestedExpiry else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "mintBackgroundCapabilityResponse.expiryWasClamped"
                    )
                }
            } else {
                guard value.expiresAtUnixMs == requestedExpiry else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "mintBackgroundCapabilityResponse.expiresAt"
                    )
                }
            }
        }

        self.protocolVersion = protocolVersion
        self.absoluteUploadURL = absoluteURL
        self.opaqueCapabilityCredential = value.opaqueCapabilityCredential
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.byteCeiling = value.byteCeiling
        self.minimumTransportSetEpoch = value.minimumTransportSetEpoch
        self.exactTransportSet = exactTransportSet
        self.uploadID = uploadID
        self.generation = generation
        self.batchID = batchID
        self.exactBatchBodySHA256 = bodySHA256
        self.httpMethod = value.httpMethod
        self.httpPath = value.httpPath
        self.expiryWasClamped = value.expiryWasClamped
    }
}

// MARK: - Private response helpers

private func responseProtocol(
    _ value: Harc_V1_ProtocolVersionV1?,
    compatibility: HarcProtobufCompatibilityPolicy,
    knownCriticalFieldNumbers: Set<UInt32>,
    field: String,
    expected: HarcProtocolVersion? = nil
) throws -> HarcProtocolVersion {
    guard let value else {
        throw HarcProtobufConversionError.missingField(field)
    }
    let version = try compatibility.validate(
        value,
        knownCriticalFieldNumbers: knownCriticalFieldNumbers
    ).0
    if let expected, version != expected {
        throw HarcProtobufConversionError.inconsistentField(field)
    }
    return version
}

private func responseGeneration(
    _ rawValue: UInt64,
    field: String
) throws -> UploadGeneration {
    guard rawValue <= UInt64(Int64.max) else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    do {
        return try UploadGeneration(rawValue)
    } catch {
        throw HarcProtobufConversionError.invalidValue(field: field)
    }
}

private let responseMaximumUnixMilliseconds: UInt64 =
    9_007_199_254_740_991

private func responseDate(_ rawValue: UInt64, field: String) throws -> Date {
    guard rawValue > 0, rawValue <= responseMaximumUnixMilliseconds else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let value = Date(timeIntervalSince1970: Double(rawValue) / 1_000)
    guard try responseUnixMilliseconds(value, field: field) == rawValue else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return value
}

private func responseUnixMilliseconds(
    _ value: Date,
    field: String
) throws -> UInt64 {
    let seconds = value.timeIntervalSince1970
    let milliseconds = seconds * 1_000
    guard seconds.isFinite, seconds > 0, milliseconds.isFinite,
          milliseconds <= Double(responseMaximumUnixMilliseconds),
          let exact = UInt64(exactly: milliseconds.rounded()),
          Date(timeIntervalSince1970: Double(exact) / 1_000) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return exact
}

private func responseSignedObject(
    _ exactBytes: Data,
    expectedMessageType: HarcSignedMessageTypeV1,
    expectedPayloadType: HarcSignedPayloadTypeV1,
    field: String,
    compatibility: HarcProtobufCompatibilityPolicy
) throws -> HarcSignedObjectV1 {
    guard !exactBytes.isEmpty else {
        throw HarcProtobufConversionError.missingField(field)
    }
    guard exactBytes.count
            <= HarcRecordingTransferRPCLimitsV1.embeddedSignedObjectBytes else {
        throw HarcProtobufConversionError.inputTooLarge(
            limit: HarcRecordingTransferRPCLimitsV1.embeddedSignedObjectBytes,
            actual: exactBytes.count
        )
    }
    let object = try HarcSignedObjectV1.decode(
        exactBytes,
        versionPolicy: compatibility.versionPolicy
    )
    guard object.header.messageType == expectedMessageType,
          object.header.payloadType == expectedPayloadType else {
        throw HarcProtobufConversionError.inconsistentField(field)
    }
    return object
}

private func responseNonzeroUUIDBytes(_ value: Data) -> Bool {
    value.count == 16 && value.contains { $0 != 0 }
}

private func requireNoDeclarationEvidence(
    _ value: Harc_V1_DeclareChunksResponseV1
) throws {
    guard !value.hasFirstAppendedIndex,
          !value.hasAppendedCount,
          !value.hasConflict else {
        throw HarcProtobufConversionError.inconsistentField(
            "declareChunksResponse.dispositionEvidence"
        )
    }
}

private func responseDeclarationConflict(
    _ value: Harc_V1_ChunkDeclarationConflictV1
) throws -> ChunkDeclarationConflict {
    guard value.hasExisting else {
        throw HarcProtobufConversionError.missingField(
            "declareChunksResponse.conflict.existing"
        )
    }
    guard value.hasAttempted else {
        throw HarcProtobufConversionError.missingField(
            "declareChunksResponse.conflict.attempted"
        )
    }
    let conflict: ChunkDeclarationConflict
    do {
        conflict = try ChunkDeclarationConflict(
            existing: value.existing.domainValue(),
            attempted: value.attempted.domainValue()
        )
    } catch {
        throw HarcProtobufConversionError.inconsistentField(
            "declareChunksResponse.conflict"
        )
    }
    let expectedKind: Harc_V1_ChunkDeclarationConflictKindV1
    switch conflict.kind {
    case .indexReused:
        expectedKind = .chunkDeclarationConflictKindIndexReused
    case .identifierReused:
        expectedKind = .chunkDeclarationConflictKindIdentifierReused
    case .indexAndIdentifierReused:
        expectedKind = .chunkDeclarationConflictKindIndexAndIdentifierReused
    }
    guard value.kind == expectedKind else {
        throw HarcProtobufConversionError.inconsistentField(
            "declareChunksResponse.conflict.kind"
        )
    }
    return conflict
}

private func responseTerminalReason(
    _ value: Harc_V1_UploadTerminalReasonV1
) throws -> UploadReconciliationTerminalReason? {
    switch value {
    case .uploadTerminalReasonExpired: return .expired
    case .uploadTerminalReasonAbandoned: return .abandoned
    case .uploadTerminalReasonDeclarationConflict: return .declarationConflict
    case .uploadTerminalReasonCommitted: return .committed
    case .uploadTerminalReasonUnspecified: return nil
    case .UNRECOGNIZED(let rawValue):
        throw HarcProtobufConversionError.unsupportedEnum(
            field: "uploadTerminalReason",
            rawValue: rawValue
        )
    }
}

private func responseIngestState(
    _ value: Harc_V1_RecordingIngestStateV1
) throws -> HarcRecordingIngestStateV1 {
    switch value {
    case .recordingIngestStateReceiving: return .receiving
    case .recordingIngestStateManifestVerified: return .manifestVerified
    case .recordingIngestStateAssembling: return .assembling
    case .recordingIngestStateAudioPublished: return .audioPublished
    case .recordingIngestStateRecordingCommitted: return .recordingCommitted
    case .recordingIngestStateReceipted: return .receipted
    case .recordingIngestStateProcessing: return .processing
    case .recordingIngestStateComplete: return .complete
    case .recordingIngestStateFailedRecoverable: return .failedRecoverable
    case .recordingIngestStateAbandoned: return .abandoned
    case .recordingIngestStateExpired: return .expired
    case .recordingIngestStateConflictBlocked: return .conflictBlocked
    case .recordingIngestStateUnspecified:
        throw HarcProtobufConversionError.unsupportedEnum(
            field: "getRecordingStatusResponse.ingestState",
            rawValue: value.rawValue
        )
    case .UNRECOGNIZED(let rawValue):
        throw HarcProtobufConversionError.unsupportedEnum(
            field: "getRecordingStatusResponse.ingestState",
            rawValue: rawValue
        )
    }
}
