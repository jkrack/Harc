import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcIdentity

package enum HostTransportPublicationKind: String, Codable, CaseIterable, Sendable {
    case initial
    case stableRenewal
    case plannedOverlap
    case plannedFinal
    case emergency
}

package struct HostCapabilityTransportReservation: Equatable, Sendable {
    package let minimumTransportSetEpoch: UInt64
    package let exactSignedTransportSet: Data
    package let retirementFloorUnixMilliseconds: UInt64
}

struct HostTransportReadyState: Sendable {
    let verifiedTransportSet: HostValidatedTransportSet
    let serverIdentity: HostTLSServerIdentity
    let retirementFloorUnixMilliseconds: UInt64
    let rotationIntent: HostTransportRotationIntent?

    var renewalDeadline: Date {
        guard let entry = verifiedTransportSet.entries.first(where: {
            $0.tlsSPKISHA256 == serverIdentity.certificate.tlsSPKISHA256
        }) else { return serverIdentity.certificate.notValidAfter }
        return min(
            serverIdentity.certificate.notValidAfter,
            Date(timeIntervalSince1970: Double(entry.notAfterUnixMilliseconds) / 1_000)
        )
    }
}

/// The transport composition root supplies this boundary so key promotion can
/// never race a listener that still serves the retiring private key.
package protocol HostTransportGenerationBoundary: Sendable {
    /// Removes discovery first, then stops admission and waits for every
    /// connection in the exposed generation to finish.
    func withdrawAdvertisementAndDrainGeneration() async throws

    /// Starts both role-specific listeners. Implementations must make the
    /// generation externally discoverable only after both listeners are ready.
    func activateGeneration(_ generation: HostTransportServingGeneration) async throws

    /// Fail-closed hard stop used when renewal cannot complete before expiry.
    func stopGenerationImmediately() async
}

package struct HostTransportDatabaseSnapshot: Equatable, Sendable {
    package let epoch: UInt64
    package let exactSignedBytes: Data?
    package let objectID: Data?
    package let retirementFloorUnixMilliseconds: UInt64
    package let pending: HostPendingTransportSetPublication?
}

package struct HostPendingTransportSetPublication: Equatable, Sendable {
    package let previousEpoch: UInt64
    package let nextEpoch: UInt64
    package let expectedPreviousObjectID: Data?
    package let exactSignedBytes: Data
    package let objectID: Data
    package let publicationKind: HostTransportPublicationKind
    package let expectedActiveSPKISHA256: Data
    package let secondarySPKISHA256: Data?
    package let retirementFloorUnixMilliseconds: UInt64
}

package struct HostTransportPendingTLSKeyCreationFacts: Equatable, Sendable {
    package let targetRole: HostCryptographicKeyRole
    package let keyExists: Bool
    package let publicKey: P256X963PublicKey?
}

package struct HostTransportPendingTLSKeyDeletionFacts: Equatable, Sendable {
    package let formerRole: HostCryptographicKeyRole
    package let publicKey: P256X963PublicKey
    package let keyExists: Bool
}

/// Exact public-only facts from the protected host record. Keeping these in
/// the startup plan lets HostDB and the Keychain record be cross-validated
/// before either crash journal is repaired, without retaining private key
/// material or a reusable listener identity snapshot.
package struct HostTransportCryptographicPreflightFacts: Equatable, Sendable {
    package let tuple: HostCryptographicStateTuple
    package let authorityPublicKey: P256X963PublicKey
    package let activeTLSSPKISHA256: Data?
    package let stagedTLSSPKISHA256: Data?
    package let retiringTLSSPKISHA256: Data?
    package let highestIssuedTransportSetEpoch: UInt64
    package let pendingTLSKeyCreation: HostTransportPendingTLSKeyCreationFacts?
    package let pendingTLSKeyDeletions: [HostTransportPendingTLSKeyDeletionFacts]

    package init(_ inspection: HostCryptographicStateInspection) {
        tuple = inspection.tuple
        authorityPublicKey = inspection.authorityPublicKey
        activeTLSSPKISHA256 = inspection.activeTLSPublicKey?.tlsSPKISHA256
        stagedTLSSPKISHA256 = inspection.stagedTLSPublicKey?.tlsSPKISHA256
        retiringTLSSPKISHA256 = inspection.retiringTLSPublicKey?.tlsSPKISHA256
        highestIssuedTransportSetEpoch = inspection.highestIssuedTransportSetEpoch
        pendingTLSKeyCreation = inspection.pendingTLSKeyCreation.map {
            HostTransportPendingTLSKeyCreationFacts(
                targetRole: $0.targetRole,
                keyExists: $0.keyExists,
                publicKey: $0.publicKey
            )
        }
        pendingTLSKeyDeletions = inspection.pendingTLSKeyDeletions.map {
            HostTransportPendingTLSKeyDeletionFacts(
                formerRole: $0.formerRole,
                publicKey: $0.publicKey,
                keyExists: $0.keyExists
            )
        }
    }

    package init(_ state: HostCryptographicState) {
        tuple = state.tuple
        authorityPublicKey = state.authorityIdentity.publicKey
        activeTLSSPKISHA256 = state.activeTLSIdentity.tlsSPKISHA256
        stagedTLSSPKISHA256 = state.stagedTLSIdentity?.tlsSPKISHA256
        retiringTLSSPKISHA256 = state.retiringTLSIdentity?.tlsSPKISHA256
        highestIssuedTransportSetEpoch = state.highestIssuedTransportSetEpoch
        pendingTLSKeyCreation = nil
        pendingTLSKeyDeletions = []
    }
}

/// Read-only dual-journal plan used only during production serving startup.
/// Reconciliation must observe the same exact HostDB snapshot and intent and
/// an allowed recovery successor of the protected public facts.
package struct HostTransportServingPreflightPlan: Equatable, Sendable {
    package let database: HostTransportDatabaseSnapshot
    package let currentPublicationKind: HostTransportPublicationKind?
    package let rotationIntent: HostTransportRotationIntent?
    package let protectedFacts: HostTransportCryptographicPreflightFacts
}

fileprivate struct HostTransportServingDatabasePreflightState: Sendable {
    let database: HostTransportDatabaseSnapshot
    let currentPublicationKind: HostTransportPublicationKind?
    let rotationIntent: HostTransportRotationIntent?
}

private struct HostPersistedTLSLeaf: Sendable {
    let certificateDER: Data
    let certificateSHA256: Data
    let serialNumber: Data
    let notBeforeUnixMilliseconds: UInt64
    let notAfterUnixMilliseconds: UInt64
}

extension HarcHostStore {
    /// Reads the current exact transport object, pending publication, history
    /// kind, and durable rotation intent in one SQLite snapshot.
    fileprivate func transportServingDatabasePreflightState() async throws
        -> HostTransportServingDatabasePreflightState
    {
        try await dbQueue.read { db in
            guard let metadata = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_metadata WHERE singleton = 1"
            ) else {
                throw HarcHostError.metadataMismatch
            }
            let epoch = try Self.unsigned(
                metadata["highest_transport_set_epoch"] as Int64,
                field: "highestTransportSetEpoch"
            )
            let pendingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_transport_set_publications WHERE singleton = 1"
            )
            let database = HostTransportDatabaseSnapshot(
                epoch: epoch,
                exactSignedBytes: metadata["exact_transport_set_bytes"],
                objectID: metadata["transport_set_object_sha256"],
                retirementFloorUnixMilliseconds: try Self.unsigned(
                    metadata["leaf_retirement_floor"] as Int64,
                    field: "leafRetirementFloorUnixMilliseconds"
                ),
                pending: try pendingRow.map(Self.pendingTransportSet(from:))
            )

            let currentKind: HostTransportPublicationKind?
            if epoch == 0 {
                currentKind = nil
            } else {
                let epochValue = try Self.sqliteInteger(epoch, field: "transportEpoch")
                guard let raw = try String.fetchOne(
                    db,
                    sql: "SELECT publication_kind FROM host_transport_sets WHERE epoch = ?",
                    arguments: [epochValue]
                ) else {
                    throw HarcHostError.transportSetPendingMismatch
                }
                if raw == "legacy" {
                    currentKind = nil
                } else if let parsed = HostTransportPublicationKind(rawValue: raw) {
                    currentKind = parsed
                } else {
                    throw HarcHostError.transportRotationStateMismatch
                }
            }

            let intent: HostTransportRotationIntent?
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_transport_rotation_intent WHERE singleton = 1"
            ) {
                guard let startedMode = HostTransportRotationMode(
                    rawValue: row["started_mode"] as String
                ), let mode = HostTransportRotationMode(
                    rawValue: row["mode"] as String
                ) else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                let createdAt = Self.date(row["created_at"] as Double)
                let escalatedAt = (row["emergency_escalated_at"] as Double?).map(Self.date)
                guard createdAt.timeIntervalSinceReferenceDate.isFinite,
                      escalatedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                intent = HostTransportRotationIntent(
                    startedMode: startedMode,
                    mode: mode,
                    oldTLSSPKISHA256: row["old_spki_sha256"],
                    newTLSSPKISHA256: row["new_spki_sha256"],
                    retirementFloorUnixMilliseconds: try Self.unsigned(
                        row["retirement_floor_unix_ms"] as Int64,
                        field: "rotationRetirementFloorUnixMilliseconds"
                    ),
                    createdAt: createdAt,
                    emergencyEscalatedAt: escalatedAt
                )
            } else {
                intent = nil
            }
            return HostTransportServingDatabasePreflightState(
                database: database,
                currentPublicationKind: currentKind,
                rotationIntent: intent
            )
        }
    }

    func transportDatabaseSnapshot() async throws -> HostTransportDatabaseSnapshot {
        try await dbQueue.read { db in
            guard let metadata = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_metadata WHERE singleton = 1"
            ) else {
                throw HarcHostError.metadataMismatch
            }
            let pendingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_transport_set_publications WHERE singleton = 1"
            )
            return HostTransportDatabaseSnapshot(
                epoch: try Self.unsigned(
                    metadata["highest_transport_set_epoch"] as Int64,
                    field: "highestTransportSetEpoch"
                ),
                exactSignedBytes: metadata["exact_transport_set_bytes"],
                objectID: metadata["transport_set_object_sha256"],
                retirementFloorUnixMilliseconds: try Self.unsigned(
                    metadata["leaf_retirement_floor"] as Int64,
                    field: "leafRetirementFloorUnixMilliseconds"
                ),
                pending: try pendingRow.map(Self.pendingTransportSet(from:))
            )
        }
    }

    func transportPublicationKind(epoch: UInt64) async throws -> HostTransportPublicationKind? {
        let epochValue = try Self.sqliteInteger(epoch, field: "transportEpoch")
        return try await dbQueue.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT publication_kind FROM host_transport_sets WHERE epoch = ?",
                arguments: [epochValue]
            ) else { throw HarcHostError.transportSetPendingMismatch }
            if raw == "legacy" { return nil }
            guard let kind = HostTransportPublicationKind(rawValue: raw) else {
                throw HarcHostError.transportRotationStateMismatch
            }
            return kind
        }
    }

    func prepareTransportSetPublication(
        _ verified: HostValidatedTransportSet,
        kind: HostTransportPublicationKind,
        expectedActiveSPKISHA256: Data,
        secondarySPKISHA256: Data?,
        retirementFloorUnixMilliseconds: UInt64,
        at date: Date
    ) async throws {
        guard verified.libraryID == expectedMetadata.libraryID,
              verified.hostAuthorityID == expectedMetadata.hostAuthorityID else {
            throw HarcHostError.invalidTransportSet("identity tuple")
        }
        let expectedSPKIs = [expectedActiveSPKISHA256]
            + (secondarySPKISHA256.map { [$0] } ?? [])
        guard expectedSPKIs.count == verified.entries.count,
              Set(expectedSPKIs) == Set(verified.entries.map(\.tlsSPKISHA256)) else {
            throw HarcHostError.invalidTransportSet("protected TLS key roles")
        }
        let objectID = verified.objectID
        let nextEpoch = try Self.sqliteInteger(
            verified.setEpoch,
            field: "transportSetEpoch"
        )
        let issuedAt = try Self.sqliteInteger(
            verified.issuedAtUnixMilliseconds,
            field: "transportSetIssuedAtUnixMilliseconds"
        )
        let floor = try Self.sqliteInteger(
            retirementFloorUnixMilliseconds,
            field: "leafRetirementFloorUnixMilliseconds"
        )
        let createdAt = Self.unixTime(date)

        return try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_metadata WHERE singleton = 1"
            ) else {
                throw HarcHostError.metadataMismatch
            }
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_transport_set_publications"
            ) == 0 else {
                throw HarcHostError.transportSetTransitionInProgress
            }
            let currentEpoch = row["highest_transport_set_epoch"] as Int64
            guard currentEpoch < Int64.max, nextEpoch == currentEpoch + 1 else {
                throw HarcHostError.transportSetPendingMismatch
            }
            let currentObjectID: Data? = row["transport_set_object_sha256"]
            guard (currentEpoch == 0 && currentObjectID == nil)
                    || (currentEpoch > 0 && currentObjectID?.count == 32),
                  floor >= (row["leaf_retirement_floor"] as Int64) else {
                throw HarcHostError.transportSetPendingMismatch
            }
            try db.execute(
                sql: """
                    INSERT INTO pending_transport_set_publications (
                        singleton, previous_epoch, next_epoch,
                        expected_previous_object_id, exact_signed_bytes,
                        object_id, publication_kind,
                        expected_active_spki_sha256, secondary_spki_sha256,
                        retirement_floor_unix_ms, created_at
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    currentEpoch,
                    nextEpoch,
                    currentObjectID,
                    verified.exactSignedBytes,
                    objectID,
                    kind.rawValue,
                    expectedActiveSPKISHA256,
                    secondarySPKISHA256,
                    floor,
                    createdAt,
                ]
            )
            _ = issuedAt // Revalidated and persisted during phase C.
        }
    }

    func applyPendingTransportSetPublication(
        expected pending: HostPendingTransportSetPublication,
        verified: HostValidatedTransportSet,
        at date: Date
    ) async throws {
        let publishedAt = Self.unixTime(date)
        let issuedAt = try Self.sqliteInteger(
            verified.issuedAtUnixMilliseconds,
            field: "transportSetIssuedAtUnixMilliseconds"
        )
        let previousEpoch = try Self.sqliteInteger(
            pending.previousEpoch,
            field: "previousEpoch"
        )
        try await dbQueue.write { db in
            guard let metadata = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_metadata WHERE singleton = 1"
            ), let pendingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_transport_set_publications WHERE singleton = 1"
            ) else {
                throw HarcHostError.transportSetPendingMismatch
            }
            let stored = try Self.pendingTransportSet(from: pendingRow)
            guard stored == pending,
                  pending.exactSignedBytes == verified.exactSignedBytes,
                  pending.objectID == verified.objectID,
                  pending.nextEpoch == verified.setEpoch,
                  (metadata["highest_transport_set_epoch"] as Int64) == previousEpoch,
                  (metadata["transport_set_object_sha256"] as Data?)
                    == pending.expectedPreviousObjectID else {
                throw HarcHostError.transportSetPendingMismatch
            }

            try db.execute(
                sql: """
                    INSERT INTO host_transport_sets (
                        epoch, exact_signed_bytes, object_id, publication_kind,
                        issued_at_unix_ms, published_at,
                        retirement_floor_unix_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    try Self.sqliteInteger(pending.nextEpoch, field: "nextEpoch"),
                    pending.exactSignedBytes,
                    pending.objectID,
                    pending.publicationKind.rawValue,
                    issuedAt,
                    publishedAt,
                    try Self.sqliteInteger(
                        pending.retirementFloorUnixMilliseconds,
                        field: "retirementFloorUnixMilliseconds"
                    ),
                ]
            )
            try db.execute(
                sql: """
                    UPDATE host_metadata
                       SET highest_transport_set_epoch = ?,
                           exact_transport_set_bytes = ?,
                           transport_set_object_sha256 = ?,
                           leaf_retirement_floor = ?,
                           updated_at = ?
                     WHERE singleton = 1
                    """,
                arguments: [
                    try Self.sqliteInteger(pending.nextEpoch, field: "nextEpoch"),
                    pending.exactSignedBytes,
                    pending.objectID,
                    try Self.sqliteInteger(
                        pending.retirementFloorUnixMilliseconds,
                        field: "retirementFloorUnixMilliseconds"
                    ),
                    publishedAt,
                ]
            )
            try db.execute(
                sql: "DELETE FROM pending_transport_set_publications WHERE singleton = 1"
            )
        }
    }

    func persistedTLSLeaf(
        transportEpoch: UInt64,
        tlsSPKISHA256: Data
    ) async throws -> Data? {
        try await dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: """
                    SELECT certificate_der FROM host_tls_leaves
                     WHERE transport_epoch = ? AND tls_spki_sha256 = ?
                    """,
                arguments: [
                    try Self.sqliteInteger(transportEpoch, field: "transportEpoch"),
                    tlsSPKISHA256,
                ]
            )
        }
    }

    func persistTLSLeaf(
        _ facts: HostTLSServerCertificateFacts,
        for verified: HostValidatedTransportSet,
        at date: Date
    ) async throws -> Data {
        guard facts.framedSignedTransportSet == verified.exactSignedBytes,
              let entry = verified.entries.first(where: {
                  $0.tlsSPKISHA256 == facts.tlsSPKISHA256
              }) else {
            throw HarcHostError.tlsLeafMismatch("transport-set extension or SPKI")
        }
        let notBefore = try Self.unixMilliseconds(facts.notValidBefore)
        let notAfter = try Self.unixMilliseconds(facts.notValidAfter)
        guard notBefore >= entry.notBeforeUnixMilliseconds,
              notAfter <= entry.notAfterUnixMilliseconds,
              notBefore < notAfter else {
            throw HarcHostError.tlsLeafMismatch("validity interval")
        }
        let record = HostPersistedTLSLeaf(
            certificateDER: facts.certificateDER,
            certificateSHA256: Data(SHA256.hash(data: facts.certificateDER)),
            serialNumber: facts.serialNumber,
            notBeforeUnixMilliseconds: notBefore,
            notAfterUnixMilliseconds: notAfter
        )
        let transportEpoch = try Self.sqliteInteger(
            verified.setEpoch,
            field: "transportEpoch"
        )
        return try await dbQueue.write { db in
            guard let metadata = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_metadata WHERE singleton = 1"
            ), (metadata["highest_transport_set_epoch"] as Int64) == transportEpoch,
               (metadata["exact_transport_set_bytes"] as Data?) == verified.exactSignedBytes,
               (metadata["transport_set_object_sha256"] as Data?)
                == verified.objectID else {
                throw HarcHostError.tlsLeafMismatch("current transport-set binding")
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM host_tls_leaves
                     WHERE transport_epoch = ? AND tls_spki_sha256 = ?
                    """,
                arguments: [
                    try Self.sqliteInteger(verified.setEpoch, field: "transportEpoch"),
                    facts.tlsSPKISHA256,
                ]
            ) {
                let existingDER: Data = existing["certificate_der"]
                guard (existing["certificate_sha256"] as Data)
                        == Data(SHA256.hash(data: existingDER)) else {
                    throw HarcHostError.tlsLeafMismatch("persisted certificate hash")
                }
                // A concurrent issuer may have won with a different random
                // serial. The caller revalidates this exact winner against the
                // request before resolving it.
                return existingDER
            }
            try db.execute(
                sql: """
                    INSERT INTO host_tls_leaves (
                        transport_epoch, tls_spki_sha256, certificate_der,
                        certificate_sha256, serial_number,
                        not_before_unix_ms, not_after_unix_ms, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    try Self.sqliteInteger(verified.setEpoch, field: "transportEpoch"),
                    facts.tlsSPKISHA256,
                    record.certificateDER,
                    record.certificateSHA256,
                    record.serialNumber,
                    try Self.sqliteInteger(record.notBeforeUnixMilliseconds, field: "notBefore"),
                    try Self.sqliteInteger(record.notAfterUnixMilliseconds, field: "notAfter"),
                    Self.unixTime(date),
                ]
            )
            return record.certificateDER
        }
    }

    private static func pendingTransportSet(from row: Row) throws -> HostPendingTransportSetPublication {
        guard let kind = HostTransportPublicationKind(
            rawValue: row["publication_kind"] as String
        ) else {
            throw HarcHostError.transportSetPendingMismatch
        }
        return HostPendingTransportSetPublication(
            previousEpoch: try unsigned(row["previous_epoch"] as Int64, field: "previousEpoch"),
            nextEpoch: try unsigned(row["next_epoch"] as Int64, field: "nextEpoch"),
            expectedPreviousObjectID: row["expected_previous_object_id"],
            exactSignedBytes: row["exact_signed_bytes"],
            objectID: row["object_id"],
            publicationKind: kind,
            expectedActiveSPKISHA256: row["expected_active_spki_sha256"],
            secondarySPKISHA256: row["secondary_spki_sha256"],
            retirementFloorUnixMilliseconds: try unsigned(
                row["retirement_floor_unix_ms"] as Int64,
                field: "retirementFloorUnixMilliseconds"
            )
        )
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(UInt64.max) else {
            throw HarcHostError.invalidTransportSet("Unix millisecond time")
        }
        return UInt64(value.rounded())
    }
}

/// Singular resident owner of transport publication and listener exposure.
/// Package-scoped construction prevents applications from creating another
/// per-actor gate or retaining raw identity material for a later bind.
package actor HostTransportLifecycle {
    private static let clockSkewMilliseconds: UInt64 = 5 * 60 * 1_000
    private static let freshLifetimeMilliseconds: UInt64 = 89 * 24 * 60 * 60 * 1_000
    private static let capabilitySafetyMarginMilliseconds: UInt64 = 5 * 60 * 1_000
    package static let renewalLeadTime: TimeInterval = 7 * 24 * 60 * 60
    package static let renewalRetryInterval: TimeInterval = 5 * 60

    private let store: HarcHostStore
    private let cryptographicStateStore: any HostCryptographicStateStore
    private let transportSetProtocol: any HostTransportSetProtocolBoundary
    private let generationBoundary: any HostTransportGenerationBoundary
    private let now: @Sendable () -> Date
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparedGeneration: PreparedGeneration?
    private var currentReadyState: HostTransportReadyState?
    private var currentGenerationStatus: HostTransportGenerationStatus?

    private struct PreparedGeneration: Sendable {
        let id: UUID
        let ready: HostTransportReadyState
        var leases: [HostTransportListenerRole: LeaseState]
    }

    private struct LeaseState: Sendable {
        let id: UUID
        var phase: LeasePhase
    }

    private enum LeasePhase: Equatable, Sendable {
        case issued
        case consumed
        case bound
    }

    init(
        store: HarcHostStore,
        cryptographicStateStore: any HostCryptographicStateStore,
        transportSetProtocol: any HostTransportSetProtocolBoundary,
        generationBoundary: any HostTransportGenerationBoundary,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.cryptographicStateStore = cryptographicStateStore
        self.transportSetProtocol = transportSetProtocol
        self.generationBoundary = generationBoundary
        self.now = now
    }

    /// Phase one of production serving recovery. This is deliberately
    /// read-only across both HostDB transport tables and the protected host
    /// record supplied by `inspect(requiredTuple:)`.
    package func preflightDeferredServingTransport(
        inspection: HostCryptographicStateInspection
    ) async throws -> HostTransportServingPreflightPlan {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        try await store.requireDeferredServingTransportPreflightAllowed()
        return try await makeDeferredServingTransportPreflight(
            protectedFacts: HostTransportCryptographicPreflightFacts(inspection)
        )
    }

    /// Rechecks the exact HostDB plan, resolves only the already-inspected TLS
    /// key journal, and then reconciles the exact pending transport-set row.
    /// The resident runtime holds the shared serving-recovery exclusion around
    /// this method and the security-registry phases.
    package func reconcileDeferredServingTransport(
        using plan: HostTransportServingPreflightPlan,
        expectedSecurityRegistryRevision: UInt64
    ) async throws {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        try await store.requireDeferredServingTransportReconcileAllowed()

        let observed = try await store.transportServingDatabasePreflightState()
        let database = observed.database
        let currentKind = observed.currentPublicationKind
        let intent = observed.rotationIntent
        guard database == plan.database,
              currentKind == plan.currentPublicationKind,
              intent == plan.rotationIntent else {
            throw HarcHostError.deferredServingPreflightMismatch
        }

        // `load` may now finish only the key creation/deletion journal already
        // captured in the plan. Both HostDB journals were validated before this
        // first potentially mutating protected-record operation.
        let state = try await cryptographicStateStore.load(
            requiredTuple: cryptographicTuple
        )
        guard state.securityRegistryRevision == expectedSecurityRegistryRevision else {
            throw HarcHostError.deferredServingPreflightMismatch
        }
        let postRecoveryObserved = try await store
            .transportServingDatabasePreflightState()
        guard postRecoveryObserved.database == database,
              postRecoveryObserved.currentPublicationKind == currentKind,
              postRecoveryObserved.rotationIntent == intent else {
            throw HarcHostError.deferredServingPreflightMismatch
        }
        let resolvedFacts = HostTransportCryptographicPreflightFacts(state)
        try validateProtectedRecoverySuccessor(
            resolvedFacts,
            of: plan.protectedFacts
        )

        let current = try validateCurrent(
            snapshot: database,
            authorityPublicKey: resolvedFacts.authorityPublicKey,
            tuple: resolvedFacts.tuple
        )
        let pending = try database.pending.map {
            try validatePending(
                $0,
                snapshot: database,
                authorityPublicKey: resolvedFacts.authorityPublicKey,
                tuple: resolvedFacts.tuple
            )
        }
        try validateDeferredServingSemantics(
            database: database,
            currentPublicationKind: currentKind,
            rotationIntent: intent,
            protectedFacts: resolvedFacts,
            current: current,
            pending: pending
        )
        if let pendingPublication = database.pending,
           let verifiedPending = pending {
            switch state.highestIssuedTransportSetEpoch {
            case database.epoch:
                _ = try await cryptographicStateStore
                    .advanceHighestIssuedTransportSetEpoch(
                        for: state.tuple,
                        from: database.epoch,
                        to: pendingPublication.nextEpoch
                    )
            case pendingPublication.nextEpoch:
                break
            default:
                throw HarcHostError.transportSetRollback(
                    databaseEpoch: database.epoch,
                    highWaterEpoch: state.highestIssuedTransportSetEpoch
                )
            }
            // This is the final exact HostDB compare-and-apply. A changed or
            // replaced row fails even if the protected mark was advanced.
            try await store.applyPendingTransportSetPublication(
                expected: pendingPublication,
                verified: verifiedPending,
                at: now()
            )
        } else {
            guard database.pending == nil,
                  state.highestIssuedTransportSetEpoch == database.epoch else {
                throw HarcHostError.transportSetPendingMismatch
            }
            let finalObserved = try await store
                .transportServingDatabasePreflightState()
            guard finalObserved.database == database,
                  finalObserved.currentPublicationKind == currentKind,
                  finalObserved.rotationIntent == intent else {
                throw HarcHostError.deferredServingPreflightMismatch
            }
        }
    }

    func prepareForServing() async throws -> HostTransportReadyState {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        if let currentReadyState { return currentReadyState }
        let ready = try await prepareForServingUnderGate()
        try await activatePreparedGeneration(ready)
        return ready
    }

    private func prepareForServingUnderGate() async throws -> HostTransportReadyState {
        try await store.requireServingBootstrapActive()
        var state = try await cryptographicStateStore.load(
            requiredTuple: cryptographicTuple
        )
        var current = try await reconcileJournal(state: state)
        if let current,
           state.highestIssuedTransportSetEpoch != current.setEpoch {
            state = try await cryptographicStateStore.load(
                requiredTuple: cryptographicTuple
            )
        }
        if current == nil {
            let initial = try freshTransportSet(
                state: state,
                epoch: 1,
                includeStaged: false,
                retirementFloorUnixMilliseconds: 0
            )
            try await publish(
                initial,
                state: state,
                kind: .initial,
                secondarySPKISHA256: nil,
                retirementFloorUnixMilliseconds: 0
            )
            state = try await cryptographicStateStore.load(requiredTuple: cryptographicTuple)
            current = initial
        }
        guard var verified = current else {
            throw HarcHostError.transportSetNotInitialized
        }

        (state, verified) = try await resumeDurableRotationIfPossible(
            state: state,
            current: verified
        )
        (state, verified) = try await renewCurrentSetIfNeeded(
            state: state,
            current: verified
        )
        let serverIdentity = try await resolveOrCreateLeaf(
            identity: state.activeTLSIdentity,
            transportSet: verified
        )
        let database = try await store.transportDatabaseSnapshot()
        return HostTransportReadyState(
            verifiedTransportSet: verified,
            serverIdentity: serverIdentity,
            retirementFloorUnixMilliseconds: database.retirementFloorUnixMilliseconds,
            rotationIntent: try await store.transportRotationIntent()
        )
    }

    /// Starts planned overlap only after the old listener generation is fully
    /// quiescent. The replacement generation serves a leaf embedding N+1.
    func beginPlannedRotation() async throws -> HostTransportReadyState {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        let ready = try requireReadyUnderGate()
        guard ready.rotationIntent == nil,
              ready.verifiedTransportSet.entries.count == 1 else {
            throw HarcHostError.transportSetTransitionInProgress
        }
        var state = try await cryptographicStateStore.load(requiredTuple: cryptographicTuple)
        guard state.stagedTLSIdentity == nil, state.retiringTLSIdentity == nil else {
            throw HarcHostError.transportRotationStateMismatch
        }
        try await quiesceCurrentGeneration()
        let oldSPKI = state.activeTLSIdentity.tlsSPKISHA256
        try await store.beginPlannedTransportRotation(
            oldSPKISHA256: oldSPKI,
            retirementFloorUnixMilliseconds: ready.retirementFloorUnixMilliseconds,
            at: now()
        )
        state = try await cryptographicStateStore.stageReplacementTLSIdentity(
            for: cryptographicTuple,
            expectedActivePublicKey: state.activeTLSIdentity.publicKey
        )
        guard let staged = state.stagedTLSIdentity else {
            throw HarcHostError.transportRotationStateMismatch
        }
        try await store.bindRotationReplacementSPKI(staged.tlsSPKISHA256)
        let overlap = try freshTransportSet(
            state: state,
            epoch: ready.verifiedTransportSet.setEpoch + 1,
            includeStaged: true,
            retirementFloorUnixMilliseconds: ready.retirementFloorUnixMilliseconds
        )
        try await publish(
            overlap,
            state: state,
            kind: .plannedOverlap,
            secondarySPKISHA256: staged.tlsSPKISHA256,
            retirementFloorUnixMilliseconds: ready.retirementFloorUnixMilliseconds
        )
        let identity = try await resolveOrCreateLeaf(
            identity: state.activeTLSIdentity,
            transportSet: overlap
        )
        let replacement = HostTransportReadyState(
            verifiedTransportSet: overlap,
            serverIdentity: identity,
            retirementFloorUnixMilliseconds: ready.retirementFloorUnixMilliseconds,
            rotationIntent: try await store.transportRotationIntent()
        )
        try await activatePreparedGeneration(replacement)
        return replacement
    }

    /// Stops/drains old-key listeners, enforces the frozen floor, then commits
    /// staged -> active, publishes the one-key successor, persists its exact
    /// leaf DER, and only then removes the retiring key reference.
    func completePlannedRotation() async throws -> HostTransportReadyState {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        var state = try await cryptographicStateStore.load(requiredTuple: cryptographicTuple)
        guard let intent = try await store.transportRotationIntent(),
              intent.mode == .planned,
              let staged = state.stagedTLSIdentity,
              intent.oldTLSSPKISHA256 == state.activeTLSIdentity.tlsSPKISHA256,
              intent.newTLSSPKISHA256 == staged.tlsSPKISHA256 else {
            throw HarcHostError.transportRotationStateMismatch
        }
        let nowMilliseconds = try Self.unixMilliseconds(now())
        guard nowMilliseconds >= intent.retirementFloorUnixMilliseconds else {
            throw HarcHostError.transportRetirementFloorNotReached(
                requiredUnixMilliseconds: intent.retirementFloorUnixMilliseconds
            )
        }
        guard let overlap = try await reconcileJournal(state: state),
              overlap.entries.count == 2,
              Set(overlap.entries.map(\.tlsSPKISHA256))
                == Set([intent.oldTLSSPKISHA256, staged.tlsSPKISHA256]) else {
            throw HarcHostError.transportRotationStateMismatch
        }
        try await quiesceCurrentGeneration()
        state = try await cryptographicStateStore.promoteStagedTLSIdentity(
            for: cryptographicTuple,
            expectedActivePublicKey: state.activeTLSIdentity.publicKey,
            expectedStagedPublicKey: staged.publicKey
        )
        guard let retiring = state.retiringTLSIdentity else {
            throw HarcHostError.transportRotationStateMismatch
        }
        let final = try freshTransportSet(
            state: state,
            epoch: overlap.setEpoch + 1,
            includeStaged: false,
            retirementFloorUnixMilliseconds: intent.retirementFloorUnixMilliseconds
        )
        try await publish(
            final,
            state: state,
            kind: .plannedFinal,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: intent.retirementFloorUnixMilliseconds
        )
        let identity = try await resolveOrCreateLeaf(
            identity: state.activeTLSIdentity,
            transportSet: final
        )
        state = try await cryptographicStateStore.finalizeRetiringTLSIdentity(
            for: cryptographicTuple,
            expectedRetiringPublicKey: retiring.publicKey
        )
        try await store.clearTransportRotationIntent(
            expectedMode: .planned,
            expectedOldSPKISHA256: intent.oldTLSSPKISHA256,
            expectedNewSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256
        )
        let replacement = HostTransportReadyState(
            verifiedTransportSet: final,
            serverIdentity: identity,
            retirementFloorUnixMilliseconds: intent.retirementFloorUnixMilliseconds,
            rotationIntent: nil
        )
        try await activatePreparedGeneration(replacement)
        return replacement
    }

    /// Emergency replacement preempts a planned overlap and bypasses its
    /// retirement floor. Security-registry mutation and transport mutation use
    /// one reciprocal gate, acquired before this lifecycle's operation gate.
    func performEmergencyRotation(
        compromisedTLSSPKISHA256: Data? = nil
    ) async throws -> HostTransportReadyState {
        try await store.withEmergencyTransportSecurityExclusion {
            try await self.performEmergencyRotationUnderSecurityGate(
                compromisedTLSSPKISHA256: compromisedTLSSPKISHA256
            )
        }
    }

    private func performEmergencyRotationUnderSecurityGate(
        compromisedTLSSPKISHA256: Data?
    ) async throws -> HostTransportReadyState {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        let ready = try requireReadyUnderGate()
        var state = try await cryptographicStateStore.load(requiredTuple: cryptographicTuple)
        let existingIntent = try await store.transportRotationIntent()
        let compromisedSPKI = compromisedTLSSPKISHA256
            ?? existingIntent?.oldTLSSPKISHA256
            ?? state.activeTLSIdentity.tlsSPKISHA256
        guard compromisedSPKI.count == SHA256.byteCount,
              existingIntent == nil || existingIntent?.mode == .planned
                    || existingIntent?.mode == .emergency,
              existingIntent?.oldTLSSPKISHA256 == nil
                    || existingIntent?.oldTLSSPKISHA256 == compromisedSPKI,
              state.stagedTLSIdentity?.tlsSPKISHA256 != compromisedSPKI else {
            throw HarcHostError.transportRotationStateMismatch
        }

        try await quiesceCurrentGeneration()
        var intent = try await store.beginOrEscalateEmergencyTransportRotation(
            compromisedSPKISHA256: compromisedSPKI,
            retirementFloorUnixMilliseconds:
                existingIntent?.retirementFloorUnixMilliseconds
                    ?? ready.retirementFloorUnixMilliseconds,
            at: now()
        )

        if intent.newTLSSPKISHA256 == nil {
            if state.stagedTLSIdentity == nil {
                guard state.activeTLSIdentity.tlsSPKISHA256 == compromisedSPKI,
                      state.retiringTLSIdentity == nil else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                state = try await cryptographicStateStore.stageReplacementTLSIdentity(
                    for: cryptographicTuple,
                    expectedActivePublicKey: state.activeTLSIdentity.publicKey
                )
            }
            guard let staged = state.stagedTLSIdentity,
                  staged.tlsSPKISHA256 != compromisedSPKI else {
                throw HarcHostError.transportRotationStateMismatch
            }
            try await store.bindRotationReplacementSPKI(staged.tlsSPKISHA256)
            guard let rebound = try await store.transportRotationIntent() else {
                throw HarcHostError.transportRotationStateMismatch
            }
            intent = rebound
        }

        guard let replacementSPKI = intent.newTLSSPKISHA256,
              replacementSPKI != compromisedSPKI else {
            throw HarcHostError.transportRotationStateMismatch
        }
        if let staged = state.stagedTLSIdentity {
            guard state.activeTLSIdentity.tlsSPKISHA256 == compromisedSPKI,
                  staged.tlsSPKISHA256 == replacementSPKI,
                  state.retiringTLSIdentity == nil else {
                throw HarcHostError.transportRotationStateMismatch
            }
            state = try await cryptographicStateStore.promoteStagedTLSIdentity(
                for: cryptographicTuple,
                expectedActivePublicKey: state.activeTLSIdentity.publicKey,
                expectedStagedPublicKey: staged.publicKey
            )
        } else {
            guard state.activeTLSIdentity.tlsSPKISHA256 == replacementSPKI,
                  state.retiringTLSIdentity?.tlsSPKISHA256 == compromisedSPKI
                    || state.retiringTLSIdentity == nil else {
                throw HarcHostError.transportRotationStateMismatch
            }
        }
        let replacement = try await finishEmergencyRotation(
            state: state,
            previous: ready.verifiedTransportSet
        )
        try await activatePreparedGeneration(replacement)
        return replacement
    }

    package func generationStatus() -> HostTransportGenerationStatus? {
        currentGenerationStatus
    }

    /// Timer and wake handlers call this same serialized path. Renewal is a
    /// complete two-listener generation swap; identities are never changed in
    /// place beneath an existing listener.
    @discardableResult
    func renewServingGenerationIfNeeded(
        force: Bool = false
    ) async throws -> HostTransportGenerationStatus {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        let ready = try requireReadyUnderGate()
        guard let status = currentGenerationStatus else {
            throw HostTransportGenerationError.generationNotPrepared
        }
        guard force || now() >= status.renewAt else { return status }

        if now() >= status.hardStopAt {
            await generationBoundary.stopGenerationImmediately()
            invalidateGenerationState()
        } else {
            try await quiesceCurrentGeneration()
        }

        // `prepareForServingUnderGate` observes the proactive threshold and
        // advances the set epoch before issuing a matching fresh leaf.
        let replacement = try await prepareForServingUnderGate()
        guard replacement.verifiedTransportSet.setEpoch
                > ready.verifiedTransportSet.setEpoch else {
            throw HarcHostError.transportRotationStateMismatch
        }
        try await activatePreparedGeneration(replacement)
        guard let renewed = currentGenerationStatus else {
            throw HostTransportGenerationError.incompleteActivation
        }
        return renewed
    }

    /// Fails closed if scheduler retries could not finish before the validity
    /// boundary. It is safe and idempotent to call from every wake event.
    @discardableResult
    package func enforceRenewalHardStopIfNeeded() async -> Bool {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        guard let status = currentGenerationStatus,
              now() >= status.hardStopAt else { return false }
        await generationBoundary.stopGenerationImmediately()
        invalidateGenerationState()
        return true
    }

    package func shutdownServingGeneration() async {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        await generationBoundary.stopGenerationImmediately()
        invalidateGenerationState()
    }

    /// Capability minting must call this actor, not mutate HostDB directly.
    /// Stable one-key sets extend the old-leaf retirement floor atomically;
    /// overlap sets bind the new epoch but never extend the old-key floor.
    package func reserveTransportForCapability(
        expiringAt expiry: Date
    ) async throws -> HostCapabilityTransportReservation {
        await acquireOperationGate()
        defer { releaseOperationGate() }
        let ready = try requireReadyUnderGate()
        let set = ready.verifiedTransportSet
        let expiryMilliseconds = try Self.unixMilliseconds(expiry)
        let floorResult = expiryMilliseconds.addingReportingOverflow(
            Self.capabilitySafetyMarginMilliseconds
        )
        guard !floorResult.overflow,
              let activeEntry = set.entries.first(where: {
                  $0.tlsSPKISHA256 == ready.serverIdentity.certificate.tlsSPKISHA256
              }),
              floorResult.partialValue <= activeEntry.notAfterUnixMilliseconds else {
            throw HarcHostError.invalidTransportSet("capability outlives active leaf coverage")
        }
        let overlap = set.entries.count == 2
        let reservation = try await store.reserveCapabilityTransportWindow(
            expectedEpoch: set.setEpoch,
            expectedObjectID: ready.verifiedTransportSet.objectID,
            proposedRetirementFloorUnixMilliseconds: floorResult.partialValue,
            extendRetirementFloor: !overlap,
            at: now()
        )
        currentReadyState = HostTransportReadyState(
            verifiedTransportSet: ready.verifiedTransportSet,
            serverIdentity: ready.serverIdentity,
            retirementFloorUnixMilliseconds:
                reservation.retirementFloorUnixMilliseconds,
            rotationIntent: ready.rotationIntent
        )
        return reservation
    }

    package func consumeListenerLease(
        leaseID: UUID,
        generationID: UUID,
        role: HostTransportListenerRole
    ) throws -> HostTransportListenerMaterial {
        guard var prepared = preparedGeneration else {
            throw HostTransportGenerationError.staleLease
        }
        guard prepared.id == generationID,
              var lease = prepared.leases[role],
              lease.id == leaseID else {
            throw HostTransportGenerationError.staleLease
        }
        guard lease.phase == .issued else {
            throw HostTransportGenerationError.leaseAlreadyConsumed
        }
        lease.phase = .consumed
        prepared.leases[role] = lease
        preparedGeneration = prepared
        return HostTransportListenerMaterial(
            lifecycle: self,
            leaseID: leaseID,
            generationID: generationID,
            role: role
        )
    }

    package func bindConsumedListenerMaterial(
        leaseID: UUID,
        generationID: UUID,
        role: HostTransportListenerRole
    ) throws -> HostTLSServerIdentity {
        guard var prepared = preparedGeneration,
              prepared.id == generationID,
              var lease = prepared.leases[role],
              lease.id == leaseID else {
            throw HostTransportGenerationError.staleLease
        }
        guard lease.phase == .consumed else {
            if lease.phase == .bound {
                throw HostTransportGenerationError.leaseAlreadyBound
            }
            throw HostTransportGenerationError.staleLease
        }
        lease.phase = .bound
        prepared.leases[role] = lease
        preparedGeneration = prepared
        return prepared.ready.serverIdentity
    }

    private func requireReadyUnderGate() throws -> HostTransportReadyState {
        guard let currentReadyState, currentGenerationStatus != nil,
              preparedGeneration == nil else {
            throw HostTransportGenerationError.generationNotPrepared
        }
        return currentReadyState
    }

    private func activatePreparedGeneration(
        _ ready: HostTransportReadyState
    ) async throws {
        guard currentReadyState == nil,
              currentGenerationStatus == nil,
              preparedGeneration == nil else {
            throw HostTransportGenerationError.generationAlreadyActive
        }
        let generationID = UUID()
        let grpcLease = LeaseState(id: UUID(), phase: .issued)
        let uploadLease = LeaseState(id: UUID(), phase: .issued)
        preparedGeneration = PreparedGeneration(
            id: generationID,
            ready: ready,
            leases: [
                .grpcControl: grpcLease,
                .backgroundUpload: uploadLease,
            ]
        )

        let hardStopAt = ready.renewalDeadline.addingTimeInterval(
            -Double(Self.clockSkewMilliseconds) / 1_000
        )
        let renewAt = ready.renewalDeadline.addingTimeInterval(-Self.renewalLeadTime)
        let generation = HostTransportServingGeneration(
            generationID: generationID,
            transportEpoch: ready.verifiedTransportSet.setEpoch,
            transportSetObjectID: ready.verifiedTransportSet.objectID,
            renewAt: renewAt,
            hardStopAt: hardStopAt,
            grpcControl: HostTransportListenerLease(
                lifecycle: self,
                generationID: generationID,
                role: .grpcControl,
                leaseID: grpcLease.id
            ),
            backgroundUpload: HostTransportListenerLease(
                lifecycle: self,
                generationID: generationID,
                role: .backgroundUpload,
                leaseID: uploadLease.id
            )
        )

        do {
            try await generationBoundary.activateGeneration(generation)
            guard let prepared = preparedGeneration,
                  prepared.id == generationID,
                  HostTransportListenerRole.allCases.allSatisfy({
                    prepared.leases[$0]?.phase == .bound
                  }) else {
                throw HostTransportGenerationError.incompleteActivation
            }
            preparedGeneration = nil
            currentReadyState = ready
            currentGenerationStatus = HostTransportGenerationStatus(
                generationID: generationID,
                transportEpoch: generation.transportEpoch,
                renewAt: renewAt,
                hardStopAt: hardStopAt
            )
        } catch {
            await generationBoundary.stopGenerationImmediately()
            invalidateGenerationState()
            throw error
        }
    }

    private func quiesceCurrentGeneration() async throws {
        guard currentGenerationStatus != nil else {
            if preparedGeneration != nil {
                await generationBoundary.stopGenerationImmediately()
                invalidateGenerationState()
            }
            return
        }
        do {
            try await generationBoundary.withdrawAdvertisementAndDrainGeneration()
            invalidateGenerationState()
        } catch {
            await generationBoundary.stopGenerationImmediately()
            invalidateGenerationState()
            throw error
        }
    }

    private func invalidateGenerationState() {
        preparedGeneration = nil
        currentReadyState = nil
        currentGenerationStatus = nil
    }

    private var cryptographicTuple: HostCryptographicStateTuple {
        HostCryptographicStateTuple(
            libraryID: store.expectedMetadata.libraryID,
            hostAuthorityID: store.expectedMetadata.hostAuthorityID,
            hostStateID: store.expectedMetadata.hostStateID
        )
    }

    private func makeDeferredServingTransportPreflight(
        protectedFacts: HostTransportCryptographicPreflightFacts
    ) async throws -> HostTransportServingPreflightPlan {
        guard protectedFacts.tuple == cryptographicTuple,
              protectedFacts.authorityPublicKey.hostAuthorityID
                == cryptographicTuple.hostAuthorityID else {
            throw HarcHostError.metadataMismatch
        }
        let observed = try await store.transportServingDatabasePreflightState()
        let database = observed.database
        let currentKind = observed.currentPublicationKind
        let intent = observed.rotationIntent
        let current = try validateCurrent(
            snapshot: database,
            authorityPublicKey: protectedFacts.authorityPublicKey,
            tuple: protectedFacts.tuple
        )
        let pending = try database.pending.map {
            try validatePending(
                $0,
                snapshot: database,
                authorityPublicKey: protectedFacts.authorityPublicKey,
                tuple: protectedFacts.tuple
            )
        }

        if let pendingPublication = database.pending {
            guard protectedFacts.highestIssuedTransportSetEpoch == database.epoch
                    || protectedFacts.highestIssuedTransportSetEpoch
                        == pendingPublication.nextEpoch else {
                throw HarcHostError.transportSetRollback(
                    databaseEpoch: database.epoch,
                    highWaterEpoch: protectedFacts.highestIssuedTransportSetEpoch
                )
            }
        } else if protectedFacts.highestIssuedTransportSetEpoch != database.epoch {
            throw HarcHostError.transportSetRollback(
                databaseEpoch: database.epoch,
                highWaterEpoch: protectedFacts.highestIssuedTransportSetEpoch
            )
        }

        try validateDeferredServingSemantics(
            database: database,
            currentPublicationKind: currentKind,
            rotationIntent: intent,
            protectedFacts: protectedFacts,
            current: current,
            pending: pending
        )
        return HostTransportServingPreflightPlan(
            database: database,
            currentPublicationKind: currentKind,
            rotationIntent: intent,
            protectedFacts: protectedFacts
        )
    }

    private func validateProtectedRecoverySuccessor(
        _ resolved: HostTransportCryptographicPreflightFacts,
        of inspected: HostTransportCryptographicPreflightFacts
    ) throws {
        guard resolved.tuple == inspected.tuple,
              resolved.authorityPublicKey == inspected.authorityPublicKey,
              resolved.highestIssuedTransportSetEpoch
                == inspected.highestIssuedTransportSetEpoch,
              resolved.pendingTLSKeyCreation == nil,
              resolved.pendingTLSKeyDeletions.isEmpty else {
            throw HarcHostError.deferredServingPreflightMismatch
        }

        guard let creation = inspected.pendingTLSKeyCreation else {
            guard resolved.activeTLSSPKISHA256 == inspected.activeTLSSPKISHA256,
                  resolved.stagedTLSSPKISHA256 == inspected.stagedTLSSPKISHA256,
                  resolved.retiringTLSSPKISHA256 == inspected.retiringTLSSPKISHA256 else {
                throw HarcHostError.deferredServingPreflightMismatch
            }
            return
        }

        guard inspected.pendingTLSKeyDeletions.isEmpty else {
            throw HarcHostError.transportRotationStateMismatch
        }
        let expectedCreatedSPKI = creation.publicKey?.tlsSPKISHA256
        switch creation.targetRole {
        case .tlsServer:
            guard inspected.activeTLSSPKISHA256 == nil,
                  inspected.stagedTLSSPKISHA256 == nil,
                  inspected.retiringTLSSPKISHA256 == nil,
                  resolved.activeTLSSPKISHA256 != nil,
                  resolved.stagedTLSSPKISHA256 == nil,
                  resolved.retiringTLSSPKISHA256 == nil,
                  expectedCreatedSPKI == nil
                    || resolved.activeTLSSPKISHA256 == expectedCreatedSPKI else {
                throw HarcHostError.deferredServingPreflightMismatch
            }
        case .tlsServerStaged:
            guard inspected.activeTLSSPKISHA256 != nil,
                  inspected.stagedTLSSPKISHA256 == nil,
                  inspected.retiringTLSSPKISHA256 == nil,
                  resolved.activeTLSSPKISHA256 == inspected.activeTLSSPKISHA256,
                  resolved.stagedTLSSPKISHA256 != nil,
                  resolved.retiringTLSSPKISHA256 == nil,
                  expectedCreatedSPKI == nil
                    || resolved.stagedTLSSPKISHA256 == expectedCreatedSPKI else {
                throw HarcHostError.deferredServingPreflightMismatch
            }
        default:
            throw HarcHostError.transportRotationStateMismatch
        }
    }

    private func validateDeferredServingSemantics(
        database: HostTransportDatabaseSnapshot,
        currentPublicationKind: HostTransportPublicationKind?,
        rotationIntent intent: HostTransportRotationIntent?,
        protectedFacts facts: HostTransportCryptographicPreflightFacts,
        current: HostValidatedTransportSet?,
        pending: HostValidatedTransportSet?
    ) throws {
        func spkis(_ set: HostValidatedTransportSet?) -> Set<Data>? {
            set.map { Set($0.entries.map(\.tlsSPKISHA256)) }
        }
        func isExactly(_ observed: Set<Data>?, _ expected: [Data]) -> Bool {
            guard let observed else { return false }
            return observed.count == expected.count && observed == Set(expected)
        }
        func isOneOf(_ observed: Set<Data>?, _ expected: [[Data]]) -> Bool {
            expected.contains { isExactly(observed, $0) }
        }

        let currentSPKIs = spkis(current)
        let pendingSPKIs = spkis(pending)
        let effectiveSPKIs = pendingSPKIs ?? currentSPKIs
        let liveSPKIs = [
            facts.activeTLSSPKISHA256,
            facts.stagedTLSSPKISHA256,
            facts.retiringTLSSPKISHA256,
        ].compactMap { $0 }
        guard liveSPKIs.allSatisfy({ $0.count == SHA256.byteCount }),
              Set(liveSPKIs).count == liveSPKIs.count,
              facts.pendingTLSKeyDeletions.count <= 1,
              facts.pendingTLSKeyCreation == nil
                || facts.pendingTLSKeyDeletions.isEmpty else {
            throw HarcHostError.transportRotationStateMismatch
        }
        guard database.epoch != 0
                || database.retirementFloorUnixMilliseconds == 0,
              database.pending == nil
                || database.pending?.retirementFloorUnixMilliseconds
                    == database.retirementFloorUnixMilliseconds else {
            throw HarcHostError.transportRotationStateMismatch
        }
        for verified in [current, pending].compactMap({ $0 }) {
            guard verified.entries.allSatisfy({
                database.retirementFloorUnixMilliseconds
                    <= $0.notAfterUnixMilliseconds
            }) else {
                throw HarcHostError.transportRotationStateMismatch
            }
        }
        for deletion in facts.pendingTLSKeyDeletions {
            guard deletion.formerRole == .tlsServerStaged
                    || deletion.formerRole == .tlsServerRetiring,
                  !liveSPKIs.contains(deletion.publicKey.tlsSPKISHA256) else {
                throw HarcHostError.transportRotationStateMismatch
            }
        }

        guard let active = facts.activeTLSSPKISHA256 else {
            guard intent == nil,
                  database.epoch == 0,
                  current == nil,
                  pending == nil,
                  facts.stagedTLSSPKISHA256 == nil,
                  facts.retiringTLSSPKISHA256 == nil,
                  facts.pendingTLSKeyDeletions.isEmpty,
                  facts.pendingTLSKeyCreation?.targetRole == .tlsServer else {
                throw HarcHostError.transportRotationStateMismatch
            }
            return
        }

        guard let intent else {
            let deletionIsHarmlessStagedCleanup = facts.pendingTLSKeyDeletions.isEmpty
                || (facts.pendingTLSKeyDeletions.count == 1
                    && facts.pendingTLSKeyDeletions[0].formerRole == .tlsServerStaged)
            guard facts.stagedTLSSPKISHA256 == nil,
                  facts.retiringTLSSPKISHA256 == nil,
                  facts.pendingTLSKeyCreation == nil,
                  deletionIsHarmlessStagedCleanup,
                  effectiveSPKIs == nil || isExactly(effectiveSPKIs, [active]),
                  currentPublicationKind != .plannedOverlap else {
                throw HarcHostError.transportRotationStateMismatch
            }
            if current == nil {
                guard database.epoch == 0,
                      database.pending == nil
                        || database.pending?.publicationKind == .initial else {
                    throw HarcHostError.transportRotationStateMismatch
                }
            } else if let pendingPublication = database.pending {
                guard pendingPublication.publicationKind == .stableRenewal else {
                    throw HarcHostError.transportRotationStateMismatch
                }
            }
            return
        }

        guard intent.oldTLSSPKISHA256.count == SHA256.byteCount,
              intent.retirementFloorUnixMilliseconds
                == database.retirementFloorUnixMilliseconds,
              current != nil else {
            throw HarcHostError.transportRotationStateMismatch
        }
        switch (intent.startedMode, intent.mode, intent.emergencyEscalatedAt) {
        case (.planned, .planned, nil), (.emergency, .emergency, nil):
            break
        case (.planned, .emergency, .some(let escalatedAt))
            where escalatedAt >= intent.createdAt:
            break
        default:
            throw HarcHostError.transportRotationStateMismatch
        }
        if let pendingPublication = database.pending {
            guard pendingPublication.retirementFloorUnixMilliseconds
                    == intent.retirementFloorUnixMilliseconds else {
                throw HarcHostError.transportRotationStateMismatch
            }
        }

        let old = intent.oldTLSSPKISHA256
        guard let replacement = intent.newTLSSPKISHA256 else {
            let creationIsStaged = facts.pendingTLSKeyCreation == nil
                || facts.pendingTLSKeyCreation?.targetRole == .tlsServerStaged
            guard active == old,
                  facts.retiringTLSSPKISHA256 == nil,
                  facts.pendingTLSKeyDeletions.isEmpty,
                  creationIsStaged,
                  !(facts.stagedTLSSPKISHA256 != nil
                    && facts.pendingTLSKeyCreation != nil),
                  isExactly(currentSPKIs, [old]),
                  pending == nil,
                  currentPublicationKind != .plannedOverlap else {
                throw HarcHostError.transportRotationStateMismatch
            }
            return
        }
        guard replacement.count == SHA256.byteCount, replacement != old else {
            throw HarcHostError.transportRotationStateMismatch
        }

        if active == old {
            guard facts.stagedTLSSPKISHA256 == replacement,
                  facts.retiringTLSSPKISHA256 == nil,
                  facts.pendingTLSKeyCreation == nil,
                  facts.pendingTLSKeyDeletions.isEmpty,
                  isOneOf(currentSPKIs, [[old], [old, replacement]]),
                  isOneOf(effectiveSPKIs, [[old], [old, replacement]]) else {
                throw HarcHostError.transportRotationStateMismatch
            }
            if isExactly(currentSPKIs, [old]) {
                guard currentPublicationKind != .plannedOverlap else {
                    throw HarcHostError.transportRotationStateMismatch
                }
            } else if currentPublicationKind != .plannedOverlap {
                throw HarcHostError.transportRotationStateMismatch
            }
            if let pendingPublication = database.pending {
                guard intent.mode == .planned,
                      pendingPublication.publicationKind == .plannedOverlap,
                      isExactly(pendingSPKIs, [old, replacement]) else {
                    throw HarcHostError.transportRotationStateMismatch
                }
            } else if isExactly(currentSPKIs, [old, replacement]) {
                guard currentPublicationKind == .plannedOverlap,
                      intent.mode == .planned
                        || intent.startedMode == .planned else {
                    throw HarcHostError.transportRotationStateMismatch
                }
            }
            return
        }

        guard active == replacement,
              facts.stagedTLSSPKISHA256 == nil,
              facts.pendingTLSKeyCreation == nil else {
            throw HarcHostError.transportRotationStateMismatch
        }
        let expectedFinalKind: HostTransportPublicationKind = intent.mode == .planned
            ? .plannedFinal
            : .emergency
        if facts.retiringTLSSPKISHA256 == old {
            guard facts.pendingTLSKeyDeletions.isEmpty else {
                throw HarcHostError.transportRotationStateMismatch
            }
            let allowedCurrent = intent.mode == .planned
                ? [[old, replacement], [replacement]]
                : [[old], [old, replacement], [replacement]]
            guard isOneOf(currentSPKIs, allowedCurrent) else {
                throw HarcHostError.transportRotationStateMismatch
            }
            if isExactly(currentSPKIs, [old]),
               currentPublicationKind == .plannedOverlap {
                throw HarcHostError.transportRotationStateMismatch
            }
            if let pendingPublication = database.pending {
                guard pendingPublication.publicationKind == expectedFinalKind,
                      isExactly(pendingSPKIs, [replacement]) else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                switch intent.mode {
                case .planned:
                    guard isExactly(currentSPKIs, [old, replacement]),
                          currentPublicationKind == .plannedOverlap else {
                        throw HarcHostError.transportRotationStateMismatch
                    }
                case .emergency:
                    guard isExactly(currentSPKIs, [old])
                            || (isExactly(currentSPKIs, [old, replacement])
                                && intent.startedMode == .planned
                                && currentPublicationKind == .plannedOverlap) else {
                        throw HarcHostError.transportRotationStateMismatch
                    }
                }
            } else if isExactly(currentSPKIs, [old, replacement]) {
                guard currentPublicationKind == .plannedOverlap,
                      intent.mode == .planned
                        || intent.startedMode == .planned else {
                    throw HarcHostError.transportRotationStateMismatch
                }
            } else if isExactly(currentSPKIs, [replacement]),
                      currentPublicationKind != expectedFinalKind {
                throw HarcHostError.transportRotationStateMismatch
            }
            return
        }

        let deletionIsRetiringCleanup = facts.pendingTLSKeyDeletions.isEmpty
            || (facts.pendingTLSKeyDeletions.count == 1
                && facts.pendingTLSKeyDeletions[0].formerRole == .tlsServerRetiring
                && facts.pendingTLSKeyDeletions[0].publicKey.tlsSPKISHA256 == old)
        guard facts.retiringTLSSPKISHA256 == nil,
              deletionIsRetiringCleanup,
              pending == nil,
              isExactly(currentSPKIs, [replacement]),
              currentPublicationKind == expectedFinalKind else {
            throw HarcHostError.transportRotationStateMismatch
        }
    }

    private func reconcileJournal(
        state: HostCryptographicState
    ) async throws -> HostValidatedTransportSet? {
        let snapshot = try await store.transportDatabaseSnapshot()
        let current = try validateCurrent(
            snapshot: snapshot,
            authorityPublicKey: state.authorityIdentity.publicKey,
            tuple: state.tuple
        )
        guard let pending = snapshot.pending else {
            guard snapshot.epoch == state.highestIssuedTransportSetEpoch else {
                throw HarcHostError.transportSetRollback(
                    databaseEpoch: snapshot.epoch,
                    highWaterEpoch: state.highestIssuedTransportSetEpoch
                )
            }
            return current
        }
        let verifiedPending = try validatePending(
            pending,
            snapshot: snapshot,
            authorityPublicKey: state.authorityIdentity.publicKey,
            tuple: state.tuple
        )
        switch state.highestIssuedTransportSetEpoch {
        case snapshot.epoch:
            _ = try await cryptographicStateStore.advanceHighestIssuedTransportSetEpoch(
                for: state.tuple,
                from: snapshot.epoch,
                to: pending.nextEpoch
            )
        case pending.nextEpoch:
            break
        default:
            throw HarcHostError.transportSetRollback(
                databaseEpoch: snapshot.epoch,
                highWaterEpoch: state.highestIssuedTransportSetEpoch
            )
        }
        try await store.applyPendingTransportSetPublication(
            expected: pending,
            verified: verifiedPending,
            at: now()
        )
        return verifiedPending
    }

    private func validateCurrent(
        snapshot: HostTransportDatabaseSnapshot,
        authorityPublicKey: P256X963PublicKey,
        tuple: HostCryptographicStateTuple
    ) throws -> HostValidatedTransportSet? {
        if snapshot.epoch == 0 {
            guard snapshot.exactSignedBytes == nil, snapshot.objectID == nil else {
                throw HarcHostError.transportSetPendingMismatch
            }
            return nil
        }
        guard let exact = snapshot.exactSignedBytes,
              let objectID = snapshot.objectID else {
            throw HarcHostError.transportSetPendingMismatch
        }
        let verified = try transportSetProtocol.decodeTransportSet(
            HostTransportSetDecodeRequest(
                exactSignedBytes: exact,
                hostAuthorityPublicKey: authorityPublicKey
            )
        )
        guard verified.libraryID == tuple.libraryID,
              verified.hostAuthorityID == tuple.hostAuthorityID,
              verified.setEpoch == snapshot.epoch,
              verified.objectID == objectID else {
            throw HarcHostError.invalidTransportSet("current HostDB exact bytes")
        }
        return verified
    }

    private func validatePending(
        _ pending: HostPendingTransportSetPublication,
        snapshot: HostTransportDatabaseSnapshot,
        authorityPublicKey: P256X963PublicKey,
        tuple: HostCryptographicStateTuple
    ) throws -> HostValidatedTransportSet {
        let verified = try transportSetProtocol.decodeTransportSet(
            HostTransportSetDecodeRequest(
                exactSignedBytes: pending.exactSignedBytes,
                hostAuthorityPublicKey: authorityPublicKey
            )
        )
        let spkis = Set(verified.entries.map(\.tlsSPKISHA256))
        let expected = Set(
            [pending.expectedActiveSPKISHA256]
                + (pending.secondarySPKISHA256.map { [$0] } ?? [])
        )
        guard pending.previousEpoch == snapshot.epoch,
              pending.nextEpoch == snapshot.epoch + 1,
              pending.expectedPreviousObjectID == snapshot.objectID,
              pending.objectID == verified.objectID,
              verified.setEpoch == pending.nextEpoch,
              verified.libraryID == tuple.libraryID,
              verified.hostAuthorityID == tuple.hostAuthorityID,
              spkis == expected,
              pending.retirementFloorUnixMilliseconds
                >= snapshot.retirementFloorUnixMilliseconds else {
            throw HarcHostError.transportSetPendingMismatch
        }
        return verified
    }

    private func publish(
        _ verified: HostValidatedTransportSet,
        state: HostCryptographicState,
        kind: HostTransportPublicationKind,
        secondarySPKISHA256: Data?,
        retirementFloorUnixMilliseconds: UInt64
    ) async throws {
        try await store.prepareTransportSetPublication(
            verified,
            kind: kind,
            expectedActiveSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: secondarySPKISHA256,
            retirementFloorUnixMilliseconds: retirementFloorUnixMilliseconds,
            at: now()
        )
        _ = try await cryptographicStateStore.advanceHighestIssuedTransportSetEpoch(
            for: state.tuple,
            from: state.highestIssuedTransportSetEpoch,
            to: verified.setEpoch
        )
        guard let pending = try await store.transportDatabaseSnapshot().pending else {
            throw HarcHostError.transportSetPendingMismatch
        }
        try await store.applyPendingTransportSetPublication(
            expected: pending,
            verified: verified,
            at: now()
        )
    }

    private func freshTransportSet(
        state: HostCryptographicState,
        epoch: UInt64,
        includeStaged: Bool,
        retirementFloorUnixMilliseconds: UInt64
    ) throws -> HostValidatedTransportSet {
        let nowMilliseconds = try Self.unixMilliseconds(now())
        let notBefore = nowMilliseconds > Self.clockSkewMilliseconds
            ? nowMilliseconds - Self.clockSkewMilliseconds
            : 0
        let notAfterResult = nowMilliseconds.addingReportingOverflow(
            Self.freshLifetimeMilliseconds
        )
        guard !notAfterResult.overflow,
              retirementFloorUnixMilliseconds <= notAfterResult.partialValue else {
            throw HarcHostError.invalidTransportSet("retirement floor exceeds 90-day entry")
        }
        var identities = [state.activeTLSIdentity]
        if includeStaged {
            guard let staged = state.stagedTLSIdentity,
                  state.retiringTLSIdentity == nil else {
                throw HarcHostError.transportRotationStateMismatch
            }
            identities.append(staged)
        }
        let entries = try identities.map {
            try HostValidatedTransportSetEntry(
                tlsSPKISHA256: $0.tlsSPKISHA256,
                notBeforeUnixMilliseconds: notBefore,
                notAfterUnixMilliseconds: notAfterResult.partialValue
            )
        }.sorted {
            $0.tlsSPKISHA256.lexicographicallyPrecedes($1.tlsSPKISHA256)
        }
        return try transportSetProtocol.issueTransportSet(
            HostTransportSetIssueRequest(
                libraryID: state.tuple.libraryID,
                hostAuthorityID: state.tuple.hostAuthorityID,
                setEpoch: epoch,
                issuedAtUnixMilliseconds: nowMilliseconds,
                entries: entries,
                hostAuthoritySigner: state.authorityIdentity
            )
        )
    }

    private func renewCurrentSetIfNeeded(
        state: HostCryptographicState,
        current: HostValidatedTransportSet
    ) async throws -> (HostCryptographicState, HostValidatedTransportSet) {
        let nowMilliseconds = try Self.unixMilliseconds(now())
        let leadMilliseconds = UInt64(Self.renewalLeadTime * 1_000)
        let threshold = nowMilliseconds.addingReportingOverflow(leadMilliseconds)
        if let active = current.entries.first(where: {
            $0.tlsSPKISHA256 == state.activeTLSIdentity.tlsSPKISHA256
        }), active.isValid(atUnixMilliseconds: nowMilliseconds),
           !threshold.overflow,
           active.notAfterUnixMilliseconds > threshold.partialValue {
            return (state, current)
        }
        let snapshot = try await store.transportDatabaseSnapshot()
        let includeStaged = state.stagedTLSIdentity != nil
        let fresh = try freshTransportSet(
            state: state,
            epoch: current.setEpoch + 1,
            includeStaged: includeStaged,
            retirementFloorUnixMilliseconds: snapshot.retirementFloorUnixMilliseconds
        )
        let kind: HostTransportPublicationKind = includeStaged
            ? .plannedOverlap
            : (state.retiringTLSIdentity == nil ? .stableRenewal : .plannedFinal)
        try await publish(
            fresh,
            state: state,
            kind: kind,
            secondarySPKISHA256: state.stagedTLSIdentity?.tlsSPKISHA256,
            retirementFloorUnixMilliseconds: snapshot.retirementFloorUnixMilliseconds
        )
        return (
            try await cryptographicStateStore.load(requiredTuple: cryptographicTuple),
            fresh
        )
    }

    private func resumeDurableRotationIfPossible(
        state initialState: HostCryptographicState,
        current initialCurrent: HostValidatedTransportSet
    ) async throws -> (HostCryptographicState, HostValidatedTransportSet) {
        guard var intent = try await store.transportRotationIntent() else {
            // Protected key roles are not free-standing state. A staged or
            // retiring slot without the exact HostDB intent means HostDB was
            // lost/restored across a key transition (or otherwise corrupted),
            // so serving either key would hide a rollback.
            guard initialState.stagedTLSIdentity == nil,
                  initialState.retiringTLSIdentity == nil,
                  initialCurrent.entries.count == 1,
                  initialCurrent.entries[0].tlsSPKISHA256
                    == initialState.activeTLSIdentity.tlsSPKISHA256 else {
                throw HarcHostError.transportRotationStateMismatch
            }
            return (initialState, initialCurrent)
        }
        var state = initialState
        var current = initialCurrent

        func currentSetIsExactly(_ expectedSPKIs: [Data]) -> Bool {
            current.entries.count == expectedSPKIs.count
                && Set(current.entries.map(\.tlsSPKISHA256))
                    == Set(expectedSPKIs)
        }

        if intent.newTLSSPKISHA256 == nil {
            guard state.activeTLSIdentity.tlsSPKISHA256 == intent.oldTLSSPKISHA256,
                  state.retiringTLSIdentity == nil,
                  currentSetIsExactly([intent.oldTLSSPKISHA256]) else {
                throw HarcHostError.transportRotationStateMismatch
            }
            // Staging the permanent replacement key and binding its SPKI in
            // HostDB are separate durable operations. A crash between them
            // must bind the already-recorded key, never mint a second key or
            // reject an otherwise recoverable rotation intent.
            if state.stagedTLSIdentity == nil {
                state = try await cryptographicStateStore.stageReplacementTLSIdentity(
                    for: cryptographicTuple,
                    expectedActivePublicKey: state.activeTLSIdentity.publicKey
                )
            }
            guard let staged = state.stagedTLSIdentity else {
                throw HarcHostError.transportRotationStateMismatch
            }
            try await store.bindRotationReplacementSPKI(staged.tlsSPKISHA256)
            guard let reboundIntent = try await store.transportRotationIntent() else {
                throw HarcHostError.transportRotationStateMismatch
            }
            intent = reboundIntent
        }
        guard let newSPKI = intent.newTLSSPKISHA256 else {
            throw HarcHostError.transportRotationStateMismatch
        }

        switch intent.mode {
        case .planned:
            if let staged = state.stagedTLSIdentity {
                guard state.activeTLSIdentity.tlsSPKISHA256 == intent.oldTLSSPKISHA256,
                      staged.tlsSPKISHA256 == newSPKI,
                      state.retiringTLSIdentity == nil else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                let expected = Set([intent.oldTLSSPKISHA256, newSPKI])
                if !currentSetIsExactly(Array(expected)) {
                    guard currentSetIsExactly([intent.oldTLSSPKISHA256]) else {
                        throw HarcHostError.transportRotationStateMismatch
                    }
                    let overlap = try freshTransportSet(
                        state: state,
                        epoch: current.setEpoch + 1,
                        includeStaged: true,
                        retirementFloorUnixMilliseconds:
                            intent.retirementFloorUnixMilliseconds
                    )
                    try await publish(
                        overlap,
                        state: state,
                        kind: .plannedOverlap,
                        secondarySPKISHA256: newSPKI,
                        retirementFloorUnixMilliseconds:
                            intent.retirementFloorUnixMilliseconds
                    )
                    current = overlap
                    state = try await cryptographicStateStore.load(
                        requiredTuple: cryptographicTuple
                    )
                }
                // Promotion needs the explicit listener-drain boundary. It is
                // safe to become listener-ready on the still-active old key.
                return (state, current)
            }
            if let retiring = state.retiringTLSIdentity {
                guard state.activeTLSIdentity.tlsSPKISHA256 == newSPKI,
                      retiring.tlsSPKISHA256 == intent.oldTLSSPKISHA256 else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                if !currentSetIsExactly([newSPKI]) {
                    guard currentSetIsExactly([intent.oldTLSSPKISHA256, newSPKI]) else {
                        throw HarcHostError.transportRotationStateMismatch
                    }
                    let final = try freshTransportSet(
                        state: state,
                        epoch: current.setEpoch + 1,
                        includeStaged: false,
                        retirementFloorUnixMilliseconds:
                            intent.retirementFloorUnixMilliseconds
                    )
                    try await publish(
                        final,
                        state: state,
                        kind: .plannedFinal,
                        secondarySPKISHA256: nil,
                        retirementFloorUnixMilliseconds:
                            intent.retirementFloorUnixMilliseconds
                    )
                    current = final
                } else if try await store.transportPublicationKind(
                    epoch: current.setEpoch
                ) != .plannedFinal {
                    throw HarcHostError.transportRotationStateMismatch
                }
                _ = try await resolveOrCreateLeaf(
                    identity: state.activeTLSIdentity,
                    transportSet: current
                )
                state = try await cryptographicStateStore.finalizeRetiringTLSIdentity(
                    for: cryptographicTuple,
                    expectedRetiringPublicKey: retiring.publicKey
                )
                try await store.clearTransportRotationIntent(
                    expectedMode: .planned,
                    expectedOldSPKISHA256: intent.oldTLSSPKISHA256,
                    expectedNewSPKISHA256: newSPKI
                )
                return (state, current)
            }
            // A crash after finalizing the old key but before clearing intent.
            guard state.activeTLSIdentity.tlsSPKISHA256 == newSPKI,
                  state.stagedTLSIdentity == nil,
                  state.retiringTLSIdentity == nil,
                  currentSetIsExactly([newSPKI]),
                  try await store.transportPublicationKind(
                    epoch: current.setEpoch
                  ) == .plannedFinal else {
                throw HarcHostError.transportRotationStateMismatch
            }
            try await store.clearTransportRotationIntent(
                expectedMode: .planned,
                expectedOldSPKISHA256: intent.oldTLSSPKISHA256,
                expectedNewSPKISHA256: newSPKI
            )
            return (state, current)

        case .emergency:
            if let staged = state.stagedTLSIdentity {
                guard state.activeTLSIdentity.tlsSPKISHA256 == intent.oldTLSSPKISHA256,
                      staged.tlsSPKISHA256 == newSPKI,
                      currentSetIsExactly([intent.oldTLSSPKISHA256])
                        || currentSetIsExactly([intent.oldTLSSPKISHA256, newSPKI]) else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                state = try await cryptographicStateStore.promoteStagedTLSIdentity(
                    for: cryptographicTuple,
                    expectedActivePublicKey: state.activeTLSIdentity.publicKey,
                    expectedStagedPublicKey: staged.publicKey
                )
            }
            guard state.activeTLSIdentity.tlsSPKISHA256 == newSPKI,
                  state.stagedTLSIdentity == nil,
                  (state.retiringTLSIdentity?.tlsSPKISHA256
                    == intent.oldTLSSPKISHA256
                    || state.retiringTLSIdentity == nil),
                  currentSetIsExactly([intent.oldTLSSPKISHA256])
                    || currentSetIsExactly([intent.oldTLSSPKISHA256, newSPKI])
                    || currentSetIsExactly([newSPKI]) else {
                throw HarcHostError.transportRotationStateMismatch
            }
            if state.retiringTLSIdentity == nil,
               !currentSetIsExactly([newSPKI]) {
                throw HarcHostError.transportRotationStateMismatch
            }
            let finished = try await finishEmergencyRotation(
                state: state,
                previous: current
            )
            return (
                try await cryptographicStateStore.load(requiredTuple: cryptographicTuple),
                finished.verifiedTransportSet
            )
        }
    }

    private func finishEmergencyRotation(
        state: HostCryptographicState,
        previous: HostValidatedTransportSet
    ) async throws -> HostTransportReadyState {
        guard let intent = try await store.transportRotationIntent(),
              intent.mode == .emergency,
              let newSPKI = intent.newTLSSPKISHA256,
              state.activeTLSIdentity.tlsSPKISHA256 == newSPKI,
              state.stagedTLSIdentity == nil,
              (state.retiringTLSIdentity?.tlsSPKISHA256 == intent.oldTLSSPKISHA256
                || state.retiringTLSIdentity == nil) else {
            throw HarcHostError.transportRotationStateMismatch
        }
        let emergency: HostValidatedTransportSet
        if previous.entries.count == 1,
           previous.entries[0].tlsSPKISHA256 == newSPKI,
           try await store.transportPublicationKind(
                epoch: previous.setEpoch
           ) == .emergency {
            emergency = previous
        } else {
            emergency = try freshTransportSet(
                state: state,
                epoch: previous.setEpoch + 1,
                includeStaged: false,
                retirementFloorUnixMilliseconds: intent.retirementFloorUnixMilliseconds
            )
            try await publish(
                emergency,
                state: state,
                kind: .emergency,
                secondarySPKISHA256: nil,
                retirementFloorUnixMilliseconds: intent.retirementFloorUnixMilliseconds
            )
        }
        let identity = try await resolveOrCreateLeaf(
            identity: state.activeTLSIdentity,
            transportSet: emergency
        )
        if let retiring = state.retiringTLSIdentity {
            _ = try await cryptographicStateStore.finalizeRetiringTLSIdentity(
                for: cryptographicTuple,
                expectedRetiringPublicKey: retiring.publicKey
            )
        }
        try await store.clearTransportRotationIntent(
            expectedMode: .emergency,
            expectedOldSPKISHA256: intent.oldTLSSPKISHA256,
            expectedNewSPKISHA256: newSPKI
        )
        return HostTransportReadyState(
            verifiedTransportSet: emergency,
            serverIdentity: identity,
            retirementFloorUnixMilliseconds: intent.retirementFloorUnixMilliseconds,
            rotationIntent: nil
        )
    }

    private func resolveOrCreateLeaf(
        identity: HostTLSSigningIdentity,
        transportSet: HostValidatedTransportSet
    ) async throws -> HostTLSServerIdentity {
        guard let entry = transportSet.entries.first(where: {
            $0.tlsSPKISHA256 == identity.tlsSPKISHA256
        }) else {
            throw HarcHostError.tlsLeafMismatch("active SPKI missing from transport set")
        }
        let request = try HostTLSServerCertificateRequest(
            transportSetEntryNotBefore: Self.date(entry.notBeforeUnixMilliseconds),
            transportSetEntryNotAfter: Self.date(entry.notAfterUnixMilliseconds),
            expectedTLSSPKISHA256: identity.tlsSPKISHA256,
            framedSignedTransportSet: transportSet.exactSignedBytes
        )
        let exactDER: Data
        if let persisted = try await store.persistedTLSLeaf(
            transportEpoch: transportSet.setEpoch,
            tlsSPKISHA256: identity.tlsSPKISHA256
        ) {
            exactDER = persisted
        } else {
            let candidate = try identity.issueServerCertificate(request: request)
            exactDER = try await store.persistTLSLeaf(
                candidate,
                for: transportSet,
                at: now()
            )
        }
        // Revalidation happens inside resolveServerIdentity even for a row
        // loaded from an existing database or won by another concurrent issuer.
        return try identity.resolveServerIdentity(
            certificateDER: exactDER,
            request: request
        )
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else {
            throw HarcHostError.invalidTransportSet("Unix millisecond time")
        }
        return UInt64(milliseconds.rounded(.down))
    }

    private static func date(_ unixMilliseconds: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000)
    }

    /// Swift actors are reentrant at every persistence await. Hold a FIFO gate
    /// across each complete public lifecycle operation so capability-floor
    /// reservations cannot interleave with the phase boundaries of publication
    /// or key rotation.
    private func acquireOperationGate() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationGate() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

extension HarcHostStore {
    func transportRotationIntent() async throws -> HostTransportRotationIntent? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_transport_rotation_intent WHERE singleton = 1"
            ) else { return nil }
            guard let startedMode = HostTransportRotationMode(
                rawValue: row["started_mode"] as String
            ), let mode = HostTransportRotationMode(rawValue: row["mode"] as String) else {
                throw HarcHostError.transportRotationStateMismatch
            }
            return HostTransportRotationIntent(
                startedMode: startedMode,
                mode: mode,
                oldTLSSPKISHA256: row["old_spki_sha256"],
                newTLSSPKISHA256: row["new_spki_sha256"],
                retirementFloorUnixMilliseconds: try Self.unsigned(
                    row["retirement_floor_unix_ms"] as Int64,
                    field: "rotationRetirementFloorUnixMilliseconds"
                ),
                createdAt: Self.date(row["created_at"] as Double),
                emergencyEscalatedAt: (row["emergency_escalated_at"] as Double?)
                    .map(Self.date)
            )
        }
    }

    func beginPlannedTransportRotation(
        oldSPKISHA256: Data,
        retirementFloorUnixMilliseconds: UInt64,
        at date: Date
    ) async throws {
        try await insertPlannedRotationIntent(
            oldSPKISHA256: oldSPKISHA256,
            retirementFloorUnixMilliseconds: retirementFloorUnixMilliseconds,
            at: date
        )
    }

    private func insertPlannedRotationIntent(
        oldSPKISHA256: Data,
        retirementFloorUnixMilliseconds: UInt64,
        at date: Date
    ) async throws {
        guard oldSPKISHA256.count == SHA256.byteCount else {
            throw HarcHostError.invalidTransportSet("rotation old SPKI")
        }
        let floor = try Self.sqliteInteger(
            retirementFloorUnixMilliseconds,
            field: "rotationRetirementFloorUnixMilliseconds"
        )
        let timestamp = Self.unixTime(date)
        try await dbQueue.write { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM host_transport_rotation_intent"
            ) == 0,
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_transport_set_publications"
            ) == 0,
            let currentFloor = try Int64.fetchOne(
                db,
                sql: """
                    SELECT leaf_retirement_floor
                    FROM host_metadata WHERE singleton = 1
                    """
            ), currentFloor == floor else {
                throw HarcHostError.transportSetTransitionInProgress
            }
            try db.execute(
                sql: """
                    INSERT INTO host_transport_rotation_intent (
                        singleton, started_mode, mode, old_spki_sha256,
                        new_spki_sha256, retirement_floor_unix_ms,
                        created_at, emergency_escalated_at
                    ) VALUES (1, 'planned', 'planned', ?, NULL, ?, ?, NULL)
                    """,
                arguments: [oldSPKISHA256, floor, timestamp]
            )
        }
    }

    func bindRotationReplacementSPKI(_ spkiSHA256: Data) async throws {
        guard spkiSHA256.count == SHA256.byteCount else {
            throw HarcHostError.invalidTransportSet("rotation new SPKI")
        }
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_transport_rotation_intent WHERE singleton = 1"
            ), (row["new_spki_sha256"] as Data?) == nil,
               (row["old_spki_sha256"] as Data) != spkiSHA256 else {
                throw HarcHostError.transportRotationStateMismatch
            }
            try db.execute(
                sql: """
                    UPDATE host_transport_rotation_intent
                       SET new_spki_sha256 = ? WHERE singleton = 1
                    """,
                arguments: [spkiSHA256]
            )
        }
    }

    func clearTransportRotationIntent(
        expectedMode: HostTransportRotationMode,
        expectedOldSPKISHA256: Data,
        expectedNewSPKISHA256: Data
    ) async throws {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_transport_rotation_intent WHERE singleton = 1"
            ), (row["mode"] as String) == expectedMode.rawValue,
               (row["old_spki_sha256"] as Data) == expectedOldSPKISHA256,
               (row["new_spki_sha256"] as Data?) == expectedNewSPKISHA256,
               try Int.fetchOne(
                   db,
                   sql: "SELECT COUNT(*) FROM pending_transport_set_publications"
               ) == 0 else {
                throw HarcHostError.transportRotationStateMismatch
            }
            try db.execute(
                sql: "DELETE FROM host_transport_rotation_intent WHERE singleton = 1"
            )
        }
    }

    func reserveCapabilityTransportWindow(
        expectedEpoch: UInt64,
        expectedObjectID: Data,
        proposedRetirementFloorUnixMilliseconds: UInt64,
        extendRetirementFloor: Bool,
        at date: Date
    ) async throws -> HostCapabilityTransportReservation {
        let epoch = try Self.sqliteInteger(expectedEpoch, field: "transportEpoch")
        let proposedFloor = try Self.sqliteInteger(
            proposedRetirementFloorUnixMilliseconds,
            field: "retirementFloorUnixMilliseconds"
        )
        return try await dbQueue.write { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_transport_set_publications"
            ) == 0,
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_metadata WHERE singleton = 1"
            ), (row["highest_transport_set_epoch"] as Int64) == epoch,
               (row["transport_set_object_sha256"] as Data?) == expectedObjectID,
               let exact: Data = row["exact_transport_set_bytes"] else {
                throw HarcHostError.transportSetTransitionInProgress
            }
            let oldFloor = row["leaf_retirement_floor"] as Int64
            let resultingFloor = extendRetirementFloor
                ? max(oldFloor, proposedFloor)
                : oldFloor
            if resultingFloor != oldFloor {
                try db.execute(
                    sql: """
                        UPDATE host_metadata
                           SET leaf_retirement_floor = ?, updated_at = ?
                         WHERE singleton = 1
                    """,
                    arguments: [resultingFloor, Self.unixTime(date)]
                )
            }
            return HostCapabilityTransportReservation(
                minimumTransportSetEpoch: expectedEpoch,
                exactSignedTransportSet: exact,
                retirementFloorUnixMilliseconds: try Self.unsigned(
                    resultingFloor,
                    field: "retirementFloorUnixMilliseconds"
                )
            )
        }
    }
}
