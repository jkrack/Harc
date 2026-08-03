import Foundation
import GRDB
import HarcDomain
import HarcIdentity

/// Durable challenge/response and short-lived session credentials. Transport
/// adapters provide already-pinned TLS facts and exact wire payloads; this
/// service independently validates negotiated capabilities against current host
/// policy before binding them into a session token.
public actor HarcSessionService {
    public static let challengeLifetime: TimeInterval = 30
    public static let sessionLifetime: TimeInterval = 30 * 60
    public static let maximumBeginsPerDeviceSource = 10
    public static let beginWindow: TimeInterval = 60
    public static let maximumOutstandingChallenges = 5

    private let store: HarcHostStore
    private let protocolBoundary: any HostSessionAuthenticationProtocolBoundary
    private let randomness: any HostAuthenticationRandomness

    public init(
        store: HarcHostStore,
        protocolBoundary: any HostSessionAuthenticationProtocolBoundary,
        randomness: any HostAuthenticationRandomness = SystemHostAuthenticationRandomness()
    ) {
        self.store = store
        self.protocolBoundary = protocolBoundary
        self.randomness = randomness
    }

    public func beginSession(
        _ request: BeginHostSessionRequest
    ) async throws -> BeginHostSessionResponse {
        let serverTime = store.now()
        guard serverTime.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.sessionAdmissionRejected
        }
        do {
            try protocolBoundary.validateProtocolVersion(
                major: request.protocolMajor,
                minor: request.protocolMinor
            )
        } catch {
            throw HarcHostError.sessionAdmissionRejected
        }
        let challengeID = try randomness.randomUUID()
        guard challengeID != Self.zeroUUID else {
            throw HarcHostError.invalidAuthenticationInput("challenge identifier")
        }
        let serverNonce = try randomness.randomBytes(count: 32)
        let dummyGrant = try randomness.randomBytes(count: 512)
        // The normative limit is per claimed device/source pair. Grant IDs are
        // lookup hints and must not let one device multiply its pre-auth quota.
        let subject = HostAuthenticationCrypto.preauthenticationSubject(
            deviceID: request.claimedDeviceID
        )
        let now = HarcHostStore.unixTime(serverTime)
        let expiresAt = serverTime.addingTimeInterval(Self.challengeLifetime)
        let expiry = HarcHostStore.unixTime(expiresAt)

        enum Admission {
            case challenge(exactGrantBytes: Data, admitted: Bool)
            case rejected
        }
        let admission: Admission = try await store.dbQueue.write { db in
            try Self.prune(in: db, at: now)
            let recentBegins = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM preauth_attempts
                    WHERE operation = 'sessionBegin'
                      AND source_binding_sha256 = ?
                      AND subject_binding_sha256 = ?
                      AND occurred_at >= ?
                    """,
                arguments: [
                    request.source.bindingSHA256,
                    subject,
                    now - Self.beginWindow,
                ]
            ) ?? 0
            let outstanding = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM session_challenges
                    WHERE source_binding_sha256 = ?
                      AND subject_binding_sha256 = ? AND expires_at > ?
                    """,
                arguments: [request.source.bindingSHA256, subject, now]
            ) ?? 0
            guard recentBegins < Self.maximumBeginsPerDeviceSource,
                  outstanding < Self.maximumOutstandingChallenges else {
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: serverTime,
                    code: "session-begin-rejected"
                )
                return .rejected
            }
            try db.execute(
                sql: """
                    INSERT INTO preauth_attempts (
                        operation, source_binding_sha256,
                        subject_binding_sha256, occurred_at
                    ) VALUES ('sessionBegin', ?, ?, ?)
                    """,
                arguments: [request.source.bindingSHA256, subject, now]
            )

            let device = try Row.fetchOne(
                db,
                sql: """
                    SELECT d.status, d.current_grant_id, d.current_grant_epoch,
                           d.public_key_x963, d.grant_expires_at,
                           d.trust_repair_required,
                           g.exact_grant_bytes
                    FROM devices d
                    JOIN grants g
                      ON g.device_id = d.device_id
                     AND g.is_current = 1
                     AND g.grant_id = d.current_grant_id
                     AND g.grant_epoch = d.current_grant_epoch
                    WHERE d.device_id = ? AND d.current_grant_id = ?
                    """,
                arguments: [
                    request.claimedDeviceID.rawBytes,
                    request.grantID.description,
                ]
            )
            let admitted = device?["status"] as String? == "active"
                && device?["trust_repair_required"] as Int? == 0
                && ((device?["grant_expires_at"] as Double?).map { now < $0 } ?? true)
            let exactGrant = admitted
                ? (device?["exact_grant_bytes"] as Data? ?? dummyGrant)
                : dummyGrant

            try db.execute(
                sql: """
                    INSERT INTO session_challenges (
                        challenge_id, source_binding_sha256,
                        subject_binding_sha256, is_admitted, device_id,
                        grant_id, grant_epoch, device_public_key_x963,
                        exact_grant_bytes, server_nonce, tls_spki_sha256,
                        exact_capabilities_bytes, capabilities_sha256,
                        protocol_major, protocol_minor, selected_codec,
                        selected_container, created_at, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    challengeID.uuidString.lowercased(),
                    request.source.bindingSHA256,
                    subject,
                    admitted ? 1 : 0,
                    admitted ? request.claimedDeviceID.rawBytes : nil,
                    admitted ? request.grantID.description : nil,
                    admitted ? device?["current_grant_epoch"] as Int64? : nil,
                    admitted ? device?["public_key_x963"] as Data? : nil,
                    exactGrant,
                    serverNonce,
                    request.tlsSPKISHA256,
                    nil as Data?,
                    nil as Data?,
                    Int64(request.protocolMajor),
                    Int64(request.protocolMinor),
                    nil as String?,
                    nil as String?,
                    now,
                    expiry,
                ]
            )
            if !admitted {
                try self.store.insertAuthenticationFailure(
                    in: db,
                    at: serverTime,
                    code: "session-begin-rejected"
                )
            }
            return .challenge(exactGrantBytes: exactGrant, admitted: admitted)
        }

        guard case .challenge(let exactGrantBytes, _) = admission else {
            // The same error covers valid and invalid lookup hints.
            throw HarcHostError.sessionAdmissionRejected
        }
        return BeginHostSessionResponse(
            challengeID: challengeID,
            serverNonce: serverNonce,
            expiresAt: expiresAt,
            exactSignedGrantBytes: exactGrantBytes,
            serverTime: serverTime
        )
    }

    public func openSession(
        _ request: OpenHostSessionRequest
    ) async throws -> HostOpenedSession {
        let openedAt = store.now()
        guard openedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.sessionProofRejected
        }
        guard let challenge = try await challenge(request.challengeID) else {
            try await auditAuthenticationFailure(
                code: "session-proof-rejected",
                at: openedAt
            )
            throw HarcHostError.sessionProofRejected
        }
        let now = HarcHostStore.unixTime(openedAt)
        let capabilities: HostNegotiatedSessionCapabilities
        do {
            guard request.protocolMajor == challenge.protocolMajor,
                  request.protocolMinor == challenge.protocolMinor else {
                throw HarcHostError.sessionProofRejected
            }
            capabilities = try protocolBoundary.validateNegotiatedCapabilities(
                exactBytes: request.exactCapabilitiesBytes,
                expectedSHA256: request.capabilitiesSHA256,
                protocolMajor: request.protocolMajor,
                protocolMinor: request.protocolMinor
            )
        } catch {
            try await deleteChallenge(request.challengeID)
            try await auditAuthenticationFailure(
                code: "session-proof-rejected",
                at: openedAt
            )
            throw HarcHostError.sessionProofRejected
        }

        // Compute every fixed-size binding check before consulting admission so
        // valid and dummy challenges share the same pre-proof work ordering.
        let tlsMatches = HostAuthenticationCrypto.constantTimeEqual(
            request.tlsSPKISHA256,
            challenge.tlsSPKISHA256
        )
        let claimedHashMatches = HostAuthenticationCrypto.constantTimeEqual(
            request.capabilitiesSHA256,
            capabilities.sha256
        )
        let unexpired = now < HarcHostStore.unixTime(challenge.expiresAt)
        guard tlsMatches,
              claimedHashMatches,
              unexpired,
              challenge.isAdmitted,
              let deviceID = challenge.deviceID,
              let grantID = challenge.grantID,
              let grantEpoch = challenge.grantEpoch,
              let devicePublicKey = challenge.devicePublicKey else {
            try await deleteChallenge(request.challengeID)
            try await auditAuthenticationFailure(
                code: "session-proof-rejected",
                at: openedAt
            )
            throw HarcHostError.sessionProofRejected
        }

        do {
            try protocolBoundary.validateSessionProof(
                HostSessionProofValidationInput(
                    protocolMajor: request.protocolMajor,
                    protocolMinor: request.protocolMinor,
                    libraryID: store.expectedMetadata.libraryID,
                    hostAuthorityID: store.expectedMetadata.hostAuthorityID,
                    tlsSPKISHA256: challenge.tlsSPKISHA256,
                    deviceID: deviceID,
                    devicePublicKey: devicePublicKey,
                    grantID: grantID,
                    grantEpoch: grantEpoch,
                    challengeID: challenge.challengeID,
                    serverNonce: challenge.serverNonce,
                    clientNonce: request.clientNonce,
                    capabilitiesSHA256: capabilities.sha256,
                    clientSignature: request.clientSignature
                )
            )
        } catch {
            try await deleteChallenge(request.challengeID)
            try await auditAuthenticationFailure(
                code: "session-proof-rejected",
                at: openedAt
            )
            throw HarcHostError.sessionProofRejected
        }

        let tokenID = try randomness.randomUUID()
        guard tokenID != Self.zeroUUID else {
            try await deleteChallenge(request.challengeID)
            throw HarcHostError.invalidAuthenticationInput("session token identifier")
        }
        let tokenSecret = try randomness.randomBytes(count: 32)
        let binding = try HostAuthenticationCrypto.sessionTokenBinding(
            tokenID: tokenID,
            secret: tokenSecret
        )
        let expiresAt = openedAt.addingTimeInterval(Self.sessionLifetime)
        let expiry = HarcHostStore.unixTime(expiresAt)

        let created = try await store.dbQueue.write { db in
            guard let live = try Row.fetchOne(
                db,
                sql: """
                    SELECT c.*, d.status AS device_status,
                           d.current_grant_id AS live_grant_id,
                           d.current_grant_epoch AS live_grant_epoch,
                           d.grant_expires_at AS live_grant_expires_at,
                           d.trust_repair_required AS live_trust_repair_required,
                           d.public_key_x963 AS live_public_key_x963
                    FROM session_challenges c
                    JOIN devices d ON d.device_id = c.device_id
                    JOIN grants g
                      ON g.device_id = d.device_id
                     AND g.is_current = 1
                     AND g.grant_id = d.current_grant_id
                     AND g.grant_epoch = d.current_grant_epoch
                    WHERE c.challenge_id = ?
                    """,
                arguments: [request.challengeID.uuidString.lowercased()]
            ) else { return false }
            let isAdmitted: Int = live["is_admitted"]
            let challengeExpiry: Double = live["expires_at"]
            let deviceStatus: String = live["device_status"]
            let trustRepairRequired: Int = live["live_trust_repair_required"]
            let liveGrantID: String = live["live_grant_id"]
            let liveGrantEpoch: Int64 = live["live_grant_epoch"]
            let liveGrantExpiry: Double? = live["live_grant_expires_at"]
            let livePublicKey: Data = live["live_public_key_x963"]
            let durableServerNonce: Data = live["server_nonce"]
            let durableTLSSPKI: Data = live["tls_spki_sha256"]
            let durableProtocolMajor: Int64 = live["protocol_major"]
            let durableProtocolMinor: Int64 = live["protocol_minor"]
            let grantIsUnexpired = liveGrantExpiry.map { now < $0 } ?? true
            let challengeStillValid = isAdmitted == 1
                && challengeExpiry > now
                && durableServerNonce == challenge.serverNonce
                && durableTLSSPKI == challenge.tlsSPKISHA256
                && durableProtocolMajor == Int64(request.protocolMajor)
                && durableProtocolMinor == Int64(request.protocolMinor)
            let grantStillValid = deviceStatus == "active"
                && trustRepairRequired == 0
                && liveGrantID == grantID.description
                && liveGrantEpoch == Int64(grantEpoch.rawValue)
                && grantIsUnexpired
                && livePublicKey == devicePublicKey.rawBytes
            let stillValid = challengeStillValid && grantStillValid
            guard stillValid else {
                try db.execute(
                    sql: "DELETE FROM session_challenges WHERE challenge_id = ?",
                    arguments: [request.challengeID.uuidString.lowercased()]
                )
                return false
            }

            try db.execute(
                sql: "DELETE FROM session_challenges WHERE challenge_id = ?",
                arguments: [request.challengeID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else { return false }
            try db.execute(
                sql: """
                    INSERT INTO session_tokens (
                        token_id, token_binding_sha256, device_id, grant_id,
                        grant_epoch, tls_spki_sha256, exact_capabilities_bytes,
                        capabilities_sha256, protocol_major, protocol_minor,
                        selected_codec, selected_container, issued_at, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    tokenID.uuidString.lowercased(),
                    binding,
                    deviceID.rawBytes,
                    grantID.description,
                    Int64(grantEpoch.rawValue),
                    challenge.tlsSPKISHA256,
                    capabilities.exactBytes,
                    capabilities.sha256,
                    Int64(capabilities.protocolMajor),
                    Int64(capabilities.protocolMinor),
                    capabilities.selectedCodec,
                    capabilities.selectedContainer,
                    now,
                    expiry,
                ]
            )
            return true
        }
        guard created else {
            try await auditAuthenticationFailure(
                code: "session-proof-rejected",
                at: openedAt
            )
            throw HarcHostError.sessionProofRejected
        }

        var credential = HostAuthenticationCrypto.uuidBytes(tokenID)
        credential.append(tokenSecret)
        return HostOpenedSession(
            credential: credential,
            issuedAt: openedAt,
            expiresAt: expiresAt,
            capabilitiesSHA256: capabilities.sha256
        )
    }

    public func authenticate(
        credential: Data,
        tlsSPKISHA256: Data,
        requiredScope: AuthorizationScope? = nil
    ) async throws -> HostAuthenticatedSession {
        let checkedAt = store.now()
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.sessionCredentialRejected
        }
        guard credential.count == 48,
              tlsSPKISHA256.count == 32,
              let tokenID = HostAuthenticationCrypto.uuid(
                from: Data(credential.prefix(16))
              ) else {
            try await auditAuthenticationFailure(
                code: "session-credential-rejected",
                at: checkedAt
            )
            throw HarcHostError.sessionCredentialRejected
        }
        let secret = Data(credential.suffix(32))
        let presentedBinding = try HostAuthenticationCrypto.sessionTokenBinding(
            tokenID: tokenID,
            secret: secret
        )
        let now = HarcHostStore.unixTime(checkedAt)

        let session: HostAuthenticatedSession? = try await store.dbQueue.write { db in
            try Self.prune(in: db, at: now)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.*, d.status AS device_status,
                           d.current_grant_id AS live_grant_id,
                           d.current_grant_epoch AS live_grant_epoch,
                           d.scopes_json AS live_scopes_json,
                           d.grant_expires_at AS live_grant_expires_at,
                           d.trust_repair_required AS live_trust_repair_required
                    FROM session_tokens s
                    JOIN devices d ON d.device_id = s.device_id
                    JOIN grants g
                      ON g.device_id = d.device_id
                     AND g.is_current = 1
                     AND g.grant_id = d.current_grant_id
                     AND g.grant_epoch = d.current_grant_epoch
                    WHERE s.token_id = ?
                    """,
                arguments: [tokenID.uuidString.lowercased()]
            ) else { return nil }
            let bindingMatches = HostAuthenticationCrypto.constantTimeEqual(
                presentedBinding,
                row["token_binding_sha256"] as Data
            )
            let tlsMatches = HostAuthenticationCrypto.constantTimeEqual(
                tlsSPKISHA256,
                row["tls_spki_sha256"] as Data
            )
            guard bindingMatches,
                  tlsMatches,
                  row["invalidated_at"] as Double? == nil,
                  now < row["expires_at"] as Double,
                  row["device_status"] as String == "active",
                  row["live_trust_repair_required"] as Int == 0,
                  row["live_grant_id"] as String == row["grant_id"] as String,
                  row["live_grant_epoch"] as Int64 == row["grant_epoch"] as Int64,
                  (row["live_grant_expires_at"] as Double?).map({ now < $0 }) ?? true,
                  let deviceID = try? DeviceID(row["device_id"] as Data),
                  let grantUUID = UUID(uuidString: row["grant_id"] as String),
                  let epoch = try? GrantEpoch(
                    HarcHostStore.unsigned(
                        row["grant_epoch"] as Int64,
                        field: "sessionGrantEpoch"
                    )
                  ),
                  let protocolMinor = UInt16(
                    exactly: row["protocol_minor"] as Int64
                  ) else { return nil }
            let scopes = try HarcHostStore.decode(
                [AuthorizationScope].self,
                from: row["live_scopes_json"] as Data
            )
            if let requiredScope, !scopes.contains(requiredScope) {
                throw HarcHostError.missingScope(requiredScope)
            }
            return HostAuthenticatedSession(
                context: AuthenticatedDeviceContext(
                    libraryID: self.store.expectedMetadata.libraryID,
                    hostAuthorityID: self.store.expectedMetadata.hostAuthorityID,
                    authenticatedDeviceID: deviceID,
                    grantID: GrantID(grantUUID),
                    grantEpoch: epoch
                ),
                scopes: scopes,
                exactCapabilitiesBytes: row["exact_capabilities_bytes"] as Data,
                capabilitiesSHA256: row["capabilities_sha256"] as Data,
                protocolMinor: protocolMinor,
                selectedCodec: row["selected_codec"] as String,
                selectedContainer: row["selected_container"] as String,
                expiresAt: HarcHostStore.date(row["expires_at"] as Double)
            )
        }
        guard let session else {
            try await auditAuthenticationFailure(
                code: "session-credential-rejected",
                at: checkedAt
            )
            throw HarcHostError.sessionCredentialRejected
        }
        return session
    }

    public func pruneAuthenticationState() async throws {
        let time = HarcHostStore.unixTime(store.now())
        try await store.dbQueue.write { db in try Self.prune(in: db, at: time) }
    }

    private func challenge(_ challengeID: UUID) async throws -> SessionChallengeRecord? {
        try await store.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM session_challenges WHERE challenge_id = ?",
                arguments: [challengeID.uuidString.lowercased()]
            ) else { return nil }
            return try SessionChallengeRecord(row: row)
        }
    }

    private func deleteChallenge(_ challengeID: UUID) async throws {
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM session_challenges WHERE challenge_id = ?",
                arguments: [challengeID.uuidString.lowercased()]
            )
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

    nonisolated private static func prune(in db: Database, at time: Double) throws {
        // Section 13.3's method-specific single-use rule controls the broader
        // seven-day terminal-row retention language: challenges are the
        // exception and are deleted immediately on success, mismatch, or expiry.
        try db.execute(
            sql: "DELETE FROM session_challenges WHERE expires_at <= ?",
            arguments: [time]
        )
        let retentionCutoff = time - HostAuthenticationRetention.terminalRowLifetime
        try db.execute(
            sql: """
                DELETE FROM session_tokens
                WHERE (invalidated_at IS NULL AND expires_at <= ?)
                   OR (invalidated_at IS NOT NULL AND invalidated_at <= ?)
                """,
            arguments: [retentionCutoff, retentionCutoff]
        )
        try db.execute(
            sql: "DELETE FROM preauth_attempts WHERE occurred_at < ?",
            arguments: [time - (10 * 60)]
        )
        try HarcHostStore.expireAndPrunePairingRows(in: db, at: time)
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

private struct SessionChallengeRecord {
    let challengeID: UUID
    let isAdmitted: Bool
    let deviceID: DeviceID?
    let grantID: GrantID?
    let grantEpoch: GrantEpoch?
    let devicePublicKey: P256X963PublicKey?
    let serverNonce: Data
    let tlsSPKISHA256: Data
    let protocolMajor: UInt16
    let protocolMinor: UInt16
    let expiresAt: Date

    init(row: Row) throws {
        guard let challengeID = UUID(uuidString: row["challenge_id"] as String),
              let protocolMajor = UInt16(exactly: row["protocol_major"] as Int64),
              let protocolMinor = UInt16(exactly: row["protocol_minor"] as Int64) else {
            throw HarcHostError.databaseFailure("Malformed durable session challenge.")
        }
        self.challengeID = challengeID
        isAdmitted = row["is_admitted"] as Int == 1
        if isAdmitted {
            guard let grantUUID = UUID(uuidString: row["grant_id"] as String) else {
                throw HarcHostError.databaseFailure("Malformed admitted session grant.")
            }
            deviceID = try DeviceID(row["device_id"] as Data)
            grantID = GrantID(grantUUID)
            grantEpoch = try GrantEpoch(
                HarcHostStore.unsigned(
                    row["grant_epoch"] as Int64,
                    field: "challengeGrantEpoch"
                )
            )
            devicePublicKey = try P256X963PublicKey(
                row["device_public_key_x963"] as Data
            )
        } else {
            deviceID = nil
            grantID = nil
            grantEpoch = nil
            devicePublicKey = nil
        }
        serverNonce = row["server_nonce"] as Data
        tlsSPKISHA256 = row["tls_spki_sha256"] as Data
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        expiresAt = HarcHostStore.date(row["expires_at"] as Double)
    }
}

extension HarcHostStore {
    nonisolated func insertAuthenticationFailure(
        in db: Database,
        at date: Date,
        code: String
    ) throws {
        try insertAuditEvent(
            in: db,
            occurredAt: date,
            severity: .warning,
            category: "authentication",
            code: code,
            deviceID: nil,
            aggregationKey: "authentication:\(code)"
        )
        try pruneAuditEvents(in: db, at: date)
    }

    static func expireAndPrunePairingRows(
        in db: Database,
        at time: Double
    ) throws {
        try db.execute(
            sql: """
                UPDATE pairing_attempts
                SET state = 'expired', terminal_at = expires_at, updated_at = ?
                WHERE protocol_state_version = 1
                  AND state IN ('reserved', 'proofVerified', 'awaitingApproval')
                  AND expires_at <= ?
                  AND (
                      state != 'awaitingApproval'
                      OR NOT EXISTS (SELECT 1 FROM pending_security_mutations)
                  )
                """,
            arguments: [time, time]
        )
        try db.execute(
            sql: """
                UPDATE pairing_tickets
                SET state = 'expired', updated_at = ?
                WHERE state IN ('issued', 'reserved', 'approved')
                  AND expires_at <= ?
                  AND (
                      state != 'approved'
                      OR NOT EXISTS (SELECT 1 FROM pending_security_mutations)
                  )
                """,
            arguments: [time, time]
        )

        let cutoff = time - HostAuthenticationRetention.terminalRowLifetime
        // Delete attempts first because their ticket reference is restrictive.
        try db.execute(
            sql: """
                DELETE FROM pairing_attempts
                WHERE (state = 'expired' AND expires_at <= ?)
                   OR (state IN ('approved', 'denied', 'cancelled')
                       AND COALESCE(terminal_at, updated_at) <= ?)
                """,
            arguments: [cutoff, cutoff]
        )
        try db.execute(
            sql: """
                DELETE FROM pairing_tickets
                WHERE (state = 'expired' AND expires_at <= ?)
                   OR (state IN ('consumed', 'cancelled') AND updated_at <= ?)
                """,
            arguments: [cutoff, cutoff]
        )
    }

    func pruneAuthenticationJournalOnReopen() async throws {
        let time = Self.unixTime(now())
        try await dbQueue.write { db in
            // Challenges are the method-specific immediate-deletion exception
            // to the seven-day retention rule for other terminal auth rows.
            try db.execute(
                sql: "DELETE FROM session_challenges WHERE expires_at <= ?",
                arguments: [time]
            )
            let cutoff = time - HostAuthenticationRetention.terminalRowLifetime
            try db.execute(
                sql: """
                    DELETE FROM session_tokens
                    WHERE (invalidated_at IS NULL AND expires_at <= ?)
                       OR (invalidated_at IS NOT NULL AND invalidated_at <= ?)
                    """,
                arguments: [cutoff, cutoff]
            )
            try db.execute(
                sql: "DELETE FROM preauth_attempts WHERE occurred_at < ?",
                arguments: [time - (10 * 60)]
            )
            try Self.expireAndPrunePairingRows(in: db, at: time)
        }
    }
}
