import Foundation
import HarcDomain

/// Hard V1 transfer limits. Storage and transport adapters may configure lower
/// quotas, but they must never accept values above these protocol ceilings.
public enum TransferLimits {
    public static let canonicalBytesPerFrame: UInt64 = 2
    public static let ordinaryChunkFrames: UInt64 = 960_000
    public static let encodedChunkBytes: UInt64 = 4 * 1_024 * 1_024
    public static let backgroundBatchBytes: UInt64 = 64 * 1_024 * 1_024
    public static let backgroundBatchEntries = 64
    /// Keeps one declaration RPC and the lifetime reconciliation response
    /// comfortably inside the frozen 1 MiB control-message edge. A client may
    /// append in multiple calls, but one upload can never grow an unbounded
    /// in-memory or durable declaration ledger.
    public static let declaredChunksPerCall = 1_024
    public static let declaredChunksPerUpload = 4_096
    public static let activeUploadAttemptsPerDevice = 4
    public static let activeStagingStreamsPerDevice = 2

    public static let uploadGenerationLifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let abandonedStagingRetention: TimeInterval = 7 * 24 * 60 * 60
}

public enum TransferValidationError: Error, Equatable, Sendable {
    case invalidDigestLength(field: String, expected: Int, actual: Int)
    case invalidLength(field: String, value: UInt64)
    case exceedsLimit(field: String, limit: UInt64, actual: UInt64)
    case invalidDate(field: String)
    case invalidOrdering(field: String)
    case duplicateIdentifier(field: String)
    case numericOverflow(field: String)
    case invalidCanonicalFormat
    case originDeviceMismatch
    case discontinuityRecordingMismatch
    case frameRangeOutsideCapture
    case inconsistentCanonicalByteCount(expected: UInt64, actual: UInt64)
    case incompatibleCodecAndContainer
    case invalidCodecParameters(reason: String)
    case rawPCMRestrictedToFixtures
    case invalidCapabilityIdentifier(String)
    case profileMismatch(field: String)
    case chunkConflict(ChunkDeclarationConflict)
    case declarationBlocked
    case declarationClosed
    case nonContiguousDeclaration(expectedIndex: UInt32, expectedStartFrame: UInt64)
    case incompleteChunkCoverage(expectedFrames: UInt64, actualFrames: UInt64)
    case invalidUploadAttempt(reason: String)
    case staleUploadGeneration(expected: UInt64, actual: UInt64)
    case uploadExpired
    case uploadNotExpired
    case uploadTerminal
    case invalidOutboxTransition(from: String, to: String)
    case receiptEvidenceRequired
    case evidenceBindingMismatch(field: String)
    case reconciliationMismatch(reason: String)
    case emptyExactObject
    case wrongExactObjectKind(expected: ExactObjectKind, actual: ExactObjectKind)
}

extension TransferValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDigestLength(let field, let expected, let actual):
            return "\(field) must contain exactly \(expected) bytes; received \(actual)."
        case .invalidLength(let field, let value):
            return "\(field) has invalid length \(value)."
        case .exceedsLimit(let field, let limit, let actual):
            return "\(field) exceeds \(limit); received \(actual)."
        case .invalidDate(let field):
            return "\(field) must be a finite date."
        case .invalidOrdering(let field):
            return "\(field) is not in canonical order."
        case .duplicateIdentifier(let field):
            return "\(field) contains a duplicate identifier."
        case .numericOverflow(let field):
            return "\(field) overflowed its V1 representation."
        case .invalidCanonicalFormat:
            return "Harc transfer V1 requires 16 kHz mono signed Int16 little-endian PCM."
        case .originDeviceMismatch:
            return "The producing device must equal the origin recording device."
        case .discontinuityRecordingMismatch:
            return "Every discontinuity must name the finalized origin recording."
        case .frameRangeOutsideCapture:
            return "A canonical frame range lies outside the finalized capture."
        case .inconsistentCanonicalByteCount(let expected, let actual):
            return "Canonical byte count must be \(expected); received \(actual)."
        case .incompatibleCodecAndContainer:
            return "The selected lossless codec and container are incompatible."
        case .invalidCodecParameters(let reason):
            return "Invalid codec parameters: \(reason)"
        case .rawPCMRestrictedToFixtures:
            return "Raw canonical PCM is permitted only for fixtures and loopback tests."
        case .invalidCapabilityIdentifier(let value):
            return "Invalid transfer capability identifier: \(value)"
        case .profileMismatch(let field):
            return "The value does not match the frozen upload profile field \(field)."
        case .chunkConflict:
            return "A chunk index or identifier was reused with different immutable fields."
        case .declarationBlocked:
            return "The upload declaration ledger is conflict-blocked."
        case .declarationClosed:
            return "The upload declaration ledger is closed."
        case .nonContiguousDeclaration(let expectedIndex, let expectedStartFrame):
            return "The next declaration must be chunk \(expectedIndex) at frame \(expectedStartFrame)."
        case .incompleteChunkCoverage(let expectedFrames, let actualFrames):
            return "Chunk coverage ends at frame \(actualFrames), expected \(expectedFrames)."
        case .invalidUploadAttempt(let reason):
            return "Invalid upload attempt: \(reason)"
        case .staleUploadGeneration(let expected, let actual):
            return "Upload generation \(actual) is stale; current generation is \(expected)."
        case .uploadExpired:
            return "The upload generation has expired."
        case .uploadNotExpired:
            return "The upload generation has not expired and cannot be reopened."
        case .uploadTerminal:
            return "The upload attempt is terminal."
        case .invalidOutboxTransition(let from, let to):
            return "Invalid outbox transition from \(from) to \(to)."
        case .receiptEvidenceRequired:
            return "A persistently stored, validated receipt is required."
        case .evidenceBindingMismatch(let field):
            return "Validated signed-object evidence does not match \(field)."
        case .reconciliationMismatch(let reason):
            return "Invalid upload reconciliation: \(reason)"
        case .emptyExactObject:
            return "An exact signed-object slot cannot be empty."
        case .wrongExactObjectKind(let expected, let actual):
            return "Expected exact object kind \(expected.rawValue), received \(actual.rawValue)."
        }
    }
}

enum TransferValidation {
    static func requireFinite(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw TransferValidationError.invalidDate(field: field)
        }
    }

    static func requireHarcV1(_ format: CanonicalPCMFormat) throws {
        guard format == .harcV1 else {
            throw TransferValidationError.invalidCanonicalFormat
        }
    }

    static func canonicalByteCount(forFrames frameCount: UInt64) throws -> UInt64 {
        let result = frameCount.multipliedReportingOverflow(by: TransferLimits.canonicalBytesPerFrame)
        guard !result.overflow else {
            throw TransferValidationError.numericOverflow(field: "canonicalByteCount")
        }
        return result.partialValue
    }

    static func adding(_ lhs: UInt64, _ rhs: UInt64, field: String) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw TransferValidationError.numericOverflow(field: field)
        }
        return result.partialValue
    }

    static func next(_ index: UInt32, field: String) throws -> UInt32 {
        let result = index.addingReportingOverflow(1)
        guard !result.overflow else {
            throw TransferValidationError.numericOverflow(field: field)
        }
        return result.partialValue
    }

    static func normalizedCode(_ value: String, field: String, maximum: Int = 128) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else {
            throw TransferValidationError.invalidCapabilityIdentifier(value)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            throw TransferValidationError.invalidCapabilityIdentifier(value)
        }
        return trimmed
    }

    static func boundedMessage(_ value: String?, maximum: Int = 4_096) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else {
            throw TransferValidationError.invalidUploadAttempt(reason: "Failure detail is empty or exceeds \(maximum) characters.")
        }
        return trimmed
    }

    static func decodingFailure(
        _ error: any Error,
        codingPath: [any CodingKey],
        description: String
    ) -> DecodingError {
        .dataCorrupted(
            .init(codingPath: codingPath, debugDescription: description, underlyingError: error)
        )
    }
}
