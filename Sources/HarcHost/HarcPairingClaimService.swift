import Foundation
import GRDB
import HarcDomain
import HarcIdentity

/// Network-neutral pairing application service. It owns no transport state and
/// never receives a host signing key or a local-approval capability.
public actor HarcPairingClaimService {
    public static let maximumBeginsPerSource = 5
    public static let beginWindow: TimeInterval = 10 * 60

    private let store: HarcHostStore
    private let randomness: any HostAuthenticationRandomness
    private let protocolBoundary: any HostPairingAuthenticationProtocolBoundary
    private let beforeProofFailureTermination: (@Sendable () async -> Void)?

    public init(
        store: HarcHostStore,
        protocolBoundary: any HostPairingAuthenticationProtocolBoundary,
        randomness: any HostAuthenticationRandomness = SystemHostAuthenticationRandomness()
    ) throws {
        self.store = store
        self.protocolBoundary = protocolBoundary
        self.randomness = randomness
        beforeProofFailureTermination = nil
    }

    /// Deterministic `@testable` seam for exercising a stale proof failure
    /// racing a successful proof and local approval.
    init(
        store: HarcHostStore,
        protocolBoundary: any HostPairingAuthenticationProtocolBoundary,
        randomness: any HostAuthenticationRandomness = SystemHostAuthenticationRandomness(),
        beforeProofFailureTermination: @escaping @Sendable () async -> Void
    ) throws {
        self.store = store
        self.protocolBoundary = protocolBoundary
        self.randomness = randomness
        self.beforeProofFailureTermination = beforeProofFailureTermination
    }

    public func beginPairingClaim(
        _ request: BeginHostPairingClaimRequest
    ) async throws -> BeginHostPairingClaimResponse {
        let acceptedAt = store.now()
        guard acceptedAt.timeIntervalSinceReferenceDate.isFinite,
              request.context.hostAuthorityPublicKey.hostAuthorityID
                == store.expectedMetadata.hostAuthorityID else {
            throw HarcHostError.invalidAuthenticationInput("pairing authority")
        }

        // Generate the response shape before the lookup. Invalid tickets still
        // traverse the same entropy and hashing path before a generic denial.
        let claimID = try randomness.randomUUID()
        let hostNonce = try randomness.randomBytes(count: 32)
        let claimantToken = try randomness.randomBytes(count: 32)
        let submittedBinding = try protocolBoundary.pairingTicketSecretBindingSHA256(
            ticketID: request.ticketID,
            secret: request.ticketSecret
        )
        let tokenBinding = try HostAuthenticationCrypto.pairingClaimTokenBinding(
            claimID: claimID,
            token: claimantToken
        )
        let subjectBinding = HarcHostStore.digest(
            HostAuthenticationCrypto.uuidBytes(request.ticketID)
        )
        let requestedScopes = try HarcHostStore.encode(request.requestedScopes)
        let acceptedTime = HarcHostStore.unixTime(acceptedAt)
        let windowStart = acceptedTime - Self.beginWindow

        enum Result { case accepted(Date), rejected }
        let result: Result = try await store.dbQueue.write { db in
            try HarcHostStore.expireAndPrunePairingRows(
                in: db,
                at: acceptedTime
            )
            try db.execute(
                sql: "DELETE FROM preauth_attempts WHERE occurred_at < ?",
                arguments: [acceptedTime - Self.beginWindow]
            )
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM preauth_attempts
                    WHERE operation = 'pairingBegin'
                      AND source_binding_sha256 = ? AND occurred_at >= ?
                    """,
                arguments: [request.source.bindingSHA256, windowStart]
            ) ?? 0
            guard count < Self.maximumBeginsPerSource else {
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: acceptedAt,
                    code: "pairing-begin-rejected"
                )
                return .rejected
            }
            try db.execute(
                sql: """
                    INSERT INTO preauth_attempts (
                        operation, source_binding_sha256,
                        subject_binding_sha256, occurred_at
                    ) VALUES ('pairingBegin', ?, ?, ?)
                    """,
                arguments: [
                    request.source.bindingSHA256,
                    subjectBinding,
                    acceptedTime,
                ]
            )

            guard let ticket = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, ticket_secret_binding_sha256, expires_at
                    FROM pairing_tickets WHERE ticket_id = ?
                    """,
                arguments: [request.ticketID.uuidString.lowercased()]
            ) else {
                // Keep the fixed-size comparison in the missing-ticket path.
                _ = HostAuthenticationCrypto.constantTimeEqual(
                    submittedBinding,
                    Data(repeating: 0, count: 32)
                )
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: acceptedAt,
                    code: "pairing-begin-rejected"
                )
                return .rejected
            }

            let expiresAt = ticket["expires_at"] as Double
            let secretMatches = HostAuthenticationCrypto.constantTimeEqual(
                submittedBinding,
                ticket["ticket_secret_binding_sha256"] as Data
            )
            if acceptedTime >= expiresAt {
                try db.execute(
                    sql: """
                        UPDATE pairing_tickets SET state = 'expired', updated_at = ?
                        WHERE ticket_id = ? AND state IN ('issued', 'reserved', 'approved')
                        """,
                    arguments: [acceptedTime, request.ticketID.uuidString.lowercased()]
                )
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: acceptedAt,
                    code: "pairing-begin-rejected"
                )
                return .rejected
            }
            guard secretMatches,
                  ticket["state"] as String == PairingTicketState.issued.rawValue else {
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: acceptedAt,
                    code: "pairing-begin-rejected"
                )
                return .rejected
            }

            try db.execute(
                sql: """
                    UPDATE pairing_tickets
                    SET state = 'reserved', reserved_device_id = ?, updated_at = ?
                    WHERE ticket_id = ? AND state = 'issued'
                    """,
                arguments: [
                    request.devicePublicKey.deviceID.rawBytes,
                    acceptedTime,
                    request.ticketID.uuidString.lowercased(),
                ]
            )
            guard db.changesCount == 1 else {
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: acceptedAt,
                    code: "pairing-begin-rejected"
                )
                return .rejected
            }

            try db.execute(
                sql: """
                    INSERT INTO pairing_attempts (
                        claim_id, ticket_id, device_id, state,
                        claimant_token_binding_sha256, requested_scopes_json,
                        created_at, expires_at, updated_at,
                        protocol_state_version, device_public_key_x963,
                        device_label, client_nonce, host_nonce,
                        tls_spki_sha256, host_authority_public_key_x963,
                        protocol_major, protocol_minor
                    ) VALUES (?, ?, ?, 'reserved', ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    claimID.uuidString.lowercased(),
                    request.ticketID.uuidString.lowercased(),
                    request.devicePublicKey.deviceID.rawBytes,
                    tokenBinding,
                    requestedScopes,
                    acceptedTime,
                    expiresAt,
                    acceptedTime,
                    request.devicePublicKey.rawBytes,
                    request.deviceLabel,
                    request.clientNonce,
                    hostNonce,
                    request.context.tlsSPKISHA256,
                    request.context.hostAuthorityPublicKey.rawBytes,
                    Int64(request.context.protocolMajor),
                    Int64(request.context.protocolMinor),
                ]
            )
            return .accepted(HarcHostStore.date(expiresAt))
        }

        guard case .accepted(let expiresAt) = result else {
            throw HarcHostError.pairingClaimRejected
        }
        return BeginHostPairingClaimResponse(
            claimID: claimID,
            hostNonce: hostNonce,
            claimantToken: claimantToken,
            expiresAt: expiresAt
        )
    }

    public func provePairingClaim(
        _ request: ProveHostPairingClaimRequest
    ) async throws -> HostPairingClaimProofResponse {
        let checkedAt = store.now()
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.pairingProofRejected
        }
        guard let record = try await pairingRecord(claimID: request.claimID) else {
            try await auditAuthenticationFailure(
                code: "pairing-proof-rejected",
                at: checkedAt
            )
            throw HarcHostError.pairingProofRejected
        }
        let presentedBinding = try HostAuthenticationCrypto.pairingClaimTokenBinding(
            claimID: request.claimID,
            token: request.claimantToken
        )
        guard HostAuthenticationCrypto.constantTimeEqual(
            presentedBinding,
            record.claimantTokenBindingSHA256
        ) else {
            // An unauthenticated caller must never be able to cancel someone
            // else's reserved claim merely by presenting a bad bearer token.
            try await auditAuthenticationFailure(
                code: "pairing-proof-rejected",
                at: checkedAt
            )
            throw HarcHostError.pairingProofRejected
        }
        guard record.state == .reserved else {
            // Proof is single-use. A replay while local approval/final journal
            // apply is in progress is rejected without rolling that work back.
            try await auditAuthenticationFailure(
                code: "pairing-proof-rejected",
                at: checkedAt
            )
            throw HarcHostError.pairingProofRejected
        }
        guard checkedAt < record.expiresAt else {
            try await expireClaim(
                claimID: request.claimID,
                ticketID: record.ticketID,
                at: checkedAt,
                auditCode: "pairing-proof-rejected"
            )
            throw HarcHostError.pairingProofRejected
        }

        let proof: HostPairingProofResult
        do {
            proof = try protocolBoundary.validatePairingProofAndDeriveSAS(
                HostPairingProofValidationInput(
                    protocolMajor: record.protocolMajor,
                    protocolMinor: record.protocolMinor,
                    ticketID: record.ticketID,
                    claimID: request.claimID,
                    libraryID: store.expectedMetadata.libraryID,
                    hostAuthorityID: store.expectedMetadata.hostAuthorityID,
                    hostAuthorityPublicKey: record.hostAuthorityPublicKey,
                    tlsSPKISHA256: record.tlsSPKISHA256,
                    deviceID: record.deviceID,
                    devicePublicKey: record.devicePublicKey,
                    clientNonce: record.clientNonce,
                    hostNonce: record.hostNonce,
                    ticketSecretBindingSHA256: record.ticketSecretBindingSHA256,
                    requestedScopes: record.requestedScopes,
                    clientSignature: request.clientSignature
                )
            )
        } catch {
            if let beforeProofFailureTermination {
                await beforeProofFailureTermination()
            }
            try await cancelReservedClaimAfterProofFailure(
                claimID: request.claimID,
                ticketID: record.ticketID,
                at: checkedAt,
                auditCode: "pairing-proof-rejected"
            )
            throw HarcHostError.pairingProofRejected
        }

        let indexes = try HarcHostStore.encode(proof.sasWordIndexes)
        let words = try HarcHostStore.encode(proof.sasWords)
        let changed = try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE pairing_attempts
                    SET state = 'awaitingApproval', proof_signature_raw = ?,
                        sas_digest = ?, sas_word_indexes_json = ?, sas_words_json = ?,
                        proof_verified_at = ?, updated_at = ?
                    WHERE claim_id = ? AND protocol_state_version = 1
                      AND state = 'reserved' AND expires_at > ?
                      AND claimant_token_binding_sha256 = ?
                    """,
                arguments: [
                    request.clientSignature.rawBytes,
                    proof.sasDigest,
                    indexes,
                    words,
                    HarcHostStore.unixTime(checkedAt),
                    HarcHostStore.unixTime(checkedAt),
                    request.claimID.uuidString.lowercased(),
                    HarcHostStore.unixTime(checkedAt),
                    presentedBinding,
                ]
            )
            return db.changesCount == 1
        }
        guard changed else {
            try await auditAuthenticationFailure(
                code: "pairing-proof-rejected",
                at: checkedAt
            )
            throw HarcHostError.pairingProofRejected
        }
        return try HostPairingClaimProofResponse(
            proof: proof,
            expiresAt: record.expiresAt
        )
    }

    public func pairingStatus(
        claimID: UUID,
        claimantToken: Data
    ) async throws -> HostPairingClaimStatus {
        let checkedAt = store.now()
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.pairingClaimRejected
        }
        guard claimantToken.count == 32,
              let record = try await pairingRecord(claimID: claimID) else {
            try await auditAuthenticationFailure(
                code: "pairing-status-rejected",
                at: checkedAt
            )
            throw HarcHostError.pairingClaimRejected
        }
        let binding = try HostAuthenticationCrypto.pairingClaimTokenBinding(
            claimID: claimID,
            token: claimantToken
        )
        guard HostAuthenticationCrypto.constantTimeEqual(
            binding,
            record.claimantTokenBindingSHA256
        ) else {
            try await auditAuthenticationFailure(
                code: "pairing-status-rejected",
                at: checkedAt
            )
            throw HarcHostError.pairingClaimRejected
        }
        switch record.state {
        case .approved:
            // Exact grant delivery is durable terminal state. Once the final
            // security-journal transaction publishes it, ticket expiry must
            // not orphan the active device by hiding its grant from the
            // claimant that still holds the bound status token.
            guard let bytes = record.exactGrantBytes, !bytes.isEmpty else {
                throw HarcHostError.pairingClaimRejected
            }
            return .approved(exactGrantBytes: bytes)
        case .denied:
            return .denied
        case .cancelled:
            return .cancelled
        case .expired:
            return .expired
        case .reserved, .proofVerified, .awaitingApproval:
            if checkedAt >= record.expiresAt {
                try await expireClaim(
                    claimID: claimID,
                    ticketID: record.ticketID,
                    at: checkedAt
                )
                return .expired
            }
            return .pending
        }
    }

    private func pairingRecord(claimID: UUID) async throws -> PairingRecord? {
        try await store.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT a.*, t.ticket_secret_binding_sha256
                    FROM pairing_attempts a
                    JOIN pairing_tickets t ON t.ticket_id = a.ticket_id
                    WHERE a.claim_id = ? AND a.protocol_state_version = 1
                    """,
                arguments: [claimID.uuidString.lowercased()]
            ) else { return nil }
            return try PairingRecord(row: row)
        }
    }

    private func cancelReservedClaimAfterProofFailure(
        claimID: UUID,
        ticketID: UUID,
        at date: Date,
        auditCode: String
    ) async throws {
        let time = HarcHostStore.unixTime(date)
        try await store.dbQueue.write { db in
            let ticketIsReserved = try String.fetchOne(
                db,
                sql: "SELECT state FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            ) == PairingTicketState.reserved.rawValue

            var attemptTransitionWon = false
            if ticketIsReserved {
                try db.execute(
                    sql: """
                        UPDATE pairing_attempts
                        SET state = 'cancelled', terminal_at = ?, updated_at = ?
                        WHERE claim_id = ? AND ticket_id = ?
                          AND protocol_state_version = 1 AND state = 'reserved'
                        """,
                    arguments: [
                        time,
                        time,
                        claimID.uuidString.lowercased(),
                        ticketID.uuidString.lowercased(),
                    ]
                )
                attemptTransitionWon = db.changesCount == 1
            }

            if attemptTransitionWon {
                // Ticket cancellation is conditional on winning the exact
                // reserved-attempt CAS. A stale mismatch must not cancel a
                // proof that has advanced to approval or journal application.
                try db.execute(
                    sql: """
                        UPDATE pairing_tickets SET state = 'cancelled', updated_at = ?
                        WHERE ticket_id = ? AND state = 'reserved'
                        """,
                    arguments: [time, ticketID.uuidString.lowercased()]
                )
                guard db.changesCount == 1 else {
                    throw HarcHostError.invalidPairingTransition
                }
            }

            try self.store.insertAuthenticationFailure(
                in: db,
                at: date,
                code: auditCode
            )
        }
    }

    private func expireClaim(
        claimID: UUID,
        ticketID: UUID,
        at date: Date,
        auditCode: String? = nil
    ) async throws {
        let time = HarcHostStore.unixTime(date)
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE pairing_attempts
                    SET state = 'expired', terminal_at = ?, updated_at = ?
                    WHERE claim_id = ? AND state IN ('reserved', 'proofVerified', 'awaitingApproval')
                      AND NOT EXISTS (SELECT 1 FROM pending_security_mutations)
                    """,
                arguments: [
                    time,
                    time,
                    claimID.uuidString.lowercased(),
                ]
            )
            try db.execute(
                sql: """
                    UPDATE pairing_tickets SET state = 'expired', updated_at = ?
                    WHERE ticket_id = ? AND state IN ('issued', 'reserved', 'approved')
                      AND NOT EXISTS (SELECT 1 FROM pending_security_mutations)
                    """,
                arguments: [
                    time,
                    ticketID.uuidString.lowercased(),
                ]
            )
            if let auditCode {
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: date,
                    code: auditCode
                )
            }
        }
    }

    private func auditAuthenticationFailure(
        code: String,
        at date: Date
    ) async throws {
        try await store.dbQueue.write { db in
            try self.store.insertAuthenticationFailure(
                in: db,
                at: date,
                code: code
            )
        }
    }
}

/// Local-only controller. The resident host app owns this actor and does not
/// hand it to any network adapter.
public actor HarcLocalPairingApprovalService {
    private let store: HarcHostStore
    private let issuer: any HostPairingGrantIssuingBoundary

    public init(
        store: HarcHostStore,
        issuer: any HostPairingGrantIssuingBoundary
    ) {
        self.store = store
        self.issuer = issuer
    }

    public func pendingClaim(_ claimID: UUID) async throws -> HostPendingPairingClaim {
        let checkedAt = store.now()
        guard let pending = try await loadPendingClaim(claimID),
              checkedAt < pending.expiresAt else {
            throw HarcHostError.pairingClaimNotAwaitingApproval
        }
        return pending
    }

    public func deny(_ claimID: UUID) async throws {
        let deniedAt = store.now()
        let time = HarcHostStore.unixTime(deniedAt)
        let changed = try await store.dbQueue.write { db in
            guard let ticketID = try String.fetchOne(
                db,
                sql: """
                    SELECT ticket_id FROM pairing_attempts
                    WHERE claim_id = ? AND protocol_state_version = 1
                      AND state = 'awaitingApproval' AND expires_at > ?
                    """,
                arguments: [claimID.uuidString.lowercased(), time]
            ) else { return false }
            try db.execute(
                sql: """
                    UPDATE pairing_attempts
                    SET state = 'denied', terminal_at = ?, updated_at = ?
                    WHERE claim_id = ? AND state = 'awaitingApproval'
                    """,
                arguments: [time, time, claimID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else { return false }
            try db.execute(
                sql: """
                    UPDATE pairing_tickets
                    SET state = 'cancelled', updated_at = ?
                    WHERE ticket_id = ? AND state = 'reserved'
                """,
                arguments: [time, ticketID]
            )
            guard db.changesCount == 1 else {
                // Throw from the write closure so the earlier attempt-state
                // update rolls back with the ticket update.
                throw HarcHostError.pairingClaimNotAwaitingApproval
            }
            return true
        }
        guard changed else { throw HarcHostError.pairingClaimNotAwaitingApproval }
    }

    @discardableResult
    public func approve(
        _ claimID: UUID,
        grantedScopes explicitGrantedScopes: [AuthorizationScope]? = nil
    ) async throws -> HostPairingIssuedGrant {
        let pending = try await pendingClaim(claimID)
        let grantedScopes = explicitGrantedScopes ?? pending.requestedScopes
        guard !grantedScopes.isEmpty,
              grantedScopes.count <= 8,
              grantedScopes == Array(Set(grantedScopes)).sorted(),
              Set(grantedScopes).isSubset(of: Set(pending.requestedScopes)) else {
            throw HarcHostError.pairingGrantMismatch
        }
        let approvedAt = store.now()
        let existing = try await store.deviceRegistryEntry(deviceID: pending.deviceID)
        let request = HostPairingGrantIssuanceRequest(
            libraryID: store.expectedMetadata.libraryID,
            hostAuthorityID: store.expectedMetadata.hostAuthorityID,
            clientKind: pending.clientKind,
            devicePublicKey: pending.devicePublicKey,
            approvedScopes: grantedScopes,
            existingEntry: existing,
            approvedAt: approvedAt
        )
        let issued = try await issuer.issueGrant(for: request)
        guard issued.claims.libraryID == request.libraryID,
              issued.claims.hostAuthorityID == request.hostAuthorityID,
              issued.claims.deviceID == pending.deviceID,
              issued.claims.devicePublicKey == pending.devicePublicKey,
              issued.claims.scopes == grantedScopes else {
            throw HarcHostError.pairingGrantMismatch
        }

        try await store.transitionPairingTicket(
            ticketID: pending.ticketID,
            to: .approved
        )
        if existing == nil {
            try await store.issueDeviceGrant(
                issued.claims,
                exactGrantBytes: issued.exactSignedGrantBytes,
                pairingTicketID: pending.ticketID
            )
        } else if pending.requiresTransportTrustRepair {
            try await store.repairTransportTrust(
                issued.claims,
                exactGrantBytes: issued.exactSignedGrantBytes,
                pairingTicketID: pending.ticketID
            )
        } else {
            try await store.readoptDevice(
                issued.claims,
                exactGrantBytes: issued.exactSignedGrantBytes,
                pairingTicketID: pending.ticketID
            )
        }
        return issued
    }

    private func loadPendingClaim(
        _ claimID: UUID
    ) async throws -> HostPendingPairingClaim? {
        try await store.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT a.*, t.client_kind,
                           COALESCE(d.trust_repair_required, 0)
                               AS requires_transport_trust_repair
                    FROM pairing_attempts a
                    JOIN pairing_tickets t ON t.ticket_id = a.ticket_id
                    LEFT JOIN devices d ON d.device_id = a.device_id
                    WHERE a.claim_id = ? AND a.protocol_state_version = 1
                      AND a.state = 'awaitingApproval'
                    """,
                arguments: [claimID.uuidString.lowercased()]
            ), let ticketID = UUID(uuidString: row["ticket_id"] as String),
               let clientKind = AdoptedClientKind(rawValue: row["client_kind"] as String) else {
                return nil
            }
            return HostPendingPairingClaim(
                claimID: claimID,
                ticketID: ticketID,
                clientKind: clientKind,
                deviceID: try DeviceID(row["device_id"] as Data),
                devicePublicKey: try P256X963PublicKey(
                    row["device_public_key_x963"] as Data
                ),
                deviceLabel: row["device_label"] as String,
                requestedScopes: try HarcHostStore.decode(
                    [AuthorizationScope].self,
                    from: row["requested_scopes_json"] as Data
                ),
                requiresTransportTrustRepair:
                    row["requires_transport_trust_repair"] as Int == 1,
                sasDigest: row["sas_digest"] as Data,
                sasWordIndexes: try HarcHostStore.decode(
                    [UInt16].self,
                    from: row["sas_word_indexes_json"] as Data
                ),
                sasWords: try HarcHostStore.decode(
                    [String].self,
                    from: row["sas_words_json"] as Data
                ),
                expiresAt: HarcHostStore.date(row["expires_at"] as Double)
            )
        }
    }
}

private struct PairingRecord {
    let ticketID: UUID
    let deviceID: DeviceID
    let state: PairingAttemptState
    let claimantTokenBindingSHA256: Data
    let requestedScopes: [AuthorizationScope]
    let devicePublicKey: P256X963PublicKey
    let clientNonce: Data
    let hostNonce: Data
    let tlsSPKISHA256: Data
    let hostAuthorityPublicKey: P256X963PublicKey
    let protocolMajor: UInt16
    let protocolMinor: UInt16
    let ticketSecretBindingSHA256: Data
    let expiresAt: Date
    let exactGrantBytes: Data?

    init(row: Row) throws {
        guard let ticketID = UUID(uuidString: row["ticket_id"] as String),
              let state = PairingAttemptState(rawValue: row["state"] as String),
              let protocolMajor = UInt16(exactly: row["protocol_major"] as Int64),
              let protocolMinor = UInt16(exactly: row["protocol_minor"] as Int64) else {
            throw HarcHostError.databaseFailure("Malformed durable pairing claim.")
        }
        self.ticketID = ticketID
        deviceID = try DeviceID(row["device_id"] as Data)
        self.state = state
        claimantTokenBindingSHA256 = row["claimant_token_binding_sha256"] as Data
        requestedScopes = try HarcHostStore.decode(
            [AuthorizationScope].self,
            from: row["requested_scopes_json"] as Data
        )
        devicePublicKey = try P256X963PublicKey(
            row["device_public_key_x963"] as Data
        )
        clientNonce = row["client_nonce"] as Data
        hostNonce = row["host_nonce"] as Data
        tlsSPKISHA256 = row["tls_spki_sha256"] as Data
        hostAuthorityPublicKey = try P256X963PublicKey(
            row["host_authority_public_key_x963"] as Data
        )
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        ticketSecretBindingSHA256 = row["ticket_secret_binding_sha256"] as Data
        expiresAt = HarcHostStore.date(row["expires_at"] as Double)
        exactGrantBytes = row["exact_grant_bytes"] as Data?
    }
}
