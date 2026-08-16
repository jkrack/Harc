import Foundation
import GRDB
import HarcDomain
import HarcIdentity

struct ActiveSecurityRegistryRepair: Sendable {
    let id: UUID
    let task: Task<Void, any Error>
}

extension HarcHostStore {
    /// Executes the exact three durable phases required by the security
    /// registry: pending HostDB row, high-water advance, final HostDB apply.
    private func applySecurityRegistryMutation(
        _ mutation: SecurityRegistryMutation
    ) async throws {
        try await repairSecurityRegistryUnderAuthorityMutation()
        guard !securityRegistryTransitionActive else {
            throw HarcHostError.securityRegistryTransitionInProgress
        }
        securityRegistryTransitionActive = true
        defer { securityRegistryTransitionActive = false }

        if try await isSecurityMutationAlreadyApplied(mutation) { return }
        try await securityFailureInjector.hit(.beforePendingMutation)

        let currentRevision = try await registryRevision()
        guard currentRevision < UInt64.max else {
            throw HarcHostError.securityMutationInvalid("The registry revision is exhausted.")
        }
        let nextRevision = currentRevision + 1
        let revisionValue = try Self.sqliteInteger(nextRevision, field: "securityRegistryRevision")
        let mutationBytes = try Self.encode(mutation)

        try await dbQueue.write { db in
            // Capture ticket acceptance only once the durable-pending
            // transaction has begun, rather than before waiting for SQLite.
            let pendingCreatedAt = self.now()
            guard pendingCreatedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw HarcHostError.securityMutationInvalid("The pending transition time is invalid.")
            }
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_security_mutations"
            ) == 0 else {
                throw HarcHostError.securityMutationAlreadyPending
            }
            guard try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM host_transport_rotation_intent
                    WHERE mode = 'emergency'
                    """
            ) == 0 else {
                throw HarcHostError.hostAuthorityMutationConflict
            }
            try self.validateSecurityMutation(
                mutation,
                initialGrantAcceptedAt: pendingCreatedAt,
                in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO pending_security_mutations (
                        singleton, registry_revision, mutation_kind, device_id,
                        mutation_json, created_at
                    ) VALUES (1, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    revisionValue,
                    mutation.kind.rawValue,
                    mutation.deviceID.rawBytes,
                    mutationBytes,
                    Self.unixTime(pendingCreatedAt),
                ]
            )
        }

        try await securityFailureInjector.hit(.afterPendingMutation)
        try await highWaterMarkStore.advanceRegistryRevision(
            from: currentRevision,
            to: nextRevision
        )
        try await securityFailureInjector.hit(.afterHighWaterAdvance)
        try await securityFailureInjector.hit(.beforeFinalDatabaseApply)
        try await applyPendingSecurityMutation(
            mutation,
            revision: nextRevision,
            appliedAt: now()
        )
        try await securityFailureInjector.hit(.afterFinalDatabaseApply)
    }

    public func issueDeviceGrant(
        _ grant: DeviceGrantClaims,
        exactGrantBytes: Data,
        pairingTicketID: UUID
    ) async throws {
        try await withSecurityRegistryMutationExclusion { [self] in
            let clientKind = try await self.pairingTicketClientKind(pairingTicketID)
            if ScopePolicy.initialGrantRequiresOSAuthentication(
                scopes: grant.scopes,
                for: clientKind
            ) {
                guard try await self.localOSAuthenticationBoundary
                    .authorizeInitialGrantExpansion(
                        for: grant.deviceID,
                        clientKind: clientKind,
                        requestedScopes: grant.scopes
                    ) else {
                    throw HarcHostError.localOSAuthenticationRequired
                }
            }
            try await self.applySecurityRegistryMutation(
                .issueGrant(
                    entry: DeviceRegistryEntry(activeGrant: grant),
                    grant: grant,
                    exactGrantBytes: exactGrantBytes,
                    pairingTicketID: pairingTicketID
                )
            )
        }
    }

    /// Fixture/bootstrap seam for tests that need an already-adopted device.
    /// Production grant issuance must use `issueDeviceGrant` and a live,
    /// locally-approved ticket reserved to the exact device public key.
    func seedDeviceGrantForTesting(
        _ grant: DeviceGrantClaims,
        exactGrantBytes: Data
    ) async throws {
        try await withSecurityRegistryMutationExclusion { [self] in
            try await self.applySecurityRegistryMutation(
                .issueGrant(
                    entry: DeviceRegistryEntry(activeGrant: grant),
                    grant: grant,
                    exactGrantBytes: exactGrantBytes,
                    pairingTicketID: nil
                )
            )
        }
    }

    public func replaceDeviceGrant(
        _ grant: DeviceGrantClaims,
        exactGrantBytes: Data
    ) async throws {
        try await withSecurityRegistryMutationExclusion { [self] in
            guard let current = try await self.deviceRegistryEntry(
                deviceID: grant.deviceID
            ) else {
                throw HarcHostError.unknownDevice
            }
            if current.currentScopes != grant.scopes,
               ScopePolicy.scopeChangeRequiresOSAuthentication {
                guard try await self.localOSAuthenticationBoundary.authorizeGrantScopeChange(
                    for: grant.deviceID,
                    currentScopes: current.currentScopes,
                    requestedScopes: grant.scopes
                ) else {
                    throw HarcHostError.localOSAuthenticationRequired
                }
            }
            try await self.applySecurityRegistryMutation(
                .replaceGrant(
                    entry: DeviceRegistryEntry(activeGrant: grant),
                    grant: grant,
                    exactGrantBytes: exactGrantBytes
                )
            )
        }
    }

    /// Re-adopts an installation whose signing key already has a registry
    /// entry. This local-only operation always crosses the interactive OS-auth
    /// boundary before it can create the journal's durable pending phase.
    public func readoptDevice(
        _ grant: DeviceGrantClaims,
        exactGrantBytes: Data,
        pairingTicketID: UUID
    ) async throws {
        try await withSecurityRegistryMutationExclusion { [self] in
            let requiresTrustRepair = try await self.deviceRequiresTransportTrustRepair(
                deviceID: grant.deviceID
            )
            guard !requiresTrustRepair else {
                throw HarcHostError.emergencyTrustRepairRequired
            }
            guard try await self.localOSAuthenticationBoundary.authorizeSameKeyReadoption(
                for: grant.deviceID
            ) else {
                throw HarcHostError.localOSAuthenticationRequired
            }
            try await self.applySecurityRegistryMutation(
                .readoptGrant(
                    entry: DeviceRegistryEntry(activeGrant: grant),
                    grant: grant,
                    exactGrantBytes: exactGrantBytes,
                    pairingTicketID: pairingTicketID
                )
            )
        }
    }

    /// Explicit, locally-visible re-adoption path after emergency TLS-key
    /// replacement. A distinct durable mutation keeps crash recovery from ever
    /// treating an ordinary same-key readoption as permission to clear the
    /// emergency trust-repair gate.
    public func repairTransportTrust(
        _ grant: DeviceGrantClaims,
        exactGrantBytes: Data,
        pairingTicketID: UUID
    ) async throws {
        try await withSecurityRegistryMutationExclusion { [self] in
            let requiresTrustRepair = try await self.deviceRequiresTransportTrustRepair(
                deviceID: grant.deviceID
            )
            guard requiresTrustRepair else {
                throw HarcHostError.securityMutationInvalid(
                    "The device does not require emergency transport-trust repair."
                )
            }
            guard try await self.localOSAuthenticationBoundary.authorizeSameKeyReadoption(
                for: grant.deviceID
            ) else {
                throw HarcHostError.localOSAuthenticationRequired
            }
            try await self.applySecurityRegistryMutation(
                .repairTransportTrustGrant(
                    entry: DeviceRegistryEntry(activeGrant: grant),
                    grant: grant,
                    exactGrantBytes: exactGrantBytes,
                    pairingTicketID: pairingTicketID
                )
            )
        }
    }

    public func revokeDevice(
        _ deviceID: DeviceID,
        revocationID: UUID,
        reasonCode: String,
        exactRevocationBytes: Data
    ) async throws {
        let issuedAt = now()
        try await withSecurityRegistryMutationExclusion { [self] in
            try await self.revokeDeviceUnderAuthorityMutation(
                deviceID,
                revocationID: revocationID,
                reasonCode: reasonCode,
                exactRevocationBytes: exactRevocationBytes,
                issuedAt: issuedAt
            )
        }
    }

    /// Deterministic `@testable` seam. Production revocation issuance always
    /// derives its time from the store's injected clock.
    func revokeDevice(
        _ deviceID: DeviceID,
        revocationID: UUID,
        reasonCode: String,
        exactRevocationBytes: Data,
        issuedAt: Date
    ) async throws {
        try await withSecurityRegistryMutationExclusion { [self] in
            try await self.revokeDeviceUnderAuthorityMutation(
                deviceID,
                revocationID: revocationID,
                reasonCode: reasonCode,
                exactRevocationBytes: exactRevocationBytes,
                issuedAt: issuedAt
            )
        }
    }

    private func revokeDeviceUnderAuthorityMutation(
        _ deviceID: DeviceID,
        revocationID: UUID,
        reasonCode: String,
        exactRevocationBytes: Data,
        issuedAt: Date
    ) async throws {
        let current = try await deviceRegistryEntry(deviceID: deviceID)
        guard let current else { throw HarcHostError.unknownDevice }
        let result = try current.revoking(
            revocationID: revocationID,
            reasonCode: reasonCode,
            issuedAt: issuedAt
        )
        try await applySecurityRegistryMutation(
            .revokeDevice(
                entry: result.entry,
                revocation: result.revocation,
                exactRevocationBytes: exactRevocationBytes
            )
        )
    }

    private nonisolated func withSecurityRegistryMutationExclusion<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await authorityMutationCoordinator.withExclusiveMutation(
            .securityRegistry,
            operation: operation
        )
    }

    public func deviceRegistryEntry(deviceID: DeviceID) async throws -> DeviceRegistryEntry? {
        try await dbQueue.read { db in
            guard let bytes = try Data.fetchOne(
                db,
                sql: "SELECT registry_entry_json FROM devices WHERE device_id = ?",
                arguments: [deviceID.rawBytes]
            ) else { return nil }
            return try Self.decode(DeviceRegistryEntry.self, from: bytes)
        }
    }

    func deviceRequiresTransportTrustRepair(deviceID: DeviceID) async throws -> Bool {
        try await dbQueue.read { db in
            guard let required = try Int.fetchOne(
                db,
                sql: "SELECT trust_repair_required FROM devices WHERE device_id = ?",
                arguments: [deviceID.rawBytes]
            ) else {
                throw HarcHostError.unknownDevice
            }
            guard required == 0 || required == 1 else {
                throw HarcHostError.databaseFailure(
                    "The durable transport-trust repair flag is malformed."
                )
            }
            return required == 1
        }
    }

    private func pairingTicketClientKind(
        _ ticketID: UUID
    ) async throws -> AdoptedClientKind {
        try await dbQueue.read { db in
            guard let rawValue = try String.fetchOne(
                db,
                sql: "SELECT client_kind FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            ) else {
                throw HarcHostError.securityMutationInvalid(
                    "Pairing ticket is not locally approved."
                )
            }
            guard let clientKind = AdoptedClientKind(rawValue: rawValue) else {
                throw HarcHostError.databaseFailure(
                    "Pairing ticket contains an unknown durable client kind."
                )
            }
            return clientKind
        }
    }

    public func exactCurrentGrantBytes(deviceID: DeviceID) async throws -> Data? {
        try await dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: """
                    SELECT exact_grant_bytes FROM grants
                    WHERE device_id = ? AND is_current = 1
                    """,
                arguments: [deviceID.rawBytes]
            )
        }
    }

    func repairSecurityRegistryOnReopen() async throws {
        try await withSecurityRegistryMutationExclusion { [self] in
            try await self.repairSecurityRegistryUnderAuthorityMutation()
        }
    }

    private func repairSecurityRegistryUnderAuthorityMutation() async throws {
        if let active = activeSecurityRegistryRepair {
            try await active.task.value
            return
        }
        guard !securityRegistryTransitionActive else {
            throw HarcHostError.securityRegistryTransitionInProgress
        }
        securityRegistryTransitionActive = true
        let repairID = UUID()
        let repairTask = Task { try await self.performSecurityRegistryRepair() }
        activeSecurityRegistryRepair = ActiveSecurityRegistryRepair(
            id: repairID,
            task: repairTask
        )
        do {
            try await repairTask.value
            finishSecurityRegistryRepair(id: repairID)
        } catch {
            finishSecurityRegistryRepair(id: repairID)
            throw error
        }
    }

    private func finishSecurityRegistryRepair(id: UUID) {
        guard activeSecurityRegistryRepair?.id == id else { return }
        activeSecurityRegistryRepair = nil
        securityRegistryTransitionActive = false
    }

    private func performSecurityRegistryRepair() async throws {
        struct Snapshot: Sendable {
            let databaseRevision: UInt64
            let pendingRevision: UInt64?
            let pendingMutation: SecurityRegistryMutation?
            let pendingCreatedAt: Date?
            let emergencyTransportIntentPresent: Bool
        }

        let snapshot: Snapshot = try await dbQueue.read { db in
            guard let dbRevisionValue = try Int64.fetchOne(
                db,
                sql: "SELECT security_registry_revision FROM host_metadata WHERE singleton = 1"
            ) else { throw HarcHostError.metadataMismatch }
            let databaseRevision = try Self.unsigned(
                dbRevisionValue,
                field: "securityRegistryRevision"
            )
            let emergencyTransportIntentPresent = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM host_transport_rotation_intent
                    WHERE mode = 'emergency'
                    """
            ) == 1
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT registry_revision, mutation_json, created_at FROM pending_security_mutations WHERE singleton = 1"
            ) else {
                return Snapshot(
                    databaseRevision: databaseRevision,
                    pendingRevision: nil,
                    pendingMutation: nil,
                    pendingCreatedAt: nil,
                    emergencyTransportIntentPresent: emergencyTransportIntentPresent
                )
            }
            let pendingRevision = try Self.unsigned(
                row["registry_revision"] as Int64,
                field: "pendingSecurityRegistryRevision"
            )
            let mutation = try Self.decode(
                SecurityRegistryMutation.self,
                from: row["mutation_json"] as Data
            )
            return Snapshot(
                databaseRevision: databaseRevision,
                pendingRevision: pendingRevision,
                pendingMutation: mutation,
                pendingCreatedAt: Self.date(row["created_at"] as Double),
                emergencyTransportIntentPresent: emergencyTransportIntentPresent
            )
        }

        let mark = try await highWaterMarkStore.loadRegistryRevision()
        guard let pendingRevision = snapshot.pendingRevision,
              let pendingMutation = snapshot.pendingMutation,
              let pendingCreatedAt = snapshot.pendingCreatedAt else {
            guard mark == snapshot.databaseRevision else {
                throw HarcHostError.securityRegistryRollback(
                    databaseRevision: snapshot.databaseRevision,
                    highWaterRevision: mark
                )
            }
            return
        }

        guard snapshot.databaseRevision < UInt64.max,
              pendingRevision == snapshot.databaseRevision + 1,
              !snapshot.emergencyTransportIntentPresent else {
            if snapshot.emergencyTransportIntentPresent {
                throw HarcHostError.hostAuthorityMutationConflict
            }
            throw HarcHostError.securityRegistryPendingMismatch
        }

        // Validate the exact pending mutation against the current DB before a
        // Keychain high-water advance. Corrupt pending bytes must fail closed
        // without moving the external monotonic mark.
        try await dbQueue.read { db in
            try self.validateSecurityMutation(
                pendingMutation,
                initialGrantAcceptedAt: pendingCreatedAt,
                in: db
            )
        }

        switch mark {
        case snapshot.databaseRevision:
            try await highWaterMarkStore.advanceRegistryRevision(
                from: snapshot.databaseRevision,
                to: pendingRevision
            )
        case pendingRevision:
            break
        default:
            throw HarcHostError.securityRegistryRollback(
                databaseRevision: snapshot.databaseRevision,
                highWaterRevision: mark
            )
        }
        try await applyPendingSecurityMutation(
            pendingMutation,
            revision: pendingRevision,
            appliedAt: now()
        )
    }

    /// Phase one of production serving recovery. This method is read-only: it
    /// validates the exact pending security row, its semantic effect against the
    /// current registry, the external mark supplied from the protected host
    /// record, and the independently composed high-water store. The transport
    /// lifecycle must finish its own read-only inspection before calling the
    /// reconciliation phase below.
    package func preflightSecurityRegistry(
        protectedRevision: UInt64
    ) async throws -> HostSecurityRegistryPreflightPlan {
        guard deferredServingBootstrapState == .awaitingSecurityPreflight else {
            throw HarcHostError.deferredServingBootstrapRequired
        }
        return try await readAndValidateSecurityRegistryPreflight(
            protectedRevision: protectedRevision
        )
    }

    /// Applies only the exact plan previously inspected. Callers hold
    /// `withServingRecoverySecurityExclusion` across security and transport
    /// preflight/reconciliation so no new phase-A mutation can appear between
    /// the two journals' read-only validation and activation.
    package func reconcileSecurityRegistry(
        using plan: HostSecurityRegistryPreflightPlan
    ) async throws {
        guard deferredServingBootstrapState == .awaitingSecurityPreflight,
              !securityRegistryTransitionActive else {
            throw HarcHostError.deferredServingBootstrapRequired
        }
        let current = try await readAndValidateSecurityRegistryPreflight(
            protectedRevision: plan.protectedRevision
        )
        guard current == plan else {
            throw HarcHostError.deferredServingPreflightMismatch
        }

        securityRegistryTransitionActive = true
        defer { securityRegistryTransitionActive = false }
        if let pendingRevision = plan.pendingRevision,
           let pendingMutation = plan.pendingMutation {
            switch plan.protectedRevision {
            case plan.databaseRevision:
                try await highWaterMarkStore.advanceRegistryRevision(
                    from: plan.databaseRevision,
                    to: pendingRevision
                )
            case pendingRevision:
                break
            default:
                throw HarcHostError.securityRegistryRollback(
                    databaseRevision: plan.databaseRevision,
                    highWaterRevision: plan.protectedRevision
                )
            }
            try await applyPendingSecurityMutation(
                pendingMutation,
                revision: pendingRevision,
                appliedAt: now()
            )
        }
        deferredServingBootstrapState = .securityReconciled
    }

    private func readAndValidateSecurityRegistryPreflight(
        protectedRevision: UInt64
    ) async throws -> HostSecurityRegistryPreflightPlan {
        let plan = try await dbQueue.read { db in
            guard let dbRevisionValue = try Int64.fetchOne(
                db,
                sql: "SELECT security_registry_revision FROM host_metadata WHERE singleton = 1"
            ) else {
                throw HarcHostError.metadataMismatch
            }
            let databaseRevision = try Self.unsigned(
                dbRevisionValue,
                field: "securityRegistryRevision"
            )
            let emergencyCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM host_transport_rotation_intent
                    WHERE mode = 'emergency'
                    """
            ) ?? 0
            guard emergencyCount == 0 || emergencyCount == 1 else {
                throw HarcHostError.hostAuthorityMutationConflict
            }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pending_security_mutations WHERE singleton = 1"
            ) else {
                return HostSecurityRegistryPreflightPlan(
                    databaseRevision: databaseRevision,
                    protectedRevision: protectedRevision,
                    pendingRevision: nil,
                    exactPendingMutationJSON: nil,
                    pendingMutation: nil,
                    pendingCreatedAt: nil,
                    emergencyTransportIntentPresent: emergencyCount == 1
                )
            }
            let exactJSON: Data = row["mutation_json"]
            let mutation = try Self.decode(
                SecurityRegistryMutation.self,
                from: exactJSON
            )
            guard (row["mutation_kind"] as String) == mutation.kind.rawValue,
                  (row["device_id"] as Data) == mutation.deviceID.rawBytes else {
                throw HarcHostError.securityRegistryPendingMismatch
            }
            return HostSecurityRegistryPreflightPlan(
                databaseRevision: databaseRevision,
                protectedRevision: protectedRevision,
                pendingRevision: try Self.unsigned(
                    row["registry_revision"] as Int64,
                    field: "pendingSecurityRegistryRevision"
                ),
                exactPendingMutationJSON: exactJSON,
                pendingMutation: mutation,
                pendingCreatedAt: Self.date(row["created_at"] as Double),
                emergencyTransportIntentPresent: emergencyCount == 1
            )
        }

        let observedProtectedRevision = try await highWaterMarkStore.loadRegistryRevision()
        guard observedProtectedRevision == protectedRevision else {
            throw HarcHostError.deferredServingPreflightMismatch
        }
        guard let pendingRevision = plan.pendingRevision,
              let pendingMutation = plan.pendingMutation,
              let pendingCreatedAt = plan.pendingCreatedAt,
              plan.exactPendingMutationJSON != nil else {
            guard plan.pendingRevision == nil,
                  plan.pendingMutation == nil,
                  plan.pendingCreatedAt == nil,
                  plan.exactPendingMutationJSON == nil,
                  protectedRevision == plan.databaseRevision else {
                throw HarcHostError.securityRegistryRollback(
                    databaseRevision: plan.databaseRevision,
                    highWaterRevision: protectedRevision
                )
            }
            return plan
        }
        guard !plan.emergencyTransportIntentPresent else {
            throw HarcHostError.hostAuthorityMutationConflict
        }
        guard plan.databaseRevision < UInt64.max,
              pendingRevision == plan.databaseRevision + 1,
              (protectedRevision == plan.databaseRevision
                || protectedRevision == pendingRevision) else {
            throw HarcHostError.securityRegistryPendingMismatch
        }
        try await dbQueue.read { db in
            try self.validateSecurityMutation(
                pendingMutation,
                initialGrantAcceptedAt: pendingCreatedAt,
                in: db
            )
        }
        return plan
    }

    private func isSecurityMutationAlreadyApplied(
        _ mutation: SecurityRegistryMutation
    ) async throws -> Bool {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT registry_entry_json, trust_repair_required FROM devices WHERE device_id = ?",
                arguments: [mutation.deviceID.rawBytes]
            ) else { return false }
            let current = try Self.decode(
                DeviceRegistryEntry.self,
                from: row["registry_entry_json"] as Data
            )
            switch mutation {
            case .issueGrant(let entry, let grant, let exactBytes, _),
                 .replaceGrant(let entry, let grant, let exactBytes),
                 .readoptGrant(let entry, let grant, let exactBytes, _),
                 .repairTransportTrustGrant(
                    let entry,
                    let grant,
                    let exactBytes,
                    _
                 ):
                guard current == entry else { return false }
                let exactBytesMatch = try Data.fetchOne(
                    db,
                    sql: """
                        SELECT exact_grant_bytes FROM grants
                        WHERE grant_id = ? AND grant_epoch = ?
                        """,
                    arguments: [
                        grant.grantID.description,
                        Self.sqliteInteger(grant.grantEpoch.rawValue, field: "grantEpoch"),
                    ]
                ) == exactBytes
                if mutation.kind == .repairTransportTrustGrant {
                    return exactBytesMatch
                        && row["trust_repair_required"] as Int == 0
                }
                return exactBytesMatch
            case .revokeDevice(let entry, let revocation, let exactBytes):
                guard current == entry else { return false }
                return try Data.fetchOne(
                    db,
                    sql: "SELECT exact_revocation_bytes FROM revocations WHERE revocation_id = ?",
                    arguments: [revocation.revocationID.uuidString.lowercased()]
                ) == exactBytes
            }
        }
    }

    nonisolated private func validateSecurityMutation(
        _ mutation: SecurityRegistryMutation,
        initialGrantAcceptedAt: Date?,
        in db: Database
    ) throws {
        func validateShared(entry: DeviceRegistryEntry) throws {
            guard entry.libraryID == expectedMetadata.libraryID,
                  entry.hostAuthorityID == expectedMetadata.hostAuthorityID,
                  entry.devicePublicKey.deviceID == entry.deviceID else {
                throw HarcHostError.securityMutationInvalid("Host or device identity mismatch.")
            }
        }

        let existingRow = try Row.fetchOne(
            db,
            sql: "SELECT registry_entry_json, trust_repair_required FROM devices WHERE device_id = ?",
            arguments: [mutation.deviceID.rawBytes]
        )
        let existing = try existingRow.map {
            try Self.decode(
                DeviceRegistryEntry.self,
                from: $0["registry_entry_json"] as Data
            )
        }
        let trustRepairRequired = existingRow?["trust_repair_required"] as Int? == 1

        func validateApprovedPairingTicket(
            _ ticketID: UUID,
            reservedFor deviceID: DeviceID
        ) throws {
            guard let ticket = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, issued_at, expires_at, reserved_device_id
                    FROM pairing_tickets WHERE ticket_id = ?
                    """,
                arguments: [ticketID.uuidString.lowercased()]
            ), ticket["state"] as String == PairingTicketState.approved.rawValue else {
                throw HarcHostError.securityMutationInvalid("Pairing ticket is not locally approved.")
            }
            guard ticket["reserved_device_id"] as Data? == deviceID.rawBytes else {
                throw HarcHostError.securityMutationInvalid("Pairing ticket is reserved to a different device.")
            }
            guard let initialGrantAcceptedAt,
                  initialGrantAcceptedAt.timeIntervalSinceReferenceDate.isFinite,
                  Self.unixTime(initialGrantAcceptedAt) >= ticket["issued_at"] as Double,
                  Self.unixTime(initialGrantAcceptedAt) < ticket["expires_at"] as Double else {
                throw HarcHostError.securityMutationInvalid(
                    "Pairing ticket expired before the grant transition became durable."
                )
            }
        }

        switch mutation {
        case .issueGrant(let entry, let grant, let exactBytes, let ticketID):
            try validateShared(entry: entry)
            guard !exactBytes.isEmpty,
                  existing == nil,
                  entry == DeviceRegistryEntry(activeGrant: grant),
                  grant.grantEpoch == .initial else {
                throw HarcHostError.securityMutationInvalid("Initial grant fields or epoch are invalid.")
            }
            if let ticketID {
                try validateApprovedPairingTicket(ticketID, reservedFor: grant.deviceID)
            }
        case .replaceGrant(let entry, let grant, let exactBytes):
            try validateShared(entry: entry)
            guard !exactBytes.isEmpty,
                  let existing,
                  existing.status == .active,
                  entry == DeviceRegistryEntry(activeGrant: grant),
                  entry.devicePublicKey == existing.devicePublicKey,
                  entry.currentGrantID == existing.currentGrantID,
                  entry.currentGrantEpoch == (try existing.currentGrantEpoch.next()) else {
                throw HarcHostError.securityMutationInvalid("Replacement grant is not the exact next live epoch.")
            }
        case .readoptGrant(let entry, let grant, let exactBytes, let ticketID),
             .repairTransportTrustGrant(
                let entry,
                let grant,
                let exactBytes,
                let ticketID
             ):
            try validateShared(entry: entry)
            let isRepair = mutation.kind == .repairTransportTrustGrant
            guard !exactBytes.isEmpty,
                  let existing,
                  trustRepairRequired == isRepair,
                  !isRepair || existing.status == .active,
                  entry == DeviceRegistryEntry(activeGrant: grant),
                  entry.deviceID == existing.deviceID,
                  entry.devicePublicKey == existing.devicePublicKey,
                  entry.currentGrantEpoch == (try existing.currentGrantEpoch.next()) else {
                throw HarcHostError.securityMutationInvalid(
                    "Re-adoption must preserve the device key and advance exactly one epoch."
                )
            }
            switch existing.status {
            case .active:
                guard entry.currentGrantID == existing.currentGrantID else {
                    throw HarcHostError.securityMutationInvalid(
                        "Active-device re-adoption must preserve the current grant ID."
                    )
                }
            case .revoked:
                let priorUseCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grants WHERE grant_id = ?",
                    arguments: [entry.currentGrantID.description]
                ) ?? 0
                guard entry.currentGrantID != existing.currentGrantID,
                      priorUseCount == 0 else {
                    throw HarcHostError.securityMutationInvalid(
                        "Revoked-device re-adoption requires a fresh grant ID."
                    )
                }
            }
            try validateApprovedPairingTicket(ticketID, reservedFor: grant.deviceID)
        case .revokeDevice(let entry, let revocation, let exactBytes):
            try validateShared(entry: entry)
            guard !exactBytes.isEmpty,
                  let existing,
                  existing.status == .active,
                  entry.status == .revoked,
                  entry.revocation == revocation,
                  entry.devicePublicKey == existing.devicePublicKey,
                  revocation.priorGrantEpoch == existing.currentGrantEpoch,
                  revocation.newGrantEpoch == entry.currentGrantEpoch,
                  revocation.grantID == existing.currentGrantID else {
                throw HarcHostError.securityMutationInvalid("Revocation is not the exact next live epoch.")
            }
        }
    }

    private func applyPendingSecurityMutation(
        _ mutation: SecurityRegistryMutation,
        revision: UInt64,
        appliedAt: Date
    ) async throws {
        let revisionValue = try Self.sqliteInteger(revision, field: "securityRegistryRevision")
        let appliedTime = Self.unixTime(appliedAt)
        let exactMutationBytes = try Self.encode(mutation)
        try await dbQueue.write { db in
            guard try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM host_transport_rotation_intent
                    WHERE mode = 'emergency'
                    """
            ) == 0 else {
                throw HarcHostError.hostAuthorityMutationConflict
            }
            guard let pending = try Row.fetchOne(
                db,
                sql: "SELECT registry_revision, mutation_json, created_at FROM pending_security_mutations WHERE singleton = 1"
            ), pending["registry_revision"] as Int64 == revisionValue,
               pending["mutation_json"] as Data == exactMutationBytes else {
                throw HarcHostError.securityRegistryPendingMismatch
            }

            try self.validateSecurityMutation(
                mutation,
                initialGrantAcceptedAt: Self.date(pending["created_at"] as Double),
                in: db
            )
            switch mutation {
            case .issueGrant(let entry, let grant, let exactBytes, let ticketID):
                try self.persist(entry: entry, grant: grant, exactGrantBytes: exactBytes, in: db, at: appliedTime)
                if let ticketID {
                    try self.consumePairingTicket(
                        ticketID,
                        reservedFor: grant.deviceID,
                        exactGrantBytes: exactBytes,
                        in: db,
                        at: appliedTime
                    )
                }
            case .replaceGrant(let entry, let grant, let exactBytes):
                try self.persist(entry: entry, grant: grant, exactGrantBytes: exactBytes, in: db, at: appliedTime)
                // Scope replacement advances the grant epoch, so both live
                // session credentials and persisted background capabilities
                // from the prior epoch must become unusable atomically with
                // the new registry entry.
                try db.execute(
                    sql: """
                        UPDATE background_capabilities
                        SET state = 'grant-replaced', invalidated_at = ?
                        WHERE owner_device_id = ? AND invalidated_at IS NULL
                        """,
                    arguments: [appliedTime, grant.deviceID.rawBytes]
                )
                try db.execute(
                    sql: """
                        UPDATE session_tokens
                        SET invalidated_at = MAX(?, issued_at),
                            invalidation_reason = 'grant-replaced'
                        WHERE device_id = ? AND invalidated_at IS NULL
                        """,
                    arguments: [appliedTime, grant.deviceID.rawBytes]
                )
            case .readoptGrant(let entry, let grant, let exactBytes, let ticketID),
                 .repairTransportTrustGrant(
                    let entry,
                    let grant,
                    let exactBytes,
                    let ticketID
                 ):
                try self.persist(entry: entry, grant: grant, exactGrantBytes: exactBytes, in: db, at: appliedTime)
                if mutation.kind == .repairTransportTrustGrant {
                    try db.execute(
                        sql: """
                            UPDATE devices
                            SET trust_repair_required = 0, updated_at = ?
                            WHERE device_id = ? AND trust_repair_required = 1
                            """,
                        arguments: [appliedTime, grant.deviceID.rawBytes]
                    )
                    guard db.changesCount == 1 else {
                        throw HarcHostError.securityRegistryPendingMismatch
                    }
                }
                try self.consumePairingTicket(
                    ticketID,
                    reservedFor: grant.deviceID,
                    exactGrantBytes: exactBytes,
                    in: db,
                    at: appliedTime
                )
                // Session credentials carry the old grant ID/epoch and every
                // request rechecks this just-replaced registry entry. They are
                // therefore invalid in this same transaction. Persisted
                // background capabilities need an explicit terminal marker.
                try db.execute(
                    sql: """
                        UPDATE background_capabilities
                        SET state = 'grant-replaced', invalidated_at = ?
                        WHERE owner_device_id = ? AND invalidated_at IS NULL
                        """,
                    arguments: [appliedTime, grant.deviceID.rawBytes]
                )
                try db.execute(
                    sql: """
                        UPDATE session_tokens
                        SET invalidated_at = MAX(?, issued_at),
                            invalidation_reason = 'readopted'
                        WHERE device_id = ? AND invalidated_at IS NULL
                        """,
                    arguments: [appliedTime, grant.deviceID.rawBytes]
                )
            case .revokeDevice(let entry, let revocation, let exactBytes):
                try self.persist(entry: entry, in: db, at: appliedTime)
                try db.execute(
                    sql: """
                        INSERT INTO revocations (
                            revocation_id, device_id, grant_id, prior_grant_epoch,
                            new_grant_epoch, reason_code, claims_json,
                            exact_revocation_bytes, issued_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        revocation.revocationID.uuidString.lowercased(),
                        revocation.deviceID.rawBytes,
                        revocation.grantID.description,
                        try Self.sqliteInteger(revocation.priorGrantEpoch.rawValue, field: "priorGrantEpoch"),
                        try Self.sqliteInteger(revocation.newGrantEpoch.rawValue, field: "newGrantEpoch"),
                        revocation.reasonCode,
                        try Self.encode(revocation),
                        exactBytes,
                        Self.unixTime(revocation.issuedAt),
                    ]
                )
                try db.execute(
                    sql: "UPDATE grants SET is_current = 0 WHERE device_id = ?",
                    arguments: [revocation.deviceID.rawBytes]
                )
                try db.execute(
                    sql: "UPDATE background_capabilities SET state = 'revoked', invalidated_at = ? WHERE owner_device_id = ? AND invalidated_at IS NULL",
                    arguments: [appliedTime, revocation.deviceID.rawBytes]
                )
                try db.execute(
                    sql: """
                        UPDATE session_tokens
                        SET invalidated_at = MAX(?, issued_at),
                            invalidation_reason = 'revoked'
                        WHERE device_id = ? AND invalidated_at IS NULL
                        """,
                    arguments: [appliedTime, revocation.deviceID.rawBytes]
                )
            }

            try db.execute(
                sql: "UPDATE host_metadata SET security_registry_revision = ?, updated_at = ? WHERE singleton = 1",
                arguments: [revisionValue, appliedTime]
            )
            try db.execute(sql: "DELETE FROM pending_security_mutations WHERE singleton = 1")
            try self.insertAuditEvent(
                in: db,
                occurredAt: appliedAt,
                severity: .security,
                category: "security-registry",
                code: mutation.kind.rawValue,
                deviceID: mutation.deviceID
            )
            try self.pruneAuditEvents(in: db, at: appliedAt)
        }
    }

    nonisolated private func consumePairingTicket(
        _ ticketID: UUID,
        reservedFor deviceID: DeviceID,
        exactGrantBytes: Data,
        in db: Database,
        at appliedTime: Double
    ) throws {
        try db.execute(
            sql: """
                UPDATE pairing_tickets
                SET state = 'consumed', updated_at = ?
                WHERE ticket_id = ? AND state = 'approved' AND reserved_device_id = ?
                """,
            arguments: [
                appliedTime,
                ticketID.uuidString.lowercased(),
                deviceID.rawBytes,
            ]
        )
        guard db.changesCount == 1 else {
            throw HarcHostError.securityRegistryPendingMismatch
        }

        // PR 6 claim approval and exact grant delivery are part of this same
        // final security-journal transaction. Recovery after a process death
        // therefore cannot consume the ticket without also making status
        // terminal and deliverable. Legacy PR 3 placeholder tickets have no
        // protocol-state-v1 attempt and remain supported by existing callers.
        let v1Attempt = try Row.fetchOne(
            db,
            sql: """
                SELECT claim_id, device_id, device_label, state
                FROM pairing_attempts
                WHERE ticket_id = ? AND protocol_state_version = 1
                """,
            arguments: [ticketID.uuidString.lowercased()]
        )
        if let v1Attempt {
            guard v1Attempt["device_id"] as Data == deviceID.rawBytes,
                  v1Attempt["state"] as String
                    == PairingAttemptState.awaitingApproval.rawValue,
                  let deviceLabel = v1Attempt["device_label"] as String?,
                  !deviceLabel.isEmpty else {
                throw HarcHostError.securityRegistryPendingMismatch
            }

            // The normalized claimed label is immutable claim state. Copy it
            // into the registry in this same final transaction so a crash can
            // expose neither a consumed ticket without a label nor a renamed
            // device before its grant/readoption becomes durable.
            try db.execute(
                sql: "UPDATE devices SET label = ?, updated_at = ? WHERE device_id = ?",
                arguments: [deviceLabel, appliedTime, deviceID.rawBytes]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.securityRegistryPendingMismatch
            }

            try db.execute(
                sql: """
                    UPDATE pairing_attempts
                    SET state = 'approved', exact_grant_bytes = ?,
                        terminal_at = ?, updated_at = ?
                    WHERE ticket_id = ? AND protocol_state_version = 1
                      AND device_id = ? AND state = 'awaitingApproval'
                    """,
                arguments: [
                    exactGrantBytes,
                    appliedTime,
                    appliedTime,
                    ticketID.uuidString.lowercased(),
                    deviceID.rawBytes,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.securityRegistryPendingMismatch
            }
        }
    }

    nonisolated private func persist(
        entry: DeviceRegistryEntry,
        grant: DeviceGrantClaims,
        exactGrantBytes: Data,
        in db: Database,
        at appliedTime: Double
    ) throws {
        try persist(entry: entry, in: db, at: appliedTime)
        try db.execute(
            sql: "UPDATE grants SET is_current = 0 WHERE device_id = ?",
            arguments: [entry.deviceID.rawBytes]
        )
        try db.execute(
            sql: """
                INSERT INTO grants (
                    grant_id, grant_epoch, device_id, claims_json,
                    exact_grant_bytes, scopes_json, issued_at, expires_at,
                    is_current
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
            arguments: [
                grant.grantID.description,
                try Self.sqliteInteger(grant.grantEpoch.rawValue, field: "grantEpoch"),
                grant.deviceID.rawBytes,
                try Self.encode(grant),
                exactGrantBytes,
                try Self.encode(grant.scopes),
                Self.unixTime(grant.issuedAt),
                grant.expiresAt.map(Self.unixTime),
            ]
        )
    }

    nonisolated private func persist(
        entry: DeviceRegistryEntry,
        in db: Database,
        at appliedTime: Double
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO devices (
                    device_id, public_key_x963, registry_entry_json, status,
                    current_grant_id, current_grant_epoch, scopes_json,
                    grant_issued_at, grant_expires_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    public_key_x963 = excluded.public_key_x963,
                    registry_entry_json = excluded.registry_entry_json,
                    status = excluded.status,
                    current_grant_id = excluded.current_grant_id,
                    current_grant_epoch = excluded.current_grant_epoch,
                    scopes_json = excluded.scopes_json,
                    grant_issued_at = excluded.grant_issued_at,
                    grant_expires_at = excluded.grant_expires_at,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                entry.deviceID.rawBytes,
                entry.devicePublicKey.rawBytes,
                try Self.encode(entry),
                entry.status.rawValue,
                entry.currentGrantID.description,
                try Self.sqliteInteger(entry.currentGrantEpoch.rawValue, field: "grantEpoch"),
                try Self.encode(entry.currentScopes),
                Self.unixTime(entry.grantIssuedAt),
                entry.grantExpiresAt.map(Self.unixTime),
                appliedTime,
                appliedTime,
            ]
        )
    }
}

// MARK: - Pairing placeholder state

extension HarcHostStore {
    public func insertPairingTicketPlaceholder(_ ticket: PairingTicketPlaceholder) async throws {
        try await insertPairingTicketPlaceholder(ticket, at: now())
    }

    /// Deterministic `@testable` seam. The ticket carries its validity facts,
    /// but production admission still verifies them against the host clock.
    func insertPairingTicketPlaceholder(
        _ ticket: PairingTicketPlaceholder,
        at acceptedAt: Date
    ) async throws {
        try await repairSecurityRegistryOnReopen()
        guard acceptedAt.timeIntervalSinceReferenceDate.isFinite,
              ticket.state == .issued,
              ticket.reservedDeviceID == nil,
              ticket.issuedAt <= acceptedAt,
              acceptedAt < ticket.expiresAt else {
            throw HarcHostError.invalidPairingTransition
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pairing_tickets (
                        ticket_id, ticket_secret_binding_sha256, client_kind, state,
                        issued_at, expires_at, reserved_device_id, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
                    """,
                arguments: [
                    ticket.ticketID.uuidString.lowercased(),
                    ticket.ticketSecretBindingSHA256,
                    ticket.clientKind.rawValue,
                    ticket.state.rawValue,
                    Self.unixTime(ticket.issuedAt),
                    Self.unixTime(ticket.expiresAt),
                    Self.unixTime(acceptedAt),
                ]
            )
        }
    }

    public func reservePairingTicket(
        ticketID: UUID,
        for deviceID: DeviceID
    ) async throws {
        try await reservePairingTicket(ticketID: ticketID, for: deviceID, at: now())
    }

    /// Deterministic `@testable` seam. Production reservation always derives
    /// its acceptance time from the store's injected clock.
    func reservePairingTicket(
        ticketID: UUID,
        for deviceID: DeviceID,
        at date: Date
    ) async throws {
        try await repairSecurityRegistryOnReopen()
        let checkedAt = date
        let time = Self.unixTime(checkedAt)
        enum Result { case reserved, expired, invalid }
        let result: Result = try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, expires_at, reserved_device_id FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            ) else { return .invalid }
            let state = row["state"] as String
            if time >= row["expires_at"] as Double {
                try db.execute(
                    sql: "UPDATE pairing_tickets SET state = 'expired', updated_at = ? WHERE ticket_id = ?",
                    arguments: [time, ticketID.uuidString.lowercased()]
                )
                return .expired
            }
            if state == PairingTicketState.reserved.rawValue,
               row["reserved_device_id"] as Data? == deviceID.rawBytes {
                return .reserved
            }
            guard state == PairingTicketState.issued.rawValue else { return .invalid }
            try db.execute(
                sql: "UPDATE pairing_tickets SET state = 'reserved', reserved_device_id = ?, updated_at = ? WHERE ticket_id = ?",
                arguments: [deviceID.rawBytes, time, ticketID.uuidString.lowercased()]
            )
            return .reserved
        }
        guard case .reserved = result else { throw HarcHostError.invalidPairingTransition }
    }

    public func transitionPairingTicket(
        ticketID: UUID,
        to state: PairingTicketState
    ) async throws {
        try await transitionPairingTicket(ticketID: ticketID, to: state, at: now())
    }

    /// Deterministic `@testable` seam. Production transitions always derive
    /// their acceptance time from the store's injected clock.
    func transitionPairingTicket(
        ticketID: UUID,
        to state: PairingTicketState,
        at date: Date
    ) async throws {
        try await repairSecurityRegistryOnReopen()
        let allowed: [PairingTicketState: Set<PairingTicketState>] = [
            .issued: [.cancelled, .expired],
            .reserved: [.approved, .cancelled, .expired],
            // Consumption is available only inside the journaled grant-issue
            // transaction; this public placeholder transition cannot do it.
            .approved: [.cancelled, .expired],
            .consumed: [],
            .expired: [],
            .cancelled: [],
        ]
        let transitionDate = date
        guard transitionDate.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.invalidPairingTransition
        }
        let transitionAt = Self.unixTime(transitionDate)
        enum Result { case changed, replay, invalid }
        let result: Result = try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, expires_at FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            ), let current = PairingTicketState(rawValue: row["state"] as String) else { return .invalid }
            let expiresAt = row["expires_at"] as Double
            if transitionAt >= expiresAt,
               ![PairingTicketState.consumed, .expired, .cancelled].contains(current) {
                try db.execute(
                    sql: "UPDATE pairing_tickets SET state = 'expired', updated_at = ? WHERE ticket_id = ?",
                    arguments: [transitionAt, ticketID.uuidString.lowercased()]
                )
                return state == .expired ? .changed : .invalid
            }
            if current == state { return .replay }
            guard state != .expired || transitionAt >= expiresAt else { return .invalid }
            guard allowed[current, default: []].contains(state) else { return .invalid }
            try db.execute(
                sql: "UPDATE pairing_tickets SET state = ?, updated_at = ? WHERE ticket_id = ?",
                arguments: [state.rawValue, transitionAt, ticketID.uuidString.lowercased()]
            )
            return .changed
        }
        guard result != .invalid else { throw HarcHostError.invalidPairingTransition }
    }

    /// Foreground-controller dismissal. Closing an already terminal or expired
    /// ticket is idempotent, while any still-open ticket is made permanently
    /// unusable in the same transaction.
    public func cancelPairingTicketIfOpen(ticketID: UUID) async throws {
        try await repairSecurityRegistryOnReopen()
        let cancelledAt = now()
        guard cancelledAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.invalidPairingTransition
        }
        let timestamp = Self.unixTime(cancelledAt)
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, expires_at FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            ), let state = PairingTicketState(
                rawValue: row["state"] as String
            ) else {
                throw HarcHostError.invalidPairingTransition
            }
            if [.consumed, .expired, .cancelled].contains(state) {
                return
            }
            let terminalState = timestamp >= row["expires_at"] as Double
                ? PairingTicketState.expired
                : .cancelled
            try db.execute(
                sql: "UPDATE pairing_tickets SET state = ?, updated_at = ? WHERE ticket_id = ? AND state = ?",
                arguments: [
                    terminalState.rawValue,
                    timestamp,
                    ticketID.uuidString.lowercased(),
                    state.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.invalidPairingTransition
            }
        }
    }
}
