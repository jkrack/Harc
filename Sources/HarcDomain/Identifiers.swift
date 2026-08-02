import Foundation

private func decodeUUID(
    from decoder: any Decoder,
    typeName: String
) throws -> UUID {
    let container = try decoder.singleValueContainer()
    let encoded = try container.decode(String.self)
    guard let value = UUID(uuidString: encoded) else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid \(typeName) UUID: \(encoded)"
        )
    }
    return value
}

private func encodeUUID(_ value: UUID, to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value.uuidString.lowercased())
}

private func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.lexicographicallyPrecedes(rhs.uuidString)
}

private func decodeDigest(
    from decoder: any Decoder,
    field: String
) throws -> Data {
    let container = try decoder.singleValueContainer()
    let data = try container.decode(Data.self)
    guard data.count == 32 else {
        let error = DomainValidationError.invalidDigestLength(
            field: field,
            expected: 32,
            actual: data.count
        )
        throw DomainValidation.decodingError(
            error,
            in: container,
            description: "\(field) must contain exactly 32 bytes."
        )
    }
    return data
}

private func encodeDigest(_ value: Data, to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
}

private func digestDescription(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

public struct LibraryID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { uuidLessThan(lhs.rawValue, rhs.rawValue) }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, typeName: "LibraryID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

public struct HostStateID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { uuidLessThan(lhs.rawValue, rhs.rawValue) }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, typeName: "HostStateID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

public struct GrantID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { uuidLessThan(lhs.rawValue, rhs.rawValue) }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, typeName: "GrantID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

public struct CanonicalRecordingID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { uuidLessThan(lhs.rawValue, rhs.rawValue) }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, typeName: "CanonicalRecordingID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

public struct UploadID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { uuidLessThan(lhs.rawValue, rhs.rawValue) }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, typeName: "UploadID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

public struct OperationID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public static func random() -> Self { Self(UUID()) }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { uuidLessThan(lhs.rawValue, rhs.rawValue) }
    public init(from decoder: any Decoder) throws { self.init(try decodeUUID(from: decoder, typeName: "OperationID")) }
    public func encode(to encoder: any Encoder) throws { try encodeUUID(rawValue, to: encoder) }
}

/// SHA-256 identity of the host's versioned canonical authority public key.
public struct HostAuthorityID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data

    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw DomainValidationError.invalidDigestLength(
                field: "HostAuthorityID",
                expected: Self.byteCount,
                actual: rawBytes.count
            )
        }
        self.rawBytes = rawBytes
    }

    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "HostAuthorityID")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

/// SHA-256 identity of a device's versioned canonical public key.
public struct DeviceID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data

    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw DomainValidationError.invalidDigestLength(
                field: "DeviceID",
                expected: Self.byteCount,
                actual: rawBytes.count
            )
        }
        self.rawBytes = rawBytes
    }

    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "DeviceID")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

/// SHA-256 over canonical signed-Int16 little-endian PCM bytes.
public struct CanonicalPCMHash: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let byteCount = 32
    public let rawBytes: Data

    public init(_ rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else {
            throw DomainValidationError.invalidDigestLength(
                field: "CanonicalPCMHash",
                expected: Self.byteCount,
                actual: rawBytes.count
            )
        }
        self.rawBytes = rawBytes
    }

    public var description: String { digestDescription(rawBytes) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawBytes.lexicographicallyPrecedes(rhs.rawBytes) }
    public init(from decoder: any Decoder) throws { try self.init(decodeDigest(from: decoder, field: "CanonicalPCMHash")) }
    public func encode(to encoder: any Encoder) throws { try encodeDigest(rawBytes, to: encoder) }
}

/// A producing-device identity paired with that device's immutable recording UUID.
public struct OriginRecordingID: Hashable, Sendable, Comparable, Codable {
    public let deviceID: DeviceID
    public let recordingUUID: UUID

    public init(deviceID: DeviceID, recordingUUID: UUID) {
        self.deviceID = deviceID
        self.recordingUUID = recordingUUID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        return uuidLessThan(lhs.recordingUUID, rhs.recordingUUID)
    }
}
