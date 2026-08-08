import Foundation
import HarcDomain
import HarcProtocolWire
import HarcTransfer

/// Inner payload ceilings leave room for the containing protobuf fields under
/// the listener's frozen 1 MiB decoded-control-message limit.
public enum HarcRecordingTransferRPCLimitsV1 {
    public static let exactUploadProfileBytes = 64 * 1_024
    public static let embeddedSignedObjectBytes =
        HarcProtocolLimits.decodedControlPayloadBytes - 1_024
}

/// Common contract for every continuation command that names a frozen upload
/// profile. The adapter must invoke this after loading the authoritative
/// profile and before entering a host mutation.
public protocol HarcValidatedUploadProfileBoundRequestV1: Sendable {
    var protocolVersion: HarcProtocolVersion { get }
    var uploadProfileSHA256: UploadProfileSHA256 { get }
}

public extension HarcValidatedUploadProfileBoundRequestV1 {
    func validateCompatibleSessionCapabilities(
        _ capabilities: HarcValidatedNegotiatedCapabilitiesV1,
        frozenProfile: FrozenUploadProfile
    ) throws {
        guard uploadProfileSHA256 == frozenProfile.profileSHA256 else {
            throw HarcProtobufConversionError.inconsistentField(
                "transfer.uploadProfileSHA256"
            )
        }
        try frozenProfile.validateCompatibleSessionCapabilities(
            capabilities,
            requestProtocolVersion: protocolVersion
        )
    }
}

public extension FrozenUploadProfile {
    /// New upload admission requires the exact negotiated-capabilities object
    /// named by the profile. This check belongs inside the host's atomic
    /// create-vs-replay decision; callers must not persist a new attempt and
    /// only then discover a mismatch.
    func validateInitialSessionCapabilities(
        _ capabilities: HarcValidatedNegotiatedCapabilitiesV1,
        requestProtocolVersion: HarcProtocolVersion
    ) throws {
        guard negotiatedCapabilitiesSHA256.rawBytes
                == capabilities.exactSHA256 else {
            throw HarcProtobufConversionError.inconsistentField(
                "transfer.negotiatedCapabilitiesSHA256"
            )
        }
        try validateCompatibleSessionCapabilities(
            capabilities,
            requestProtocolVersion: requestProtocolVersion
        )
    }

    /// A later session may negotiate unrelated additive features, while every
    /// transfer semantic frozen by the upload profile remains identical.
    func validateCompatibleSessionCapabilities(
        _ capabilities: HarcValidatedNegotiatedCapabilitiesV1,
        requestProtocolVersion: HarcProtocolVersion
    ) throws {
        guard protocolVersion.major == requestProtocolVersion.major,
              protocolVersion.minor == requestProtocolVersion.minor,
              protocolVersion.major == capabilities.protocolVersion.major,
              protocolVersion.minor == capabilities.protocolVersion.minor else {
            throw HarcProtobufConversionError.inconsistentField(
                "transfer.protocol"
            )
        }
        guard descriptorSchema.rawValue
                == capabilities.descriptorSchemaID else {
            throw HarcProtobufConversionError.inconsistentField(
                "transfer.descriptorSchemaID"
            )
        }
        guard encoding == capabilities.encoding else {
            throw HarcProtobufConversionError.inconsistentField(
                "transfer.encoding"
            )
        }
        guard canonicalFormat == capabilities.canonicalFormat else {
            throw HarcProtobufConversionError.inconsistentField(
                "transfer.canonicalFormat"
            )
        }
        let selected = Set(capabilities.selectedFeatureIDs)
        for requirement in requiredCapabilities
            where !selected.contains(requirement.rawValue) {
            throw HarcProtobufConversionError.unsupportedRequiredFeature(
                requirement.rawValue
            )
        }
    }
}

/// Fail-closed, transport-neutral interpretation of `BeginUploadRequestV1`.
/// The exact upload-profile bytes remain available through `profilePayload`;
/// callers must never recreate those bytes by serializing `frozenProfile`.
public struct HarcValidatedBeginUploadRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let uploadID: UploadID
    public let originRecordingID: OriginRecordingID
    public let producingDeviceID: DeviceID
    public let canonicalFormat: CanonicalPCMFormat
    public let captureStartedAt: Date?
    public let captureStartedMonotonicNanoseconds: UInt64?
    public let profilePayload: HarcValidatedUploadProfilePayload

    public var frozenProfile: FrozenUploadProfile {
        profilePayload.domainValue
    }

    public init(
        _ value: Harc_V1_BeginUploadRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        let protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 11),
            field: "beginUpload.protocol"
        )
        guard value.hasLibraryID else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.libraryID"
            )
        }
        guard value.hasHostAuthorityID else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.hostAuthorityID"
            )
        }
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.uploadID"
            )
        }
        guard value.hasOriginRecordingID else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.originRecordingID"
            )
        }
        guard value.hasProducingDeviceID else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.producingDeviceID"
            )
        }
        guard value.hasCanonicalFormat else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.canonicalFormat"
            )
        }
        guard !value.exactUploadProfilePayload.isEmpty else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.exactUploadProfilePayload"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "beginUpload.uploadProfileSHA256"
            )
        }

        let originRecordingID = try value.originRecordingID.domainValue()
        let producingDeviceID = try value.producingDeviceID.domainValue()
        guard originRecordingID.deviceID == producingDeviceID else {
            throw HarcProtobufConversionError.inconsistentField(
                "beginUpload.producingDeviceID"
            )
        }
        let canonicalFormat = try value.canonicalFormat.domainValue()
        guard value.exactUploadProfilePayload.count
                <= HarcRecordingTransferRPCLimitsV1.exactUploadProfileBytes else {
            throw HarcProtobufConversionError.inputTooLarge(
                limit: HarcRecordingTransferRPCLimitsV1.exactUploadProfileBytes,
                actual: value.exactUploadProfilePayload.count
            )
        }
        let profilePayload = try HarcValidatedUploadProfilePayload(
            decoding: value.exactUploadProfilePayload,
            compatibility: compatibility
        )
        let claimedProfileSHA256 = try decodeUploadProfileSHA256(
            value.uploadProfileSha256,
            field: "beginUpload.uploadProfileSHA256"
        )
        guard profilePayload.domainValue.profileSHA256
                == claimedProfileSHA256 else {
            throw HarcProtobufConversionError.exactPayloadHashMismatch
        }
        guard profilePayload.domainValue.protocolVersion.major
                == protocolVersion.major,
              profilePayload.domainValue.protocolVersion.minor
                == protocolVersion.minor else {
            throw HarcProtobufConversionError.inconsistentField(
                "beginUpload.protocol"
            )
        }
        guard profilePayload.domainValue.canonicalFormat
                == canonicalFormat else {
            throw HarcProtobufConversionError.inconsistentField(
                "beginUpload.canonicalFormat"
            )
        }

        self.protocolVersion = protocolVersion
        self.libraryID = try value.libraryID.domainValue()
        self.hostAuthorityID = try value.hostAuthorityID.domainValue()
        self.uploadID = try value.uploadID.domainValue()
        self.originRecordingID = originRecordingID
        self.producingDeviceID = producingDeviceID
        self.canonicalFormat = canonicalFormat
        self.captureStartedAt = try value.hasCaptureStartedAtUnixMs
            ? transferDate(
                value.captureStartedAtUnixMs,
                field: "beginUpload.captureStartedAt"
            )
            : nil
        self.captureStartedMonotonicNanoseconds =
            value.hasCaptureStartedMonotonicNanoseconds
                ? value.captureStartedMonotonicNanoseconds
                : nil
        self.profilePayload = profilePayload
    }

    /// Proves that a newly created profile names the exact capabilities bound
    /// into its first authenticated session, then checks the full semantic
    /// transfer selection.
    public func validateInitialSessionCapabilities(
        _ capabilities: HarcValidatedNegotiatedCapabilitiesV1
    ) throws {
        try frozenProfile.validateInitialSessionCapabilities(
            capabilities,
            requestProtocolVersion: protocolVersion
        )
    }

    /// Proves compatibility for an exact replay or reopen under a later
    /// session. Its negotiated payload may contain extra unrelated features,
    /// but the protocol, descriptor schema, codec/container, canonical format,
    /// and every profile-required feature remain fixed.
    public func validateCompatibleSessionCapabilities(
        _ capabilities: HarcValidatedNegotiatedCapabilitiesV1
    ) throws {
        try frozenProfile.validateCompatibleSessionCapabilities(
            capabilities,
            requestProtocolVersion: protocolVersion
        )
    }
}

public struct HarcValidatedDeclareChunksRequestV1:
    HarcValidatedUploadProfileBoundRequestV1 {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let descriptors: [LogicalChunkDescriptor]

    public init(
        _ value: Harc_V1_DeclareChunksRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 5),
            field: "declareChunks.protocol"
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "declareChunks.uploadID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "declareChunks.uploadProfileSHA256"
            )
        }
        guard !value.descriptors.isEmpty else {
            throw HarcProtobufConversionError.invalidValue(
                field: "declareChunks.descriptors"
            )
        }
        guard value.descriptors.count
                <= TransferLimits.declaredChunksPerCall else {
            throw HarcProtobufConversionError.inputTooLarge(
                limit: TransferLimits.declaredChunksPerCall,
                actual: value.descriptors.count
            )
        }
        uploadID = try value.uploadID.domainValue()
        generation = try transferGeneration(
            value.uploadGeneration,
            field: "declareChunks.uploadGeneration"
        )
        uploadProfileSHA256 = try decodeUploadProfileSHA256(
            value.uploadProfileSha256,
            field: "declareChunks.uploadProfileSHA256"
        )
        descriptors = try value.descriptors.map { try $0.domainValue() }
    }
}

public struct HarcValidatedUploadChunkRequestV1:
    HarcValidatedUploadProfileBoundRequestV1 {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let chunkIndex: UInt32
    public let chunkID: ChunkID
    public let encodedByteLength: UInt64
    public let encodedSHA256: EncodedChunkSHA256
    public let encodedChunk: Data

    public init(
        _ value: Harc_V1_UploadChunkRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 9),
            field: "uploadChunk.protocol"
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "uploadChunk.uploadID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "uploadChunk.uploadProfileSHA256"
            )
        }
        guard value.hasChunkID else {
            throw HarcProtobufConversionError.missingField(
                "uploadChunk.chunkID"
            )
        }
        guard value.hasEncodedSha256 else {
            throw HarcProtobufConversionError.missingField(
                "uploadChunk.encodedSHA256"
            )
        }
        guard value.encodedByteLength > 0,
              value.encodedByteLength <= TransferLimits.encodedChunkBytes else {
            throw HarcProtobufConversionError.invalidValue(
                field: "uploadChunk.encodedByteLength"
            )
        }
        guard UInt64(value.encodedChunk.count)
                == value.encodedByteLength else {
            throw HarcProtobufConversionError.inconsistentField(
                "uploadChunk.encodedChunk"
            )
        }

        uploadID = try value.uploadID.domainValue()
        generation = try transferGeneration(
            value.uploadGeneration,
            field: "uploadChunk.uploadGeneration"
        )
        uploadProfileSHA256 = try decodeUploadProfileSHA256(
            value.uploadProfileSha256,
            field: "uploadChunk.uploadProfileSHA256"
        )
        chunkIndex = value.chunkIndex
        chunkID = try value.chunkID.domainValue()
        encodedByteLength = value.encodedByteLength
        encodedSHA256 = try EncodedChunkSHA256(
            value.encodedSha256.validatedBytes(
                field: "uploadChunk.encodedSHA256"
            )
        )
        encodedChunk = value.encodedChunk
    }
}

public struct HarcValidatedReconcileUploadRequestV1:
    HarcValidatedUploadProfileBoundRequestV1 {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let uploadProfileSHA256: UploadProfileSHA256

    public init(
        _ value: Harc_V1_ReconcileUploadRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 3),
            field: "reconcileUpload.protocol"
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "reconcileUpload.uploadID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "reconcileUpload.uploadProfileSHA256"
            )
        }
        uploadID = try value.uploadID.domainValue()
        uploadProfileSHA256 = try decodeUploadProfileSHA256(
            value.uploadProfileSha256,
            field: "reconcileUpload.uploadProfileSHA256"
        )
    }
}

public struct HarcValidatedCommitUploadRequestV1:
    HarcValidatedUploadProfileBoundRequestV1 {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let exactSignedRecordingManifest: Data

    public init(
        _ value: Harc_V1_CommitUploadRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 5),
            field: "commitUpload.protocol"
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "commitUpload.uploadID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "commitUpload.uploadProfileSHA256"
            )
        }
        guard value.hasExactSignedRecordingManifest,
              !value.exactSignedRecordingManifest.framedBytes.isEmpty else {
            throw HarcProtobufConversionError.missingField(
                "commitUpload.exactSignedRecordingManifest"
            )
        }
        guard value.exactSignedRecordingManifest.framedBytes.count
                <= HarcRecordingTransferRPCLimitsV1.embeddedSignedObjectBytes else {
            throw HarcProtobufConversionError.inputTooLarge(
                limit: HarcRecordingTransferRPCLimitsV1.embeddedSignedObjectBytes,
                actual: value.exactSignedRecordingManifest.framedBytes.count
            )
        }
        let structuralManifest = try HarcSignedObjectV1.decode(
            value.exactSignedRecordingManifest.framedBytes,
            versionPolicy: compatibility.versionPolicy
        )
        guard structuralManifest.header.messageType == .recordingManifest,
              structuralManifest.header.payloadType == .recordingManifest else {
            throw HarcProtobufConversionError.inconsistentField(
                "commitUpload.exactSignedRecordingManifest"
            )
        }
        uploadID = try value.uploadID.domainValue()
        generation = try transferGeneration(
            value.uploadGeneration,
            field: "commitUpload.uploadGeneration"
        )
        uploadProfileSHA256 = try decodeUploadProfileSHA256(
            value.uploadProfileSha256,
            field: "commitUpload.uploadProfileSHA256"
        )
        exactSignedRecordingManifest =
            value.exactSignedRecordingManifest.framedBytes
    }
}

public struct HarcValidatedAbandonUploadRequestV1:
    HarcValidatedUploadProfileBoundRequestV1 {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256

    public init(
        _ value: Harc_V1_AbandonUploadRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 4),
            field: "abandonUpload.protocol"
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "abandonUpload.uploadID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "abandonUpload.uploadProfileSHA256"
            )
        }
        uploadID = try value.uploadID.domainValue()
        generation = try transferGeneration(
            value.uploadGeneration,
            field: "abandonUpload.uploadGeneration"
        )
        uploadProfileSHA256 = try decodeUploadProfileSHA256(
            value.uploadProfileSha256,
            field: "abandonUpload.uploadProfileSHA256"
        )
    }
}

public enum HarcRecordingStatusKeyV1: Equatable, Hashable, Sendable {
    case uploadID(UploadID)
    case originRecordingID(OriginRecordingID)
}

public struct HarcValidatedGetRecordingStatusRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let recordingKey: HarcRecordingStatusKeyV1

    public init(
        _ value: Harc_V1_GetRecordingStatusRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 3),
            field: "getRecordingStatus.protocol"
        )
        switch value.recordingKey {
        case .uploadID(let uploadID):
            recordingKey = .uploadID(try uploadID.domainValue())
        case .originRecordingID(let originRecordingID):
            recordingKey = .originRecordingID(
                try originRecordingID.domainValue()
            )
        case nil:
            throw HarcProtobufConversionError.missingField(
                "getRecordingStatus.recordingKey"
            )
        }
    }
}

public struct HarcBackgroundChunkBindingV1: Equatable, Hashable, Sendable {
    public let chunkIndex: UInt32
    public let encodedSHA256: EncodedChunkSHA256

    public init(chunkIndex: UInt32, encodedSHA256: EncodedChunkSHA256) {
        self.chunkIndex = chunkIndex
        self.encodedSHA256 = encodedSHA256
    }
}

public struct HarcValidatedMintBackgroundCapabilityRequestV1:
    HarcValidatedUploadProfileBoundRequestV1 {
    public let protocolVersion: HarcProtocolVersion
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let batchID: AudioBatchID
    public let chunks: [HarcBackgroundChunkBindingV1]
    public let exactBatchBodySHA256: ImmutableBatchSHA256
    public let exactBatchBodyLength: UInt64
    public let requestedExpiresAt: Date

    public init(
        _ value: Harc_V1_MintBackgroundCapabilityRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        protocolVersion = try validateTransferProtocol(
            value.hasProtocol ? value.protocol : nil,
            compatibility: compatibility,
            knownCriticalFieldNumbers: Set(1 ... 9),
            field: "mintBackgroundCapability.protocol"
        )
        guard value.hasUploadID else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapability.uploadID"
            )
        }
        guard value.hasUploadProfileSha256 else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapability.uploadProfileSHA256"
            )
        }
        guard value.hasBatchID else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapability.batchID"
            )
        }
        guard !value.chunks.isEmpty,
              value.chunks.count <= TransferLimits.backgroundBatchEntries else {
            throw HarcProtobufConversionError.invalidValue(
                field: "mintBackgroundCapability.chunks"
            )
        }
        guard value.hasExactBatchBodySha256 else {
            throw HarcProtobufConversionError.missingField(
                "mintBackgroundCapability.exactBatchBodySHA256"
            )
        }
        guard value.exactBatchBodyLength > 0,
              value.exactBatchBodyLength
                <= TransferLimits.backgroundBatchBytes else {
            throw HarcProtobufConversionError.invalidValue(
                field: "mintBackgroundCapability.exactBatchBodyLength"
            )
        }

        var bindings: [HarcBackgroundChunkBindingV1] = []
        bindings.reserveCapacity(value.chunks.count)
        for chunk in value.chunks {
            guard chunk.hasEncodedSha256 else {
                throw HarcProtobufConversionError.missingField(
                    "mintBackgroundCapability.chunks.encodedSHA256"
                )
            }
            bindings.append(
                HarcBackgroundChunkBindingV1(
                    chunkIndex: chunk.chunkIndex,
                    encodedSHA256: try EncodedChunkSHA256(
                        chunk.encodedSha256.validatedBytes(
                            field:
                                "mintBackgroundCapability.chunks.encodedSHA256"
                        )
                    )
                )
            )
        }
        let indexes = bindings.map(\.chunkIndex)
        guard indexes == indexes.sorted() else {
            throw HarcProtobufConversionError.nonCanonicalOrder(
                field: "mintBackgroundCapability.chunks"
            )
        }
        guard Set(indexes).count == indexes.count else {
            throw HarcProtobufConversionError.duplicateValue(
                field: "mintBackgroundCapability.chunks"
            )
        }

        uploadID = try value.uploadID.domainValue()
        generation = try transferGeneration(
            value.uploadGeneration,
            field: "mintBackgroundCapability.uploadGeneration"
        )
        uploadProfileSHA256 = try decodeUploadProfileSHA256(
            value.uploadProfileSha256,
            field: "mintBackgroundCapability.uploadProfileSHA256"
        )
        batchID = try value.batchID.domainValue()
        chunks = bindings
        exactBatchBodySHA256 = try ImmutableBatchSHA256(
            value.exactBatchBodySha256.validatedBytes(
                field: "mintBackgroundCapability.exactBatchBodySHA256"
            )
        )
        exactBatchBodyLength = value.exactBatchBodyLength
        requestedExpiresAt = try transferDate(
            value.requestedExpiresAtUnixMs,
            field: "mintBackgroundCapability.requestedExpiresAt"
        )
    }
}

// MARK: - Transfer response projections

public extension Harc_V1_ExactSignedObjectV1 {
    init(_ value: OpaqueExactObjectSlot) {
        self.init()
        framedBytes = value.exactBytes
    }
}

public extension Harc_V1_ChunkDeclarationConflictV1 {
    init(_ value: ChunkDeclarationConflict) throws {
        self.init()
        switch value.kind {
        case .indexReused:
            kind = .chunkDeclarationConflictKindIndexReused
        case .identifierReused:
            kind = .chunkDeclarationConflictKindIdentifierReused
        case .indexAndIdentifierReused:
            kind = .chunkDeclarationConflictKindIndexAndIdentifierReused
        }
        existing = try Harc_V1_ChunkDescriptorV1(value.existing)
        attempted = try Harc_V1_ChunkDescriptorV1(value.attempted)
    }
}

public extension Harc_V1_ReconcileUploadResponseV1 {
    init(
        _ value: UploadReconciliation,
        protocolVersion: HarcProtocolVersion = .v1
    ) throws {
        self.init()
        `protocol` = protocolVersion.protobufV1()
        uploadID = Harc_V1_UploadIDV1(value.uploadID)
        ownerDeviceID = Harc_V1_DeviceIDV1(value.ownerDeviceID)
        originRecordingID = Harc_V1_OriginRecordingIDV1(
            value.originRecordingID
        )
        uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: value.uploadProfileSHA256.rawBytes
        )
        uploadGeneration = value.generation.rawValue
        firstBeganAtUnixMs = try transferUnixMilliseconds(
            value.firstBeganAt,
            field: "reconcileUpload.firstBeganAt"
        )
        generationBeganAtUnixMs = try transferUnixMilliseconds(
            value.generationBeganAt,
            field: "reconcileUpload.generationBeganAt"
        )
        generationExpiresAtUnixMs = try transferUnixMilliseconds(
            value.generationExpiresAt,
            field: "reconcileUpload.generationExpiresAt"
        )
        declarations = try value.declarations.map(
            Harc_V1_ChunkDescriptorV1.init
        )
        if let boundManifestObjectSHA256 =
            value.boundManifestObjectSHA256 {
            boundManifestObjectSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: boundManifestObjectSHA256.rawBytes
            )
        }
        durableChunks = try value.durableChunks.map(
            Harc_V1_DurableChunkV1.init
        )
        rejectedChunks = value.rejectedChunks.map(
            Harc_V1_RejectedChunkV1.init
        )
        switch value.terminalReason {
        case .expired?: terminalReason = .uploadTerminalReasonExpired
        case .abandoned?: terminalReason = .uploadTerminalReasonAbandoned
        case .declarationConflict?:
            terminalReason = .uploadTerminalReasonDeclarationConflict
        case .committed?: terminalReason = .uploadTerminalReasonCommitted
        case nil: terminalReason = .uploadTerminalReasonUnspecified
        }
        if let existingReceipt = value.existingReceipt {
            exactExistingReceipt = Harc_V1_ExactSignedObjectV1(
                existingReceipt
            )
        }
    }
}

// MARK: - Private validation helpers

private func validateTransferProtocol(
    _ value: Harc_V1_ProtocolVersionV1?,
    compatibility: HarcProtobufCompatibilityPolicy,
    knownCriticalFieldNumbers: Set<UInt32>,
    field: String
) throws -> HarcProtocolVersion {
    guard let value else {
        throw HarcProtobufConversionError.missingField(field)
    }
    return try compatibility.validate(
        value,
        knownCriticalFieldNumbers: knownCriticalFieldNumbers
    ).0
}

private func transferGeneration(
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

private func decodeUploadProfileSHA256(
    _ value: Harc_V1_SHA256DigestV1,
    field: String
) throws -> UploadProfileSHA256 {
    try UploadProfileSHA256(value.validatedBytes(field: field))
}

private let transferMaximumExactlyRepresentableUnixMilliseconds: UInt64 =
    9_007_199_254_740_991

private func transferDate(_ value: UInt64, field: String) throws -> Date {
    guard value <= transferMaximumExactlyRepresentableUnixMilliseconds else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let date = Date(timeIntervalSince1970: Double(value) / 1_000)
    guard try transferUnixMilliseconds(date, field: field) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return date
}

private func transferUnixMilliseconds(
    _ value: Date,
    field: String
) throws -> UInt64 {
    let seconds = value.timeIntervalSince1970
    guard seconds.isFinite, seconds >= 0 else {
        throw HarcProtobufConversionError.invalidValue(field: field)
    }
    let milliseconds = seconds * 1_000
    guard milliseconds.isFinite,
          milliseconds
            <= Double(transferMaximumExactlyRepresentableUnixMilliseconds) else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let rounded = milliseconds.rounded()
    guard let result = UInt64(exactly: rounded) else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return result
}
