import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity

public struct PairingTranscriptV1: Equatable, Hashable, Sendable {
    public static let magic = Data("HARCPAIR1\0".utf8)
    private static let proofDomain = "HARC-PAIRING-CLIENT-PROOF-V1\0"
    private static let sasDomain = "HARC-PAIRING-SAS-V1\0"

    public let protocolVersion: HarcProtocolVersion
    public let ticketID: UUID
    public let claimID: UUID
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let hostAuthorityPublicKey: P256X963PublicKey
    public let tlsSPKISHA256: Data
    public let deviceID: DeviceID
    public let devicePublicKey: P256X963PublicKey
    public let clientNonce: Data
    public let hostNonce: Data
    public let ticketSecretBindingSHA256: Data
    public let requestedScopes: [AuthorizationScope]

    public init(
        protocolVersion: HarcProtocolVersion = .v1,
        ticketID: UUID,
        claimID: UUID,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostAuthorityPublicKey: P256X963PublicKey,
        tlsSPKISHA256: Data,
        deviceID: DeviceID,
        devicePublicKey: P256X963PublicKey,
        clientNonce: Data,
        hostNonce: Data,
        ticketSecretBindingSHA256: Data,
        requestedScopes: [AuthorizationScope],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws {
        try versionPolicy.validate(protocolVersion)
        guard hostAuthorityPublicKey.hostAuthorityID == hostAuthorityID else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")
        }
        guard devicePublicKey.deviceID == deviceID else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "deviceID")
        }
        try harcRequireDigest(tlsSPKISHA256, field: "tlsSPKISHA256")
        try harcRequireDigest(clientNonce, field: "clientNonce")
        try harcRequireDigest(hostNonce, field: "hostNonce")
        try harcRequireDigest(
            ticketSecretBindingSHA256,
            field: "ticketSecretBindingSHA256"
        )
        guard requestedScopes.count <= HarcProtocolLimits.pairingRequestedScopes else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "requestedScopes",
                minimum: 0,
                maximum: UInt64(HarcProtocolLimits.pairingRequestedScopes),
                actual: UInt64(requestedScopes.count)
            )
        }
        try Self.validateCanonicalScopes(requestedScopes)
        self.protocolVersion = protocolVersion
        self.ticketID = ticketID
        self.claimID = claimID
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.tlsSPKISHA256 = tlsSPKISHA256
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.clientNonce = clientNonce
        self.hostNonce = hostNonce
        self.ticketSecretBindingSHA256 = ticketSecretBindingSHA256
        self.requestedScopes = requestedScopes
    }

    public func encoded() throws -> Data {
        var writer = HarcBinaryWriter()
        writer.append(Self.magic)
        writer.append(protocolVersion.major)
        writer.append(protocolVersion.minor)
        writer.append(uuid: ticketID)
        writer.append(uuid: claimID)
        writer.append(uuid: libraryID.rawValue)
        writer.append(hostAuthorityID.rawBytes)
        writer.append(hostAuthorityPublicKey.rawBytes)
        writer.append(tlsSPKISHA256)
        writer.append(deviceID.rawBytes)
        writer.append(devicePublicKey.rawBytes)
        writer.append(clientNonce)
        writer.append(hostNonce)
        writer.append(ticketSecretBindingSHA256)
        writer.append(UInt8(requestedScopes.count))
        for scope in requestedScopes {
            try writer.appendLengthPrefixedASCII(scope.rawValue, field: "requestedScope")
        }
        guard writer.data.count <= HarcProtocolLimits.pairingTranscriptBytes else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: "PairingTranscriptV1",
                limit: UInt64(HarcProtocolLimits.pairingTranscriptBytes),
                actual: UInt64(writer.data.count)
            )
        }
        return writer.data
    }

    public static func decode(
        _ exactBytes: Data,
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws -> Self {
        var reader = try HarcBinaryReader(
            exactBytes,
            maximumBytes: HarcProtocolLimits.pairingTranscriptBytes,
            field: "PairingTranscriptV1"
        )
        try reader.requireMagic(Self.magic, field: "PairingTranscriptV1")
        let version = HarcProtocolVersion(
            major: try reader.readUInt16(field: "protocolMajor"),
            minor: try reader.readUInt16(field: "protocolMinor")
        )
        try versionPolicy.validate(version)
        let ticketID = try reader.readUUID(field: "ticketID")
        let claimID = try reader.readUUID(field: "claimID")
        let libraryID = LibraryID(try reader.readUUID(field: "libraryID"))
        let hostAuthorityID = try HostAuthorityID(
            reader.readData(count: HostAuthorityID.byteCount, field: "hostAuthorityID")
        )
        let hostPublicKey = try P256X963PublicKey(
            reader.readData(count: P256X963PublicKey.byteCount, field: "hostPublicKeyX963")
        )
        let tlsSPKI = try reader.readData(count: 32, field: "tlsSPKISHA256")
        let deviceID = try DeviceID(
            reader.readData(count: DeviceID.byteCount, field: "deviceID")
        )
        let devicePublicKey = try P256X963PublicKey(
            reader.readData(count: P256X963PublicKey.byteCount, field: "devicePublicKeyX963")
        )
        let clientNonce = try reader.readData(count: 32, field: "clientNonce")
        let hostNonce = try reader.readData(count: 32, field: "hostNonce")
        let secretBinding = try reader.readData(
            count: 32,
            field: "ticketSecretBindingSHA256"
        )
        let scopeCount = Int(try reader.readUInt8(field: "requestedScopeCount"))
        guard scopeCount <= HarcProtocolLimits.pairingRequestedScopes else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "requestedScopeCount",
                minimum: 0,
                maximum: UInt64(HarcProtocolLimits.pairingRequestedScopes),
                actual: UInt64(scopeCount)
            )
        }
        var scopes: [AuthorizationScope] = []
        scopes.reserveCapacity(scopeCount)
        for index in 0 ..< scopeCount {
            let raw = try reader.readLengthPrefixedASCII(field: "requestedScopes[\(index)]")
            guard let scope = AuthorizationScope(rawValue: raw) else {
                throw HarcProtocolCodecError.invalidText(field: "requestedScopes[\(index)]")
            }
            scopes.append(scope)
        }
        try reader.requireEnd()
        let decoded = try Self(
            protocolVersion: version,
            ticketID: ticketID,
            claimID: claimID,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            hostAuthorityPublicKey: hostPublicKey,
            tlsSPKISHA256: tlsSPKI,
            deviceID: deviceID,
            devicePublicKey: devicePublicKey,
            clientNonce: clientNonce,
            hostNonce: hostNonce,
            ticketSecretBindingSHA256: secretBinding,
            requestedScopes: scopes,
            versionPolicy: versionPolicy
        )
        guard try decoded.encoded() == exactBytes else {
            throw HarcProtocolCodecError.headerPayloadMismatch(field: "canonicalPairingTranscript")
        }
        return decoded
    }

    public func clientProofDigest() throws -> P256SHA256Digest {
        try P256SHA256Digest(
            harcDomainSeparatedSHA256(Self.proofDomain, encoded())
        )
    }

    public func signClientProof(using signer: any P256DigestSigner) throws -> P256RawSignature {
        guard signer.publicKey == devicePublicKey else {
            throw HarcProtocolCodecError.invalidKeyBinding(field: "devicePublicKeyX963")
        }
        return try signer.sign(digest: clientProofDigest())
    }

    public func verifyClientProof(_ signature: P256RawSignature) throws {
        guard devicePublicKey.isValidSignature(signature, for: try clientProofDigest()) else {
            throw HarcProtocolCodecError.invalidSignature
        }
    }

    public func sasDigest(clientSignature: P256RawSignature) throws -> Data {
        harcDomainSeparatedSHA256(
            Self.sasDomain,
            try encoded(),
            clientSignature.rawBytes
        )
    }

    private static func validateCanonicalScopes(_ scopes: [AuthorizationScope]) throws {
        for (prior, current) in zip(scopes, scopes.dropFirst()) {
            if prior == current {
                throw HarcProtocolCodecError.duplicateValue(field: "requestedScopes")
            }
            guard prior.rawValue.lexicographicallyPrecedes(current.rawValue) else {
                throw HarcProtocolCodecError.nonCanonicalOrder(field: "requestedScopes")
            }
        }
    }
}

public struct HarcSASDictionaryV1: Equatable, Hashable, Sendable {
    public static let wordCount = 2_048
    public static let expectedSHA256 = Data([
        0x2f, 0x5e, 0xed, 0x53, 0xa4, 0x72, 0x7b, 0x4b,
        0xf8, 0x88, 0x0d, 0x8f, 0x3f, 0x19, 0x9e, 0xfc,
        0x90, 0xe5, 0x85, 0x03, 0x64, 0x6d, 0x9f, 0xf8,
        0xef, 0xf3, 0xa2, 0xed, 0x3b, 0x24, 0xdb, 0xda,
    ])

    public let words: [String]

    /// Loads the single checked-in SAS dictionary that ships with the
    /// `HarcProtocol` product. Hash validation remains mandatory so an app
    /// bundle or packaging error cannot silently change the displayed phrase.
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(
            forResource: "harc-sas-words-v1",
            withExtension: "txt"
        ) else {
            throw HarcProtocolCodecError.invalidSASDictionary
        }
        return try Self(exactUTF8LFBytes: Data(contentsOf: url))
    }

    public init(exactUTF8LFBytes bytes: Data) throws {
        guard Data(SHA256.hash(data: bytes)) == Self.expectedSHA256,
              let text = String(data: bytes, encoding: .utf8),
              Data(text.utf8) == bytes,
              text.hasSuffix("\n") else {
            throw HarcProtocolCodecError.invalidSASDictionary
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true else {
            throw HarcProtocolCodecError.invalidSASDictionary
        }
        lines.removeLast()
        let words = lines.map(String.init)
        guard words.count == Self.wordCount,
              Set(words).count == Self.wordCount,
              words.allSatisfy({ word in
                  !word.isEmpty && word.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7a }
              }) else {
            throw HarcProtocolCodecError.invalidSASDictionary
        }
        self.words = words
    }

    public func phrase(
        for transcript: PairingTranscriptV1,
        clientSignature: P256RawSignature
    ) throws -> HarcSASPhraseV1 {
        let digest = try transcript.sasDigest(clientSignature: clientSignature)
        let bytes = [UInt8](digest)
        let indexes = [
            (Int(bytes[0]) << 3) | (Int(bytes[1]) >> 5),
            ((Int(bytes[1]) & 0x1f) << 6) | (Int(bytes[2]) >> 2),
            ((Int(bytes[2]) & 0x03) << 9) | (Int(bytes[3]) << 1) | (Int(bytes[4]) >> 7),
            ((Int(bytes[4]) & 0x7f) << 4) | (Int(bytes[5]) >> 4),
        ]
        return HarcSASPhraseV1(
            digest: digest,
            indexes: indexes,
            words: indexes.map { words[$0] }
        )
    }
}

public struct HarcSASPhraseV1: Equatable, Hashable, Sendable {
    public let digest: Data
    public let indexes: [Int]
    public let words: [String]

    public var displayedPhrase: String { words.joined(separator: " ") }

    fileprivate init(digest: Data, indexes: [Int], words: [String]) {
        self.digest = digest
        self.indexes = indexes
        self.words = words
    }
}
