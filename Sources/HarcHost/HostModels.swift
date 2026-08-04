import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer

// MARK: - Host identity and authenticated calls

/// The public, non-secret identity tuple shared by `Harc.db`, `HarcHost.db`,
/// and the host authority key record. Private keys are deliberately absent.
public struct HarcHostMetadata: Codable, Equatable, Sendable {
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let hostStateID: HostStateID
    public let controlPort: UInt16?
    public let uploadPort: UInt16?
    public let highestTransportSetEpoch: UInt64
    public let leafRetirementFloor: UInt64

    public init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostStateID: HostStateID,
        controlPort: UInt16? = nil,
        uploadPort: UInt16? = nil,
        highestTransportSetEpoch: UInt64 = 0,
        leafRetirementFloor: UInt64 = 0
    ) {
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.hostStateID = hostStateID
        self.controlPort = controlPort
        self.uploadPort = uploadPort
        self.highestTransportSetEpoch = highestTransportSetEpoch
        self.leafRetirementFloor = leafRetirementFloor
    }
}

/// Identity established by a future authenticated transport. Request payloads
/// never get to replace `authenticatedDeviceID` with a claimed device ID.
public struct AuthenticatedDeviceContext: Codable, Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let authenticatedDeviceID: DeviceID
    public let grantID: GrantID
    public let grantEpoch: GrantEpoch

    public init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        authenticatedDeviceID: DeviceID,
        grantID: GrantID,
        grantEpoch: GrantEpoch
    ) {
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.authenticatedDeviceID = authenticatedDeviceID
        self.grantID = grantID
        self.grantEpoch = grantEpoch
    }
}

public struct AuthorizedDeviceContext: Equatable, Sendable {
    public let authenticatedDeviceID: DeviceID
    public let grantID: GrantID
    public let grantEpoch: GrantEpoch
    public let requiredScope: AuthorizationScope

    public init(
        authenticatedDeviceID: DeviceID,
        grantID: GrantID,
        grantEpoch: GrantEpoch,
        requiredScope: AuthorizationScope
    ) {
        self.authenticatedDeviceID = authenticatedDeviceID
        self.grantID = grantID
        self.grantEpoch = grantEpoch
        self.requiredScope = requiredScope
    }
}

// MARK: - Security registry journal

/// The durable transport-key transition mode. `startedMode` on the matching
/// intent never changes; `mode` may make the single reviewed transition from
/// planned to emergency when the old key becomes compromised mid-overlap.
public enum HostTransportRotationMode: String, Codable, CaseIterable, Sendable {
    case planned
    case emergency
}

public struct HostTransportRotationIntent: Equatable, Sendable {
    public let startedMode: HostTransportRotationMode
    public let mode: HostTransportRotationMode
    public let oldTLSSPKISHA256: Data
    public let newTLSSPKISHA256: Data?
    public let retirementFloorUnixMilliseconds: UInt64
    public let createdAt: Date
    public let emergencyEscalatedAt: Date?

    public init(
        startedMode: HostTransportRotationMode,
        mode: HostTransportRotationMode,
        oldTLSSPKISHA256: Data,
        newTLSSPKISHA256: Data?,
        retirementFloorUnixMilliseconds: UInt64,
        createdAt: Date,
        emergencyEscalatedAt: Date?
    ) {
        self.startedMode = startedMode
        self.mode = mode
        self.oldTLSSPKISHA256 = oldTLSSPKISHA256
        self.newTLSSPKISHA256 = newTLSSPKISHA256
        self.retirementFloorUnixMilliseconds = retirementFloorUnixMilliseconds
        self.createdAt = createdAt
        self.emergencyEscalatedAt = emergencyEscalatedAt
    }
}

package enum HostAuthorityMutationKind: Sendable {
    case securityRegistry
    case emergencyTransport
    case servingRecovery
}

/// One runtime-owned FIFO exclusion boundary shared by the security-registry
/// and emergency transport journals. SQLite predicates remain the cross-process
/// authority; this actor closes the in-process windows before either phase-A
/// transaction becomes durable.
package actor HostAuthorityMutationCoordinator {
    private var mutationActive = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func withExclusiveMutation<T: Sendable>(
        _: HostAuthorityMutationKind,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard mutationActive else {
            mutationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            mutationActive = false
            return
        }
        waiters.removeFirst().resume()
    }

    /// Module-internal deterministic observation for `@testable` FIFO tests.
    func queuedMutationCountForTesting() -> Int { waiters.count }
}

/// Opaque, exact read-only inspection of the security half of serving startup.
/// Reconciliation must observe this same plan again before either durable mark
/// is changed. The transport lifecycle performs its own read-only inspection
/// while holding the same serving-recovery exclusion.
package struct HostSecurityRegistryPreflightPlan: Equatable, Sendable {
    package let databaseRevision: UInt64
    package let protectedRevision: UInt64
    package let pendingRevision: UInt64?
    package let exactPendingMutationJSON: Data?
    package let pendingMutation: SecurityRegistryMutation?
    package let pendingCreatedAt: Date?
    package let emergencyTransportIntentPresent: Bool
}

public protocol SecurityRegistryHighWaterMarkStore: Sendable {
    func loadRegistryRevision() async throws -> UInt64
    func advanceRegistryRevision(from expectedRevision: UInt64, to newRevision: UInt64) async throws
}

/// Test/loopback implementation. Production composes the same protocol with a
/// this-device-only Keychain item in PR 6.
public actor InMemorySecurityRegistryHighWaterMarkStore: SecurityRegistryHighWaterMarkStore {
    private var revision: UInt64

    public init(initialRevision: UInt64 = 0) {
        self.revision = initialRevision
    }

    public func loadRegistryRevision() -> UInt64 { revision }

    public func advanceRegistryRevision(from expectedRevision: UInt64, to newRevision: UInt64) throws {
        guard expectedRevision < UInt64.max,
              revision == expectedRevision,
              newRevision == expectedRevision + 1 else {
            throw HarcHostError.securityRegistryRollback(
                databaseRevision: expectedRevision,
                highWaterRevision: revision
            )
        }
        revision = newRevision
    }

    func replaceForTesting(_ revision: UInt64) {
        self.revision = revision
    }
}

public enum SecurityRegistryFailurePoint: String, Codable, CaseIterable, Sendable {
    case beforePendingMutation
    case afterPendingMutation
    case afterHighWaterAdvance
    case beforeFinalDatabaseApply
    case afterFinalDatabaseApply
}

public protocol SecurityRegistryFailureInjector: Sendable {
    func hit(_ point: SecurityRegistryFailurePoint) async throws
}

public struct NoSecurityRegistryFailureInjector: SecurityRegistryFailureInjector {
    public init() {}
    public func hit(_ point: SecurityRegistryFailurePoint) async throws {}
}

/// Local administrative authentication is deliberately an injected boundary,
/// not a caller-supplied Boolean. The resident host app will bridge this to
/// LocalAuthentication; transport adapters never receive this capability.
public protocol HostLocalOSAuthenticationBoundary: Sendable {
    func authorizeInitialGrantExpansion(
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind,
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool

    func authorizeGrantScopeChange(
        for deviceID: DeviceID,
        currentScopes: [AuthorizationScope],
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool

    func authorizeSameKeyReadoption(for deviceID: DeviceID) async throws -> Bool
}

/// Fail closed until the resident host app supplies its interactive
/// LocalAuthentication-backed implementation.
public struct RejectingHostLocalOSAuthenticationBoundary: HostLocalOSAuthenticationBoundary {
    public init() {}

    public func authorizeInitialGrantExpansion(
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind,
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool {
        false
    }

    public func authorizeGrantScopeChange(
        for deviceID: DeviceID,
        currentScopes: [AuthorizationScope],
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool {
        false
    }

    public func authorizeSameKeyReadoption(for deviceID: DeviceID) async throws -> Bool {
        false
    }
}

public enum SecurityRegistryMutationKind: String, Codable, CaseIterable, Sendable {
    case issueGrant
    case replaceGrant
    case readoptGrant
    case repairTransportTrustGrant
    case revokeDevice
}

/// Exact bytes are opaque until PR 4. They are journaled now so the security
/// state transition can never get ahead of the future signed grant/revocation.
public enum SecurityRegistryMutation: Codable, Equatable, Sendable {
    case issueGrant(
        entry: DeviceRegistryEntry,
        grant: DeviceGrantClaims,
        exactGrantBytes: Data,
        pairingTicketID: UUID?
    )
    case replaceGrant(
        entry: DeviceRegistryEntry,
        grant: DeviceGrantClaims,
        exactGrantBytes: Data
    )
    case readoptGrant(
        entry: DeviceRegistryEntry,
        grant: DeviceGrantClaims,
        exactGrantBytes: Data,
        pairingTicketID: UUID
    )
    /// Explicit same-key re-adoption after emergency TLS rotation. Keeping a
    /// distinct Codable case preserves every durable v4 `readoptGrant` row as
    /// ordinary re-adoption and prevents it from clearing trust-repair state.
    case repairTransportTrustGrant(
        entry: DeviceRegistryEntry,
        grant: DeviceGrantClaims,
        exactGrantBytes: Data,
        pairingTicketID: UUID
    )
    case revokeDevice(
        entry: DeviceRegistryEntry,
        revocation: DeviceRevocationClaims,
        exactRevocationBytes: Data
    )

    public var kind: SecurityRegistryMutationKind {
        switch self {
        case .issueGrant: .issueGrant
        case .replaceGrant: .replaceGrant
        case .readoptGrant: .readoptGrant
        case .repairTransportTrustGrant: .repairTransportTrustGrant
        case .revokeDevice: .revokeDevice
        }
    }

    public var deviceID: DeviceID {
        switch self {
        case .issueGrant(let entry, _, _, _),
             .replaceGrant(let entry, _, _),
             .readoptGrant(let entry, _, _, _),
             .repairTransportTrustGrant(let entry, _, _, _),
             .revokeDevice(let entry, _, _):
            entry.deviceID
        }
    }
}

// MARK: - Pairing placeholders (wire bytes land in PR 4)

public enum PairingTicketState: String, Codable, CaseIterable, Sendable {
    case issued
    case reserved
    case approved
    case consumed
    case expired
    case cancelled
}

public enum PairingAttemptState: String, Codable, CaseIterable, Sendable {
    case reserved
    case proofVerified
    case awaitingApproval
    case approved
    case denied
    case expired
    case cancelled
}

public struct PairingTicketPlaceholder: Codable, Equatable, Sendable {
    public let ticketID: UUID
    public let ticketSecretBindingSHA256: Data
    public let clientKind: AdoptedClientKind
    public let issuedAt: Date
    public let expiresAt: Date
    public let state: PairingTicketState
    public let reservedDeviceID: DeviceID?

    private enum CodingKeys: String, CodingKey {
        case ticketID
        case ticketSecretBindingSHA256
        case clientKind
        case issuedAt
        case expiresAt
        case state
        case reservedDeviceID
    }

    public init(
        ticketID: UUID,
        ticketSecretBindingSHA256: Data,
        clientKind: AdoptedClientKind = .mobile,
        issuedAt: Date,
        expiresAt: Date,
        state: PairingTicketState = .issued,
        reservedDeviceID: DeviceID? = nil
    ) throws {
        guard ticketSecretBindingSHA256.count == 32 else {
            throw HarcHostError.invalidDigestLength(
                field: "ticketSecretBindingSHA256",
                expected: 32,
                actual: ticketSecretBindingSHA256.count
            )
        }
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 120 else {
            throw HarcHostError.invalidPairingTransition
        }
        self.ticketID = ticketID
        self.ticketSecretBindingSHA256 = ticketSecretBindingSHA256
        self.clientKind = clientKind
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.state = state
        self.reservedDeviceID = reservedDeviceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                ticketID: container.decode(UUID.self, forKey: .ticketID),
                ticketSecretBindingSHA256: container.decode(Data.self, forKey: .ticketSecretBindingSHA256),
                clientKind: container.decode(AdoptedClientKind.self, forKey: .clientKind),
                issuedAt: container.decode(Date.self, forKey: .issuedAt),
                expiresAt: container.decode(Date.self, forKey: .expiresAt),
                state: container.decode(PairingTicketState.self, forKey: .state),
                reservedDeviceID: container.decodeIfPresent(DeviceID.self, forKey: .reservedDeviceID)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid pairing ticket placeholder.",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ticketID, forKey: .ticketID)
        try container.encode(ticketSecretBindingSHA256, forKey: .ticketSecretBindingSHA256)
        try container.encode(clientKind, forKey: .clientKind)
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(reservedDeviceID, forKey: .reservedDeviceID)
    }
}

// MARK: - Replay

public enum HostOperationSigner: Codable, Equatable, Hashable, Sendable {
    case hostAuthority(HostAuthorityID)
    case device(DeviceID)

    var databaseKind: String {
        switch self {
        case .hostAuthority: "host"
        case .device: "device"
        }
    }

    var databaseIdentity: Data {
        switch self {
        case .hostAuthority(let identity): identity.rawBytes
        case .device(let identity): identity.rawBytes
        }
    }
}

public struct HostOperationReplayKey: Codable, Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let messageType: String
    public let signer: HostOperationSigner
    public let operationID: OperationID

    private enum CodingKeys: String, CodingKey {
        case libraryID
        case hostAuthorityID
        case messageType
        case signer
        case operationID
    }

    public init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        messageType: String,
        signer: HostOperationSigner,
        operationID: OperationID
    ) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard !messageType.isEmpty,
              messageType.count <= 128,
              messageType.unicodeScalars.allSatisfy(allowed.contains) else {
            throw HarcHostError.invalidMessageType(messageType)
        }
        guard operationID.rawValue != zeroUUID else {
            throw HarcHostError.invalidOperationID
        }
        if case .hostAuthority(let signerAuthorityID) = signer,
           signerAuthorityID != hostAuthorityID {
            throw HarcHostError.invalidOperationSigner
        }
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.messageType = messageType
        self.signer = signer
        self.operationID = operationID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                libraryID: container.decode(LibraryID.self, forKey: .libraryID),
                hostAuthorityID: container.decode(HostAuthorityID.self, forKey: .hostAuthorityID),
                messageType: container.decode(String.self, forKey: .messageType),
                signer: container.decode(HostOperationSigner.self, forKey: .signer),
                operationID: container.decode(OperationID.self, forKey: .operationID)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid host operation replay key.",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(libraryID, forKey: .libraryID)
        try container.encode(hostAuthorityID, forKey: .hostAuthorityID)
        try container.encode(messageType, forKey: .messageType)
        try container.encode(signer, forKey: .signer)
        try container.encode(operationID, forKey: .operationID)
    }
}

public enum HostOperationReplayDisposition: Equatable, Sendable {
    case accepted(originalResult: Data)
    case exactReplay(originalResult: Data)
}

/// Recovery state for an operation whose effect cannot participate in the
/// HarcHost.db transaction. A prepared effect is durable but has not yet been
/// acknowledged as applied; callers must reconcile the external system by its
/// own idempotency key before completing it.
public enum HostPreparedOperationDisposition: Equatable, Sendable {
    case prepared
    case exactPreparedReplay(preparedEffect: Data)
    case alreadyApplied(originalResult: Data)
}

/// Authoritative current-grant snapshot used only at the signed-command edge.
/// `acceptedAt` comes from the Host store clock and the registry entry is read
/// in the same database access that reauthorizes the live session context.
public struct HostCurrentDeviceCommandAuthority: Sendable {
    public let acceptedAt: Date
    public let registryEntry: DeviceRegistryEntry

    public init(acceptedAt: Date, registryEntry: DeviceRegistryEntry) {
        self.acceptedAt = acceptedAt
        self.registryEntry = registryEntry
    }
}

// MARK: - Upload and staging

public enum HostUploadJournalState: String, Codable, CaseIterable, Sendable {
    case receiving
    case manifestVerified
    case assembling
    case temporarySynchronized
    case audioRenamed
    case audioPublished
    case recordingCommitted
    case receiptPrepared
    case receipted
    case processing
    case complete
    case failedRecoverable
    case conflictBlocked
    case abandoned
}

public struct BeginHostUploadRequest: Equatable, Sendable {
    public let uploadID: UploadID
    public let originRecordingID: OriginRecordingID
    public let frozenProfile: FrozenUploadProfile
    public let beganAt: Date

    public init(
        uploadID: UploadID,
        originRecordingID: OriginRecordingID,
        frozenProfile: FrozenUploadProfile,
        beganAt: Date
    ) {
        self.uploadID = uploadID
        self.originRecordingID = originRecordingID
        self.frozenProfile = frozenProfile
        self.beganAt = beganAt
    }
}

public enum BeginHostUploadDisposition: Equatable, Sendable {
    case created(UploadReconciliation)
    case exactReplay(UploadReconciliation)
    case reopened(UploadReconciliation)
    case alreadyCommitted(OpaqueExactObjectSlot)
}

public enum HostManifestPrecommitDisposition: Equatable, Sendable {
    case bound(missingChunkIndexes: [UInt32])
    case exactReplay(missingChunkIndexes: [UInt32])
}

/// Transport-neutral evidence for one positive `UploadChunks` response.
/// `durableAt` is the timestamp of the original HostDB durability transition;
/// exact replays must return that value rather than the retry time.
public struct HostDurableChunkAcknowledgement: Equatable, Sendable {
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let durableChunk: DurableChunkStatus
    public let durableAt: Date

    public init(
        uploadID: UploadID,
        generation: UploadGeneration,
        uploadProfileSHA256: UploadProfileSHA256,
        durableChunk: DurableChunkStatus,
        durableAt: Date
    ) {
        self.uploadID = uploadID
        self.generation = generation
        self.uploadProfileSHA256 = uploadProfileSHA256
        self.durableChunk = durableChunk
        self.durableAt = durableAt
    }
}

public enum StagedChunkDisposition: Equatable, Sendable {
    case durablyAccepted(HostDurableChunkAcknowledgement)
    case exactReplay(HostDurableChunkAcknowledgement)
}

/// Stable result of an idempotent owner-authorized abandonment. The timestamp
/// is the original terminal boundary and is never replaced by a retry time.
public struct HostAbandonUploadResult: Equatable, Sendable {
    public let uploadID: UploadID
    public let terminalReason: UploadReconciliationTerminalReason
    public let terminalAt: Date

    public init(
        uploadID: UploadID,
        terminalReason: UploadReconciliationTerminalReason,
        terminalAt: Date
    ) {
        self.uploadID = uploadID
        self.terminalReason = terminalReason
        self.terminalAt = terminalAt
    }
}

/// Bounded streaming source used identically by future gRPC and HTTPS
/// adapters. HarcHost consumes and hashes one fragment at a time; it never asks
/// an adapter to materialize the declared encoded body in one allocation.
public struct HostChunkBody: AsyncSequence, Sendable {
    public typealias Element = Data
    public typealias AsyncIterator = AsyncThrowingStream<Data, any Error>.Iterator

    private let stream: AsyncThrowingStream<Data, any Error>

    public init(stream: AsyncThrowingStream<Data, any Error>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }

    public static func fragments(_ fragments: [Data]) -> HostChunkBody {
        HostChunkBody(
            stream: AsyncThrowingStream { continuation in
                for fragment in fragments { continuation.yield(fragment) }
                continuation.finish()
            }
        )
    }
}

public enum StagingFailurePoint: String, Codable, CaseIterable, Sendable {
    case afterJournalReservation
    case afterFileCreation
    case afterBodyWrite
    case afterFileSynchronization
    case afterDirectorySynchronization
    case afterDatabaseAcknowledgement
    case beforeReapCandidateRead
    case afterReapCandidateSnapshot
    case afterReapCandidateClaim
    case afterReapObjectDeletion
}

public protocol StagingFailureInjector: Sendable {
    func hit(_ point: StagingFailurePoint) async throws
}

public struct NoStagingFailureInjector: StagingFailureInjector {
    public init() {}
    public func hit(_ point: StagingFailurePoint) async throws {}
}

public struct HostVolumeCapacity: Equatable, Sendable {
    public let availableBytes: UInt64
    public let totalBytes: UInt64

    public init(availableBytes: UInt64, totalBytes: UInt64) {
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }
}

public protocol HostVolumeCapacityProvider: Sendable {
    func capacity(for stagingRoot: URL) throws -> HostVolumeCapacity
}

public struct FileSystemHostVolumeCapacityProvider: HostVolumeCapacityProvider {
    public init() {}

    public func capacity(for stagingRoot: URL) throws -> HostVolumeCapacity {
        let values = try stagingRoot.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity,
              available >= 0,
              total >= 0 else {
            throw HarcHostError.volumeCapacityUnavailable
        }
        return HostVolumeCapacity(
            availableBytes: UInt64(available),
            totalBytes: UInt64(total)
        )
    }
}

public struct HostStagingQuotaPolicy: Equatable, Sendable {
    public static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

    public let perDeviceBytes: UInt64
    public let globalBytes: UInt64
    public let minimumFreeBytes: UInt64
    /// Integer permille avoids floating-point policy drift. The default 100 is 10%.
    public let minimumFreePermille: UInt16

    public init(
        perDeviceBytes: UInt64 = 20 * Self.gibibyte,
        globalBytes: UInt64 = 100 * Self.gibibyte,
        minimumFreeBytes: UInt64 = 10 * Self.gibibyte,
        minimumFreePermille: UInt16 = 100
    ) {
        precondition(perDeviceBytes > 0)
        precondition(globalBytes > 0)
        precondition(minimumFreePermille <= 1_000)
        self.perDeviceBytes = perDeviceBytes
        self.globalBytes = globalBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.minimumFreePermille = minimumFreePermille
    }
}

public enum IncompleteRemoteUploadReason: String, Codable, CaseIterable, Sendable {
    case awaitingChunks
    case rejectedChunks
    case expired
    case conflictBlocked
    case failedRecoverable
    case manifestAwaitingChunks
}

/// Deliberately path-free and separate from HarcStore's local-WAV RecoveryQueue.
public struct IncompleteRemoteUpload: Codable, Equatable, Sendable, Identifiable {
    public var id: UploadID { uploadID }
    public let uploadID: UploadID
    public let ownerDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let generation: UploadGeneration
    public let generationExpiresAt: Date
    public let declaredChunkCount: Int
    public let durableChunkCount: Int
    public let rejectedChunkCount: Int
    public let reason: IncompleteRemoteUploadReason
    public let updatedAt: Date
}

// MARK: - Bounded diagnostic audit

public enum HostAuditSeverity: String, Codable, CaseIterable, Sendable {
    case information
    case warning
    case security
}

public struct HostAuditEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let occurredAt: Date
    public let severity: HostAuditSeverity
    public let category: String
    public let code: String
    public let deviceID: DeviceID?
    public let aggregateCount: UInt64
}

// MARK: - Fail-closed errors

public enum HarcHostError: Error, Equatable, Sendable {
    case databaseOpenFailed(String)
    case migrationFailed(String)
    case databaseFailure(String)
    case metadataMismatch
    case invalidListenerPort(field: String)
    case listenerPortsMustBeDistinct
    case listenerPortPersistenceConflict
    case invalidDigestLength(field: String, expected: Int, actual: Int)
    case invalidMessageType(String)
    case invalidOperationID
    case invalidOperationSigner
    case invalidPairingTransition
    case invalidHostInfoInput(String)
    case publicHostInfoRateLimited
    case invalidAuthenticationInput(String)
    case pairingClaimRejected
    case pairingProofRejected
    case pairingClaimNotAwaitingApproval
    case pairingGrantMismatch
    case sessionAdmissionRejected
    case sessionProofRejected
    case sessionCredentialRejected
    case localOSAuthenticationRequired
    case securityMutationAlreadyPending
    case securityRegistryTransitionInProgress
    case hostAuthorityMutationConflict
    case securityMutationInvalid(String)
    case securityRegistryRollback(databaseRevision: UInt64, highWaterRevision: UInt64)
    case securityRegistryPendingMismatch
    case deferredServingBootstrapRequired
    case deferredServingPreflightMismatch
    case transportSetTransitionInProgress
    case transportSetNotInitialized
    case transportSetPendingMismatch
    case transportSetRollback(databaseEpoch: UInt64, highWaterEpoch: UInt64)
    case invalidTransportSet(String)
    case tlsLeafMismatch(String)
    case tlsLeafNotReady
    case transportRetirementFloorNotReached(requiredUnixMilliseconds: UInt64)
    case transportRotationStateMismatch
    case emergencyTrustRepairRequired
    case unknownDevice
    case deviceRevoked
    case grantExpired
    case grantMismatch
    case missingScope(AuthorizationScope)
    case objectOwnershipMismatch
    case replayConflict
    case operationResultConflict
    case operationPreparedRequiresRecovery
    case preparedEffectConflict
    case operationPayloadTooLarge
    case operationCapacityExhausted
    case commandExpired
    case commandIssuedInFuture
    case uploadNotFound
    case uploadConflict(String)
    case staleUploadGeneration(expected: UInt64, actual: UInt64)
    case encodedLengthMismatch(expected: UInt64, actual: UInt64)
    case encodedHashMismatch
    case bodyFragmentTooLarge(limit: Int, actual: Int)
    case activeStagingStreamLimitExceeded(limit: Int)
    case quotaExceeded(scope: String, limit: UInt64, requestedTotal: UInt64)
    case insufficientFreeSpace(requiredRemaining: UInt64, projectedRemaining: UInt64)
    case volumeCapacityUnavailable
    case unsafeStagingRoot
    case unsafeStagingPath
    case stagingIO(String)
    case incompleteBody
    case manifestEvidenceRequired
    case canonicalCommitUnavailableUntilPR5
    case incompleteCanonicalUpload
    case publicationRecoveryRequired(String)
    case publicationCheckpointConflict(expected: [String], actual: String)
    case canonicalPublicationAlreadyInProgress(UploadID)
    case qualifiedDecoderUnavailable(codec: String, container: String)
    case fixtureDecoderForbidden
    case invalidCanonicalFrameCount(UInt64)
    case decodedLengthMismatch(expected: UInt64, actual: UInt64)
    case canonicalHashMismatch
    case canonicalArtifactIdentityMismatch
    case classicRIFFSizeExceeded(maximumPCMBytes: UInt64, requestedPCMBytes: UInt64)
    case unsafePublicationRoot
    case unsafePublicationPath
    case canonicalDestinationExists
    case invalidCanonicalWAV
    case provenanceSidecarConflict
    case publicationIO(String)
    case processingSchedulerUnavailable
}

extension HarcHostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let detail): "Could not open HarcHost.db: \(detail)"
        case .migrationFailed(let detail): "Could not migrate HarcHost.db: \(detail)"
        case .databaseFailure(let detail): "HarcHost.db failed: \(detail)"
        case .metadataMismatch: "The host-state identity tuple does not match this library and authority."
        case .invalidListenerPort(let field): "The host listener \(field) must be a nonzero UInt16 port."
        case .listenerPortsMustBeDistinct: "The host control and upload listeners must use distinct ports."
        case .listenerPortPersistenceConflict:
            "The persisted host listener ports are missing, malformed, or differ from the requested restart binding."
        case .invalidDigestLength(let field, let expected, let actual): "\(field) must be \(expected) bytes; received \(actual)."
        case .invalidMessageType(let value): "Unregistered or malformed message type: \(value)"
        case .invalidOperationID: "Operation IDs must be nonzero UUIDs."
        case .invalidOperationSigner: "A host operation signer must match the key's host authority."
        case .invalidPairingTransition: "The pairing placeholder transition is invalid."
        case .invalidHostInfoInput(let field): "Invalid public host information: \(field)."
        case .publicHostInfoRateLimited: "Public host information requests are rate limited."
        case .invalidAuthenticationInput(let field): "Invalid authentication input: \(field)."
        case .pairingClaimRejected: "The pairing claim could not be accepted."
        case .pairingProofRejected: "The pairing proof could not be verified."
        case .pairingClaimNotAwaitingApproval: "The pairing claim is not awaiting local approval."
        case .pairingGrantMismatch: "The locally issued grant does not match the immutable pairing claim."
        case .sessionAdmissionRejected: "The session challenge could not be admitted."
        case .sessionProofRejected: "The session proof could not be verified."
        case .sessionCredentialRejected: "The session credential is invalid or no longer current."
        case .localOSAuthenticationRequired: "Same-key re-adoption requires successful local OS user authentication."
        case .securityMutationAlreadyPending: "A security-registry mutation is already pending."
        case .securityRegistryTransitionInProgress: "A security-registry transition is in progress; retry after it completes."
        case .hostAuthorityMutationConflict:
            "Emergency transport retirement and security-registry mutation cannot overlap."
        case .securityMutationInvalid(let detail): "The security-registry mutation is invalid: \(detail)"
        case .securityRegistryRollback(let database, let mark): "Security registry rollback detected (database \(database), high-water \(mark))."
        case .securityRegistryPendingMismatch: "The pending security mutation does not form the exact next revision."
        case .deferredServingBootstrapRequired:
            "Serving startup has not completed its dual-journal recovery boundary."
        case .deferredServingPreflightMismatch:
            "Serving startup state changed after its read-only dual-journal preflight."
        case .transportSetTransitionInProgress: "A transport-set publication or rotation is already in progress."
        case .transportSetNotInitialized: "The host transport set has not been initialized."
        case .transportSetPendingMismatch: "The pending transport set is not the exact valid successor of HostDB state."
        case .transportSetRollback(let database, let mark): "Transport-set rollback detected (database epoch \(database), high-water epoch \(mark))."
        case .invalidTransportSet(let detail): "The host transport set is invalid: \(detail)"
        case .tlsLeafMismatch(let detail): "The persisted TLS leaf does not match its transport set: \(detail)"
        case .tlsLeafNotReady: "No validated persisted TLS leaf is ready for the active transport key."
        case .transportRetirementFloorNotReached(let floor): "The old TLS key cannot retire before Unix millisecond \(floor)."
        case .transportRotationStateMismatch: "The durable transport rotation intent conflicts with the protected TLS key roles."
        case .emergencyTrustRepairRequired: "This device must be re-adopted after emergency host transport rotation."
        case .unknownDevice: "The authenticated device is not registered."
        case .deviceRevoked: "The authenticated device is revoked."
        case .grantExpired: "The current device grant has expired."
        case .grantMismatch: "The authenticated session does not use the registry's current grant and epoch."
        case .missingScope(let scope): "The current grant is missing \(scope.rawValue)."
        case .objectOwnershipMismatch: "The authenticated device does not own this object."
        case .replayConflict: "The operation ID was reused with different exact request bytes."
        case .operationResultConflict: "The operation replay result conflicts with the original result."
        case .operationPreparedRequiresRecovery: "The operation has a prepared external effect that must be reconciled before it can be applied."
        case .preparedEffectConflict: "The prepared external effect conflicts with the durable operation journal."
        case .operationPayloadTooLarge: "The operation request, prepared effect, or result exceeds the host control-plane limit."
        case .operationCapacityExhausted: "The device's durable operation replay capacity is exhausted."
        case .commandExpired: "The signed command has expired."
        case .commandIssuedInFuture: "The signed command issue time is too far in the future."
        case .uploadNotFound: "The upload session does not exist."
        case .uploadConflict(let detail): "The upload is conflict-blocked: \(detail)"
        case .staleUploadGeneration(let expected, let actual): "Upload generation \(actual) is stale; expected \(expected)."
        case .encodedLengthMismatch(let expected, let actual): "Encoded length mismatch: expected \(expected), received \(actual)."
        case .encodedHashMismatch: "The staged bytes do not match the declared SHA-256."
        case .bodyFragmentTooLarge(let limit, let actual): "A streaming body fragment exceeds \(limit) bytes; received \(actual)."
        case .activeStagingStreamLimitExceeded(let limit): "An authenticated device may have at most \(limit) active staging streams."
        case .quotaExceeded(let scope, let limit, let total): "The \(scope) staging quota of \(limit) bytes would be exceeded by \(total) bytes."
        case .insufficientFreeSpace(let required, let projected): "Staging would leave \(projected) free bytes; at least \(required) are required."
        case .volumeCapacityUnavailable: "The host volume capacity could not be determined."
        case .unsafeStagingRoot: "The host staging root is missing, a symlink, or has unsafe ownership/type."
        case .unsafeStagingPath: "A staged path escaped the host-generated staging namespace or traversed a symlink."
        case .stagingIO(let detail): "Host staging failed: \(detail)"
        case .incompleteBody: "The encoded chunk body ended before the declared byte length."
        case .manifestEvidenceRequired: "A PR 4 validated exact manifest is required."
        case .canonicalCommitUnavailableUntilPR5: "Canonical publication and durable receipts are not implemented before PR 5."
        case .incompleteCanonicalUpload:
            "Every declared upload chunk must be durably staged before canonical publication."
        case .publicationRecoveryRequired(let detail):
            "Canonical publication requires recovery: \(detail)"
        case .publicationCheckpointConflict(let expected, let actual):
            "Canonical publication checkpoint \(actual) conflicts with expected state(s): \(expected.joined(separator: ", "))."
        case .canonicalPublicationAlreadyInProgress(let uploadID):
            "Canonical publication is already in progress for upload \(uploadID.description)."
        case .qualifiedDecoderUnavailable(let codec, let container):
            "The production decoder for \(codec) in \(container) is unavailable until its physical-device qualification gate passes."
        case .fixtureDecoderForbidden: "Raw canonical PCM decode is permitted only in an explicit fixture loopback upload."
        case .invalidCanonicalFrameCount(let count): "Canonical frame count must be positive; received \(count)."
        case .decodedLengthMismatch(let expected, let actual):
            "Decoded canonical PCM length mismatch: expected \(expected) bytes, received \(actual)."
        case .canonicalHashMismatch: "Decoded canonical PCM does not match the signed manifest SHA-256."
        case .canonicalArtifactIdentityMismatch:
            "The canonical WAV no longer matches its durable filesystem identity."
        case .classicRIFFSizeExceeded(let maximum, let requested):
            "Canonical PCM requires \(requested) bytes, beyond the classic RIFF ceiling of \(maximum); RF64 is not a V1 format."
        case .unsafePublicationRoot: "The canonical publication root is missing, a symlink, not owned by this user, or writable by another user."
        case .unsafePublicationPath: "A canonical publication path is unsafe or escaped its host-generated directory."
        case .canonicalDestinationExists: "The host-generated canonical destination already exists and was not overwritten."
        case .invalidCanonicalWAV: "The published WAV header does not match Harc's canonical V1 PCM format."
        case .provenanceSidecarConflict: "An existing manifest or receipt sidecar has different exact bytes."
        case .publicationIO(let detail): "Canonical publication failed: \(detail)"
        case .processingSchedulerUnavailable: "The durable host processing scheduler is not configured."
        }
    }
}
