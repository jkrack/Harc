import Foundation

private func decodeUUID(from decoder: any Decoder, type: String) throws -> UUID {
    let container = try decoder.singleValueContainer()
    let encoded = try container.decode(String.self)
    guard let value = UUID(uuidString: encoded) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid \(type) UUID.")
    }
    return value
}

private func encodeUUID(_ value: UUID, to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value.uuidString.lowercased())
}

private func decodeDigest(from decoder: any Decoder, field: String) throws -> Data {
    let container = try decoder.singleValueContainer()
    let bytes = try container.decode(Data.self)
    guard bytes.count == 32 else {
        let error = TransferValidationError.invalidDigestLength(field: field, expected: 32, actual: bytes.count)
        throw DecodingError.dataCorrupted(
            .init(codingPath: container.codingPath, debugDescription: "\(field) must be 32 bytes.", underlyingError: error)
        )
    }
    return bytes
}

private func encodeDigest(_ value: Data, to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
}

private func digestDescription(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

public struct ChunkID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, type: "ChunkID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

public struct AudioBatchID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, type: "AudioBatchID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

public struct EncodedChunkSHA256: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data
    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw TransferValidationError.invalidDigestLength(field: "EncodedChunkSHA256", expected: Self.byteCount, actual: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }
    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "EncodedChunkSHA256")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

public struct NegotiatedCapabilitiesSHA256: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data
    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw TransferValidationError.invalidDigestLength(field: "NegotiatedCapabilitiesSHA256", expected: Self.byteCount, actual: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }
    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "NegotiatedCapabilitiesSHA256")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

public struct UploadProfileSHA256: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data
    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw TransferValidationError.invalidDigestLength(field: "UploadProfileSHA256", expected: Self.byteCount, actual: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }
    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "UploadProfileSHA256")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

/// Section 11 signed-object identity. HarcProtocol computes it from the exact
/// framed bytes; HarcTransfer only preserves and compares the validated digest.
public struct ExactObjectSHA256: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data
    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw TransferValidationError.invalidDigestLength(field: "ExactObjectSHA256", expected: Self.byteCount, actual: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }
    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "ExactObjectSHA256")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

public struct ImmutableBatchSHA256: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data
    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw TransferValidationError.invalidDigestLength(field: "ImmutableBatchSHA256", expected: Self.byteCount, actual: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }
    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "ImmutableBatchSHA256")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

public struct UploadGeneration: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let initial = try! UploadGeneration(1)
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else {
            throw TransferValidationError.invalidUploadAttempt(reason: "Upload generation must be nonzero.")
        }
        self.rawValue = rawValue
    }

    public func next() throws -> Self {
        guard rawValue < UInt64.max else {
            throw TransferValidationError.numericOverflow(field: "UploadGeneration")
        }
        return try Self(rawValue + 1)
    }

    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do { try self.init(container.decode(UInt64.self)) }
        catch { throw TransferValidation.decodingFailure(error, codingPath: container.codingPath, description: "Invalid upload generation.") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
