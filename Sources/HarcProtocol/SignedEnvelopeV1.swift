import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer

public enum HarcSignedMessageTypeV1: String, CaseIterable, Sendable {
    case hostTransportSet = "host.transport.set.v1"
    case deviceGrant = "identity.device-grant.v1"
    case deviceRevocation = "identity.device-revocation.v1"
    case recordingManifest = "transfer.recording-manifest.v1"
    case batchAcknowledgement = "transfer.batch-ack.v1"
    case recordingReceipt = "transfer.recording-receipt.v1"
    case metadataMutation = "library.metadata-mutation.v1"
    case processingArtifact = "processing.artifact.v1"
    case portableTrustHistory = "migration.trust-history.v1"
}

public enum HarcSignedPayloadTypeV1: String, CaseIterable, Sendable {
    case hostTransportSet = "harc.v1.HostTransportSetV1"
    case deviceGrant = "harc.v1.DeviceGrantV1"
    case deviceRevocation = "harc.v1.DeviceRevocationV1"
    case recordingManifest = "harc.v1.RecordingManifestV1"
    case batchAcknowledgement = "harc.v1.BatchAckV1"
    case recordingReceipt = "harc.v1.RecordingReceiptV1"
    case metadataMutation = "harc.v1.MetadataMutationV1"
    case processingArtifact = "harc.v1.ProcessingArtifactV1"
    case portableTrustHistory = "harc.v1.PortableTrustHistoryV1"
}

public struct HarcSignedEnvelopeV1: Equatable, Hashable, Sendable {
    public static let magic = Data("HARCSE1\0".utf8)

    public let messageType: HarcSignedMessageTypeV1
    public let protocolVersion: HarcProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let signerDeviceID: DeviceID?
    public let grantID: UUID?
    public let grantEpoch: UInt64
    public let operationID: UUID?
    public let issuedAtUnixMilliseconds: UInt64
    public let expiresAtUnixMilliseconds: UInt64?
    public let payloadType: HarcSignedPayloadTypeV1
    public let expectedRevision: UInt64?
    public let payloadSHA256: Data

    public init(
        messageType: HarcSignedMessageTypeV1,
        protocolVersion: HarcProtocolVersion = .v1,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        signerDeviceID: DeviceID?,
        grantID: UUID?,
        grantEpoch: UInt64,
        operationID: UUID?,
        issuedAtUnixMilliseconds: UInt64,
        expiresAtUnixMilliseconds: UInt64?,
        payloadType: HarcSignedPayloadTypeV1,
        expectedRevision: UInt64?,
        payloadSHA256: Data,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws {
        try versionPolicy.validate(protocolVersion)
        try harcRequireDigest(payloadSHA256, field: "payloadSHA256")
        if let grantID, grantID == Self.zeroUUID {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "grantID")
        }
        if let operationID, operationID == Self.zeroUUID {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "operationID")
        }
        if let signerDeviceID, signerDeviceID.rawBytes.allSatisfy({ $0 == 0 }) {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "signerDeviceID")
        }
        if let expiresAtUnixMilliseconds, expiresAtUnixMilliseconds == 0 {
            throw HarcProtocolCodecError.invalidTimeRange(field: "expiresAtUnixMilliseconds")
        }
        if let expectedRevision, expectedRevision == UInt64.max {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "expectedRevision")
        }
        self.messageType = messageType
        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.signerDeviceID = signerDeviceID
        self.grantID = grantID
        self.grantEpoch = grantEpoch
        self.operationID = operationID
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.payloadType = payloadType
        self.expectedRevision = expectedRevision
        self.payloadSHA256 = payloadSHA256
        try HarcRegisteredSignedObjectV1.validateHeaderAdmission(self)
    }

    public static func payloadDigest(_ exactPayload: Data) -> Data {
        Data(SHA256.hash(data: exactPayload))
    }

    public func encoded() throws -> Data {
        try HarcRegisteredSignedObjectV1.validateHeaderAdmission(self)
        var writer = HarcBinaryWriter()
        writer.append(Self.magic)
        try writer.appendLengthPrefixedASCII(messageType.rawValue, field: "messageType")
        writer.append(protocolVersion.major)
        writer.append(protocolVersion.minor)
        writer.append(uuid: libraryID.rawValue)
        writer.append(hostAuthorityID.rawBytes)
        writer.append(signerDeviceID?.rawBytes ?? Data(repeating: 0, count: 32))
        writer.append(uuid: grantID ?? Self.zeroUUID)
        writer.append(grantEpoch)
        writer.append(uuid: operationID ?? Self.zeroUUID)
        writer.append(issuedAtUnixMilliseconds)
        writer.append(expiresAtUnixMilliseconds ?? 0)
        try writer.appendLengthPrefixedASCII(payloadType.rawValue, field: "payloadType")
        writer.append(expectedRevision ?? UInt64.max)
        writer.append(payloadSHA256)
        guard writer.data.count <= HarcProtocolLimits.signedEnvelopeHeaderBytes else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "HarcSignedEnvelopeV1",
                limit: UInt64(HarcProtocolLimits.signedEnvelopeHeaderBytes),
                actual: UInt64(writer.data.count)
            )
        }
        return writer.data
    }

    public static func decode(
        _ exactHeaderBytes: Data,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        var reader = try HarcBinaryReader(
            exactHeaderBytes,
            maximumBytes: HarcProtocolLimits.signedEnvelopeHeaderBytes,
            field: "HarcSignedEnvelopeV1"
        )
        try reader.requireMagic(Self.magic, field: "HarcSignedEnvelopeV1")
        let rawMessageType = try reader.readLengthPrefixedASCII(field: "messageType")
        guard let messageType = HarcSignedMessageTypeV1(rawValue: rawMessageType) else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: rawMessageType,
                payloadType: "unknown"
            )
        }
        let version = HarcProtocolVersion(
            major: try reader.readUInt16(field: "protocolMajor"),
            minor: try reader.readUInt16(field: "protocolMinor")
        )
        try versionPolicy.validate(version)
        let libraryID = LibraryID(try reader.readUUID(field: "libraryID"))
        let hostAuthorityID = try HostAuthorityID(
            reader.readData(count: 32, field: "hostAuthorityID")
        )
        let signerBytes = try reader.readData(count: 32, field: "signerDeviceID")
        let signerDeviceID = signerBytes.allSatisfy { $0 == 0 }
            ? nil
            : try DeviceID(signerBytes)
        let rawGrantID = try reader.readUUID(field: "grantID")
        let grantID = rawGrantID == zeroUUID ? nil : rawGrantID
        let grantEpoch = try reader.readUInt64(field: "grantEpoch")
        let rawOperationID = try reader.readUUID(field: "operationID")
        let operationID = rawOperationID == zeroUUID ? nil : rawOperationID
        let issuedAt = try reader.readUInt64(field: "issuedAtUnixMilliseconds")
        let rawExpiry = try reader.readUInt64(field: "expiresAtUnixMilliseconds")
        let expiry = rawExpiry == 0 ? nil : rawExpiry
        let rawPayloadType = try reader.readLengthPrefixedASCII(field: "payloadType")
        guard let payloadType = HarcSignedPayloadTypeV1(rawValue: rawPayloadType) else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: rawMessageType,
                payloadType: rawPayloadType
            )
        }
        let rawRevision = try reader.readUInt64(field: "expectedRevision")
        let revision = rawRevision == UInt64.max ? nil : rawRevision
        let payloadHash = try reader.readData(count: 32, field: "payloadSHA256")
        try reader.requireEnd()
        let decoded = try Self(
            messageType: messageType,
            protocolVersion: version,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            signerDeviceID: signerDeviceID,
            grantID: grantID,
            grantEpoch: grantEpoch,
            operationID: operationID,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: expiry,
            payloadType: payloadType,
            expectedRevision: revision,
            payloadSHA256: payloadHash,
            versionPolicy: versionPolicy
        )
        guard try decoded.encoded() == exactHeaderBytes else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "canonicalHeader")
        }
        return decoded
    }

    public static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

public struct HarcSignedObjectV1: Equatable, Hashable, Sendable {
    public static let magic = Data("HARCSO1\0".utf8)
    private static let signingDomain = "HARC-SIGNED-ENVELOPE-V1\0"
    private static let objectIDDomain = "HARC-SIGNED-OBJECT-ID-V1\0"

    public let header: HarcSignedEnvelopeV1
    public let exactHeaderBytes: Data
    public let exactPayloadBytes: Data
    public let signature: P256RawSignature
    public let exactFramedBytes: Data

    public var objectID: ExactObjectSHA256 {
        try! ExactObjectSHA256(
            harcDomainSeparatedSHA256(Self.objectIDDomain, exactFramedBytes)
        )
    }

    public static func signingDigest(forExactHeaderBytes bytes: Data) -> P256SHA256Digest {
        try! P256SHA256Digest(harcDomainSeparatedSHA256(signingDomain, bytes))
    }

    /// Low-level exact-byte construction primitive. This enforces registry
    /// header admission, signer identity, payload hashing, and low-S signing.
    /// Producers with decoded payload fields should prefer `signRegistered`,
    /// which additionally checks every registered payload mirror. Its output
    /// is not semantically accepted until `verifyRegistered` succeeds with
    /// decoded payload bindings (and current grant state when applicable).
    public static func sign(
        header: HarcSignedEnvelopeV1,
        exactPayloadBytes: Data,
        using signer: any P256DigestSigner
    ) throws -> Self {
        try HarcRegisteredSignedObjectV1.validateHeaderAdmission(header)
        guard header.payloadSHA256 == HarcSignedEnvelopeV1.payloadDigest(exactPayloadBytes) else {
            throw HarcProtocolCodecError.payloadHashMismatch
        }
        if let signerDeviceID = header.signerDeviceID {
            guard signer.publicKey.deviceID == signerDeviceID else {
                throw HarcProtocolCodecError.invalidKeyBinding(field: "signerDeviceID")
            }
        } else {
            guard signer.publicKey.hostAuthorityID == header.hostAuthorityID else {
                throw HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")
            }
        }
        let exactHeaderBytes = try header.encoded()
        let signature = try signer.sign(digest: signingDigest(forExactHeaderBytes: exactHeaderBytes))
        return try frame(
            header: header,
            exactHeaderBytes: exactHeaderBytes,
            exactPayloadBytes: exactPayloadBytes,
            signature: signature
        )
    }

    /// Parses and preserves an exact frame, enforcing canonical header
    /// admission, bounds, low-S structure, and payload hashing. This does not
    /// authenticate the signer or payload mirrors; callers must pass the value
    /// through a typed registered verifier before treating it as accepted.
    public static func decode(
        _ exactFramedBytes: Data,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        var reader = try HarcBinaryReader(
            exactFramedBytes,
            maximumBytes: HarcProtocolLimits.signedObjectBytes,
            field: "HarcSignedObjectV1"
        )
        try reader.requireMagic(Self.magic, field: "HarcSignedObjectV1")
        let headerLength = UInt64(try reader.readUInt32(field: "headerLength"))
        guard headerLength > 0,
              headerLength <= UInt64(HarcProtocolLimits.signedEnvelopeHeaderBytes),
              let headerCount = Int(exactly: headerLength) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "headerLength",
                minimum: 1,
                maximum: UInt64(HarcProtocolLimits.signedEnvelopeHeaderBytes),
                actual: headerLength
            )
        }
        let exactHeader = try reader.readData(count: headerCount, field: "canonicalHeader")
        let header = try HarcSignedEnvelopeV1.decode(exactHeader, versionPolicy: versionPolicy)
        try HarcRegisteredSignedObjectV1.validateHeaderAdmission(header)
        let payloadLength = try reader.readUInt64(field: "payloadLength")
        guard payloadLength <= UInt64(HarcProtocolLimits.decodedControlPayloadBytes),
              let payloadCount = Int(exactly: payloadLength) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "payloadLength",
                minimum: 0,
                maximum: UInt64(HarcProtocolLimits.decodedControlPayloadBytes),
                actual: payloadLength
            )
        }
        let payload = try reader.readData(count: payloadCount, field: "exactPayload")
        let signatureLength = try reader.readUInt16(field: "signatureLength")
        guard signatureLength == UInt16(P256RawSignature.byteCount) else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "signatureLength",
                expected: UInt64(P256RawSignature.byteCount),
                actual: UInt64(signatureLength)
            )
        }
        let signature = try P256RawSignature(
            reader.readData(count: Int(signatureLength), field: "signature")
        )
        try reader.requireEnd()
        guard header.payloadSHA256 == HarcSignedEnvelopeV1.payloadDigest(payload) else {
            throw HarcProtocolCodecError.payloadHashMismatch
        }
        return Self(
            header: header,
            exactHeaderBytes: exactHeader,
            exactPayloadBytes: payload,
            signature: signature,
            exactFramedBytes: exactFramedBytes
        )
    }

    /// Cryptographic primitive kept module-internal so callers cannot confuse
    /// a valid signature with full registered-object acceptance.
    func verifySignature(using publicKey: P256X963PublicKey) throws {
        if let signerDeviceID = header.signerDeviceID {
            guard publicKey.deviceID == signerDeviceID else {
                throw HarcProtocolCodecError.invalidKeyBinding(field: "signerDeviceID")
            }
        } else {
            guard publicKey.hostAuthorityID == header.hostAuthorityID else {
                throw HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")
            }
        }
        guard header.payloadSHA256 == HarcSignedEnvelopeV1.payloadDigest(exactPayloadBytes) else {
            throw HarcProtocolCodecError.payloadHashMismatch
        }
        guard publicKey.isValidSignature(
            signature,
            for: Self.signingDigest(forExactHeaderBytes: exactHeaderBytes)
        ) else {
            throw HarcProtocolCodecError.invalidSignature
        }
    }

    private static func frame(
        header: HarcSignedEnvelopeV1,
        exactHeaderBytes: Data,
        exactPayloadBytes: Data,
        signature: P256RawSignature
    ) throws -> Self {
        guard let headerLength = UInt32(exactly: exactHeaderBytes.count) else {
            throw HarcProtocolCodecError.numericOverflow(field: "headerLength")
        }
        guard exactPayloadBytes.count <= HarcProtocolLimits.decodedControlPayloadBytes else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "exactPayload",
                limit: UInt64(HarcProtocolLimits.decodedControlPayloadBytes),
                actual: UInt64(exactPayloadBytes.count)
            )
        }
        var writer = HarcBinaryWriter()
        writer.append(Self.magic)
        writer.append(headerLength)
        writer.append(exactHeaderBytes)
        writer.append(UInt64(exactPayloadBytes.count))
        writer.append(exactPayloadBytes)
        writer.append(UInt16(P256RawSignature.byteCount))
        writer.append(signature.rawBytes)
        return Self(
            header: header,
            exactHeaderBytes: exactHeaderBytes,
            exactPayloadBytes: exactPayloadBytes,
            signature: signature,
            exactFramedBytes: writer.data
        )
    }
}
