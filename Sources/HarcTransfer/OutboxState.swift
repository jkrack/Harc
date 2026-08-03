import Foundation

public struct TransferFailure: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let detail: String?

    public init(code: String, detail: String? = nil) throws {
        self.code = try TransferValidation.normalizedCode(code, field: "TransferFailure.code")
        self.detail = try TransferValidation.boundedMessage(detail)
    }

    private enum CodingKeys: String, CodingKey { case code, detail }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                code: container.decode(String.self, forKey: .code),
                detail: container.decodeIfPresent(String.self, forKey: .detail)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid transfer failure.")
        }
    }
}

public enum TransferSecurityBlockReason: String, Codable, CaseIterable, Sendable {
    case installationKeyLost
    case hostIdentityMismatch
    case grantRevoked
    case grantEpochChanged
    case authorizationDenied
    case signatureOrObjectMismatch
    case unknownCriticalField
}

public enum RecordingOutboxState: String, Codable, CaseIterable, Sendable {
    case localOnly
    case queued
    case authorizing
    case activeUpload
    case backgroundScheduled
    case hostCommitPending
    case committed
    case failedRecoverable
    case securityBlocked
}

/// Pure recording-level transfer state. Local retention and cleanup intent are
/// store concerns; this machine never equates a staging ACK with commit.
public struct RecordingOutboxStateMachine: Codable, Equatable, Hashable, Sendable {
    public private(set) var state: RecordingOutboxState
    public private(set) var failure: TransferFailure?
    public private(set) var securityBlockReason: TransferSecurityBlockReason?
    public private(set) var exactReceipt: OpaqueExactObjectSlot?

    public init() {
        state = .localOnly
        failure = nil
        securityBlockReason = nil
        exactReceipt = nil
    }

    public mutating func queue() throws { try advance(from: [.localOnly], to: .queued) }
    public mutating func beginAuthorization() throws { try advance(from: [.queued], to: .authorizing) }
    public mutating func beginActiveUpload() throws { try advance(from: [.authorizing], to: .activeUpload) }
    public mutating func scheduleBackgroundUpload() throws {
        try advance(from: [.authorizing, .activeUpload], to: .backgroundScheduled)
    }
    public mutating func awaitHostCommit() throws {
        try advance(from: [.activeUpload, .backgroundScheduled], to: .hostCommitPending)
    }

    public mutating func failRecoverably(_ failure: TransferFailure) throws {
        let permitted: Set<RecordingOutboxState> = [
            .localOnly, .queued, .authorizing, .activeUpload, .backgroundScheduled, .hostCommitPending,
        ]
        guard permitted.contains(state) else {
            throw TransferValidationError.invalidOutboxTransition(from: state.rawValue, to: RecordingOutboxState.failedRecoverable.rawValue)
        }
        state = .failedRecoverable
        self.failure = failure
        securityBlockReason = nil
    }

    /// Security blocking is valid while authorization is validating the local
    /// key, pinned host, and grant epoch, or from any later authorized state.
    /// `queued` is deliberately excluded: a scheduler first enters
    /// `authorizing`, then records any trust failure. There is no automatic
    /// retry transition.
    public mutating func blockForSecurity(_ reason: TransferSecurityBlockReason) throws {
        let permitted: Set<RecordingOutboxState> = [
            .authorizing, .activeUpload, .backgroundScheduled, .hostCommitPending,
        ]
        guard permitted.contains(state) else {
            throw TransferValidationError.invalidOutboxTransition(from: state.rawValue, to: RecordingOutboxState.securityBlocked.rawValue)
        }
        state = .securityBlocked
        failure = nil
        securityBlockReason = reason
    }

    public mutating func retryRecoverable() throws {
        try advance(from: [.failedRecoverable], to: .queued)
    }

    /// This explicit API is the only exit from `securityBlocked`; schedulers
    /// cannot accidentally use the ordinary recoverable retry path.
    public mutating func resumeAfterUserSecurityAction() throws {
        try advance(from: [.securityBlocked], to: .queued)
    }

    public mutating func markCommitted(
        using evidence: ValidatedRecordingReceiptEvidence
    ) throws {
        guard state == .hostCommitPending else {
            throw TransferValidationError.invalidOutboxTransition(from: state.rawValue, to: RecordingOutboxState.committed.rawValue)
        }
        let receipt = evidence.exactReceiptObject
        guard receipt.kind == .recordingReceiptV1 else {
            throw TransferValidationError.wrongExactObjectKind(expected: .recordingReceiptV1, actual: receipt.kind)
        }
        state = .committed
        failure = nil
        securityBlockReason = nil
        exactReceipt = receipt
    }

    private mutating func advance(
        from permitted: Set<RecordingOutboxState>,
        to next: RecordingOutboxState
    ) throws {
        guard permitted.contains(state) else {
            throw TransferValidationError.invalidOutboxTransition(from: state.rawValue, to: next.rawValue)
        }
        state = next
        failure = nil
        securityBlockReason = nil
    }

    private enum CodingKeys: String, CodingKey {
        case state, failure, securityBlockReason, exactReceipt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let state = try container.decode(RecordingOutboxState.self, forKey: .state)
            let failure = try container.decodeIfPresent(TransferFailure.self, forKey: .failure)
            let security = try container.decodeIfPresent(TransferSecurityBlockReason.self, forKey: .securityBlockReason)
            let receipt = try container.decodeIfPresent(OpaqueExactObjectSlot.self, forKey: .exactReceipt)

            switch state {
            case .failedRecoverable:
                guard failure != nil, security == nil, receipt == nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Recoverable outbox state requires only a failure.")
                }
            case .securityBlocked:
                guard failure == nil, security != nil, receipt == nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Security-blocked outbox state requires only a security reason.")
                }
            case .committed:
                guard failure == nil, security == nil, let receipt,
                      receipt.kind == .recordingReceiptV1 else {
                    throw TransferValidationError.receiptEvidenceRequired
                }
            default:
                guard failure == nil, security == nil, receipt == nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Active outbox state carries incompatible detail.")
                }
            }
            self.state = state
            self.failure = failure
            self.securityBlockReason = security
            self.exactReceipt = receipt
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid recording outbox state.")
        }
    }
}

public enum ChunkOutboxState: String, Codable, CaseIterable, Sendable {
    case pending
    case encoding
    case ready
    case scheduled
    case sending
    case durableAtHost
    case failedRecoverable
}

public enum ChunkRetryPoint: String, Codable, CaseIterable, Sendable {
    case pending
    case ready
}

public struct ChunkOutboxStateMachine: Codable, Equatable, Hashable, Sendable {
    public private(set) var state: ChunkOutboxState
    public private(set) var failure: TransferFailure?
    public private(set) var retryPoint: ChunkRetryPoint?

    public init() {
        state = .pending
        failure = nil
        retryPoint = nil
    }

    public mutating func beginEncoding() throws { try advance(from: [.pending], to: .encoding) }
    public mutating func markReady() throws { try advance(from: [.encoding], to: .ready) }
    public mutating func schedule() throws { try advance(from: [.ready], to: .scheduled) }
    public mutating func beginSending() throws { try advance(from: [.ready, .scheduled], to: .sending) }
    public mutating func markDurableAtHost() throws {
        // A background completion can be reconciled directly from `scheduled`
        // after process termination, without observing in-memory `sending`.
        try advance(from: [.scheduled, .sending], to: .durableAtHost)
    }

    public mutating func failRecoverably(
        _ failure: TransferFailure,
        retryFrom retryPoint: ChunkRetryPoint
    ) throws {
        guard state != .durableAtHost, state != .failedRecoverable else {
            throw TransferValidationError.invalidOutboxTransition(from: state.rawValue, to: ChunkOutboxState.failedRecoverable.rawValue)
        }
        state = .failedRecoverable
        self.failure = failure
        self.retryPoint = retryPoint
    }

    public mutating func retryRecoverable() throws {
        guard state == .failedRecoverable, let retryPoint else {
            throw TransferValidationError.invalidOutboxTransition(from: state.rawValue, to: "retry")
        }
        state = retryPoint == .pending ? .pending : .ready
        failure = nil
        self.retryPoint = nil
    }

    private mutating func advance(
        from permitted: Set<ChunkOutboxState>,
        to next: ChunkOutboxState
    ) throws {
        guard permitted.contains(state) else {
            throw TransferValidationError.invalidOutboxTransition(from: state.rawValue, to: next.rawValue)
        }
        state = next
        failure = nil
        retryPoint = nil
    }

    private enum CodingKeys: String, CodingKey { case state, failure, retryPoint }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let state = try container.decode(ChunkOutboxState.self, forKey: .state)
            let failure = try container.decodeIfPresent(TransferFailure.self, forKey: .failure)
            let retryPoint = try container.decodeIfPresent(ChunkRetryPoint.self, forKey: .retryPoint)
            if state == .failedRecoverable {
                guard failure != nil, retryPoint != nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Failed chunk requires failure and retry point.")
                }
            } else {
                guard failure == nil, retryPoint == nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Active chunk carries failure state.")
                }
            }
            self.state = state
            self.failure = failure
            self.retryPoint = retryPoint
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid chunk outbox state.")
        }
    }
}
