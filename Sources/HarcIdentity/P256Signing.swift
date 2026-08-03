import CryptoKit
import Foundation
import HarcDomain

/// Fail-closed validation errors for Harc's only v1 signing profile.
public enum IdentityCryptoError: Error, Equatable, Sendable {
    case invalidDigestLength(expected: Int, actual: Int)
    case invalidPublicKeyLength(expected: Int, actual: Int)
    case invalidPublicKeyPrefix(actual: UInt8?)
    case invalidPublicKey
    case invalidSignatureLength(expected: Int, actual: Int)
    case invalidSignatureScalar
    case signatureNotLowS
    case invalidPrivateKey
}

extension IdentityCryptoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDigestLength(let expected, let actual):
            return "A P-256 SHA-256 digest must contain \(expected) bytes; received \(actual)."
        case .invalidPublicKeyLength(let expected, let actual):
            return "A P-256 X9.63 public key must contain \(expected) bytes; received \(actual)."
        case .invalidPublicKeyPrefix(let actual):
            let value = actual.map { String(format: "0x%02x", $0) } ?? "none"
            return "A P-256 X9.63 public key must use the uncompressed 0x04 prefix; received \(value)."
        case .invalidPublicKey:
            return "The P-256 X9.63 public key is not a canonical point on the curve."
        case .invalidSignatureLength(let expected, let actual):
            return "A raw P-256 signature must contain \(expected) bytes; received \(actual)."
        case .invalidSignatureScalar:
            return "A raw P-256 signature contains an out-of-range scalar."
        case .signatureNotLowS:
            return "A raw P-256 signature must use its low-S representation."
        case .invalidPrivateKey:
            return "The P-256 private key is invalid."
        }
    }
}

/// The one 32-byte SHA-256 prehash accepted by Harc signing primitives.
///
/// Callers hash the exact registered domain and canonical payload once, then
/// pass this value to `P256DigestSigner`. There is deliberately no API that
/// signs arbitrary message bytes.
public struct P256SHA256Digest: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data

    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw IdentityCryptoError.invalidDigestLength(
                expected: Self.byteCount,
                actual: rawBytes.count
            )
        }
        self.rawBytes = rawBytes
    }

    /// Computes the single SHA-256 prehash over already-canonical signing bytes.
    public init<D: DataProtocol>(hashing canonicalSigningBytes: D) {
        self.rawBytes = Data(SHA256.hash(data: canonicalSigningBytes))
    }

    public var description: String { rawBytes.hexString }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let bytes = try container.decode(Data.self)
        do {
            try self.init(bytes)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A P-256 SHA-256 digest must contain exactly 32 bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawBytes)
    }
}

/// A strict SEC1 uncompressed P-256 public key in X9.63 form.
public struct P256X963PublicKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 65
    public static let uncompressedPrefix: UInt8 = 0x04

    public let rawBytes: Data

    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw IdentityCryptoError.invalidPublicKeyLength(
                expected: Self.byteCount,
                actual: rawBytes.count
            )
        }
        guard rawBytes.first == Self.uncompressedPrefix else {
            throw IdentityCryptoError.invalidPublicKeyPrefix(actual: rawBytes.first)
        }

        let key: P256.Signing.PublicKey
        do {
            key = try P256.Signing.PublicKey(x963Representation: rawBytes)
        } catch {
            throw IdentityCryptoError.invalidPublicKey
        }
        guard key.x963Representation == rawBytes else {
            throw IdentityCryptoError.invalidPublicKey
        }
        self.rawBytes = rawBytes
    }

    /// `SHA256("harc-p256-x963-v1\0" || publicKeyX963)`, typed as a device ID.
    public var deviceID: DeviceID {
        // The digest is structurally guaranteed to be 32 bytes.
        try! DeviceID(Self.derivedIdentityDigest(for: rawBytes))
    }

    /// `SHA256("harc-p256-x963-v1\0" || publicKeyX963)`, typed as a host authority ID.
    public var hostAuthorityID: HostAuthorityID {
        // The digest is structurally guaranteed to be 32 bytes.
        try! HostAuthorityID(Self.derivedIdentityDigest(for: rawBytes))
    }

    public var description: String { rawBytes.hexString }

    public func isValidSignature(
        _ signature: P256RawSignature,
        for digest: P256SHA256Digest
    ) -> Bool {
        guard
            let key = try? P256.Signing.PublicKey(x963Representation: rawBytes),
            let cryptoSignature = try? P256.Signing.ECDSASignature(
                rawRepresentation: signature.rawBytes
            )
        else {
            return false
        }
        return key.isValidSignature(
            cryptoSignature,
            for: PrecomputedSHA256Digest(digest.rawBytes)
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let bytes = try container.decode(Data.self)
        do {
            try self.init(bytes)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid strict P-256 X9.63 public key.",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawBytes)
    }

    private static func derivedIdentityDigest(for publicKey: Data) -> Data {
        var bytes = Data("harc-p256-x963-v1\0".utf8)
        bytes.append(publicKey)
        return Data(SHA256.hash(data: bytes))
    }
}

/// A canonical `r || s` P-256 signature. Construction rejects high-S values.
public struct P256RawSignature: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 64
    public let rawBytes: Data

    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw IdentityCryptoError.invalidSignatureLength(
                expected: Self.byteCount,
                actual: rawBytes.count
            )
        }

        let bytes = [UInt8](rawBytes)
        let r = Array(bytes[0..<32])
        let s = Array(bytes[32..<64])
        guard
            P256Scalar.isNonzeroAndBelowOrder(r),
            P256Scalar.isNonzeroAndBelowOrder(s)
        else {
            throw IdentityCryptoError.invalidSignatureScalar
        }
        guard !P256Scalar.isGreaterThanHalfOrder(s) else {
            throw IdentityCryptoError.signatureNotLowS
        }
        guard (try? P256.Signing.ECDSASignature(rawRepresentation: rawBytes)) != nil else {
            throw IdentityCryptoError.invalidSignatureScalar
        }
        self.rawBytes = rawBytes
    }

    public var description: String { rawBytes.hexString }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let bytes = try container.decode(Data.self)
        do {
            try self.init(bytes)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid canonical raw low-S P-256 signature.",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawBytes)
    }

    static func normalizing(_ rawBytes: Data) throws -> Self {
        guard rawBytes.count == Self.byteCount else {
            throw IdentityCryptoError.invalidSignatureLength(
                expected: Self.byteCount,
                actual: rawBytes.count
            )
        }
        var bytes = [UInt8](rawBytes)
        let s = Array(bytes[32..<64])
        if P256Scalar.isGreaterThanHalfOrder(s) {
            bytes.replaceSubrange(32..<64, with: P256Scalar.orderMinus(s))
        }
        return try Self(Data(bytes))
    }
}

/// A signing-key seam shared by software, Keychain, and future Secure Enclave adapters.
public protocol P256DigestSigner: Sendable {
    var publicKey: P256X963PublicKey { get }
    func sign(digest: P256SHA256Digest) throws -> P256RawSignature
}

/// CryptoKit software P-256 key. Private material is intentionally not exposed.
public struct SoftwareP256SigningKey: P256DigestSigner, Sendable {
    private let privateKey: P256.Signing.PrivateKey

    public init() {
        self.privateKey = P256.Signing.PrivateKey()
    }

    init(rawRepresentation: Data) throws {
        do {
            self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw IdentityCryptoError.invalidPrivateKey
        }
    }

    public var publicKey: P256X963PublicKey {
        // CryptoKit always emits a canonical uncompressed P-256 point here.
        try! P256X963PublicKey(privateKey.publicKey.x963Representation)
    }

    public func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        // This Digest overload consumes the supplied SHA-256 prehash directly.
        // The Data overload is deliberately not used because it would hash again.
        let signature = try privateKey.signature(
            for: PrecomputedSHA256Digest(digest.rawBytes)
        )
        return try P256RawSignature.normalizing(signature.rawRepresentation)
    }

    var persistedRawRepresentation: Data { privateKey.rawRepresentation }
}

struct PrecomputedSHA256Digest: Digest {
    static let byteCount = P256SHA256Digest.byteCount
    let bytes: Data

    init(_ bytes: Data) {
        precondition(bytes.count == Self.byteCount)
        self.bytes = bytes
    }

    func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }
}

private enum P256Scalar {
    static let order: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    ]

    static let halfOrder: [UInt8] = [
        0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
        0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
    ]

    static func isNonzeroAndBelowOrder(_ scalar: [UInt8]) -> Bool {
        scalar.contains(where: { $0 != 0 }) && compare(scalar, order) == .orderedAscending
    }

    static func isGreaterThanHalfOrder(_ scalar: [UInt8]) -> Bool {
        compare(scalar, halfOrder) == .orderedDescending
    }

    static func orderMinus(_ scalar: [UInt8]) -> [UInt8] {
        precondition(scalar.count == order.count)
        var result = [UInt8](repeating: 0, count: order.count)
        var borrow = 0
        for index in stride(from: order.count - 1, through: 0, by: -1) {
            var difference = Int(order[index]) - Int(scalar[index]) - borrow
            if difference < 0 {
                difference += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(difference)
        }
        precondition(borrow == 0)
        return result
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
        precondition(lhs.count == rhs.count)
        for (left, right) in zip(lhs, rhs) {
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
