import Foundation

public struct ProcessingFailure: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let message: String?

    public init(code: String, message: String? = nil) throws {
        let code = try DomainValidation.nonemptyTrimmed(
            code,
            field: "ProcessingFailure.code",
            maximum: 128
        )
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard code.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DomainValidationError.invalidCode(field: "ProcessingFailure.code")
        }

        let normalizedMessage: String?
        if let message {
            normalizedMessage = try DomainValidation.nonemptyTrimmed(
                message,
                field: "ProcessingFailure.message",
                maximum: 4_096
            )
        } else {
            normalizedMessage = nil
        }

        self.code = code
        self.message = normalizedMessage
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                code: container.decode(String.self, forKey: .code),
                message: container.decodeIfPresent(String.self, forKey: .message)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid processing failure.",
                    underlyingError: error
                )
            )
        }
    }
}

/// Canonical post-commit processing state. Audio durability is independent of
/// this state.
public enum RecordingProcessingState: String, Codable, CaseIterable, Sendable {
    case pending
    case transcribing
    case projecting
    case ready
    case degraded
    case failedRecoverable
}

public struct ProcessingDescriptor: Codable, Equatable, Hashable, Sendable {
    public let state: RecordingProcessingState
    public let failure: ProcessingFailure?

    public init(
        state: RecordingProcessingState,
        failure: ProcessingFailure? = nil
    ) throws {
        if failure != nil {
            guard state == .degraded || state == .failedRecoverable else {
                throw DomainValidationError.invalidState(
                    reason: "Processing failure detail is allowed only for degraded or failedRecoverable state."
                )
            }
        }
        self.state = state
        self.failure = failure
    }

    public static let pending = try! ProcessingDescriptor(state: .pending)
    public static let ready = try! ProcessingDescriptor(state: .ready)

    private enum CodingKeys: String, CodingKey {
        case state
        case failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                state: container.decode(RecordingProcessingState.self, forKey: .state),
                failure: container.decodeIfPresent(ProcessingFailure.self, forKey: .failure)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid processing descriptor.",
                    underlyingError: error
                )
            )
        }
    }
}

public enum RecordingProjectionState: String, Codable, CaseIterable, Sendable {
    case unknownLegacy
    case pending
    case projecting
    case ready
    case degraded
    case failedRecoverable
}

public struct ProjectionDescriptor: Codable, Equatable, Hashable, Sendable {
    public let state: RecordingProjectionState
    public let version: ProjectionVersion?
    public let failure: ProcessingFailure?

    public init(
        state: RecordingProjectionState,
        version: ProjectionVersion? = nil,
        failure: ProcessingFailure? = nil
    ) throws {
        if state == .unknownLegacy, version != nil || failure != nil {
            throw DomainValidationError.invalidState(
                reason: "unknownLegacy projection state cannot claim a version or failure."
            )
        }
        if state == .ready, version == nil {
            throw DomainValidationError.invalidState(
                reason: "A ready projection requires a nonzero version."
            )
        }
        if failure != nil {
            guard state == .degraded || state == .failedRecoverable else {
                throw DomainValidationError.invalidState(
                    reason: "Projection failure detail is allowed only for degraded or failedRecoverable state."
                )
            }
        }

        self.state = state
        self.version = version
        self.failure = failure
    }

    public static let unknownLegacy = try! ProjectionDescriptor(state: .unknownLegacy)
    public static let pending = try! ProjectionDescriptor(state: .pending)
    public static let readyV1 = try! ProjectionDescriptor(
        state: .ready,
        version: ProjectionVersion(1)
    )

    private enum CodingKeys: String, CodingKey {
        case state
        case version
        case failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                state: container.decode(RecordingProjectionState.self, forKey: .state),
                version: container.decodeIfPresent(ProjectionVersion.self, forKey: .version),
                failure: container.decodeIfPresent(ProcessingFailure.self, forKey: .failure)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid projection descriptor.",
                    underlyingError: error
                )
            )
        }
    }
}
