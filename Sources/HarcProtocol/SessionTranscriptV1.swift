import Foundation
import HarcDomain
import HarcIdentity

public struct SessionTranscriptV1: Equatable, Hashable, Sendable {
    public static let magic = Data("HARCSESSION1\0".utf8)
    private static let proofDomain = "HARC-SESSION-CLIENT-PROOF-V1\0"

    public let protocolVersion: HarcProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let tlsSPKISHA256: Data
    public let deviceID: DeviceID
    public let grantID: UUID
    public let grantEpoch: UInt64
    public let challengeID: UUID
    public let serverNonce: Data
    public let clientNonce: Data
    public let capabilitiesSHA256: Data

    public init(
        protocolVersion: HarcProtocolVersion = .v1,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        tlsSPKISHA256: Data,
        deviceID: DeviceID,
        grantID: UUID,
        grantEpoch: UInt64,
        challengeID: UUID,
        serverNonce: Data,
        clientNonce: Data,
        capabilitiesSHA256: Data,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws {
        try versionPolicy.validate(protocolVersion)
        try harcRequireDigest(tlsSPKISHA256, field: "tlsSPKISHA256")
        try harcRequireDigest(serverNonce, field: "serverNonce")
        try harcRequireDigest(clientNonce, field: "clientNonce")
        try harcRequireDigest(capabilitiesSHA256, field: "capabilitiesSHA256")
        guard grantID != HarcSignedEnvelopeV1.zeroUUID, grantEpoch > 0 else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "grant")
        }
        guard challengeID != HarcSignedEnvelopeV1.zeroUUID else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "challengeID")
        }
        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.tlsSPKISHA256 = tlsSPKISHA256
        self.deviceID = deviceID
        self.grantID = grantID
        self.grantEpoch = grantEpoch
        self.challengeID = challengeID
        self.serverNonce = serverNonce
        self.clientNonce = clientNonce
        self.capabilitiesSHA256 = capabilitiesSHA256
    }

    public func encoded() -> Data {
        var writer = HarcBinaryWriter()
        writer.append(Self.magic)
        writer.append(protocolVersion.major)
        writer.append(protocolVersion.minor)
        writer.append(uuid: libraryID.rawValue)
        writer.append(hostAuthorityID.rawBytes)
        writer.append(tlsSPKISHA256)
        writer.append(deviceID.rawBytes)
        writer.append(uuid: grantID)
        writer.append(grantEpoch)
        writer.append(uuid: challengeID)
        writer.append(serverNonce)
        writer.append(clientNonce)
        writer.append(capabilitiesSHA256)
        precondition(writer.data.count <= HarcProtocolLimits.sessionTranscriptBytes)
        return writer.data
    }

    public static func decode(
        _ exactBytes: Data,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        var reader = try HarcBinaryReader(
            exactBytes,
            maximumBytes: HarcProtocolLimits.sessionTranscriptBytes,
            field: "SessionTranscriptV1"
        )
        try reader.requireMagic(Self.magic, field: "SessionTranscriptV1")
        let version = HarcProtocolVersion(
            major: try reader.readUInt16(field: "protocolMajor"),
            minor: try reader.readUInt16(field: "protocolMinor")
        )
        try versionPolicy.validate(version)
        let decoded = try Self(
            protocolVersion: version,
            libraryID: LibraryID(try reader.readUUID(field: "libraryID")),
            hostAuthorityID: HostAuthorityID(
                reader.readData(count: HostAuthorityID.byteCount, field: "hostAuthorityID")
            ),
            tlsSPKISHA256: reader.readData(count: 32, field: "tlsSPKISHA256"),
            deviceID: DeviceID(
                reader.readData(count: DeviceID.byteCount, field: "deviceID")
            ),
            grantID: reader.readUUID(field: "grantID"),
            grantEpoch: reader.readUInt64(field: "grantEpoch"),
            challengeID: reader.readUUID(field: "challengeID"),
            serverNonce: reader.readData(count: 32, field: "serverNonce"),
            clientNonce: reader.readData(count: 32, field: "clientNonce"),
            capabilitiesSHA256: reader.readData(count: 32, field: "capabilitiesSHA256"),
            versionPolicy: versionPolicy
        )
        try reader.requireEnd()
        guard decoded.encoded() == exactBytes else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "canonicalSessionTranscript")
        }
        return decoded
    }

    public func clientProofDigest() -> P256SHA256Digest {
        try! P256SHA256Digest(
            harcDomainSeparatedSHA256(Self.proofDomain, encoded())
        )
    }

    public func signClientProof(using signer: any P256DigestSigner) throws -> P256RawSignature {
        guard signer.publicKey.deviceID == deviceID else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "deviceID")
        }
        return try signer.sign(digest: clientProofDigest())
    }

    public func verifyClientProof(
        _ signature: P256RawSignature,
        using devicePublicKey: P256X963PublicKey
    ) throws {
        guard devicePublicKey.deviceID == deviceID else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "deviceID")
        }
        guard devicePublicKey.isValidSignature(signature, for: clientProofDigest()) else {
            throw HarcProtocolCodecError.invalidSignature
        }
    }
}
