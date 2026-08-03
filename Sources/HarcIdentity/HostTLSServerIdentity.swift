import CryptoKit
import Foundation
@preconcurrency import Security

public struct HostTLSServerCertificateRequest: Equatable, Sendable {
    public static let transportSetExtensionOID =
        "2.25.148088663479842491025708621331721812820"
    public static let maximumTransportSetExtensionBytes = 4_096
    public static let maximumValidity: TimeInterval = 90 * 24 * 60 * 60

    public let transportSetEntryNotBefore: Date
    public let transportSetEntryNotAfter: Date
    public let expectedTLSSPKISHA256: Data
    public let framedSignedTransportSet: Data

    public init(
        transportSetEntryNotBefore: Date,
        transportSetEntryNotAfter: Date,
        expectedTLSSPKISHA256: Data,
        framedSignedTransportSet: Data
    ) throws {
        guard transportSetEntryNotBefore.timeIntervalSinceReferenceDate.isFinite,
              transportSetEntryNotAfter.timeIntervalSinceReferenceDate.isFinite,
              transportSetEntryNotBefore < transportSetEntryNotAfter,
              transportSetEntryNotAfter.timeIntervalSince(transportSetEntryNotBefore)
                <= Self.maximumValidity,
              Self.ceilToWholeSecond(transportSetEntryNotBefore)
                < Self.floorToWholeSecond(transportSetEntryNotAfter)
        else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        guard expectedTLSSPKISHA256.count == SHA256.byteCount else {
            throw HostCryptographicStateError.certificateProfileMismatch(
                field: "tlsSPKISHA256"
            )
        }
        guard !framedSignedTransportSet.isEmpty else {
            throw HostCryptographicStateError.transportSetExtensionEmpty
        }
        guard framedSignedTransportSet.count <= Self.maximumTransportSetExtensionBytes else {
            throw HostCryptographicStateError.transportSetExtensionTooLarge(
                actual: framedSignedTransportSet.count
            )
        }
        self.transportSetEntryNotBefore = transportSetEntryNotBefore
        self.transportSetEntryNotAfter = transportSetEntryNotAfter
        self.expectedTLSSPKISHA256 = expectedTLSSPKISHA256
        self.framedSignedTransportSet = framedSignedTransportSet
    }

    var certificateNotBefore: Date { Self.ceilToWholeSecond(transportSetEntryNotBefore) }
    var certificateNotAfter: Date { Self.floorToWholeSecond(transportSetEntryNotAfter) }

    private static func ceilToWholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
    }

    private static func floorToWholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }
}

public struct HostTLSServerCertificateFacts: Equatable, Sendable {
    public let certificateDER: Data
    public let serialNumber: Data
    public let notValidBefore: Date
    public let notValidAfter: Date
    public let publicKeyX963: P256X963PublicKey
    public let tlsSPKISHA256: Data
    public let framedSignedTransportSet: Data

    public static func validate(
        certificateDER: Data,
        request: HostTLSServerCertificateRequest
    ) throws -> Self {
        try HostTLSCertificateDER.parseAndValidate(
            certificateDER,
            request: request
        )
    }
}

/// The only public bridge from Harc identity state to Network.framework TLS.
/// It contains the installed certificate and matching opaque `SecIdentity`,
/// never exportable private-key bytes or a standalone private `SecKey`.
public struct HostTLSServerIdentity: @unchecked Sendable {
    public let securityIdentity: SecIdentity
    public let certificate: HostTLSServerCertificateFacts

    init(securityIdentity: SecIdentity, certificate: HostTLSServerCertificateFacts) {
        self.securityIdentity = securityIdentity
        self.certificate = certificate
    }
}

enum HostTLSCertificateSerialNumber {
    static let maximumOctets = 20

    /// Converts exactly 20 random octets into one canonical positive DER
    /// INTEGER content value without ever exceeding X.509's 20-octet limit.
    static func canonicalize(_ randomBytes: [UInt8]) throws -> Data {
        guard randomBytes.count == maximumOctets else {
            throw HostCryptographicStateError.certificateProfileMismatch(
                field: "serialNumber"
            )
        }
        var bytes = randomBytes
        bytes[0] &= 0x7f
        if !bytes.contains(where: { $0 != 0 }) {
            bytes[bytes.count - 1] = 1
        }
        while bytes.count > 1,
              bytes[0] == 0,
              bytes[1] & 0x80 == 0 {
            bytes.removeFirst()
        }
        return Data(bytes)
    }
}

extension HostTLSSigningIdentity {
    /// SHA-256 of the complete DER SubjectPublicKeyInfo for the TLS P-256 key.
    package var tlsSPKISHA256: Data {
        publicKey.tlsSPKISHA256
    }

    /// Issues the exact self-signed Harc leaf profile without mutating the
    /// certificate Keychain. Callers persist these exact DER bytes in HostDB
    /// before resolving the serving identity, so restart never proliferates
    /// certificates or silently changes the embedded transport set.
    package func issueServerCertificate(
        request: HostTLSServerCertificateRequest
    ) throws -> HostTLSServerCertificateFacts {
        try issueServerCertificate(request: request, serialNumber: nil)
    }

    func issueServerCertificate(
        request: HostTLSServerCertificateRequest,
        serialNumber: Data?
    ) throws -> HostTLSServerCertificateFacts {
        guard case .securityFramework(let securityKey) = key else {
            throw HostCryptographicStateError.serverIdentityUnavailable
        }
        guard request.expectedTLSSPKISHA256 == tlsSPKISHA256 else {
            throw HostCryptographicStateError.certificateProfileMismatch(
                field: "transportSetSPKIBinding"
            )
        }
        let serial = try serialNumber ?? HostTLSCertificateDER.randomSerialNumber()
        let certificateDER = try HostTLSCertificateDER.issue(
            privateKey: securityKey.copyPrivateKeyForCertificateIssuance(),
            publicKey: publicKey,
            serialNumber: serial,
            notValidBefore: request.certificateNotBefore,
            notValidAfter: request.certificateNotAfter,
            framedSignedTransportSet: request.framedSignedTransportSet
        )
        let facts = try HostTLSServerCertificateFacts.validate(
            certificateDER: certificateDER,
            request: request
        )
        guard facts.publicKeyX963 == publicKey else {
            throw HostCryptographicStateError.serverCertificateKeyMismatch
        }
        return facts
    }

    /// Revalidates previously persisted DER, installs that exact public
    /// certificate if necessary, and resolves it against this permanent key.
    package func resolveServerIdentity(
        certificateDER: Data,
        request: HostTLSServerCertificateRequest
    ) throws -> HostTLSServerIdentity {
        guard case .securityFramework(let securityKey) = key else {
            throw HostCryptographicStateError.serverIdentityUnavailable
        }
        guard request.expectedTLSSPKISHA256 == tlsSPKISHA256 else {
            throw HostCryptographicStateError.certificateProfileMismatch(
                field: "transportSetSPKIBinding"
            )
        }
        let facts = try HostTLSServerCertificateFacts.validate(
            certificateDER: certificateDER,
            request: request
        )
        guard facts.publicKeyX963 == publicKey else {
            throw HostCryptographicStateError.serverCertificateKeyMismatch
        }
        let identity = try HostTLSCertificateDER.installAndResolveIdentity(
            certificateDER: certificateDER,
            expectedPublicKey: publicKey,
            useDataProtectionKeychain: securityKey.usesDataProtectionKeychain
        )
        return HostTLSServerIdentity(securityIdentity: identity, certificate: facts)
    }

    /// Compatibility composition for callers that do not need restart-stable
    /// DER persistence. Host lifecycle code uses the split APIs above.
    package func issueServerIdentity(
        request: HostTLSServerCertificateRequest
    ) throws -> HostTLSServerIdentity {
        try issueServerIdentity(request: request, serialNumber: nil)
    }

    func issueServerIdentity(
        request: HostTLSServerCertificateRequest,
        serialNumber: Data?
    ) throws -> HostTLSServerIdentity {
        let facts = try issueServerCertificate(
            request: request,
            serialNumber: serialNumber
        )
        return try resolveServerIdentity(
            certificateDER: facts.certificateDER,
            request: request
        )
    }

    /// Removes a test/runtime-installed leaf without racing another identity
    /// resolution in this process.
    package static func deleteInstalledServerCertificateBestEffort(
        certificateDER: Data
    ) {
        HostTLSCertificateDER.deleteInstalledCertificateBestEffort(
            certificateDER: certificateDER
        )
    }
}

extension P256X963PublicKey {
    /// SHA-256 of the complete DER SubjectPublicKeyInfo for this TLS P-256 key.
    /// This public-only fact is safe to use when validating a non-mutating
    /// cryptographic-state inspection during serving startup.
    public var tlsSPKISHA256: Data {
        HostTLSCertificateDER.spkiSHA256(publicKey: self)
    }
}

private enum HostTLSCertificateDER {
    // DER content bytes, without the OBJECT IDENTIFIER tag and length.
    private static let commonNameOID = Data([0x55, 0x04, 0x03])
    private static let ecdsaWithSHA256OID = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])
    private static let ecPublicKeyOID = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])
    private static let prime256v1OID = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
    private static let basicConstraintsOID = Data([0x55, 0x1d, 0x13])
    private static let keyUsageOID = Data([0x55, 0x1d, 0x0f])
    private static let extendedKeyUsageOID = Data([0x55, 0x1d, 0x25])
    private static let serverAuthOID = Data([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])

    // 2.25.148088663479842491025708621331721812820. SwiftASN1 1.x
    // represents OID components as UInt and therefore cannot express this
    // UUID-derived 128-bit arc. These are its canonical base-128 content bytes.
    private static let harcTransportSetOID = Data([
        0x69, 0x81, 0xde, 0xe8, 0xeb, 0xb4, 0xc0, 0xac, 0xba, 0xa9,
        0xcd, 0xae, 0xf4, 0xc2, 0xe9, 0xb7, 0xe9, 0xbb, 0xf6, 0x54,
    ])

    private static var signatureAlgorithm: Data {
        sequence(objectIdentifier(ecdsaWithSHA256OID))
    }

    static func spkiDER(publicKey: P256X963PublicKey) -> Data {
        sequence(
            sequence(
                objectIdentifier(ecPublicKeyOID)
                    + objectIdentifier(prime256v1OID)
            )
                + bitString(Data([0x00]) + publicKey.rawBytes)
        )
    }

    static func spkiSHA256(publicKey: P256X963PublicKey) -> Data {
        Data(SHA256.hash(data: spkiDER(publicKey: publicKey)))
    }

    static func randomSerialNumber() throws -> Data {
        var bytes = [UInt8](
            repeating: 0,
            count: HostTLSCertificateSerialNumber.maximumOctets
        )
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw HostCryptographicStateError.secureRandomFailure(status)
        }
        return try HostTLSCertificateSerialNumber.canonicalize(bytes)
    }

    static func issue(
        privateKey: SecKey,
        publicKey: P256X963PublicKey,
        serialNumber: Data,
        notValidBefore: Date,
        notValidAfter: Date,
        framedSignedTransportSet: Data
    ) throws -> Data {
        try validateSerialNumber(serialNumber)
        let name = sequence(
            set(
                sequence(
                    objectIdentifier(commonNameOID)
                        + utf8String(Data("Harc Local Host".utf8))
                )
            )
        )
        let validity = sequence(
            try time(notValidBefore) + time(notValidAfter)
        )
        let extensions = try certificateExtensions(
            framedSignedTransportSet: framedSignedTransportSet
        )
        let tbsCertificate = sequence(
            explicit(tag: 0xa0, integer(Data([0x02])))
                + integer(serialNumber)
                + signatureAlgorithm
                + name
                + validity
                + name
                + spkiDER(publicKey: publicKey)
                + explicit(tag: 0xa3, extensions)
        )

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signingError
        ) as Data? else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        return sequence(
            tbsCertificate
                + signatureAlgorithm
                + bitString(Data([0x00]) + signature)
        )
    }

    static func parseAndValidate(
        _ certificateDER: Data,
        request: HostTLSServerCertificateRequest
    ) throws -> HostTLSServerCertificateFacts {
        do {
            var certificateCursor = DERCursor(certificateDER)
            let certificate = try certificateCursor.read(tag: 0x30)
            try certificateCursor.requireEnd()
            var fields = DERCursor(certificate.content)
            let tbs = try fields.read(tag: 0x30)
            let outerAlgorithm = try fields.read(tag: 0x30)
            let signatureValue = try fields.read(tag: 0x03)
            try fields.requireEnd()
            guard outerAlgorithm.encoded == signatureAlgorithm,
                  signatureValue.content.first == 0,
                  signatureValue.content.count > 1 else {
                throw HostCryptographicStateError.certificateProfileMismatch(
                    field: "signatureAlgorithm"
                )
            }

            var tbsFields = DERCursor(tbs.content)
            let version = try tbsFields.read(tag: 0xa0)
            guard version.content == integer(Data([0x02])) else {
                throw HostCryptographicStateError.certificateProfileMismatch(field: "version")
            }
            let serial = try tbsFields.read(tag: 0x02).content
            try validateSerialNumber(serial)
            guard try tbsFields.read(tag: 0x30).encoded == signatureAlgorithm else {
                throw HostCryptographicStateError.certificateProfileMismatch(
                    field: "tbsSignatureAlgorithm"
                )
            }
            let issuer = try tbsFields.read(tag: 0x30)
            let validity = try tbsFields.read(tag: 0x30)
            let subject = try tbsFields.read(tag: 0x30)
            guard issuer.encoded == subject.encoded else {
                throw HostCryptographicStateError.certificateProfileMismatch(field: "selfIssuedName")
            }
            let spki = try tbsFields.read(tag: 0x30)
            let publicKey = try parseP256SPKI(spki.encoded)
            let extensions = try tbsFields.read(tag: 0xa3)
            try tbsFields.requireEnd()

            let (notBefore, notAfter) = try parseValidity(validity.content)
            guard notBefore >= request.certificateNotBefore,
                  notAfter <= request.certificateNotAfter,
                  notBefore < notAfter,
                  notAfter.timeIntervalSince(notBefore)
                    <= HostTLSServerCertificateRequest.maximumValidity else {
                throw HostCryptographicStateError.invalidCertificateValidity
            }
            let framedTransportSet = try parseExtensions(extensions.content)
            guard framedTransportSet == request.framedSignedTransportSet else {
                throw HostCryptographicStateError.certificateProfileMismatch(
                    field: "transportSetExtensionBytes"
                )
            }
            let observedSPKI = Data(SHA256.hash(data: spki.encoded))
            guard observedSPKI == request.expectedTLSSPKISHA256 else {
                throw HostCryptographicStateError.certificateProfileMismatch(
                    field: "tlsSPKISHA256"
                )
            }
            try verifySelfSignature(
                publicKey: publicKey,
                tbsCertificate: tbs.encoded,
                signatureDER: signatureValue.content.dropFirst()
            )
            guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
                throw HostCryptographicStateError.invalidServerCertificate
            }
            return HostTLSServerCertificateFacts(
                certificateDER: certificateDER,
                serialNumber: serial,
                notValidBefore: notBefore,
                notValidAfter: notAfter,
                publicKeyX963: publicKey,
                tlsSPKISHA256: observedSPKI,
                framedSignedTransportSet: framedTransportSet
            )
        } catch let error as HostCryptographicStateError {
            throw error
        } catch {
            throw HostCryptographicStateError.invalidServerCertificate
        }
    }

    static func installAndResolveIdentity(
        certificateDER: Data,
        expectedPublicKey: P256X963PublicKey,
        useDataProtectionKeychain: Bool
    ) throws -> SecIdentity {
        try HostSecurityP256SigningKey.withKeychainLifecycle {
            try installAndResolveIdentityLocked(
                certificateDER: certificateDER,
                expectedPublicKey: expectedPublicKey,
                useDataProtectionKeychain: useDataProtectionKeychain
            )
        }
    }

    private static func installAndResolveIdentityLocked(
        certificateDER: Data,
        expectedPublicKey: P256X963PublicKey,
        useDataProtectionKeychain: Bool
    ) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(
            nil,
            certificateDER as CFData
        ), let certificateKey = SecCertificateCopyKey(certificate) else {
            throw HostCryptographicStateError.invalidServerCertificate
        }
        guard try externalPublicKey(certificateKey) == expectedPublicKey else {
            throw HostCryptographicStateError.serverCertificateKeyMismatch
        }

        var addAttributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrLabel as String: "Harc TLS server certificate",
        ]
        if useDataProtectionKeychain {
            addAttributes[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        }
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw HostCryptographicStateError.unexpectedKeychainStatus(addStatus)
        }

        var identity: SecIdentity?
        let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard identityStatus == errSecSuccess, let identity else {
            throw HostCryptographicStateError.serverIdentityUnavailable
        }
        var matchedPrivateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &matchedPrivateKey) == errSecSuccess,
              let matchedPrivateKey,
              let matchedPublicKey = SecKeyCopyPublicKey(matchedPrivateKey),
              try externalPublicKey(matchedPublicKey) == expectedPublicKey
        else {
            throw HostCryptographicStateError.serverIdentityUnavailable
        }
        return identity
    }

    static func deleteInstalledCertificateBestEffort(certificateDER: Data) {
        HostSecurityP256SigningKey.withKeychainLifecycle {
            guard let certificate = SecCertificateCreateWithData(
                nil,
                certificateDER as CFData
            ) else {
                return
            }
            _ = SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
            ] as CFDictionary)
        }
    }

    private static func certificateExtensions(
        framedSignedTransportSet: Data
    ) throws -> Data {
        guard !framedSignedTransportSet.isEmpty else {
            throw HostCryptographicStateError.transportSetExtensionEmpty
        }
        guard framedSignedTransportSet.count
                <= HostTLSServerCertificateRequest.maximumTransportSetExtensionBytes else {
            throw HostCryptographicStateError.transportSetExtensionTooLarge(
                actual: framedSignedTransportSet.count
            )
        }
        let basicConstraints = extensionValue(
            oid: basicConstraintsOID,
            critical: true,
            value: sequence(Data())
        )
        let keyUsage = extensionValue(
            oid: keyUsageOID,
            critical: true,
            value: bitString(Data([0x07, 0x80]))
        )
        let extendedKeyUsage = extensionValue(
            oid: extendedKeyUsageOID,
            critical: false,
            value: sequence(objectIdentifier(serverAuthOID))
        )
        let harcTransportSet = extensionValue(
            oid: harcTransportSetOID,
            critical: false,
            value: framedSignedTransportSet
        )
        return sequence(
            basicConstraints + keyUsage + extendedKeyUsage + harcTransportSet
        )
    }

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

    private static func parseExtensions(_ bytes: Data) throws -> Data {
        var outer = DERCursor(bytes)
        let sequenceNode = try outer.read(tag: 0x30)
        try outer.requireEnd()
        var extensions = DERCursor(sequenceNode.content)
        var sawBasicConstraints = false
        var sawKeyUsage = false
        var sawExtendedKeyUsage = false
        var framedTransportSet: Data?
        var count = 0
        while !extensions.isAtEnd {
            count += 1
            let extensionNode = try extensions.read(tag: 0x30)
            var fields = DERCursor(extensionNode.content)
            let oid = try fields.read(tag: 0x06).content
            var critical = false
            if fields.peekTag() == 0x01 {
                let criticalValue = try fields.read(tag: 0x01).content
                guard criticalValue == Data([0xff]) else {
                    throw HostCryptographicStateError.certificateProfileMismatch(
                        field: "extensionCriticalEncoding"
                    )
                }
                critical = true
            }
            let value = try fields.read(tag: 0x04).content
            try fields.requireEnd()
            switch oid {
            case basicConstraintsOID:
                guard !sawBasicConstraints, critical, value == sequence(Data()) else {
                    throw HostCryptographicStateError.certificateProfileMismatch(
                        field: "basicConstraints"
                    )
                }
                sawBasicConstraints = true
            case keyUsageOID:
                guard !sawKeyUsage, critical, value == bitString(Data([0x07, 0x80])) else {
                    throw HostCryptographicStateError.certificateProfileMismatch(field: "keyUsage")
                }
                sawKeyUsage = true
            case extendedKeyUsageOID:
                guard !sawExtendedKeyUsage,
                      !critical,
                      value == sequence(objectIdentifier(serverAuthOID)) else {
                    throw HostCryptographicStateError.certificateProfileMismatch(
                        field: "extendedKeyUsage"
                    )
                }
                sawExtendedKeyUsage = true
            case harcTransportSetOID:
                guard framedTransportSet == nil, !critical else {
                    throw HostCryptographicStateError.certificateProfileMismatch(
                        field: "transportSetExtension"
                    )
                }
                guard !value.isEmpty else {
                    throw HostCryptographicStateError.transportSetExtensionEmpty
                }
                guard value.count
                        <= HostTLSServerCertificateRequest.maximumTransportSetExtensionBytes else {
                    throw HostCryptographicStateError.transportSetExtensionTooLarge(actual: value.count)
                }
                framedTransportSet = value
            default:
                throw HostCryptographicStateError.certificateProfileMismatch(
                    field: "unexpectedExtension"
                )
            }
        }
        guard count == 4,
              sawBasicConstraints,
              sawKeyUsage,
              sawExtendedKeyUsage,
              let framedTransportSet else {
            throw HostCryptographicStateError.certificateProfileMismatch(
                field: "requiredExtensions"
            )
        }
        return framedTransportSet
    }

    private static func parseP256SPKI(_ bytes: Data) throws -> P256X963PublicKey {
        var cursor = DERCursor(bytes)
        let spki = try cursor.read(tag: 0x30)
        try cursor.requireEnd()
        var fields = DERCursor(spki.content)
        let algorithm = try fields.read(tag: 0x30)
        let keyBits = try fields.read(tag: 0x03)
        try fields.requireEnd()
        var algorithms = DERCursor(algorithm.content)
        guard try algorithms.read(tag: 0x06).content == ecPublicKeyOID,
              try algorithms.read(tag: 0x06).content == prime256v1OID else {
            throw HostCryptographicStateError.certificateProfileMismatch(field: "spkiAlgorithm")
        }
        try algorithms.requireEnd()
        guard keyBits.content.first == 0, keyBits.content.count == 66 else {
            throw HostCryptographicStateError.certificateProfileMismatch(field: "spkiPublicKey")
        }
        return try P256X963PublicKey(keyBits.content.dropFirst())
    }

    private static func parseValidity(_ bytes: Data) throws -> (Date, Date) {
        var cursor = DERCursor(bytes)
        let notBefore = try parseTime(cursor.readAnyTime())
        let notAfter = try parseTime(cursor.readAnyTime())
        try cursor.requireEnd()
        return (notBefore, notAfter)
    }

    private static func verifySelfSignature(
        publicKey: P256X963PublicKey,
        tbsCertificate: Data,
        signatureDER: Data.SubSequence
    ) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            publicKey.rawBytes as CFData,
            attributes as CFDictionary,
            &keyError
        ), SecKeyVerifySignature(
            secKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            Data(signatureDER) as CFData,
            &keyError
        ) else {
            throw HostCryptographicStateError.certificateProfileMismatch(
                field: "selfSignature"
            )
        }
    }

    private static func externalPublicKey(_ key: SecKey) throws -> P256X963PublicKey {
        let publicKey = SecKeyCopyPublicKey(key) ?? key
        var exportError: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw HostCryptographicStateError.serverIdentityUnavailable
        }
        return try P256X963PublicKey(bytes)
    }

    private static func validateSerialNumber(_ serial: Data) throws {
        guard let first = serial.first,
              serial.count <= 20,
              first & 0x80 == 0,
              serial.contains(where: { $0 != 0 }),
              !(serial.count > 1
                && first == 0
                && serial[serial.index(after: serial.startIndex)] & 0x80 == 0)
        else {
            throw HostCryptographicStateError.certificateProfileMismatch(field: "serialNumber")
        }
    }

    private static func time(_ date: Date) throws -> Data {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        if (1950...2049).contains(year) {
            let value = String(
                format: "%02d%02d%02d%02d%02d%02dZ",
                year % 100, month, day, hour, minute, second
            )
            return tlv(tag: 0x17, content: Data(value.utf8))
        }
        let value = String(
            format: "%04d%02d%02d%02d%02d%02dZ",
            year, month, day, hour, minute, second
        )
        return tlv(tag: 0x18, content: Data(value.utf8))
    }

    private static func parseTime(_ node: DERNode) throws -> Date {
        guard node.tag == 0x17 || node.tag == 0x18,
              let value = String(data: node.content, encoding: .ascii),
              value.last == "Z" else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        let digits = value.dropLast()
        let expectedCount = node.tag == 0x17 ? 12 : 14
        guard digits.count == expectedCount, digits.allSatisfy(\.isNumber) else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        func integer(_ range: Range<String.Index>) -> Int? {
            Int(digits[range])
        }
        var index = digits.startIndex
        func next(_ count: Int) -> Int? {
            let end = digits.index(index, offsetBy: count)
            defer { index = end }
            return integer(index..<end)
        }
        let encodedYear = try require(next(node.tag == 0x17 ? 2 : 4))
        let year: Int
        if node.tag == 0x17 {
            year = encodedYear >= 50 ? 1900 + encodedYear : 2000 + encodedYear
        } else {
            year = encodedYear
        }
        var components = DateComponents()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = try require(next(2))
        components.day = try require(next(2))
        components.hour = try require(next(2))
        components.minute = try require(next(2))
        components.second = try require(next(2))
        guard let date = components.date else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == components.year,
              roundTrip.month == components.month,
              roundTrip.day == components.day,
              roundTrip.hour == components.hour,
              roundTrip.minute == components.minute,
              roundTrip.second == components.second else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        return date
    }

    private static func require(_ value: Int?) throws -> Int {
        guard let value else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        return value
    }

    private static func sequence(_ content: Data) -> Data { tlv(tag: 0x30, content: content) }
    private static func set(_ content: Data) -> Data { tlv(tag: 0x31, content: content) }
    private static func integer(_ content: Data) -> Data { tlv(tag: 0x02, content: content) }
    private static func objectIdentifier(_ content: Data) -> Data { tlv(tag: 0x06, content: content) }
    private static func utf8String(_ content: Data) -> Data { tlv(tag: 0x0c, content: content) }
    private static func octetString(_ content: Data) -> Data { tlv(tag: 0x04, content: content) }
    private static func bitString(_ content: Data) -> Data { tlv(tag: 0x03, content: content) }
    private static func boolean(_ value: Bool) -> Data {
        tlv(tag: 0x01, content: Data([value ? 0xff : 0x00]))
    }
    private static func explicit(tag: UInt8, _ content: Data) -> Data {
        tlv(tag: tag, content: content)
    }

    private static func tlv(tag: UInt8, content: Data) -> Data {
        var encoded = Data([tag])
        encoded.append(length(content.count))
        encoded.append(content)
        return encoded
    }

    private static func length(_ count: Int) -> Data {
        precondition(count >= 0)
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

private struct DERNode {
    let tag: UInt8
    let content: Data
    let encoded: Data
}

private struct DERCursor {
    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) {
        // Normalize possibly sliced Data to a zero-based owned buffer before
        // applying integer offsets in the bounded DER reader.
        self.bytes = Data(bytes)
    }

    var isAtEnd: Bool { offset == bytes.count }

    func peekTag() -> UInt8? {
        guard offset < bytes.count else { return nil }
        return bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
    }

    mutating func read(tag expectedTag: UInt8) throws -> DERNode {
        let node = try read()
        guard node.tag == expectedTag else {
            throw HostCryptographicStateError.invalidServerCertificate
        }
        return node
    }

    mutating func readAnyTime() throws -> DERNode {
        let node = try read()
        guard node.tag == 0x17 || node.tag == 0x18 else {
            throw HostCryptographicStateError.invalidCertificateValidity
        }
        return node
    }

    mutating func read() throws -> DERNode {
        let start = offset
        let tag = try readByte()
        let firstLength = try readByte()
        let contentLength: Int
        if firstLength & 0x80 == 0 {
            contentLength = Int(firstLength)
        } else {
            let octetCount = Int(firstLength & 0x7f)
            guard octetCount > 0,
                  octetCount <= MemoryLayout<Int>.size,
                  offset + octetCount <= bytes.count else {
                throw HostCryptographicStateError.invalidServerCertificate
            }
            var parsed = 0
            for index in 0..<octetCount {
                let octet = try readByte()
                if index == 0, octet == 0 {
                    throw HostCryptographicStateError.invalidServerCertificate
                }
                guard parsed <= (Int.max - Int(octet)) / 256 else {
                    throw HostCryptographicStateError.invalidServerCertificate
                }
                parsed = (parsed * 256) + Int(octet)
            }
            guard parsed >= 128 else {
                throw HostCryptographicStateError.invalidServerCertificate
            }
            contentLength = parsed
        }
        guard contentLength >= 0,
              offset <= bytes.count,
              contentLength <= bytes.count - offset else {
            throw HostCryptographicStateError.invalidServerCertificate
        }
        let contentStart = offset
        offset += contentLength
        return DERNode(
            tag: tag,
            content: bytes.subdata(in: contentStart..<offset),
            encoded: bytes.subdata(in: start..<offset)
        )
    }

    func requireEnd() throws {
        guard isAtEnd else {
            throw HostCryptographicStateError.invalidServerCertificate
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw HostCryptographicStateError.invalidServerCertificate
        }
        defer { offset += 1 }
        return bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
    }
}
