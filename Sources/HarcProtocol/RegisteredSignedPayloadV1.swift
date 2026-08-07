import Foundation
import HarcDomain
import HarcIdentity
import HarcProtocolWire
import HarcTransfer

/// The exact payload selected by one of the nine registered V1 signed-object
/// rows. Protobuf cases retain their original bytes through
/// `HarcExactProtobufPayload`; the transport set retains its independent binary
/// representation through the enclosing signed object.
public enum HarcRegisteredSignedPayloadV1: Sendable {
    case hostTransportSet(HostTransportSetV1)
    case deviceGrant(
        exact: HarcExactProtobufPayload<Harc_V1_DeviceGrantV1>,
        claims: DeviceGrantClaims
    )
    case deviceRevocation(
        exact: HarcExactProtobufPayload<Harc_V1_DeviceRevocationV1>,
        claims: DeviceRevocationClaims
    )
    case recordingManifest(HarcExactProtobufPayload<Harc_V1_RecordingManifestV1>)
    case batchAcknowledgement(HarcExactProtobufPayload<Harc_V1_BatchAckV1>)
    case recordingReceipt(HarcExactProtobufPayload<Harc_V1_RecordingReceiptV1>)
    case metadataMutation(HarcExactProtobufPayload<Harc_V1_MetadataMutationV1>)
    case processingArtifact(HarcExactProtobufPayload<Harc_V1_ProcessingArtifactV1>)
    case portableTrustHistory(HarcExactProtobufPayload<Harc_V1_PortableTrustHistoryV1>)
}

/// The caller must state whether it is verifying already-durable historical
/// evidence or accepting a side-effecting command for the first time. This
/// prevents a missing clock/grant argument from silently bypassing command
/// expiry and current-grant enforcement.
public enum HarcSignedObjectAuthenticationPurposeV1: Equatable, Hashable, Sendable {
    case historicalEvidence
    case initialCommandAcceptance(
        acceptedAtUnixMilliseconds: UInt64,
        currentGrant: HarcCurrentGrantBindingV1
    )
}

/// Cryptographic and registry authentication result.
///
/// This proves that the signature, exact-byte hash, registry row, signer class,
/// and all envelope mirror fields were derived from and match the signed
/// payload. Application handlers must still apply operation-specific policy
/// such as ownership, quotas, revisions, and publication invariants.
public struct HarcAuthenticatedSignedObjectV1: Sendable {
    public let signedObject: HarcSignedObjectV1
    public let payload: HarcRegisteredSignedPayloadV1
    /// The assurance under which this object was authenticated. Historical
    /// evidence is intentionally weaker than first acceptance of a live
    /// command and must not be promoted by downstream conversion code.
    public let authenticationPurpose: HarcSignedObjectAuthenticationPurposeV1

    fileprivate init(
        signedObject: HarcSignedObjectV1,
        payload: HarcRegisteredSignedPayloadV1,
        authenticationPurpose: HarcSignedObjectAuthenticationPurposeV1
    ) {
        self.signedObject = signedObject
        self.payload = payload
        self.authenticationPurpose = authenticationPurpose
    }

    public static func decodeAndAuthenticate(
        _ exactFramedBytes: Data,
        using publicKey: P256X963PublicKey,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1,
        purpose: HarcSignedObjectAuthenticationPurposeV1
    ) throws -> Self {
        let object = try HarcSignedObjectV1.decode(
            exactFramedBytes,
            versionPolicy: compatibility.versionPolicy
        )
        return try object.authenticateRegisteredPayload(
            using: publicKey,
            compatibility: compatibility,
            purpose: purpose
        )
    }
}

public extension HarcSignedObjectV1 {
    /// Public signed-object acceptance always derives mirror bindings from the
    /// untouched payload bytes. The lower-level caller-supplied binding seam is
    /// package-only for protocol tests and reviewed adapters.
    func authenticateRegisteredPayload(
        using publicKey: P256X963PublicKey,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1,
        purpose: HarcSignedObjectAuthenticationPurposeV1
    ) throws -> HarcAuthenticatedSignedObjectV1 {
        try authenticateRegisteredPayload(
            using: publicKey,
            compatibility: compatibility,
            purpose: purpose,
            portableTrustHistoryDepth: 0
        )
    }

    fileprivate func authenticateRegisteredPayload(
        using publicKey: P256X963PublicKey,
        compatibility: HarcProtobufCompatibilityPolicy,
        purpose: HarcSignedObjectAuthenticationPurposeV1,
        portableTrustHistoryDepth: Int
    ) throws -> HarcAuthenticatedSignedObjectV1 {
        // Authenticate the admitted frame before interpreting any payload. In
        // particular, an unauthenticated portable-history payload must never
        // trigger recursive parsing of its embedded signed objects.
        try verifySignature(using: publicKey)
        let decoded = try HarcRegisteredPayloadDecoderV1.decode(
            exactPayloadBytes,
            header: header,
            compatibility: compatibility,
            portableTrustHistoryDepth: portableTrustHistoryDepth
        )
        switch purpose {
        case .historicalEvidence:
            try verifyRegistered(
                using: publicKey,
                payloadBindings: decoded.bindings
            )
        case .initialCommandAcceptance(let acceptedAt, let currentGrant):
            try verifyRegistered(
                using: publicKey,
                payloadBindings: decoded.bindings,
                acceptedAtUnixMilliseconds: acceptedAt,
                currentGrant: currentGrant
            )
        }
        return HarcAuthenticatedSignedObjectV1(
            signedObject: self,
            payload: decoded.payload,
            authenticationPurpose: purpose
        )
    }
}

private enum HarcRegisteredPayloadDecoderV1 {
    private static let maximumPortableTrustHistoryDepth = 1
    private static let maximumHistoricalDevices = 1_024
    private static let maximumSignedTrustObjectsPerDevice = 1_024
    private static let maximumSignedTrustObjects = 4_096

    struct Result {
        let payload: HarcRegisteredSignedPayloadV1
        let bindings: HarcSignedPayloadBindingsV1
    }

    static func decode(
        _ exactPayloadBytes: Data,
        header: HarcSignedEnvelopeV1,
        compatibility: HarcProtobufCompatibilityPolicy,
        portableTrustHistoryDepth: Int
    ) throws -> Result {
        switch header.payloadType {
        case .hostTransportSet:
            let value = try HostTransportSetV1.decode(
                exactPayloadBytes,
                versionPolicy: compatibility.versionPolicy
            )
            return Result(
                payload: .hostTransportSet(value),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: value.protocolVersion,
                    libraryID: value.libraryID,
                    hostAuthorityID: value.hostAuthorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMilliseconds
                )
            )

        case .deviceGrant:
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_DeviceGrantV1.self
            )
            let value = exact.message
            let claims = try value.domainValue(compatibility: compatibility)
            return Result(
                payload: .deviceGrant(exact: exact, claims: claims),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: protocolVersion(claims.protocolVersion),
                    libraryID: claims.libraryID,
                    hostAuthorityID: claims.hostAuthorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    grantID: claims.grantID.rawValue,
                    grantEpoch: claims.grantEpoch.rawValue,
                    expiresAtUnixMilliseconds: value.hasExpiresAtUnixMs
                        ? value.expiresAtUnixMs
                        : nil
                )
            )

        case .deviceRevocation:
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_DeviceRevocationV1.self
            )
            let value = exact.message
            let claims = try value.domainValue(compatibility: compatibility)
            return Result(
                payload: .deviceRevocation(exact: exact, claims: claims),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: protocolVersion(claims.protocolVersion),
                    libraryID: claims.libraryID,
                    hostAuthorityID: claims.hostAuthorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    grantID: claims.grantID.rawValue,
                    grantEpoch: claims.newGrantEpoch.rawValue,
                    operationID: claims.revocationID
                )
            )

        case .recordingManifest:
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_RecordingManifestV1.self
            )
            let value = exact.message
            let version = try requireProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownFields: Set(1 ... 23),
                field: "recordingManifest.protocol",
                compatibility: compatibility
            )
            try require(value.manifestVersion == 1, field: "recordingManifest.manifestVersion")
            let libraryID = try requireLibrary(value.hasLibraryID, value.libraryID, "recordingManifest.libraryID")
            let authorityID = try requireAuthority(
                value.hasHostAuthorityID,
                value.hostAuthorityID,
                "recordingManifest.hostAuthorityID"
            )
            let origin = try requireOrigin(
                value.hasOriginRecordingID,
                value.originRecordingID,
                "recordingManifest.originRecordingID"
            )
            let deviceID = try requireDevice(
                value.hasProducingDeviceID,
                value.producingDeviceID,
                "recordingManifest.producingDeviceID"
            )
            try require(origin.deviceID == deviceID, field: "recordingManifest.originDevice")
            let uploadID = try requireUUID(
                value.hasUploadID,
                value.uploadID.value,
                "recordingManifest.uploadID"
            )
            try validateManifest(value, origin: origin)
            return Result(
                payload: .recordingManifest(exact),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: version,
                    libraryID: libraryID,
                    hostAuthorityID: authorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    signerDeviceID: deviceID,
                    operationID: uploadID
                )
            )

        case .batchAcknowledgement:
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_BatchAckV1.self
            )
            let value = exact.message
            let version = try requireProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownFields: Set(1 ... 11),
                field: "batchAck.protocol",
                compatibility: compatibility
            )
            let libraryID = try requireLibrary(value.hasLibraryID, value.libraryID, "batchAck.libraryID")
            let authorityID = try requireAuthority(value.hasHostAuthorityID, value.hostAuthorityID, "batchAck.hostAuthorityID")
            _ = try requireDevice(value.hasDeviceID, value.deviceID, "batchAck.deviceID")
            _ = try requireUUID(value.hasUploadID, value.uploadID.value, "batchAck.uploadID")
            let batchID = try requireUUID(value.hasBatchID, value.batchID.value, "batchAck.batchID")
            try requireDigest(value.hasExactBatchBodySha256, value.exactBatchBodySha256.value, "batchAck.exactBatchBodySHA256")
            _ = try requireUUID(value.hasAckID, value.ackID.value, "batchAck.ackID")
            try require(value.issuedAtUnixMs == value.durableAtUnixMs, field: "batchAck.issuedAtUnixMs")
            try validateAcceptedChunks(value.acceptedChunks)
            return Result(
                payload: .batchAcknowledgement(exact),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: version,
                    libraryID: libraryID,
                    hostAuthorityID: authorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    operationID: batchID
                )
            )

        case .recordingReceipt:
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_RecordingReceiptV1.self
            )
            let value = exact.message
            let version = try requireProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownFields: Set(1 ... 16),
                field: "recordingReceipt.protocol",
                compatibility: compatibility
            )
            let libraryID = try requireLibrary(value.hasLibraryID, value.libraryID, "recordingReceipt.libraryID")
            let authorityID = try requireAuthority(value.hasHostAuthorityID, value.hostAuthorityID, "recordingReceipt.hostAuthorityID")
            let producingDevice = try requireDevice(value.hasProducingDeviceID, value.producingDeviceID, "recordingReceipt.producingDeviceID")
            let origin = try requireOrigin(value.hasOriginRecordingID, value.originRecordingID, "recordingReceipt.originRecordingID")
            try require(origin.deviceID == producingDevice, field: "recordingReceipt.originDevice")
            _ = try requireUUID(value.hasCanonicalRecordingID, value.canonicalRecordingID.value, "recordingReceipt.canonicalRecordingID")
            let uploadID = try requireUUID(value.hasUploadID, value.uploadID.value, "recordingReceipt.uploadID")
            try requireDigest(value.hasSignedManifestObjectSha256, value.signedManifestObjectSha256.value, "recordingReceipt.manifestObjectSHA256")
            try requireDigest(value.hasCanonicalPcmSha256, value.canonicalPcmSha256.value, "recordingReceipt.canonicalPCMSHA256")
            try require(value.totalCanonicalFrames > 0, field: "recordingReceipt.totalCanonicalFrames")
            guard value.hasCanonicalFormat else {
                throw HarcProtobufConversionError.missingField("recordingReceipt.canonicalFormat")
            }
            _ = try value.canonicalFormat.domainValue()
            try require(value.canonicalRecordingRevision > 0, field: "recordingReceipt.canonicalRecordingRevision")
            try require(value.changeCursor > 0, field: "recordingReceipt.changeCursor")
            try validateProcessingState(value.processingState, field: "recordingReceipt.processingState")
            _ = try requireUUID(value.hasReceiptID, value.receiptID.value, "recordingReceipt.receiptID")
            return Result(
                payload: .recordingReceipt(exact),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: version,
                    libraryID: libraryID,
                    hostAuthorityID: authorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    operationID: uploadID
                )
            )

        case .metadataMutation:
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_MetadataMutationV1.self
            )
            let value = exact.message
            let version = try requireProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownFields: Set(1 ... 16),
                field: "metadataMutation.protocol",
                compatibility: compatibility
            )
            let libraryID = try requireLibrary(value.hasLibraryID, value.libraryID, "metadataMutation.libraryID")
            let authorityID = try requireAuthority(value.hasHostAuthorityID, value.hostAuthorityID, "metadataMutation.hostAuthorityID")
            let deviceID = try requireDevice(value.hasRequestingDeviceID, value.requestingDeviceID, "metadataMutation.requestingDeviceID")
            let grantID = try requireUUID(value.hasGrantID, value.grantID.value, "metadataMutation.grantID")
            try require(value.grantEpoch > 0, field: "metadataMutation.grantEpoch")
            let operationID = try requireUUID(value.hasOperationID, value.operationID.value, "metadataMutation.operationID")
            _ = try requireUUID(value.hasCanonicalRecordingID, value.canonicalRecordingID.value, "metadataMutation.canonicalRecordingID")
            try require(value.expiresAtUnixMs > value.issuedAtUnixMs, field: "metadataMutation.expiry")
            try require(value.expectedRevision > 0, field: "metadataMutation.expectedRevision")
            try validateMutation(value.mutation)
            return Result(
                payload: .metadataMutation(exact),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: version,
                    libraryID: libraryID,
                    hostAuthorityID: authorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    signerDeviceID: deviceID,
                    grantID: grantID,
                    grantEpoch: value.grantEpoch,
                    operationID: operationID,
                    expiresAtUnixMilliseconds: value.expiresAtUnixMs,
                    expectedRevision: value.expectedRevision
                )
            )

        case .processingArtifact:
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_ProcessingArtifactV1.self
            )
            let value = exact.message
            let version = try requireProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownFields: Set(1 ... 23),
                field: "processingArtifact.protocol",
                compatibility: compatibility
            )
            let libraryID = try requireLibrary(value.hasLibraryID, value.libraryID, "processingArtifact.libraryID")
            let authorityID = try requireAuthority(value.hasHostAuthorityID, value.hostAuthorityID, "processingArtifact.hostAuthorityID")
            _ = try requireUUID(value.hasArtifactID, value.artifactID.value, "processingArtifact.artifactID")
            let origin = try requireOrigin(value.hasOriginRecordingID, value.originRecordingID, "processingArtifact.originRecordingID")
            try requireDigest(value.hasCanonicalAudioSha256, value.canonicalAudioSha256.value, "processingArtifact.canonicalAudioSHA256")
            let deviceID = try requireDevice(value.hasProducingDeviceID, value.producingDeviceID, "processingArtifact.producingDeviceID")
            try require(origin.deviceID == deviceID, field: "processingArtifact.originDevice")
            let grantID = try requireUUID(value.hasGrantID, value.grantID.value, "processingArtifact.grantID")
            try require(value.grantEpoch > 0, field: "processingArtifact.grantEpoch")
            let operationID = try requireUUID(value.hasOperationID, value.operationID.value, "processingArtifact.operationID")
            try require(value.submissionExpiresAtUnixMs > value.issuedAtUnixMs, field: "processingArtifact.expiry")
            try validateProcessingProvenance(value)
            try require(value.exactBundleByteLength > 0 && value.exactBundleByteLength <= UInt64(HarcProcessingBundleV1.maximumExactBytes), field: "processingArtifact.bundleLength")
            try requireDigest(value.hasExactBundleSha256, value.exactBundleSha256.value, "processingArtifact.bundleSHA256")
            return Result(
                payload: .processingArtifact(exact),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: version,
                    libraryID: libraryID,
                    hostAuthorityID: authorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    signerDeviceID: deviceID,
                    grantID: grantID,
                    grantEpoch: value.grantEpoch,
                    operationID: operationID,
                    expiresAtUnixMilliseconds: value.submissionExpiresAtUnixMs
                )
            )

        case .portableTrustHistory:
            guard portableTrustHistoryDepth < maximumPortableTrustHistoryDepth else {
                throw HarcProtobufConversionError.invalidValue(
                    field: "portableTrustHistory.depth"
                )
            }
            let exact = try HarcExactProtobufPayload(
                decoding: exactPayloadBytes,
                as: Harc_V1_PortableTrustHistoryV1.self
            )
            let value = exact.message
            let version = try requireProtocol(
                present: value.hasProtocol,
                value: value.protocol,
                knownFields: Set(1 ... 7),
                field: "portableTrustHistory.protocol",
                compatibility: compatibility
            )
            let libraryID = try requireLibrary(value.hasLibraryID, value.libraryID, "portableTrustHistory.libraryID")
            let authorityID = try requireAuthority(value.hasHostAuthorityID, value.hostAuthorityID, "portableTrustHistory.hostAuthorityID")
            let authorityKey = try P256X963PublicKey(value.oldHostAuthorityPublicKeyX963)
            try require(authorityKey.hostAuthorityID == authorityID, field: "portableTrustHistory.authorityKey")
            let exportID = try requireUUID(value.hasExportID, value.exportID.value, "portableTrustHistory.exportID")
            try validateHistoricalDevices(
                value.devices,
                libraryID: libraryID,
                authorityID: authorityID,
                authorityPublicKey: authorityKey,
                exportIssuedAtUnixMilliseconds: value.issuedAtUnixMs,
                compatibility: compatibility,
                portableTrustHistoryDepth: portableTrustHistoryDepth + 1
            )
            return Result(
                payload: .portableTrustHistory(exact),
                bindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: version,
                    libraryID: libraryID,
                    hostAuthorityID: authorityID,
                    issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                    operationID: exportID
                )
            )
        }
    }

    private static func protocolVersion(_ value: IdentityProtocolVersion) -> HarcProtocolVersion {
        HarcProtocolVersion(major: value.major, minor: value.minor)
    }

    private static func requireProtocol(
        present: Bool,
        value: Harc_V1_ProtocolVersionV1,
        knownFields: Set<UInt32>,
        field: String,
        compatibility: HarcProtobufCompatibilityPolicy
    ) throws -> HarcProtocolVersion {
        guard present else { throw HarcProtobufConversionError.missingField(field) }
        return try compatibility.validate(
            value,
            knownCriticalFieldNumbers: knownFields
        ).0
    }

    private static func requireLibrary(
        _ present: Bool,
        _ value: Harc_V1_LibraryIDV1,
        _ field: String
    ) throws -> LibraryID {
        guard present else { throw HarcProtobufConversionError.missingField(field) }
        return try value.domainValue()
    }

    private static func requireAuthority(
        _ present: Bool,
        _ value: Harc_V1_HostAuthorityIDV1,
        _ field: String
    ) throws -> HostAuthorityID {
        guard present else { throw HarcProtobufConversionError.missingField(field) }
        return try value.domainValue()
    }

    private static func requireDevice(
        _ present: Bool,
        _ value: Harc_V1_DeviceIDV1,
        _ field: String
    ) throws -> DeviceID {
        guard present else { throw HarcProtobufConversionError.missingField(field) }
        return try value.domainValue()
    }

    private static func requireOrigin(
        _ present: Bool,
        _ value: Harc_V1_OriginRecordingIDV1,
        _ field: String
    ) throws -> OriginRecordingID {
        guard present else { throw HarcProtobufConversionError.missingField(field) }
        return try value.domainValue()
    }

    private static func requireUUID(_ present: Bool, _ value: Data, _ field: String) throws -> UUID {
        guard present else { throw HarcProtobufConversionError.missingField(field) }
        guard value.count == 16 else {
            throw HarcProtobufConversionError.invalidLength(
                field: field,
                expected: 16,
                actual: value.count
            )
        }
        let bytes = [UInt8](value)
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        guard uuid != HarcSignedEnvelopeV1.zeroUUID else {
            throw HarcProtobufConversionError.invalidValue(field: field)
        }
        return uuid
    }

    private static func requireDigest(_ present: Bool, _ value: Data, _ field: String) throws {
        guard present else { throw HarcProtobufConversionError.missingField(field) }
        guard value.count == 32 else {
            throw HarcProtobufConversionError.invalidLength(
                field: field,
                expected: 32,
                actual: value.count
            )
        }
    }

    private static func require(_ condition: Bool, field: String) throws {
        guard condition else { throw HarcProtobufConversionError.invalidValue(field: field) }
    }

    private static func validateManifest(
        _ value: Harc_V1_RecordingManifestV1,
        origin: OriginRecordingID
    ) throws {
        try requireDigest(value.hasUploadProfileSha256, value.uploadProfileSha256.value, "recordingManifest.uploadProfileSHA256")
        guard value.descriptorSchemaID == ChunkDescriptorSchema.v1.rawValue else {
            throw HarcProtobufConversionError.invalidValue(field: "recordingManifest.descriptorSchemaID")
        }
        guard value.hasEncoding, value.hasCanonicalFormat, value.hasCanonicalPcmSha256 else {
            throw HarcProtobufConversionError.missingField("recordingManifest.audioDescriptor")
        }
        let manifestEncoding = try value.encoding.domainValue()
        let manifestFormat = try value.canonicalFormat.domainValue()
        try requireDigest(true, value.canonicalPcmSha256.value, "recordingManifest.canonicalPCMSHA256")
        try require(value.captureEndedAtUnixMs >= value.captureStartedAtUnixMs, field: "recordingManifest.captureWallTimes")
        try require(value.captureEndedMonotonicNanoseconds >= value.captureStartedMonotonicNanoseconds, field: "recordingManifest.captureMonotonicTimes")
        try require(value.totalCanonicalFrames > 0, field: "recordingManifest.totalCanonicalFrames")
        let expectedBytes = value.totalCanonicalFrames.multipliedReportingOverflow(by: 2)
        try require(!expectedBytes.overflow && expectedBytes.partialValue == value.totalCanonicalBytes, field: "recordingManifest.totalCanonicalBytes")
        try validateFinalizationReason(value.finalizationReason)

        let chunks = try value.chunks.map { try $0.domainValue() }
        guard !chunks.isEmpty else {
            throw HarcProtobufConversionError.missingField("recordingManifest.chunks")
        }
        var nextIndex: UInt32 = 0
        var nextFrame: UInt64 = 0
        var chunkIDs = Set<ChunkID>()
        for chunk in chunks {
            try require(chunk.originRecordingID == origin, field: "recordingManifest.chunkOrigin")
            try require(chunkIDs.insert(chunk.chunkID).inserted, field: "recordingManifest.chunkID")
            try require(chunk.encoding == manifestEncoding, field: "recordingManifest.chunkEncoding")
            try require(chunk.canonicalFormat == manifestFormat, field: "recordingManifest.chunkCanonicalFormat")
            try require(chunk.chunkIndex == nextIndex, field: "recordingManifest.chunkIndex")
            try require(chunk.canonicalStartFrame == nextFrame, field: "recordingManifest.chunkFrames")
            let increment = nextIndex.addingReportingOverflow(1)
            try require(!increment.overflow, field: "recordingManifest.chunkIndex")
            nextIndex = increment.partialValue
            nextFrame = chunk.canonicalEndFrameExclusive
        }
        try require(nextFrame == value.totalCanonicalFrames, field: "recordingManifest.chunkCoverage")
        let discontinuities = try value.discontinuities.map { try $0.domainValue() }
        var priorMonotonic: UInt64?
        var priorWallTime: Date?
        for domain in discontinuities {
            try require(domain.recordingID == origin, field: "recordingManifest.discontinuityOrigin")
            try require(domain.affectedFrames.endFrameExclusive <= value.totalCanonicalFrames, field: "recordingManifest.discontinuityFrames")
            if let priorMonotonic {
                try require(
                    domain.monotonicTimeNanoseconds >= priorMonotonic,
                    field: "recordingManifest.discontinuities"
                )
                if domain.monotonicTimeNanoseconds == priorMonotonic,
                   let priorWallTime {
                    try require(
                        domain.wallTime >= priorWallTime,
                        field: "recordingManifest.discontinuities"
                    )
                }
            }
            priorMonotonic = domain.monotonicTimeNanoseconds
            priorWallTime = domain.wallTime
        }
        var priorArtifactID: Data?
        for digest in value.processingArtifactObjectIds {
            try requireDigest(true, digest.value, "recordingManifest.processingArtifactObjectID")
            if let priorArtifactID {
                try require(priorArtifactID.lexicographicallyPrecedes(digest.value), field: "recordingManifest.processingArtifactObjectIDs")
            }
            priorArtifactID = digest.value
        }
    }

    private static func validateFinalizationReason(_ value: Harc_V1_CaptureFinalizationReasonV1) throws {
        switch value {
        case .captureFinalizationReasonUserStopped,
             .captureFinalizationReasonSystemEnded,
             .captureFinalizationReasonRecoveredDurablePrefix,
             .captureFinalizationReasonStorageExhausted,
             .captureFinalizationReasonWriterFailure:
            return
        case .captureFinalizationReasonUnspecified, .UNRECOGNIZED:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "recordingManifest.finalizationReason",
                rawValue: value.rawValue
            )
        }
    }

    private static func validateAcceptedChunks(_ values: [Harc_V1_AcceptedBatchChunkV1]) throws {
        guard !values.isEmpty else {
            throw HarcProtobufConversionError.missingField("batchAck.acceptedChunks")
        }
        var priorIndex: UInt32?
        for value in values {
            if let priorIndex {
                try require(value.chunkIndex > priorIndex, field: "batchAck.acceptedChunks")
            }
            try requireDigest(value.hasEncodedSha256, value.encodedSha256.value, "batchAck.acceptedChunkSHA256")
            priorIndex = value.chunkIndex
        }
    }

    private static func validateProcessingState(
        _ value: Harc_V1_RecordingProcessingStateV1,
        field: String
    ) throws {
        switch value {
        case .recordingProcessingStatePending,
             .recordingProcessingStateTranscribing,
             .recordingProcessingStateProjecting,
             .recordingProcessingStateReady,
             .recordingProcessingStateDegraded,
             .recordingProcessingStateFailedRecoverable:
            return
        case .recordingProcessingStateUnspecified, .UNRECOGNIZED:
            throw HarcProtobufConversionError.unsupportedEnum(field: field, rawValue: value.rawValue)
        }
    }

    private static func validateProcessingProvenance(
        _ value: Harc_V1_ProcessingArtifactV1
    ) throws {
        try requireProtocolIdentifier(value.engineRevision, field: "processingArtifact.engineRevision")
        try requireProtocolIdentifier(value.buildRevision, field: "processingArtifact.buildRevision")
        try requireProtocolIdentifier(value.diarizationRevision, field: "processingArtifact.diarizationRevision")
        try requireProtocolIdentifier(value.vadRevision, field: "processingArtifact.vadRevision")
        try requireProtocolIdentifier(value.vocabularyRevision, field: "processingArtifact.vocabularyRevision")
        try requireProtocolIdentifier(value.promptRevision, field: "processingArtifact.promptRevision")
        try requireProtocolIdentifier(value.wordTimingSchemaID, field: "processingArtifact.wordTimingSchemaID")

        var priorComponentID: String?
        for revision in value.modelRevisions {
            try requireProtocolIdentifier(revision.componentID, field: "processingArtifact.modelRevision.componentID")
            try requireProtocolIdentifier(revision.revision, field: "processingArtifact.modelRevision.revision")
            if let priorComponentID {
                try require(
                    priorComponentID < revision.componentID,
                    field: "processingArtifact.modelRevisions"
                )
            }
            priorComponentID = revision.componentID
        }

        guard value.hasCoverage else {
            throw HarcProtobufConversionError.missingField("processingArtifact.coverage")
        }
        try validateCoverage(value.coverage)
    }

    private static func validateCoverage(_ value: Harc_V1_ArtifactCoverageV1) throws {
        try validateFrameRanges(
            value.coveredRanges,
            field: "processingArtifact.coverage.coveredRanges"
        )
        try validateExplainedFrameRanges(
            value.degradedRanges,
            field: "processingArtifact.coverage.degradedRanges"
        )
        try validateExplainedFrameRanges(
            value.failedRanges,
            field: "processingArtifact.coverage.failedRanges"
        )
        var partition = value.coveredRanges.map { ($0.startFrame, $0.endFrameExclusive) }
        partition += value.degradedRanges.map { ($0.frames.startFrame, $0.frames.endFrameExclusive) }
        partition += value.failedRanges.map { ($0.frames.startFrame, $0.frames.endFrameExclusive) }
        partition.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        guard !partition.isEmpty else {
            throw HarcProtobufConversionError.missingField("processingArtifact.coverage.partition")
        }
        var expectedStart: UInt64 = 0
        for range in partition {
            try require(range.0 == expectedStart, field: "processingArtifact.coverage.partition")
            expectedStart = range.1
        }
    }

    private static func validateFrameRanges(
        _ values: [Harc_V1_CanonicalFrameRangeV1],
        field: String
    ) throws {
        var priorEnd: UInt64?
        for value in values {
            try require(value.endFrameExclusive > value.startFrame, field: field)
            if let priorEnd {
                try require(value.startFrame >= priorEnd, field: field)
            }
            priorEnd = value.endFrameExclusive
        }
    }

    private static func validateExplainedFrameRanges(
        _ values: [Harc_V1_ExplainedFrameRangeV1],
        field: String
    ) throws {
        var priorEnd: UInt64?
        for value in values {
            guard value.hasFrames else {
                throw HarcProtobufConversionError.missingField("\(field).frames")
            }
            try require(value.frames.endFrameExclusive > value.frames.startFrame, field: field)
            if let priorEnd {
                try require(value.frames.startFrame >= priorEnd, field: field)
            }
            try requireProtocolIdentifier(value.reasonCode, field: "\(field).reasonCode")
            priorEnd = value.frames.endFrameExclusive
        }
    }

    private static func validateMutation(
        _ mutation: Harc_V1_MetadataMutationV1.OneOf_Mutation?
    ) throws {
        guard let mutation else {
            throw HarcProtobufConversionError.missingField("metadataMutation.mutation")
        }
        switch mutation {
        case .setTitle(let value):
            if value.hasTitle { try requireNonemptyText(value.title, field: "metadataMutation.title") }
        case .replaceTags(let value):
            try require(value.tags == value.tags.sorted(), field: "metadataMutation.tags")
            try require(Set(value.tags).count == value.tags.count, field: "metadataMutation.tags")
            for tag in value.tags { try requireNonemptyText(tag, field: "metadataMutation.tag") }
        case .setSpeakerLabel(let value):
            if value.hasDisplayName {
                try requireNonemptyText(value.displayName, field: "metadataMutation.speakerLabel")
            }
        case .assignSpeakerIdentity(let value):
            if value.hasPersonID {
                _ = try value.personID.domainValue()
            }
        case .setNotesMarkdown(let value):
            if value.hasMarkdown {
                try requireNonemptyText(value.markdown, field: "metadataMutation.notesMarkdown")
            }
        case .setPinned:
            break
        }
    }

    private static func requireNonemptyText(_ value: String, field: String) throws {
        try require(
            !value.isEmpty
                && value.utf8.count <= HarcProtocolLimits.decodedControlPayloadBytes
                && value.precomposedStringWithCanonicalMapping == value,
            field: field
        )
    }

    private static func requireProtocolIdentifier(_ value: String, field: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        try require(
            !value.isEmpty
                && value.utf8.count <= 128
                && value.unicodeScalars.allSatisfy(allowed.contains),
            field: field
        )
    }

    private static func validateHistoricalDevices(
        _ values: [Harc_V1_HistoricalDeviceTrustV1],
        libraryID: LibraryID,
        authorityID: HostAuthorityID,
        authorityPublicKey: P256X963PublicKey,
        exportIssuedAtUnixMilliseconds: UInt64,
        compatibility: HarcProtobufCompatibilityPolicy,
        portableTrustHistoryDepth: Int
    ) throws {
        try require(
            portableTrustHistoryDepth <= maximumPortableTrustHistoryDepth,
            field: "portableTrustHistory.depth"
        )
        try require(
            values.count <= maximumHistoricalDevices,
            field: "portableTrustHistory.devices"
        )
        var signedObjectCount = 0
        for value in values {
            try require(
                value.exactSignedDeviceGrants.count <= maximumSignedTrustObjectsPerDevice,
                field: "portableTrustHistory.signedGrants"
            )
            try require(
                value.exactSignedDeviceRevocations.count <= maximumSignedTrustObjectsPerDevice,
                field: "portableTrustHistory.signedRevocations"
            )
            let deviceObjectCount = value.exactSignedDeviceGrants.count
                + value.exactSignedDeviceRevocations.count
            let newCount = signedObjectCount.addingReportingOverflow(deviceObjectCount)
            try require(
                !newCount.overflow && newCount.partialValue <= maximumSignedTrustObjects,
                field: "portableTrustHistory.signedObjects"
            )
            signedObjectCount = newCount.partialValue
        }

        var priorID: Data?
        for value in values {
            let deviceID = try requireDevice(value.hasDeviceID, value.deviceID, "portableTrustHistory.deviceID")
            let publicKey = try P256X963PublicKey(value.devicePublicKeyX963)
            try require(publicKey.deviceID == deviceID, field: "portableTrustHistory.devicePublicKey")
            if let priorID {
                try require(priorID.lexicographicallyPrecedes(deviceID.rawBytes), field: "portableTrustHistory.devices")
            }
            var priorGrantOrder: (epoch: UInt64, objectID: Data)?
            for carrier in value.exactSignedDeviceGrants {
                try require(!carrier.framedBytes.isEmpty, field: "portableTrustHistory.signedGrant")
                let authenticated = try authenticateHistoricalObject(
                    carrier.framedBytes,
                    expectedMessageType: .deviceGrant,
                    expectedPayloadType: .deviceGrant,
                    wrongTypeField: "portableTrustHistory.signedGrantType",
                    using: authorityPublicKey,
                    compatibility: compatibility,
                    portableTrustHistoryDepth: portableTrustHistoryDepth
                )
                guard case .deviceGrant(let exact, let claims) = authenticated.payload else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "portableTrustHistory.signedGrantType"
                    )
                }
                try require(claims.libraryID == libraryID, field: "portableTrustHistory.grantLibrary")
                try require(claims.hostAuthorityID == authorityID, field: "portableTrustHistory.grantAuthority")
                try require(claims.deviceID == deviceID, field: "portableTrustHistory.grantDevice")
                try require(claims.devicePublicKey == publicKey, field: "portableTrustHistory.grantDevicePublicKey")
                try require(
                    exact.message.issuedAtUnixMs <= exportIssuedAtUnixMilliseconds,
                    field: "portableTrustHistory.grantIssuedAt"
                )
                let currentOrder = (
                    epoch: claims.grantEpoch.rawValue,
                    objectID: authenticated.signedObject.objectID.rawBytes
                )
                if let priorGrantOrder {
                    try require(
                        priorGrantOrder.epoch < currentOrder.epoch
                            || (priorGrantOrder.epoch == currentOrder.epoch
                                && priorGrantOrder.objectID.lexicographicallyPrecedes(currentOrder.objectID)),
                        field: "portableTrustHistory.signedGrants"
                    )
                }
                priorGrantOrder = currentOrder
            }

            var priorRevocationOrder: (epoch: UInt64, objectID: Data)?
            for carrier in value.exactSignedDeviceRevocations {
                try require(!carrier.framedBytes.isEmpty, field: "portableTrustHistory.signedRevocation")
                let authenticated = try authenticateHistoricalObject(
                    carrier.framedBytes,
                    expectedMessageType: .deviceRevocation,
                    expectedPayloadType: .deviceRevocation,
                    wrongTypeField: "portableTrustHistory.signedRevocationType",
                    using: authorityPublicKey,
                    compatibility: compatibility,
                    portableTrustHistoryDepth: portableTrustHistoryDepth
                )
                guard case .deviceRevocation(let exact, let claims) = authenticated.payload else {
                    throw HarcProtobufConversionError.inconsistentField(
                        "portableTrustHistory.signedRevocationType"
                    )
                }
                try require(claims.libraryID == libraryID, field: "portableTrustHistory.revocationLibrary")
                try require(claims.hostAuthorityID == authorityID, field: "portableTrustHistory.revocationAuthority")
                try require(claims.deviceID == deviceID, field: "portableTrustHistory.revocationDevice")
                try require(
                    exact.message.issuedAtUnixMs <= exportIssuedAtUnixMilliseconds,
                    field: "portableTrustHistory.revocationIssuedAt"
                )
                let currentOrder = (
                    epoch: claims.newGrantEpoch.rawValue,
                    objectID: authenticated.signedObject.objectID.rawBytes
                )
                if let priorRevocationOrder {
                    try require(
                        priorRevocationOrder.epoch < currentOrder.epoch
                            || (priorRevocationOrder.epoch == currentOrder.epoch
                                && priorRevocationOrder.objectID.lexicographicallyPrecedes(currentOrder.objectID)),
                        field: "portableTrustHistory.signedRevocations"
                    )
                }
                priorRevocationOrder = currentOrder
            }
            priorID = deviceID.rawBytes
        }
    }

    /// Decode only the signed frame, then admit the exact registered tuple
    /// expected by this carrier before dispatching to a payload decoder. This
    /// makes portable history structurally one level deep: a carrier cannot
    /// select the portable-history decoder (or any other generic payload row).
    private static func authenticateHistoricalObject(
        _ exactFramedBytes: Data,
        expectedMessageType: HarcSignedMessageTypeV1,
        expectedPayloadType: HarcSignedPayloadTypeV1,
        wrongTypeField: String,
        using publicKey: P256X963PublicKey,
        compatibility: HarcProtobufCompatibilityPolicy,
        portableTrustHistoryDepth: Int
    ) throws -> HarcAuthenticatedSignedObjectV1 {
        try require(
            portableTrustHistoryDepth <= maximumPortableTrustHistoryDepth,
            field: "portableTrustHistory.depth"
        )
        let object = try HarcSignedObjectV1.decode(
            exactFramedBytes,
            versionPolicy: compatibility.versionPolicy
        )
        guard object.header.messageType == expectedMessageType,
              object.header.payloadType == expectedPayloadType else {
            throw HarcProtobufConversionError.inconsistentField(wrongTypeField)
        }
        return try object.authenticateRegisteredPayload(
            using: publicKey,
            compatibility: compatibility,
            purpose: .historicalEvidence,
            portableTrustHistoryDepth: portableTrustHistoryDepth
        )
    }
}
