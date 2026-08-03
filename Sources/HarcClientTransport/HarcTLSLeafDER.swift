import CryptoKit
import Foundation
import HarcIdentity

/// The exact security-relevant facts admitted from a Harc TLS leaf.
///
/// This is intentionally produced by Harc's bounded raw-DER parser. Neither
/// system trust nor a general-purpose X.509 object is used as an identity
/// decision.
public struct HarcTLSLeafCertificateFacts: Equatable, Sendable {
    public let certificateDER: Data
    public let notValidBefore: Date
    public let notValidAfter: Date
    public let publicKeyX963: P256X963PublicKey
    public let fullDERSPKISHA256: Data
    public let exactSignedTransportSet: Data
}

public enum HarcTLSLeafDERError: Error, Equatable, Sendable {
    case inputTooLarge(actual: Int, maximum: Int)
    case malformedDER
    case profileMismatch(field: String)
    case invalidValidity
    case invalidSelfSignature
    case transportSetExtensionEmpty
    case transportSetExtensionTooLarge(actual: Int, maximum: Int)
}

/// Strict parser for the one self-signed P-256 leaf profile emitted by Harc.
///
/// The parser admits only the fixed signature/SPKI algorithms, exact Harc
/// subject and issuer, the four required extensions, and the mandatory private
/// transport-set OID. It also verifies the leaf's self-signature over the exact
/// encoded TBSCertificate bytes.
public enum HarcTLSLeafDERParser {
    public static let maximumCertificateBytes = 16_384
    public static let maximumTransportSetExtensionBytes = 4_096
    public static let maximumValidity: TimeInterval = 90 * 24 * 60 * 60

    /// Canonical DER OBJECT IDENTIFIER content bytes for
    /// 2.25.148088663479842491025708621331721812820.
    public static let transportSetExtensionOIDBytes = Data([
        0x69, 0x81, 0xde, 0xe8, 0xeb, 0xb4, 0xc0, 0xac, 0xba, 0xa9,
        0xcd, 0xae, 0xf4, 0xc2, 0xe9, 0xb7, 0xe9, 0xbb, 0xf6, 0x54,
    ])

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

    // SEQUENCE { SET { SEQUENCE { commonName, UTF8String "Harc Local Host" } } }
    private static let harcName = Data([
        0x30, 0x1a, 0x31, 0x18, 0x30, 0x16, 0x06, 0x03, 0x55, 0x04,
        0x03, 0x0c, 0x0f, 0x48, 0x61, 0x72, 0x63, 0x20, 0x4c, 0x6f,
        0x63, 0x61, 0x6c, 0x20, 0x48, 0x6f, 0x73, 0x74,
    ])

    private static var signatureAlgorithm: Data {
        derSequence(derObjectIdentifier(ecdsaWithSHA256OID))
    }

    public static func parse(_ certificateDER: Data) throws -> HarcTLSLeafCertificateFacts {
        guard certificateDER.count <= maximumCertificateBytes else {
            throw HarcTLSLeafDERError.inputTooLarge(
                actual: certificateDER.count,
                maximum: maximumCertificateBytes
            )
        }

        do {
            var certificateCursor = HarcDERCursor(certificateDER)
            let certificate = try certificateCursor.read(tag: 0x30)
            try certificateCursor.requireEnd()

            var certificateFields = HarcDERCursor(certificate.content)
            let tbsCertificate = try certificateFields.read(tag: 0x30)
            let outerSignatureAlgorithm = try certificateFields.read(tag: 0x30)
            let signatureValue = try certificateFields.read(tag: 0x03)
            try certificateFields.requireEnd()

            guard outerSignatureAlgorithm.encoded == signatureAlgorithm else {
                throw HarcTLSLeafDERError.profileMismatch(field: "signatureAlgorithm")
            }
            guard signatureValue.content.first == 0,
                  signatureValue.content.count > 1 else {
                throw HarcTLSLeafDERError.profileMismatch(field: "signatureValue")
            }
            let signatureDER = Data(signatureValue.content.dropFirst())
            try validateECDSASignatureDER(signatureDER)

            var tbsFields = HarcDERCursor(tbsCertificate.content)
            let version = try tbsFields.read(tag: 0xa0)
            guard version.content == derInteger(Data([0x02])) else {
                throw HarcTLSLeafDERError.profileMismatch(field: "version")
            }
            try validateSerialNumber(try tbsFields.read(tag: 0x02).content)
            guard try tbsFields.read(tag: 0x30).encoded == signatureAlgorithm else {
                throw HarcTLSLeafDERError.profileMismatch(field: "tbsSignatureAlgorithm")
            }

            let issuer = try tbsFields.read(tag: 0x30)
            guard issuer.encoded == harcName else {
                throw HarcTLSLeafDERError.profileMismatch(field: "issuer")
            }
            let validity = try tbsFields.read(tag: 0x30)
            let subject = try tbsFields.read(tag: 0x30)
            guard subject.encoded == harcName, issuer.encoded == subject.encoded else {
                throw HarcTLSLeafDERError.profileMismatch(field: "selfIssuedName")
            }

            let spki = try tbsFields.read(tag: 0x30)
            let publicKey = try parseP256SPKI(spki.encoded)
            let extensions = try tbsFields.read(tag: 0xa3)
            try tbsFields.requireEnd()

            let (notBefore, notAfter) = try parseValidity(validity.content)
            guard notBefore < notAfter,
                  notAfter.timeIntervalSince(notBefore) <= maximumValidity else {
                throw HarcTLSLeafDERError.invalidValidity
            }
            let transportSet = try parseExtensions(extensions.content)

            guard verifySelfSignature(
                publicKey: publicKey,
                tbsCertificate: tbsCertificate.encoded,
                signatureDER: signatureDER
            ) else {
                throw HarcTLSLeafDERError.invalidSelfSignature
            }

            return HarcTLSLeafCertificateFacts(
                certificateDER: certificateDER,
                notValidBefore: notBefore,
                notValidAfter: notAfter,
                publicKeyX963: publicKey,
                fullDERSPKISHA256: Data(SHA256.hash(data: spki.encoded)),
                exactSignedTransportSet: transportSet
            )
        } catch let error as HarcTLSLeafDERError {
            throw error
        } catch {
            throw HarcTLSLeafDERError.malformedDER
        }
    }

    private static func parseP256SPKI(_ encodedSPKI: Data) throws -> P256X963PublicKey {
        var spkiCursor = HarcDERCursor(encodedSPKI)
        let spki = try spkiCursor.read(tag: 0x30)
        try spkiCursor.requireEnd()
        var fields = HarcDERCursor(spki.content)
        let algorithm = try fields.read(tag: 0x30)
        let publicKeyBits = try fields.read(tag: 0x03)
        try fields.requireEnd()

        var algorithms = HarcDERCursor(algorithm.content)
        guard try algorithms.read(tag: 0x06).content == ecPublicKeyOID,
              try algorithms.read(tag: 0x06).content == prime256v1OID else {
            throw HarcTLSLeafDERError.profileMismatch(field: "spkiAlgorithm")
        }
        try algorithms.requireEnd()
        guard publicKeyBits.content.first == 0,
              publicKeyBits.content.count == P256X963PublicKey.byteCount + 1 else {
            throw HarcTLSLeafDERError.profileMismatch(field: "spkiPublicKey")
        }
        do {
            return try P256X963PublicKey(publicKeyBits.content.dropFirst())
        } catch {
            throw HarcTLSLeafDERError.profileMismatch(field: "spkiPublicKey")
        }
    }

    private static func parseExtensions(_ encodedExtensions: Data) throws -> Data {
        var outer = HarcDERCursor(encodedExtensions)
        let sequence = try outer.read(tag: 0x30)
        try outer.requireEnd()

        var extensions = HarcDERCursor(sequence.content)
        var sawBasicConstraints = false
        var sawKeyUsage = false
        var sawExtendedKeyUsage = false
        var exactTransportSet: Data?
        var count = 0

        while !extensions.isAtEnd {
            count += 1
            let node = try extensions.read(tag: 0x30)
            var fields = HarcDERCursor(node.content)
            let oid = try fields.read(tag: 0x06).content
            var critical = false
            if fields.peekTag() == 0x01 {
                let encodedCritical = try fields.read(tag: 0x01).content
                guard encodedCritical == Data([0xff]) else {
                    throw HarcTLSLeafDERError.profileMismatch(
                        field: "extensionCriticalEncoding"
                    )
                }
                critical = true
            }
            let value = try fields.read(tag: 0x04).content
            try fields.requireEnd()

            switch oid {
            case basicConstraintsOID:
                guard !sawBasicConstraints,
                      critical,
                      value == derSequence(Data()) else {
                    throw HarcTLSLeafDERError.profileMismatch(field: "basicConstraints")
                }
                sawBasicConstraints = true
            case keyUsageOID:
                // One meaningful bit: digitalSignature (bit zero).
                guard !sawKeyUsage,
                      critical,
                      value == derBitString(Data([0x07, 0x80])) else {
                    throw HarcTLSLeafDERError.profileMismatch(field: "keyUsage")
                }
                sawKeyUsage = true
            case extendedKeyUsageOID:
                guard !sawExtendedKeyUsage,
                      !critical,
                      value == derSequence(derObjectIdentifier(serverAuthOID)) else {
                    throw HarcTLSLeafDERError.profileMismatch(field: "extendedKeyUsage")
                }
                sawExtendedKeyUsage = true
            case transportSetExtensionOIDBytes:
                guard exactTransportSet == nil, !critical else {
                    throw HarcTLSLeafDERError.profileMismatch(
                        field: "transportSetExtension"
                    )
                }
                guard !value.isEmpty else {
                    throw HarcTLSLeafDERError.transportSetExtensionEmpty
                }
                guard value.count <= maximumTransportSetExtensionBytes else {
                    throw HarcTLSLeafDERError.transportSetExtensionTooLarge(
                        actual: value.count,
                        maximum: maximumTransportSetExtensionBytes
                    )
                }
                exactTransportSet = value
            default:
                throw HarcTLSLeafDERError.profileMismatch(field: "unexpectedExtension")
            }
        }

        guard count == 4,
              sawBasicConstraints,
              sawKeyUsage,
              sawExtendedKeyUsage,
              let exactTransportSet else {
            throw HarcTLSLeafDERError.profileMismatch(field: "requiredExtensions")
        }
        return exactTransportSet
    }

    private static func parseValidity(_ encodedValidity: Data) throws -> (Date, Date) {
        var fields = HarcDERCursor(encodedValidity)
        let notBefore = try parseTime(fields.readAnyTime())
        let notAfter = try parseTime(fields.readAnyTime())
        try fields.requireEnd()
        return (notBefore, notAfter)
    }

    private static func parseTime(_ node: HarcDERNode) throws -> Date {
        guard let value = String(data: node.content, encoding: .ascii),
              value.last == "Z" else {
            throw HarcTLSLeafDERError.invalidValidity
        }
        let digits = value.dropLast()
        let expectedCount = node.tag == 0x17 ? 12 : 14
        guard digits.count == expectedCount, digits.allSatisfy(\.isNumber) else {
            throw HarcTLSLeafDERError.invalidValidity
        }

        var index = digits.startIndex
        func next(_ count: Int) -> Int? {
            let end = digits.index(index, offsetBy: count)
            defer { index = end }
            return Int(digits[index..<end])
        }

        guard let encodedYear = next(node.tag == 0x17 ? 2 : 4) else {
            throw HarcTLSLeafDERError.invalidValidity
        }
        let year = node.tag == 0x17
            ? (encodedYear >= 50 ? 1_900 + encodedYear : 2_000 + encodedYear)
            : encodedYear
        guard let month = next(2),
              let day = next(2),
              let hour = next(2),
              let minute = next(2),
              let second = next(2) else {
            throw HarcTLSLeafDERError.invalidValidity
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = components.date else {
            throw HarcTLSLeafDERError.invalidValidity
        }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == second else {
            throw HarcTLSLeafDERError.invalidValidity
        }
        return date
    }

    private static func validateSerialNumber(_ serial: Data) throws {
        guard let first = serial.first,
              serial.count <= 20,
              first & 0x80 == 0,
              serial.contains(where: { $0 != 0 }),
              !(serial.count > 1
                && first == 0
                && serial[serial.index(after: serial.startIndex)] & 0x80 == 0) else {
            throw HarcTLSLeafDERError.profileMismatch(field: "serialNumber")
        }
    }

    private static func validateECDSASignatureDER(_ signature: Data) throws {
        var outer = HarcDERCursor(signature)
        let sequence = try outer.read(tag: 0x30)
        try outer.requireEnd()
        var scalars = HarcDERCursor(sequence.content)
        try validatePositiveScalar(try scalars.read(tag: 0x02).content)
        try validatePositiveScalar(try scalars.read(tag: 0x02).content)
        try scalars.requireEnd()
    }

    private static func validatePositiveScalar(_ scalar: Data) throws {
        guard let first = scalar.first,
              scalar.count <= 33,
              first & 0x80 == 0,
              scalar.contains(where: { $0 != 0 }),
              !(scalar.count > 1
                && first == 0
                && scalar[scalar.index(after: scalar.startIndex)] & 0x80 == 0) else {
            throw HarcTLSLeafDERError.profileMismatch(field: "signatureScalar")
        }
    }

    private static func verifySelfSignature(
        publicKey: P256X963PublicKey,
        tbsCertificate: Data,
        signatureDER: Data
    ) -> Bool {
        guard let key = try? P256.Signing.PublicKey(
            x963Representation: publicKey.rawBytes
        ), let signature = try? P256.Signing.ECDSASignature(
            derRepresentation: signatureDER
        ) else {
            return false
        }
        return key.isValidSignature(signature, for: tbsCertificate)
    }

    private static func derSequence(_ content: Data) -> Data {
        derTLV(tag: 0x30, content: content)
    }

    private static func derObjectIdentifier(_ content: Data) -> Data {
        derTLV(tag: 0x06, content: content)
    }

    private static func derInteger(_ content: Data) -> Data {
        derTLV(tag: 0x02, content: content)
    }

    private static func derBitString(_ content: Data) -> Data {
        derTLV(tag: 0x03, content: content)
    }

    private static func derTLV(tag: UInt8, content: Data) -> Data {
        var encoded = Data([tag])
        if content.count < 128 {
            encoded.append(UInt8(content.count))
        } else {
            var value = content.count
            var octets: [UInt8] = []
            while value > 0 {
                octets.append(UInt8(value & 0xff))
                value >>= 8
            }
            octets.reverse()
            encoded.append(0x80 | UInt8(octets.count))
            encoded.append(contentsOf: octets)
        }
        encoded.append(content)
        return encoded
    }
}

private struct HarcDERNode {
    let tag: UInt8
    let content: Data
    let encoded: Data
}

private struct HarcDERCursor {
    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) {
        self.bytes = Data(bytes)
    }

    var isAtEnd: Bool { offset == bytes.count }

    func peekTag() -> UInt8? {
        guard offset < bytes.count else { return nil }
        return bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
    }

    mutating func read(tag expectedTag: UInt8) throws -> HarcDERNode {
        let node = try read()
        guard node.tag == expectedTag else {
            throw HarcTLSLeafDERError.malformedDER
        }
        return node
    }

    mutating func readAnyTime() throws -> HarcDERNode {
        let node = try read()
        guard node.tag == 0x17 || node.tag == 0x18 else {
            throw HarcTLSLeafDERError.invalidValidity
        }
        return node
    }

    mutating func read() throws -> HarcDERNode {
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
                throw HarcTLSLeafDERError.malformedDER
            }
            var parsed = 0
            for index in 0..<octetCount {
                let octet = try readByte()
                if index == 0, octet == 0 {
                    throw HarcTLSLeafDERError.malformedDER
                }
                guard parsed <= (Int.max - Int(octet)) / 256 else {
                    throw HarcTLSLeafDERError.malformedDER
                }
                parsed = parsed * 256 + Int(octet)
            }
            guard parsed >= 128 else {
                throw HarcTLSLeafDERError.malformedDER
            }
            contentLength = parsed
        }
        guard contentLength <= bytes.count - offset else {
            throw HarcTLSLeafDERError.malformedDER
        }
        let contentStart = offset
        offset += contentLength
        return HarcDERNode(
            tag: tag,
            content: bytes.subdata(in: contentStart..<offset),
            encoded: bytes.subdata(in: start..<offset)
        )
    }

    func requireEnd() throws {
        guard isAtEnd else {
            throw HarcTLSLeafDERError.malformedDER
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw HarcTLSLeafDERError.malformedDER
        }
        defer { offset += 1 }
        return bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
    }
}
