import CryptoKit
import Foundation

public enum HarcProtocolCodecError: Error, Equatable, Sendable {
    case inputTooLarge(field: String, limit: UInt64, actual: UInt64)
    case truncated(field: String)
    case trailingBytes(count: Int)
    case invalidMagic(field: String)
    case lengthOutOfRange(field: String, minimum: UInt64, maximum: UInt64, actual: UInt64)
    case lengthMismatch(field: String, expected: UInt64, actual: UInt64)
    case unsupportedProtocolMajor(UInt16)
    case unsupportedProtocolMinor(UInt16)
    case invalidTimeRange(field: String)
    case expired(field: String)
    case nonCanonicalOrder(field: String)
    case duplicateValue(field: String)
    case invalidText(field: String)
    case invalidEndpoint(field: String)
    case invalidBase64URL
    case invalidPairingURI
    case invalidKeyBinding(field: String)
    case invalidDigest(field: String)
    case invalidSignature
    case payloadHashMismatch
    case unregisteredSignedObject(messageType: String, payloadType: String)
    case wrongSignerClass
    case headerPayloadMismatch(field: String)
    case missingPayloadBinding(field: String)
    case currentGrantRequired
    case staleGrant
    case commandExpired
    case commandLifetimeExceeded
    case invalidSASDictionary
    case numericOverflow(field: String)
}

extension HarcProtocolCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inputTooLarge(let field, let limit, let actual):
            return "\(field) exceeds \(limit) bytes; received \(actual)."
        case .truncated(let field): return "\(field) is truncated."
        case .trailingBytes(let count): return "The canonical value has \(count) trailing bytes."
        case .invalidMagic(let field): return "\(field) has the wrong magic bytes."
        case .lengthOutOfRange(let field, let minimum, let maximum, let actual):
            return "\(field) length \(actual) is outside \(minimum)...\(maximum)."
        case .lengthMismatch(let field, let expected, let actual):
            return "\(field) length is \(actual), expected \(expected)."
        case .unsupportedProtocolMajor(let major): return "Protocol major \(major) is unsupported."
        case .unsupportedProtocolMinor(let minor): return "Protocol minor \(minor) is unsupported."
        case .invalidTimeRange(let field): return "\(field) has an invalid time range."
        case .expired(let field): return "\(field) is expired."
        case .nonCanonicalOrder(let field): return "\(field) is not in canonical order."
        case .duplicateValue(let field): return "\(field) contains a duplicate value."
        case .invalidText(let field): return "\(field) is not canonical protocol text."
        case .invalidEndpoint(let field): return "\(field) is not a valid canonical endpoint."
        case .invalidBase64URL: return "The value is not shortest-form unpadded base64url."
        case .invalidPairingURI: return "The pairing URI is not canonical."
        case .invalidKeyBinding(let field): return "\(field) does not match its derived key identity."
        case .invalidDigest(let field): return "\(field) is not a 32-byte SHA-256 value."
        case .invalidSignature: return "The exact signed object has an invalid signature."
        case .payloadHashMismatch: return "The untouched payload bytes do not match the signed hash."
        case .unregisteredSignedObject(let messageType, let payloadType):
            return "The signed-object tuple \(messageType) / \(payloadType) is not registered."
        case .wrongSignerClass: return "The signed object uses the wrong signer class."
        case .headerPayloadMismatch(let field): return "The signed header does not mirror payload field \(field)."
        case .missingPayloadBinding(let field): return "The decoded payload did not supply required binding \(field)."
        case .currentGrantRequired: return "Initial command acceptance requires current registry grant state."
        case .staleGrant: return "The command is not bound to the current registry grant."
        case .commandExpired: return "The signed command is expired."
        case .commandLifetimeExceeded: return "The signed command lifetime exceeds seven days."
        case .invalidSASDictionary: return "The pairing SAS dictionary does not match the frozen protocol resource."
        case .numericOverflow(let field): return "\(field) exceeds the canonical integer range."
        }
    }
}

public enum HarcProtocolLimits {
    public static let decodedControlPayloadBytes = 1 * 1_024 * 1_024
    public static let signedEnvelopeHeaderBytes = 4 * 1_024
    public static let signedObjectBytes = decodedControlPayloadBytes + signedEnvelopeHeaderBytes + 86
    public static let transportCertificateExtensionBytes = 4 * 1_024
    public static let pairingURIBytes = 1_400
    public static let pairingTicketBytes = 1_024
    public static let pairingTransportObjectBytes = 768
    public static let pairingEndpoints = 4
    public static let pairingRequestedScopes = 8
    public static let pairingDeviceLabelBytes = 256
    public static let pairingTranscriptBytes = 4 * 1_024
    public static let sessionTranscriptBytes = 265
    public static let transportEntries = 2
    public static let transportEntryLifetimeMilliseconds: UInt64 = 90 * 24 * 60 * 60 * 1_000
    public static let transportClockSkewMilliseconds: UInt64 = 5 * 60 * 1_000
    public static let pairingTicketLifetimeMilliseconds: UInt64 = 2 * 60 * 1_000
    public static let initialCommandLifetimeMilliseconds: UInt64 = 7 * 24 * 60 * 60 * 1_000
    public static let clientFutureSkewMilliseconds: UInt64 = 5 * 60 * 1_000
}

public struct HarcProtocolVersion: Equatable, Hashable, Sendable {
    public static let v1 = HarcProtocolVersion(major: 1, minor: 0)

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }
}

public struct HarcProtocolVersionPolicy: Equatable, Hashable, Sendable {
    public static let currentV1 = HarcProtocolVersionPolicy(
        major: 1,
        supportedMinorRange: 0 ... 0
    )

    public let major: UInt16
    public let supportedMinorRange: ClosedRange<UInt16>

    public init(major: UInt16, supportedMinorRange: ClosedRange<UInt16>) {
        self.major = major
        self.supportedMinorRange = supportedMinorRange
    }

    public func validate(_ version: HarcProtocolVersion) throws {
        guard version.major == major else {
            throw HarcProtocolCodecError.unsupportedProtocolMajor(version.major)
        }
        guard supportedMinorRange.contains(version.minor) else {
            throw HarcProtocolCodecError.unsupportedProtocolMinor(version.minor)
        }
    }
}

struct HarcBinaryWriter {
    private(set) var data = Data()

    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func append(_ byte: UInt8) { data.append(byte) }

    mutating func append(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func append(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func append(uuid: UUID) { data.append(harcUUIDBytes(uuid)) }

    mutating func appendLengthPrefixedASCII(_ value: String, field: String) throws {
        let bytes = Data(value.utf8)
        guard value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw HarcProtocolCodecError.invalidText(field: field)
        }
        guard let count = UInt16(exactly: bytes.count), count > 0 else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: field,
                minimum: 1,
                maximum: UInt64(UInt16.max),
                actual: UInt64(bytes.count)
            )
        }
        append(count)
        append(bytes)
    }
}

struct HarcBinaryReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data, maximumBytes: Int, field: String) throws {
        guard data.count <= maximumBytes else {
            throw HarcProtocolCodecError.inputTooLarge(
                field: field,
                limit: UInt64(maximumBytes),
                actual: UInt64(data.count)
            )
        }
        bytes = Array(data)
    }

    var remainingCount: Int { bytes.count - offset }

    mutating func readData(count: Int, field: String) throws -> Data {
        guard count >= 0, remainingCount >= count else {
            throw HarcProtocolCodecError.truncated(field: field)
        }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }

    mutating func readUInt8(field: String) throws -> UInt8 {
        try readData(count: 1, field: field).first!
    }

    mutating func readUInt16(field: String) throws -> UInt16 {
        let value = [UInt8](try readData(count: 2, field: field))
        return (UInt16(value[0]) << 8) | UInt16(value[1])
    }

    mutating func readUInt32(field: String) throws -> UInt32 {
        let value = [UInt8](try readData(count: 4, field: field))
        return value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64(field: String) throws -> UInt64 {
        let value = [UInt8](try readData(count: 8, field: field))
        return value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUUID(field: String) throws -> UUID {
        harcUUID(from: try readData(count: 16, field: field))
    }

    mutating func readLengthPrefixedASCII(field: String) throws -> String {
        let count = Int(try readUInt16(field: "\(field).length"))
        guard count > 0 else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: field,
                minimum: 1,
                maximum: UInt64(UInt16.max),
                actual: 0
            )
        }
        let data = try readData(count: count, field: field)
        guard let value = String(data: data, encoding: .utf8),
              Data(value.utf8) == data,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw HarcProtocolCodecError.invalidText(field: field)
        }
        return value
    }

    mutating func requireMagic(_ magic: Data, field: String) throws {
        guard try readData(count: magic.count, field: field) == magic else {
            throw HarcProtocolCodecError.invalidMagic(field: field)
        }
    }

    func requireEnd() throws {
        guard remainingCount == 0 else {
            throw HarcProtocolCodecError.trailingBytes(count: remainingCount)
        }
    }
}

func harcUUIDBytes(_ value: UUID) -> Data {
    withUnsafeBytes(of: value.uuid) { Data($0) }
}

func harcUUID(from data: Data) -> UUID {
    precondition(data.count == 16)
    let bytes = [UInt8](data)
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

func harcDomainSeparatedSHA256(_ domain: String, _ components: Data...) -> Data {
    var hasher = SHA256()
    hasher.update(data: Data(domain.utf8))
    for component in components { hasher.update(data: component) }
    return Data(hasher.finalize())
}

func harcRequireDigest(_ data: Data, field: String) throws {
    guard data.count == SHA256.Digest.byteCount else {
        throw HarcProtocolCodecError.invalidDigest(field: field)
    }
}

func harcUnixMilliseconds(_ date: Date) throws -> UInt64 {
    try harcUnixMilliseconds(date, field: "unixMilliseconds")
}

func harcUnixMilliseconds(_ date: Date, field: String) throws -> UInt64 {
    let milliseconds = date.timeIntervalSince1970 * 1_000
    guard milliseconds.isFinite,
          milliseconds >= 0,
          milliseconds.rounded(.towardZero) <= Double(UInt64.max) else {
        throw HarcProtocolCodecError.invalidTimeRange(field: field)
    }
    return UInt64(milliseconds.rounded(.towardZero))
}

func harcDateFromUnixMilliseconds(_ value: UInt64, field: String) throws -> Date {
    let seconds = Double(value) / 1_000
    guard seconds.isFinite else {
        throw HarcProtocolCodecError.invalidTimeRange(field: field)
    }
    let date = Date(timeIntervalSince1970: seconds)
    guard try harcUnixMilliseconds(date, field: field) == value else {
        throw HarcProtocolCodecError.invalidTimeRange(field: field)
    }
    return date
}

func harcAdding(_ lhs: UInt64, _ rhs: UInt64, field: String) throws -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw HarcProtocolCodecError.numericOverflow(field: field) }
    return result.partialValue
}

func harcEncodeBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func harcDecodeCanonicalBase64URL(_ value: String) throws -> Data {
    guard !value.isEmpty,
          value.utf8.allSatisfy({
              ($0 >= 0x41 && $0 <= 0x5a)
                  || ($0 >= 0x61 && $0 <= 0x7a)
                  || ($0 >= 0x30 && $0 <= 0x39)
                  || $0 == 0x2d || $0 == 0x5f
          }),
          value.count % 4 != 1 else {
        throw HarcProtocolCodecError.invalidBase64URL
    }
    var standard = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    standard.append(String(repeating: "=", count: (4 - standard.count % 4) % 4))
    guard let data = Data(base64Encoded: standard), harcEncodeBase64URL(data) == value else {
        throw HarcProtocolCodecError.invalidBase64URL
    }
    return data
}

func harcValidateCanonicalText(_ data: Data, field: String) throws -> String {
    guard let value = String(data: data, encoding: .utf8),
          Data(value.utf8) == data,
          value.precomposedStringWithCanonicalMapping == value,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw HarcProtocolCodecError.invalidText(field: field)
    }
    return value
}
