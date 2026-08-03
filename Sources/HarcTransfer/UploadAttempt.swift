import Foundation
import HarcDomain

public enum UploadAttemptStatus: String, Codable, CaseIterable, Sendable {
    case active
    case conflictBlocked
    case abandoned
    case committed
}

public enum UploadAttemptBlockReason: String, Codable, CaseIterable, Sendable {
    case chunkDeclarationConflict
    case manifestObjectConflict
}

public enum UploadLeaseState: String, Codable, CaseIterable, Sendable {
    case active
    case expired
    case conflictBlocked
    case abandoned
    case committed
}

public enum ExactObjectBindingDisposition: Equatable, Hashable, Sendable {
    case bound
    case exactReplay
}

/// One resumable upload identity and its immutable declarations. Expiry is
/// absolute within a generation; ordinary activity has no API that can slide it.
public struct UploadAttempt: Codable, Equatable, Hashable, Sendable {
    public let uploadID: UploadID
    public let ownerDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let firstBeganAt: Date
    public private(set) var generation: UploadGeneration
    public private(set) var generationBeganAt: Date
    public private(set) var generationExpiresAt: Date
    public private(set) var status: UploadAttemptStatus
    public private(set) var blockReason: UploadAttemptBlockReason?
    public private(set) var declarations: ChunkDeclarationLedger
    public private(set) var boundHostTrust: RecordingHostTrustBinding?
    public private(set) var boundManifest: OpaqueExactObjectSlot?
    public private(set) var boundFinalizedCapture: ChunkedFinalizedCapture?
    public private(set) var exactReceipt: OpaqueExactObjectSlot?
    public private(set) var terminalAt: Date?

    public var frozenProfile: FrozenUploadProfile { declarations.frozenProfile }

    public init(
        uploadID: UploadID,
        ownerDeviceID: DeviceID,
        originRecordingID: OriginRecordingID,
        frozenProfile: FrozenUploadProfile,
        beganAt: Date,
        grantExpiresAt: Date? = nil
    ) throws {
        guard originRecordingID.deviceID == ownerDeviceID else {
            throw TransferValidationError.originDeviceMismatch
        }
        try TransferValidation.requireFinite(beganAt, field: "UploadAttempt.beganAt")
        let expiry = try Self.expiry(beginningAt: beganAt, grantExpiresAt: grantExpiresAt)

        self.uploadID = uploadID
        self.ownerDeviceID = ownerDeviceID
        self.originRecordingID = originRecordingID
        self.firstBeganAt = beganAt
        self.generation = .initial
        self.generationBeganAt = beganAt
        self.generationExpiresAt = expiry
        self.status = .active
        self.blockReason = nil
        self.declarations = ChunkDeclarationLedger(
            originRecordingID: originRecordingID,
            frozenProfile: frozenProfile
        )
        self.boundHostTrust = nil
        self.boundManifest = nil
        self.boundFinalizedCapture = nil
        self.exactReceipt = nil
        self.terminalAt = nil
    }

    /// Reconstructs an active attempt from host-authoritative reconciliation.
    /// This is required when the host accepted `BeginUpload` but the response
    /// did not cross the client's durable boundary. Unlike deriving a start
    /// time from expiry, it remains exact when grant expiry shortens a lease.
    public static func recoverActive(
        uploadID: UploadID,
        ownerDeviceID: DeviceID,
        originRecordingID: OriginRecordingID,
        frozenProfile: FrozenUploadProfile,
        firstBeganAt: Date,
        generation: UploadGeneration,
        generationBeganAt: Date,
        generationExpiresAt: Date
    ) throws -> Self {
        try TransferValidation.requireFinite(
            firstBeganAt,
            field: "UploadAttempt.recovery.firstBeganAt"
        )
        try TransferValidation.requireFinite(
            generationBeganAt,
            field: "UploadAttempt.recovery.generationBeganAt"
        )
        try TransferValidation.requireFinite(
            generationExpiresAt,
            field: "UploadAttempt.recovery.generationExpiresAt"
        )
        guard firstBeganAt <= generationBeganAt,
              generationBeganAt < generationExpiresAt,
              generationExpiresAt <= generationBeganAt.addingTimeInterval(
                TransferLimits.uploadGenerationLifetime
              ) else {
            throw TransferValidationError.invalidOrdering(
                field: "UploadAttempt.recovery.generationLifetime"
            )
        }
        if generation == .initial, firstBeganAt != generationBeganAt {
            throw TransferValidationError.invalidUploadAttempt(
                reason: "The initial generation must begin with the upload."
            )
        }

        var recovered = try Self(
            uploadID: uploadID,
            ownerDeviceID: ownerDeviceID,
            originRecordingID: originRecordingID,
            frozenProfile: frozenProfile,
            beganAt: firstBeganAt
        )
        recovered.generation = generation
        recovered.generationBeganAt = generationBeganAt
        recovered.generationExpiresAt = generationExpiresAt
        return recovered
    }

    public func leaseState(at date: Date) throws -> UploadLeaseState {
        try TransferValidation.requireFinite(date, field: "UploadAttempt.leaseState.at")
        switch status {
        case .active:
            return date >= generationExpiresAt ? .expired : .active
        case .conflictBlocked: return .conflictBlocked
        case .abandoned: return .abandoned
        case .committed: return .committed
        }
    }

    public func validateExactBeginReplay(
        uploadID: UploadID,
        ownerDeviceID: DeviceID,
        originRecordingID: OriginRecordingID,
        frozenProfile: FrozenUploadProfile
    ) throws {
        guard self.uploadID == uploadID else {
            throw TransferValidationError.invalidUploadAttempt(reason: "Upload ID replay mismatch.")
        }
        guard self.ownerDeviceID == ownerDeviceID else {
            throw TransferValidationError.invalidUploadAttempt(reason: "Upload owner replay mismatch.")
        }
        guard self.originRecordingID == originRecordingID else {
            throw TransferValidationError.invalidUploadAttempt(reason: "Origin recording replay mismatch.")
        }
        guard self.frozenProfile == frozenProfile else {
            throw TransferValidationError.invalidUploadAttempt(reason: "Frozen upload profile replay mismatch.")
        }
    }

    public func requireActive(generation requestedGeneration: UploadGeneration, at date: Date) throws {
        try TransferValidation.requireFinite(date, field: "UploadAttempt.requireActive.at")
        guard requestedGeneration == generation else {
            throw TransferValidationError.staleUploadGeneration(
                expected: generation.rawValue,
                actual: requestedGeneration.rawValue
            )
        }
        guard status == .active else {
            if status == .conflictBlocked { throw TransferValidationError.declarationBlocked }
            throw TransferValidationError.uploadTerminal
        }
        guard date >= generationBeganAt else {
            throw TransferValidationError.invalidOrdering(field: "UploadAttempt operation time")
        }
        guard try leaseState(at: date) == .active else {
            throw TransferValidationError.uploadExpired
        }
    }

    @discardableResult
    public mutating func declare(
        _ descriptors: [LogicalChunkDescriptor],
        generation requestedGeneration: UploadGeneration,
        at date: Date
    ) throws -> ChunkDeclarationDisposition {
        try requireActive(generation: requestedGeneration, at: date)
        do {
            return try declarations.declare(descriptors)
        } catch let error as TransferValidationError {
            if case .chunkConflict = error {
                status = .conflictBlocked
                blockReason = .chunkDeclarationConflict
            }
            throw error
        }
    }

    @discardableResult
    public mutating func bindFinalManifest(
        using evidence: ValidatedRecordingManifestEvidence,
        generation requestedGeneration: UploadGeneration,
        at date: Date
    ) throws -> ExactObjectBindingDisposition {
        try requireActive(generation: requestedGeneration, at: date)
        let manifest = evidence.exactManifestObject
        let finalizedCapture = evidence.finalizedCapture
        guard manifest.kind == .recordingManifestV1 else {
            throw TransferValidationError.wrongExactObjectKind(
                expected: .recordingManifestV1,
                actual: manifest.kind
            )
        }
        guard evidence.uploadID == uploadID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "uploadID")
        }
        guard evidence.producingDeviceID == ownerDeviceID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "producingDeviceID")
        }
        guard evidence.originRecordingID == originRecordingID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "originRecordingID")
        }
        guard evidence.uploadProfileSHA256 == frozenProfile.profileSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "uploadProfileSHA256")
        }
        guard evidence.canonicalFormat == frozenProfile.canonicalFormat else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalFormat")
        }
        try finalizedCapture.validate(against: frozenProfile)

        if let existing = boundManifest {
            if existing == manifest,
               boundHostTrust == evidence.hostTrust,
               boundFinalizedCapture == finalizedCapture {
                return .exactReplay
            }
            status = .conflictBlocked
            blockReason = .manifestObjectConflict
            throw TransferValidationError.invalidUploadAttempt(
                reason: "A different final manifest object was supplied for the same upload ID."
            )
        }

        _ = try declarations.close(for: finalizedCapture)
        boundHostTrust = evidence.hostTrust
        boundManifest = manifest
        boundFinalizedCapture = finalizedCapture
        return .bound
    }

    /// Reopens only an expired, otherwise nonterminal attempt. Declarations and
    /// an already bound exact manifest remain unchanged; transport capabilities
    /// bind the incremented generation and therefore become stale externally.
    public mutating func reopen(
        at date: Date,
        grantExpiresAt: Date? = nil
    ) throws {
        try TransferValidation.requireFinite(date, field: "UploadAttempt.reopen.at")
        guard status == .active else {
            if status == .conflictBlocked { throw TransferValidationError.declarationBlocked }
            throw TransferValidationError.uploadTerminal
        }
        guard date >= generationExpiresAt else {
            throw TransferValidationError.uploadNotExpired
        }
        generation = try generation.next()
        generationBeganAt = date
        generationExpiresAt = try Self.expiry(beginningAt: date, grantExpiresAt: grantExpiresAt)
    }

    /// Idempotent for an already abandoned attempt. A conflict-blocked or
    /// expired attempt remains explicitly abandonable by its owner.
    public mutating func abandon(at date: Date) throws {
        try TransferValidation.requireFinite(date, field: "UploadAttempt.abandon.at")
        guard date >= generationBeganAt else {
            throw TransferValidationError.invalidOrdering(field: "UploadAttempt.abandon.at")
        }
        if status == .abandoned { return }
        guard status != .committed else {
            throw TransferValidationError.uploadTerminal
        }
        status = .abandoned
        blockReason = nil
        terminalAt = date
    }

    /// PR 5 supplies concrete validator evidence. HarcTransfer rechecks every
    /// binding it can recover from the attempt before recording commit.
    public mutating func markCommitted(
        using evidence: ValidatedRecordingReceiptEvidence,
        generation requestedGeneration: UploadGeneration,
        at date: Date
    ) throws {
        try markCommittedFromAcceptedPublication(
            using: evidence,
            generation: requestedGeneration,
            authorizationAcceptedAt: date,
            committedAt: date
        )
    }

    /// Completes a publication whose authorization and immutable plan were
    /// durably accepted while this upload generation was active. Recovery may
    /// call this after the generation or grant has subsequently expired; it
    /// must present the original acceptance instant and generation instead of
    /// manufacturing a new authorization decision.
    package mutating func markCommittedFromAcceptedPublication(
        using evidence: ValidatedRecordingReceiptEvidence,
        generation requestedGeneration: UploadGeneration,
        authorizationAcceptedAt: Date,
        committedAt: Date
    ) throws {
        try requireActive(
            generation: requestedGeneration,
            at: authorizationAcceptedAt
        )
        try TransferValidation.requireFinite(
            committedAt,
            field: "UploadAttempt.markCommittedFromAcceptedPublication.committedAt"
        )
        guard committedAt >= authorizationAcceptedAt else {
            throw TransferValidationError.invalidOrdering(
                field: "UploadAttempt publication commit time"
            )
        }
        guard let boundHostTrust, let boundManifest, let boundFinalizedCapture else {
            throw TransferValidationError.invalidUploadAttempt(reason: "Commit requires a bound final manifest.")
        }
        let receipt = evidence.exactReceiptObject
        guard receipt.kind == .recordingReceiptV1 else {
            throw TransferValidationError.wrongExactObjectKind(
                expected: .recordingReceiptV1,
                actual: receipt.kind
            )
        }
        guard evidence.hostTrust == boundHostTrust else {
            throw TransferValidationError.evidenceBindingMismatch(field: "hostTrust")
        }
        guard evidence.uploadID == uploadID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "uploadID")
        }
        guard evidence.producingDeviceID == ownerDeviceID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "producingDeviceID")
        }
        guard evidence.originRecordingID == originRecordingID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "originRecordingID")
        }
        guard evidence.exactManifestObject == boundManifest,
              evidence.signedManifestObjectSHA256 == boundManifest.objectSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "signedManifestObject")
        }
        guard evidence.uploadProfileSHA256 == frozenProfile.profileSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "uploadProfileSHA256")
        }
        guard evidence.canonicalPCMSHA256 == boundFinalizedCapture.capture.canonicalPCMSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalPCMSHA256")
        }
        guard evidence.totalCanonicalFrames == boundFinalizedCapture.capture.totalCanonicalFrames else {
            throw TransferValidationError.evidenceBindingMismatch(field: "totalCanonicalFrames")
        }
        guard evidence.canonicalFormat == boundFinalizedCapture.capture.canonicalFormat else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalFormat")
        }
        status = .committed
        blockReason = nil
        exactReceipt = receipt
        terminalAt = committedAt
    }

    private static func expiry(beginningAt date: Date, grantExpiresAt: Date?) throws -> Date {
        let protocolExpiry = date.addingTimeInterval(TransferLimits.uploadGenerationLifetime)
        try TransferValidation.requireFinite(protocolExpiry, field: "UploadAttempt.generationExpiresAt")
        guard let grantExpiresAt else { return protocolExpiry }
        try TransferValidation.requireFinite(grantExpiresAt, field: "UploadAttempt.grantExpiresAt")
        guard grantExpiresAt > date else {
            throw TransferValidationError.invalidUploadAttempt(reason: "The grant is already expired.")
        }
        return min(protocolExpiry, grantExpiresAt)
    }

    private enum CodingKeys: String, CodingKey {
        case uploadID
        case ownerDeviceID
        case originRecordingID
        case firstBeganAt
        case generation
        case generationBeganAt
        case generationExpiresAt
        case status
        case blockReason
        case declarations
        case boundHostTrust
        case boundManifest
        case boundFinalizedCapture
        case exactReceipt
        case terminalAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let uploadID = try container.decode(UploadID.self, forKey: .uploadID)
            let owner = try container.decode(DeviceID.self, forKey: .ownerDeviceID)
            let origin = try container.decode(OriginRecordingID.self, forKey: .originRecordingID)
            let firstBeganAt = try container.decode(Date.self, forKey: .firstBeganAt)
            let generation = try container.decode(UploadGeneration.self, forKey: .generation)
            let generationBeganAt = try container.decode(Date.self, forKey: .generationBeganAt)
            let generationExpiresAt = try container.decode(Date.self, forKey: .generationExpiresAt)
            let status = try container.decode(UploadAttemptStatus.self, forKey: .status)
            let blockReason = try container.decodeIfPresent(UploadAttemptBlockReason.self, forKey: .blockReason)
            let declarations = try container.decode(ChunkDeclarationLedger.self, forKey: .declarations)
            let boundHostTrust = try container.decodeIfPresent(
                RecordingHostTrustBinding.self,
                forKey: .boundHostTrust
            )
            let boundManifest = try container.decodeIfPresent(OpaqueExactObjectSlot.self, forKey: .boundManifest)
            let boundCapture = try container.decodeIfPresent(ChunkedFinalizedCapture.self, forKey: .boundFinalizedCapture)
            let exactReceipt = try container.decodeIfPresent(OpaqueExactObjectSlot.self, forKey: .exactReceipt)
            let terminalAt = try container.decodeIfPresent(Date.self, forKey: .terminalAt)

            guard origin.deviceID == owner else { throw TransferValidationError.originDeviceMismatch }
            try TransferValidation.requireFinite(firstBeganAt, field: "UploadAttempt.firstBeganAt")
            try TransferValidation.requireFinite(generationBeganAt, field: "UploadAttempt.generationBeganAt")
            try TransferValidation.requireFinite(generationExpiresAt, field: "UploadAttempt.generationExpiresAt")
            guard generationBeganAt >= firstBeganAt, generationExpiresAt > generationBeganAt,
                  generationExpiresAt <= generationBeganAt.addingTimeInterval(TransferLimits.uploadGenerationLifetime) else {
                throw TransferValidationError.invalidOrdering(field: "UploadAttempt generation dates")
            }
            guard declarations.originRecordingID == origin else {
                throw TransferValidationError.profileMismatch(field: "originRecordingID")
            }
            if let boundManifest {
                guard boundManifest.kind == .recordingManifestV1,
                      boundHostTrust != nil,
                      let boundCapture,
                      boundCapture.capture.originRecordingID == origin,
                      declarations.status == .closed,
                      declarations.descriptors == boundCapture.chunks else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Bound manifest state is inconsistent.")
                }
                try boundCapture.validate(against: declarations.frozenProfile)
            } else if boundCapture != nil || boundHostTrust != nil {
                throw TransferValidationError.invalidUploadAttempt(reason: "Trust and capture facts cannot be bound without exact manifest bytes.")
            }

            switch status {
            case .active:
                guard blockReason == nil, exactReceipt == nil, terminalAt == nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Active attempt carries terminal state.")
                }
                guard (declarations.status == .open && boundManifest == nil)
                        || (declarations.status == .closed && boundManifest != nil) else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Active declaration and manifest state are inconsistent.")
                }
            case .conflictBlocked:
                guard blockReason != nil, exactReceipt == nil, terminalAt == nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Conflict-blocked attempt is inconsistent.")
                }
                if blockReason == .chunkDeclarationConflict {
                    guard declarations.status == .conflictBlocked else {
                        throw TransferValidationError.invalidUploadAttempt(reason: "Chunk conflict must block its declaration ledger.")
                    }
                } else {
                    guard declarations.status == .closed, boundManifest != nil else {
                        throw TransferValidationError.invalidUploadAttempt(reason: "Manifest conflict requires the original bound manifest.")
                    }
                }
            case .abandoned:
                guard blockReason == nil, exactReceipt == nil, terminalAt != nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Abandoned attempt requires one terminal time.")
                }
            case .committed:
                guard blockReason == nil, let exactReceipt,
                      exactReceipt.kind == .recordingReceiptV1, terminalAt != nil,
                      boundManifest != nil, declarations.status == .closed else {
                    throw TransferValidationError.receiptEvidenceRequired
                }
            }
            if let terminalAt {
                try TransferValidation.requireFinite(terminalAt, field: "UploadAttempt.terminalAt")
                guard terminalAt >= firstBeganAt else {
                    throw TransferValidationError.invalidOrdering(field: "UploadAttempt.terminalAt")
                }
            }

            self.uploadID = uploadID
            self.ownerDeviceID = owner
            self.originRecordingID = origin
            self.firstBeganAt = firstBeganAt
            self.generation = generation
            self.generationBeganAt = generationBeganAt
            self.generationExpiresAt = generationExpiresAt
            self.status = status
            self.blockReason = blockReason
            self.declarations = declarations
            self.boundHostTrust = boundHostTrust
            self.boundManifest = boundManifest
            self.boundFinalizedCapture = boundCapture
            self.exactReceipt = exactReceipt
            self.terminalAt = terminalAt
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid upload attempt.")
        }
    }
}

public enum UploadAdmissionDecision: Equatable, Hashable, Sendable {
    case create
    case exactReplay(UploadID)
    case reopenRequired(UploadID)
    case conflictBlocked(UploadID, UploadAttemptBlockReason)
    case abandoned(UploadID)
    case alreadyCommitted(OpaqueExactObjectSlot)
}

public enum UploadAttemptAdmission {
    /// Enforces one nonterminal attempt per origin and the V1 four-active-upload
    /// per-device ceiling. Eligible expired rows are omitted from the count.
    public static func decide(
        proposedUploadID: UploadID,
        ownerDeviceID: DeviceID,
        originRecordingID: OriginRecordingID,
        frozenProfile: FrozenUploadProfile,
        existingAttempts: [UploadAttempt],
        at date: Date
    ) throws -> UploadAdmissionDecision {
        try TransferValidation.requireFinite(date, field: "UploadAttemptAdmission.at")
        guard originRecordingID.deviceID == ownerDeviceID else {
            throw TransferValidationError.originDeviceMismatch
        }

        let sameOriginAttempts = existingAttempts.filter {
            $0.originRecordingID == originRecordingID
        }
        for attempt in sameOriginAttempts where attempt.status == .committed {
            guard let receipt = attempt.exactReceipt else {
                throw TransferValidationError.receiptEvidenceRequired
            }
            return .alreadyCommitted(receipt)
        }

        // A replacement can be admitted only after the prior generation's
        // absolute expiry (or its explicit terminal boundary), so its begin
        // time is a durable monotonic ordering fact. Once such a newer row
        // exists, the older ID is permanently superseded: expiry of the newer
        // row must never make the older row eligible to reopen again.
        if let proposed = sameOriginAttempts.first(where: {
            $0.uploadID == proposedUploadID
        }), sameOriginAttempts.contains(where: {
            $0.uploadID != proposedUploadID && $0.firstBeganAt > proposed.firstBeganAt
        }) {
            throw TransferValidationError.invalidUploadAttempt(
                reason: "Upload ID was permanently superseded by a newer attempt for this origin recording."
            )
        }

        // Establish ownership across every row for this origin before an
        // early exact-replay/reopen return. Otherwise an older proposed ID can
        // bypass the newer ID that currently owns the origin merely because it
        // sorts first in persistence order.
        for attempt in sameOriginAttempts where attempt.uploadID != proposedUploadID {
            let lease = try attempt.leaseState(at: date)
            if lease != .abandoned, lease != .expired {
                throw TransferValidationError.invalidUploadAttempt(
                    reason: "Another nonterminal upload ID already owns this origin recording."
                )
            }
        }

        // An explicit abandonment can occur at the same clock instant as the
        // original begin. Requiring the replacement to start strictly after
        // that durable boundary keeps `firstBeganAt` a total ordering proof;
        // otherwise two IDs could share the timestamp and the older one could
        // become indistinguishable after the replacement is later abandoned.
        if !sameOriginAttempts.contains(where: { $0.uploadID == proposedUploadID }) {
            for attempt in sameOriginAttempts where attempt.status == .abandoned {
                guard let terminalAt = attempt.terminalAt else {
                    throw TransferValidationError.invalidUploadAttempt(
                        reason: "Abandoned upload is missing its terminal boundary."
                    )
                }
                guard date > terminalAt else {
                    throw TransferValidationError.invalidUploadAttempt(
                        reason: "Replacement upload must begin strictly after the prior abandonment boundary."
                    )
                }
            }
        }

        let activeCount = try existingAttempts.filter {
            guard $0.ownerDeviceID == ownerDeviceID else { return false }
            let lease = try $0.leaseState(at: date)
            return lease == .active || lease == .conflictBlocked
        }.count

        if let attempt = sameOriginAttempts.first(where: { $0.uploadID == proposedUploadID }) {
            try attempt.validateExactBeginReplay(
                uploadID: proposedUploadID,
                ownerDeviceID: ownerDeviceID,
                originRecordingID: originRecordingID,
                frozenProfile: frozenProfile
            )
            switch try attempt.leaseState(at: date) {
            case .active:
                return .exactReplay(attempt.uploadID)
            case .expired:
                guard activeCount < TransferLimits.activeUploadAttemptsPerDevice else {
                    throw TransferValidationError.exceedsLimit(
                        field: "active upload attempts per device",
                        limit: UInt64(TransferLimits.activeUploadAttemptsPerDevice),
                        actual: UInt64(activeCount + 1)
                    )
                }
                return .reopenRequired(attempt.uploadID)
            case .conflictBlocked:
                guard let reason = attempt.blockReason else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Blocked upload is missing its reason.")
                }
                return .conflictBlocked(attempt.uploadID, reason)
            case .abandoned:
                return .abandoned(attempt.uploadID)
            case .committed:
                // Handled above with the exact receipt.
                throw TransferValidationError.receiptEvidenceRequired
            }
        }

        guard activeCount < TransferLimits.activeUploadAttemptsPerDevice else {
            throw TransferValidationError.exceedsLimit(
                field: "active upload attempts per device",
                limit: UInt64(TransferLimits.activeUploadAttemptsPerDevice),
                actual: UInt64(activeCount + 1)
            )
        }
        return .create
    }
}
