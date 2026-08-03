import Foundation
import HarcIdentity
import HarcProtocol
import HarcTransfer

/// Durable projection required by the TLS trust boundary in adopted mode.
///
/// This value deliberately carries the exact signed object, not a reconstructed
/// transport-set payload. The coordinator authenticates and revalidates it on
/// every load.
public struct HarcPersistedTransportTrustState: Equatable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let highestTransportSetEpoch: UInt64
    public let exactHighestTransportSet: Data

    public init(
        hostTrust: RecordingHostTrustBinding,
        highestTransportSetEpoch: UInt64,
        exactHighestTransportSet: Data
    ) {
        self.hostTrust = hostTrust
        self.highestTransportSetEpoch = highestTransportSetEpoch
        self.exactHighestTransportSet = exactHighestTransportSet
    }
}

/// Persistence seam implemented by the transfer store at application
/// composition time.
///
/// `persistVerifiedTransportSet` must not return until the verified exact bytes
/// and epoch are durably committed. It must atomically reject rollback and
/// equal-epoch byte equivocation. The coordinator reloads and authenticates the
/// state after this method returns; a claimed but missing commit never opens a
/// TLS connection.
public protocol HarcTransportTrustPersistence: Sendable {
    func loadActiveTransportTrust() async throws -> HarcPersistedTransportTrustState?

    func persistVerifiedTransportSet(
        _ evidence: ValidatedTransportSetEvidence
    ) async throws
}

public struct HarcAcceptedServerTrust: Equatable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let transportSetEpoch: UInt64
    public let exactTransportSet: Data
    public let leaf: HarcTLSLeafCertificateFacts
}

public enum HarcTransportTrustError: Error, Equatable, Sendable {
    case noActiveAdoption
    case corruptPersistedTransportState
    case signedTransportSetInvalid
    case hostTrustTupleMismatch
    case pairingTransportSetMismatch
    case transportSetRollback(stored: UInt64, presented: UInt64)
    case transportSetEquivocation(epoch: UInt64)
    case durableCommitNotObserved(expectedEpoch: UInt64, actualEpoch: UInt64)
    case activeAdoptionChanged
    case certificateOutsideValidity
    case certificateOutsideTransportEntry
    case observedSPKINotAuthorized
}

/// One serialized trust authority shared by foreground gRPC and background
/// URLSession adapters.
///
/// Actor isolation alone is reentrant at persistence `await` points. The small
/// FIFO gate below intentionally keeps an entire load/validate/commit/reload
/// transaction single-file so concurrent handshakes cannot race transport-set
/// epochs or invoke persistence concurrently.
public actor HarcTransportTrustCoordinator {
    public typealias UnixMillisecondsClock = @Sendable () -> UInt64

    private enum Mode: Sendable {
        case pairing(exactQRSet: Data, verifiedQRSet: VerifiedHostTransportSetV1)
        case adopted(any HarcTransportTrustPersistence)
    }

    private let mode: Mode
    private let clock: UnixMillisecondsClock
    private var validationInProgress = false
    private var validationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates the pre-adoption verifier. The leaf extension must contain these
    /// exact QR bytes; even a newer valid set from the same authority is not a
    /// substitute during pairing.
    public init(
        pairingExactQRTransportSet: Data,
        hostAuthorityPublicKey: P256X963PublicKey,
        clock: @escaping UnixMillisecondsClock = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) throws {
        let verified = try VerifiedHostTransportSetV1.decode(
            pairingExactQRTransportSet,
            hostAuthorityPublicKey: hostAuthorityPublicKey
        )
        mode = .pairing(
            exactQRSet: pairingExactQRTransportSet,
            verifiedQRSet: verified
        )
        self.clock = clock
    }

    /// Creates the post-adoption verifier backed by the transfer store's active
    /// tuple, pinned authority key, and monotonic exact transport-set slot.
    public init(
        adoptedPersistence: any HarcTransportTrustPersistence,
        clock: @escaping UnixMillisecondsClock = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        mode = .adopted(adoptedPersistence)
        self.clock = clock
    }

    @discardableResult
    public func validateServerLeaf(
        certificateDER: Data
    ) async throws -> HarcAcceptedServerTrust {
        await acquireValidationGate()
        defer { releaseValidationGate() }
        try Task.checkCancellation()

        let leaf = try HarcTLSLeafDERParser.parse(certificateDER)
        let now = clock()
        switch mode {
        case .pairing(let exactQRSet, let verifiedQRSet):
            return try validatePairingLeaf(
                leaf,
                exactQRSet: exactQRSet,
                verifiedQRSet: verifiedQRSet,
                now: now
            )
        case .adopted(let persistence):
            return try await validateAdoptedLeaf(
                leaf,
                persistence: persistence,
                now: now
            )
        }
    }

    private func validatePairingLeaf(
        _ leaf: HarcTLSLeafCertificateFacts,
        exactQRSet: Data,
        verifiedQRSet: VerifiedHostTransportSetV1,
        now: UInt64
    ) throws -> HarcAcceptedServerTrust {
        guard leaf.exactSignedTransportSet == exactQRSet else {
            throw HarcTransportTrustError.pairingTransportSetMismatch
        }
        // Reauthenticate the extension itself. Exact equality makes this
        // redundant cryptographically, but retaining the decode here keeps the
        // certificate acceptance path independently fail-closed.
        let candidate = try decodeTransportSet(
            leaf.exactSignedTransportSet,
            authorityPublicKey: verifiedQRSet.hostAuthorityPublicKey
        )
        guard candidate.transportSet.libraryID
                == verifiedQRSet.transportSet.libraryID,
              candidate.transportSet.hostAuthorityID
                == verifiedQRSet.transportSet.hostAuthorityID,
              candidate.transportSet.setEpoch
                == verifiedQRSet.transportSet.setEpoch else {
            throw HarcTransportTrustError.hostTrustTupleMismatch
        }
        try validateLeafCoverage(leaf, by: candidate, now: now)
        return try acceptedTrust(leaf: leaf, verifiedSet: candidate)
    }

    private func validateAdoptedLeaf(
        _ leaf: HarcTLSLeafCertificateFacts,
        persistence: any HarcTransportTrustPersistence,
        now: UInt64
    ) async throws -> HarcAcceptedServerTrust {
        guard let initialState = try await persistence.loadActiveTransportTrust() else {
            throw HarcTransportTrustError.noActiveAdoption
        }
        let persisted = try decodePersistedState(initialState)
        let candidate = try decodeTransportSet(
            leaf.exactSignedTransportSet,
            authorityPublicKey: initialState.hostTrust.hostAuthorityPublicKey
        )
        try requireSameTuple(
            candidate,
            as: initialState.hostTrust
        )

        let advanced: Bool
        switch compare(
            candidate: candidate,
            againstEpoch: initialState.highestTransportSetEpoch,
            exactStoredBytes: initialState.exactHighestTransportSet
        ) {
        case .rollback(let stored, let presented):
            throw HarcTransportTrustError.transportSetRollback(
                stored: stored,
                presented: presented
            )
        case .equivocation(let epoch):
            throw HarcTransportTrustError.transportSetEquivocation(epoch: epoch)
        case .exactReplay:
            advanced = false
        case .advance:
            advanced = true
            // Coverage is checked before any write. A signed set that does not
            // authorize this exact full-DER SPKI can never enter persistence via
            // certificate trust evaluation.
            try validateLeafCoverage(leaf, by: candidate, now: now)
            try await persistence.persistVerifiedTransportSet(
                candidate.validatedEvidence()
            )
        }

        // For an exact replay, the already-persisted highest set itself must
        // authorize the leaf. During an advance, the old set is intentionally
        // allowed not to contain a newly introduced SPKI; the authenticated
        // candidate was checked before commit and the reloaded set is checked
        // below.
        if !advanced {
            try validateLeafCoverage(leaf, by: persisted, now: now)
        }

        guard let reloadedState = try await persistence.loadActiveTransportTrust() else {
            throw HarcTransportTrustError.noActiveAdoption
        }
        guard reloadedState.hostTrust == initialState.hostTrust else {
            throw HarcTransportTrustError.activeAdoptionChanged
        }
        let reloaded = try decodePersistedState(reloadedState)

        let candidateEpoch = candidate.transportSet.setEpoch
        if candidateEpoch < reloadedState.highestTransportSetEpoch {
            throw HarcTransportTrustError.transportSetRollback(
                stored: reloadedState.highestTransportSetEpoch,
                presented: candidateEpoch
            )
        }
        if candidateEpoch == reloadedState.highestTransportSetEpoch {
            guard leaf.exactSignedTransportSet
                    == reloadedState.exactHighestTransportSet else {
                throw HarcTransportTrustError.transportSetEquivocation(
                    epoch: candidateEpoch
                )
            }
        } else {
            throw HarcTransportTrustError.durableCommitNotObserved(
                expectedEpoch: candidateEpoch,
                actualEpoch: reloadedState.highestTransportSetEpoch
            )
        }

        try validateLeafCoverage(leaf, by: reloaded, now: now)
        return try acceptedTrust(leaf: leaf, verifiedSet: reloaded)
    }

    private func decodePersistedState(
        _ state: HarcPersistedTransportTrustState
    ) throws -> VerifiedHostTransportSetV1 {
        guard state.highestTransportSetEpoch > 0,
              !state.exactHighestTransportSet.isEmpty else {
            throw HarcTransportTrustError.corruptPersistedTransportState
        }
        let verified = try decodeTransportSet(
            state.exactHighestTransportSet,
            authorityPublicKey: state.hostTrust.hostAuthorityPublicKey
        )
        guard verified.transportSet.setEpoch == state.highestTransportSetEpoch else {
            throw HarcTransportTrustError.corruptPersistedTransportState
        }
        do {
            try requireSameTuple(verified, as: state.hostTrust)
        } catch {
            throw HarcTransportTrustError.corruptPersistedTransportState
        }
        return verified
    }

    private func decodeTransportSet(
        _ exactBytes: Data,
        authorityPublicKey: P256X963PublicKey
    ) throws -> VerifiedHostTransportSetV1 {
        do {
            return try VerifiedHostTransportSetV1.decode(
                exactBytes,
                hostAuthorityPublicKey: authorityPublicKey
            )
        } catch {
            throw HarcTransportTrustError.signedTransportSetInvalid
        }
    }

    private func requireSameTuple(
        _ verified: VerifiedHostTransportSetV1,
        as trust: RecordingHostTrustBinding
    ) throws {
        guard verified.transportSet.libraryID == trust.libraryID,
              verified.transportSet.hostAuthorityID == trust.hostAuthorityID,
              verified.hostAuthorityPublicKey == trust.hostAuthorityPublicKey else {
            throw HarcTransportTrustError.hostTrustTupleMismatch
        }
    }

    private enum CandidateDisposition {
        case rollback(stored: UInt64, presented: UInt64)
        case equivocation(epoch: UInt64)
        case exactReplay
        case advance
    }

    private func compare(
        candidate: VerifiedHostTransportSetV1,
        againstEpoch storedEpoch: UInt64,
        exactStoredBytes: Data
    ) -> CandidateDisposition {
        let candidateEpoch = candidate.transportSet.setEpoch
        if candidateEpoch < storedEpoch {
            return .rollback(stored: storedEpoch, presented: candidateEpoch)
        }
        if candidateEpoch == storedEpoch {
            return candidate.exactSignedBytes == exactStoredBytes
                ? .exactReplay
                : .equivocation(epoch: candidateEpoch)
        }
        return .advance
    }

    private func validateLeafCoverage(
        _ leaf: HarcTLSLeafCertificateFacts,
        by verified: VerifiedHostTransportSetV1,
        now: UInt64
    ) throws {
        let notBefore = try unixMilliseconds(leaf.notValidBefore)
        let notAfter = try unixMilliseconds(leaf.notValidAfter)
        let skew = HarcProtocolLimits.transportClockSkewMilliseconds
        let earliest = notBefore > skew ? notBefore - skew : 0
        let latestAddition = notAfter.addingReportingOverflow(skew)
        let latest = latestAddition.overflow ? UInt64.max : latestAddition.partialValue
        guard now >= earliest, now <= latest else {
            throw HarcTransportTrustError.certificateOutsideValidity
        }

        guard let entry = verified.transportSet.entry(
            matchingSPKISHA256: leaf.fullDERSPKISHA256,
            atUnixMilliseconds: now,
            clockSkewMilliseconds: skew
        ) else {
            throw HarcTransportTrustError.observedSPKINotAuthorized
        }
        guard notBefore >= entry.notBeforeUnixMilliseconds,
              notAfter <= entry.notAfterUnixMilliseconds else {
            throw HarcTransportTrustError.certificateOutsideTransportEntry
        }
    }

    private func acceptedTrust(
        leaf: HarcTLSLeafCertificateFacts,
        verifiedSet: VerifiedHostTransportSetV1
    ) throws -> HarcAcceptedServerTrust {
        HarcAcceptedServerTrust(
            hostTrust: try RecordingHostTrustBinding(
                libraryID: verifiedSet.transportSet.libraryID,
                hostAuthorityID: verifiedSet.transportSet.hostAuthorityID,
                hostAuthorityPublicKey: verifiedSet.hostAuthorityPublicKey
            ),
            transportSetEpoch: verifiedSet.transportSet.setEpoch,
            exactTransportSet: verifiedSet.exactSignedBytes,
            leaf: leaf
        )
    }

    private func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
              seconds >= 0,
              seconds.rounded(.towardZero) == seconds,
              seconds <= Double(UInt64.max / 1_000) else {
            throw HarcTransportTrustError.certificateOutsideValidity
        }
        return UInt64(seconds) * 1_000
    }

    private func acquireValidationGate() async {
        if !validationInProgress {
            validationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            validationWaiters.append(continuation)
        }
    }

    private func releaseValidationGate() {
        guard !validationWaiters.isEmpty else {
            validationInProgress = false
            return
        }
        validationWaiters.removeFirst().resume()
    }
}
