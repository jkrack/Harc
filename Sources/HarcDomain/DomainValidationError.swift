import Foundation

/// Validation failures for portable Harc domain values.
///
/// These errors intentionally describe domain invariants rather than storage or
/// transport failures. GRDB and protobuf adapters translate them at their own
/// boundaries.
public enum DomainValidationError: Error, Equatable, Sendable {
    case invalidDigestLength(field: String, expected: Int, actual: Int)
    case zeroEntityRevision
    case invalidSignedValue(field: String, value: Int64)
    case numericOverflow(field: String)
    case invalidFrameRange(startFrame: UInt64, endFrameExclusive: UInt64)
    case invalidDate(field: String)
    case emptyField(field: String)
    case fieldTooLong(field: String, maximum: Int, actual: Int)
    case invalidCode(field: String)
    case invalidState(reason: String)
    case invalidOrdering(field: String)
    case duplicateIdentifier(field: String)
    case inconsistentHostIdentity
    case matchingConflictRevisions
}

extension DomainValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDigestLength(let field, let expected, let actual):
            return "\(field) must contain exactly \(expected) bytes; received \(actual)."
        case .zeroEntityRevision:
            return "An entity revision must be greater than zero."
        case .invalidSignedValue(let field, let value):
            return "\(field) cannot be constructed from signed value \(value)."
        case .numericOverflow(let field):
            return "\(field) cannot be incremented or represented without overflow."
        case .invalidFrameRange(let startFrame, let endFrameExclusive):
            return "Frame range end \(endFrameExclusive) precedes start \(startFrame)."
        case .invalidDate(let field):
            return "\(field) must be a finite date."
        case .emptyField(let field):
            return "\(field) must not be empty."
        case .fieldTooLong(let field, let maximum, let actual):
            return "\(field) is \(actual) characters; the maximum is \(maximum)."
        case .invalidCode(let field):
            return "\(field) contains characters outside the portable code alphabet."
        case .invalidState(let reason):
            return "Invalid domain state: \(reason)"
        case .invalidOrdering(let field):
            return "\(field) is not in canonical order."
        case .duplicateIdentifier(let field):
            return "\(field) contains a duplicate identifier."
        case .inconsistentHostIdentity:
            return "Host authority and host-state identifiers must be present together, and Host mode requires both."
        case .matchingConflictRevisions:
            return "A revision conflict must contain different expected and current revisions."
        }
    }
}

enum DomainValidation {
    static func requireFinite(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainValidationError.invalidDate(field: field)
        }
    }

    static func nonemptyTrimmed(
        _ value: String,
        field: String,
        maximum: Int
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainValidationError.emptyField(field: field)
        }
        guard trimmed.count <= maximum else {
            throw DomainValidationError.fieldTooLong(
                field: field,
                maximum: maximum,
                actual: trimmed.count
            )
        }
        return trimmed
    }

    static func decodingError(
        _ error: any Error,
        in container: any SingleValueDecodingContainer,
        description: String
    ) -> DecodingError {
        .dataCorrupted(
            .init(
                codingPath: container.codingPath,
                debugDescription: description,
                underlyingError: error
            )
        )
    }
}
