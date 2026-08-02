import Foundation

/// A nonzero, monotonically increasing entity revision.
public struct EntityRevision: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let initial = try! EntityRevision(1)
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else { throw DomainValidationError.zeroEntityRevision }
        self.rawValue = rawValue
    }

    public init(signedValue: Int64) throws {
        guard signedValue > 0 else {
            throw DomainValidationError.invalidSignedValue(field: "EntityRevision", value: signedValue)
        }
        try self.init(UInt64(signedValue))
    }

    public func next() throws -> Self {
        guard rawValue < UInt64.max else {
            throw DomainValidationError.numericOverflow(field: "EntityRevision")
        }
        return try Self(rawValue + 1)
    }

    public func signedInt64Value() throws -> Int64 {
        guard let value = Int64(exactly: rawValue) else {
            throw DomainValidationError.numericOverflow(field: "EntityRevision")
        }
        return value
    }

    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt64.self)
        do {
            try self.init(value)
        } catch {
            throw DomainValidation.decodingError(
                error,
                in: container,
                description: "EntityRevision must be greater than zero."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A host-monotonic cursor. Zero is the valid anchor for a new or migrated
/// library whose change log has not recorded its first mutation.
public struct ChangeCursor: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let zero = ChangeCursor(0)
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    public init(signedValue: Int64) throws {
        guard signedValue >= 0 else {
            throw DomainValidationError.invalidSignedValue(field: "ChangeCursor", value: signedValue)
        }
        self.init(UInt64(signedValue))
    }

    public func next() throws -> Self {
        guard rawValue < UInt64.max else {
            throw DomainValidationError.numericOverflow(field: "ChangeCursor")
        }
        return Self(rawValue + 1)
    }

    public func signedInt64Value() throws -> Int64 {
        guard let value = Int64(exactly: rawValue) else {
            throw DomainValidationError.numericOverflow(field: "ChangeCursor")
        }
        return value
    }

    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(UInt64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A nonzero portable projection schema/content version.
public struct ProjectionVersion: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else {
            throw DomainValidationError.invalidState(reason: "ProjectionVersion must be greater than zero.")
        }
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt64.self)
        do {
            try self.init(value)
        } catch {
            throw DomainValidation.decodingError(
                error,
                in: container,
                description: "ProjectionVersion must be greater than zero."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum LibraryWriterMode: String, Codable, CaseIterable, Sendable {
    case standalone
    case host
}
