#if canImport(Network)
import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
@testable import HarcClientTransport

enum TransportTrustFixtures {
    static let nowMilliseconds: UInt64 = 2_000_000_000_000
    static let libraryID = LibraryID(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    enum ExtensionProfile: Equatable {
        case valid
        case missingTransportSet
        case duplicateTransportSet
        case criticalTransportSet
        case wrongKeyUsage
        case oversizedTransportSet
    }

    static func authorityKey(_ byte: UInt8 = 0x31) throws -> SoftwareP256SigningKey {
        _ = byte
        return SoftwareP256SigningKey()
    }

    static func tlsKey(_ byte: UInt8 = 0x41) throws -> P256.Signing.PrivateKey {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = byte
        return try P256.Signing.PrivateKey(rawRepresentation: scalar)
    }

    static func spkiDER(for key: P256.Signing.PrivateKey) -> Data {
        sequence(
            sequence(
                objectIdentifier(ecPublicKeyOID)
                    + objectIdentifier(prime256v1OID)
            )
                + bitString(Data([0]) + key.publicKey.x963Representation)
        )
    }

    static func spkiSHA256(for key: P256.Signing.PrivateKey) -> Data {
        Data(SHA256.hash(data: spkiDER(for: key)))
    }

    static func transportSet(
        authorityKey: SoftwareP256SigningKey,
        tlsKeys: [P256.Signing.PrivateKey],
        epoch: UInt64,
        issuedAt: UInt64 = nowMilliseconds - 120_000,
        entryNotBefore: UInt64 = nowMilliseconds - 60_000,
        entryNotAfter: UInt64 = nowMilliseconds + 86_400_000
    ) throws -> VerifiedHostTransportSetV1 {
        let entries = try tlsKeys.map { key in
            try HostTransportEntryV1(
                tlsSPKISHA256: spkiSHA256(for: key),
                notBeforeUnixMilliseconds: entryNotBefore,
                notAfterUnixMilliseconds: entryNotAfter
            )
        }.sorted {
            $0.tlsSPKISHA256.lexicographicallyPrecedes($1.tlsSPKISHA256)
        }
        let payload = try HostTransportSetV1(
            libraryID: libraryID,
            hostAuthorityID: authorityKey.publicKey.hostAuthorityID,
            setEpoch: epoch,
            issuedAtUnixMilliseconds: issuedAt,
            entries: entries
        )
        let payloadBytes = payload.encoded()
        let header = try HarcSignedEnvelopeV1(
            messageType: .hostTransportSet,
            libraryID: payload.libraryID,
            hostAuthorityID: payload.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: nil,
            issuedAtUnixMilliseconds: payload.issuedAtUnixMilliseconds,
            expiresAtUnixMilliseconds: nil,
            payloadType: .hostTransportSet,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payloadBytes)
        )
        let signed = try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: payloadBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: payload.protocolVersion,
                libraryID: payload.libraryID,
                hostAuthorityID: payload.hostAuthorityID,
                issuedAtUnixMilliseconds: payload.issuedAtUnixMilliseconds
            ),
            using: authorityKey
        )
        return try VerifiedHostTransportSetV1.decode(
            signed.exactFramedBytes,
            hostAuthorityPublicKey: authorityKey.publicKey
        )
    }

    static func leafCertificate(
        tlsKey: P256.Signing.PrivateKey,
        exactTransportSet: Data,
        notBefore: UInt64 = nowMilliseconds - 30_000,
        notAfter: UInt64 = nowMilliseconds + 3_600_000,
        profile: ExtensionProfile = .valid
    ) throws -> Data {
        let transportBytes = profile == .oversizedTransportSet
            ? Data(repeating: 0xa5, count: 4_097)
            : exactTransportSet
        let basicConstraints = extensionValue(
            oid: basicConstraintsOID,
            critical: true,
            value: sequence(Data())
        )
        let keyUsage = extensionValue(
            oid: keyUsageOID,
            critical: true,
            value: profile == .wrongKeyUsage
                ? bitString(Data([0x07, 0x40]))
                : bitString(Data([0x07, 0x80]))
        )
        let extendedKeyUsage = extensionValue(
            oid: extendedKeyUsageOID,
            critical: false,
            value: sequence(objectIdentifier(serverAuthOID))
        )
        let transport = extensionValue(
            oid: transportSetOID,
            critical: profile == .criticalTransportSet,
            value: transportBytes
        )
        var encodedExtensions = basicConstraints + keyUsage + extendedKeyUsage
        if profile != .missingTransportSet {
            encodedExtensions.append(transport)
        }
        if profile == .duplicateTransportSet {
            encodedExtensions.append(transport)
        }

        let signatureAlgorithm = sequence(objectIdentifier(ecdsaWithSHA256OID))
        let tbs = sequence(
            explicit(tag: 0xa0, integer(Data([0x02])))
                + integer(Data([0x01]))
                + signatureAlgorithm
                + harcName
                + sequence(time(notBefore) + time(notAfter))
                + harcName
                + spkiDER(for: tlsKey)
                + explicit(tag: 0xa3, sequence(encodedExtensions))
        )
        let signature = try tlsKey.signature(for: tbs).derRepresentation
        return sequence(
            tbs
                + signatureAlgorithm
                + bitString(Data([0]) + signature)
        )
    }

    static func persistedState(
        authorityKey: SoftwareP256SigningKey,
        verifiedSet: VerifiedHostTransportSetV1
    ) throws -> HarcPersistedTransportTrustState {
        HarcPersistedTransportTrustState(
            hostTrust: try RecordingHostTrustBinding(
                libraryID: verifiedSet.transportSet.libraryID,
                hostAuthorityID: verifiedSet.transportSet.hostAuthorityID,
                hostAuthorityPublicKey: authorityKey.publicKey
            ),
            highestTransportSetEpoch: verifiedSet.transportSet.setEpoch,
            exactHighestTransportSet: verifiedSet.exactSignedBytes
        )
    }

    private static let ecdsaWithSHA256OID = Data([
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02,
    ])
    private static let ecPublicKeyOID = Data([
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    ])
    private static let prime256v1OID = Data([
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
    ])
    private static let basicConstraintsOID = Data([0x55, 0x1d, 0x13])
    private static let keyUsageOID = Data([0x55, 0x1d, 0x0f])
    private static let extendedKeyUsageOID = Data([0x55, 0x1d, 0x25])
    private static let serverAuthOID = Data([
        0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01,
    ])
    private static let transportSetOID =
        HarcTLSLeafDERParser.transportSetExtensionOIDBytes
    private static let harcName = Data([
        0x30, 0x1a, 0x31, 0x18, 0x30, 0x16, 0x06, 0x03, 0x55, 0x04,
        0x03, 0x0c, 0x0f, 0x48, 0x61, 0x72, 0x63, 0x20, 0x4c, 0x6f,
        0x63, 0x61, 0x6c, 0x20, 0x48, 0x6f, 0x73, 0x74,
    ])

    private static func extensionValue(
        oid: Data,
        critical: Bool,
        value: Data
    ) -> Data {
        sequence(
            objectIdentifier(oid)
                + (critical ? boolean(true) : Data())
                + octetString(value)
        )
    }

    private static func time(_ unixMilliseconds: UInt64) -> Data {
        let date = Date(
            timeIntervalSince1970: Double(unixMilliseconds) / 1_000
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let values = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = values.year!
        let text: String
        let tag: UInt8
        if (1950...2049).contains(year) {
            tag = 0x17
            text = String(
                format: "%02d%02d%02d%02d%02d%02dZ",
                year % 100,
                values.month!,
                values.day!,
                values.hour!,
                values.minute!,
                values.second!
            )
        } else {
            tag = 0x18
            text = String(
                format: "%04d%02d%02d%02d%02d%02dZ",
                year,
                values.month!,
                values.day!,
                values.hour!,
                values.minute!,
                values.second!
            )
        }
        return tlv(tag: tag, content: Data(text.utf8))
    }

    private static func sequence(_ content: Data) -> Data {
        tlv(tag: 0x30, content: content)
    }

    private static func explicit(tag: UInt8, _ content: Data) -> Data {
        tlv(tag: tag, content: content)
    }

    private static func integer(_ content: Data) -> Data {
        tlv(tag: 0x02, content: content)
    }

    private static func objectIdentifier(_ content: Data) -> Data {
        tlv(tag: 0x06, content: content)
    }

    private static func bitString(_ content: Data) -> Data {
        tlv(tag: 0x03, content: content)
    }

    private static func octetString(_ content: Data) -> Data {
        tlv(tag: 0x04, content: content)
    }

    private static func boolean(_ value: Bool) -> Data {
        tlv(tag: 0x01, content: Data([value ? 0xff : 0]))
    }

    private static func tlv(tag: UInt8, content: Data) -> Data {
        var encoded = Data([tag])
        if content.count < 128 {
            encoded.append(UInt8(content.count))
        } else {
            var remaining = content.count
            var length: [UInt8] = []
            while remaining > 0 {
                length.append(UInt8(remaining & 0xff))
                remaining >>= 8
            }
            length.reverse()
            encoded.append(0x80 | UInt8(length.count))
            encoded.append(contentsOf: length)
        }
        encoded.append(content)
        return encoded
    }
}

enum TransportTrustTestPersistenceError: Error, Equatable {
    case forcedFailure
}

actor TransportTrustTestPersistence: HarcTransportTrustPersistence {
    private var state: HarcPersistedTransportTrustState?
    private let failPersist: Bool
    private let ignorePersist: Bool
    private let blockFirstPersist: Bool
    private var firstPersistBlocked = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var persistInFlight = 0
    private(set) var maximumConcurrentPersists = 0
    private(set) var persistedEpochs: [UInt64] = []

    init(
        state: HarcPersistedTransportTrustState?,
        failPersist: Bool = false,
        ignorePersist: Bool = false,
        blockFirstPersist: Bool = false
    ) {
        self.state = state
        self.failPersist = failPersist
        self.ignorePersist = ignorePersist
        self.blockFirstPersist = blockFirstPersist
    }

    func loadActiveTransportTrust() -> HarcPersistedTransportTrustState? {
        state
    }

    func persistVerifiedTransportSet(
        _ evidence: ValidatedTransportSetEvidence
    ) async throws {
        persistInFlight += 1
        maximumConcurrentPersists = max(maximumConcurrentPersists, persistInFlight)
        defer { persistInFlight -= 1 }

        if blockFirstPersist, persistedEpochs.isEmpty {
            firstPersistBlocked = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        if failPersist {
            throw TransportTrustTestPersistenceError.forcedFailure
        }
        if ignorePersist {
            return
        }
        guard let current = state else {
            state = HarcPersistedTransportTrustState(
                hostTrust: evidence.hostTrust,
                highestTransportSetEpoch: evidence.epoch,
                exactHighestTransportSet: evidence.exactSignedBytes
            )
            persistedEpochs.append(evidence.epoch)
            return
        }
        guard current.hostTrust == evidence.hostTrust else {
            throw HarcTransportTrustError.activeAdoptionChanged
        }
        if evidence.epoch < current.highestTransportSetEpoch {
            throw HarcTransportTrustError.transportSetRollback(
                stored: current.highestTransportSetEpoch,
                presented: evidence.epoch
            )
        }
        if evidence.epoch == current.highestTransportSetEpoch {
            guard evidence.exactSignedBytes == current.exactHighestTransportSet else {
                throw HarcTransportTrustError.transportSetEquivocation(
                    epoch: evidence.epoch
                )
            }
            return
        }
        state = HarcPersistedTransportTrustState(
            hostTrust: current.hostTrust,
            highestTransportSetEpoch: evidence.epoch,
            exactHighestTransportSet: evidence.exactSignedBytes
        )
        persistedEpochs.append(evidence.epoch)
    }

    func isFirstPersistBlocked() -> Bool {
        firstPersistBlocked
    }

    func releaseFirstPersist() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func currentState() -> HarcPersistedTransportTrustState? {
        state
    }
}

actor TransportTrustCompletionProbe<Value: Sendable> {
    private var value: Value?

    func record(_ value: Value) {
        self.value = value
    }

    func snapshot() -> Value? {
        value
    }
}
#endif
