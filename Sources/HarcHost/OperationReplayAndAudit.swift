import Foundation
import GRDB
import HarcDomain
import HarcIdentity

private let hostOperationPayloadLimit = 1 * 1_024 * 1_024

private enum AppliedOperationDatabaseDisposition {
    case accepted(Data)
    case exactReplay(Data)
    case prepared
    case requestConflict
    case capacity
}

private enum PreparedOperationDatabaseDisposition {
    case prepared
    case exactPrepared(Data)
    case alreadyApplied(Data)
    case requestConflict
    case effectConflict
    case capacity
}

private enum CompletePreparedOperationDatabaseDisposition {
    case accepted(Data)
    case exactReplay(Data)
    case missing
    case requestConflict
    case effectConflict
    case resultConflict
}

extension HarcHostStore {
    /// Checks durable replay state and applies a HarcHost.db effect in one
    /// SQLite transaction. `apply` is invoked exactly once for a newly
    /// accepted replay tuple and is never invoked for an exact replay.
    ///
    /// The closure must only mutate the supplied HarcHost.db `Database`. It
    /// must not perform filesystem, network, keychain, or other cross-database
    /// effects, because those cannot roll back with this transaction. Use the
    /// explicit prepared/applied API below for such effects.
    package func checkAndApplyHostDatabaseOperation(
        context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        messageType: String,
        operationID: OperationID,
        issuedAt: Date,
        expiresAt: Date,
        exactRequestBytes: Data,
        apply: @escaping @Sendable (Database) throws -> Data
    ) async throws -> HostOperationReplayDisposition {
        try await checkAndApplyHostDatabaseOperation(
            context: context,
            requiredScope: requiredScope,
            messageType: messageType,
            operationID: operationID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: exactRequestBytes,
            at: now(),
            apply: apply
        )
    }

    /// Deterministic `@testable` seam. Production initial acceptance always
    /// derives its time from the store's injected clock.
    func checkAndApplyHostDatabaseOperation(
        context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        messageType: String,
        operationID: OperationID,
        issuedAt: Date,
        expiresAt: Date,
        exactRequestBytes: Data,
        at date: Date,
        apply: @escaping @Sendable (Database) throws -> Data
    ) async throws -> HostOperationReplayDisposition {
        try await repairSecurityRegistryOnReopen()
        let acceptedAt = date
        try Self.validateOperationEnvelopeShape(
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            acceptedAt: acceptedAt,
            exactRequestBytes: exactRequestBytes
        )
        let key = try operationReplayKey(
            context: context,
            messageType: messageType,
            operationID: operationID
        )
        let requestFingerprint = Self.digest(exactRequestBytes)

        let disposition: AppliedOperationDatabaseDisposition = try await dbQueue.write { db in
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: requiredScope,
                objectOwner: nil,
                at: acceptedAt
            )

            if let row = try self.operationRow(for: key, in: db) {
                guard try self.operationRequestMatches(
                    row,
                    exactRequestBytes: exactRequestBytes,
                    requestFingerprint: requestFingerprint
                ) else {
                    try self.auditOperationRequestConflict(
                        in: db,
                        context: context,
                        at: acceptedAt
                    )
                    return .requestConflict
                }
                switch row["application_state"] as String {
                case "prepared":
                    return .prepared
                case "applied":
                    return .exactReplay(try self.validatedOperationResult(row))
                default:
                    throw HarcHostError.databaseFailure("Unknown processed operation state.")
                }
            }

            try Self.validateOperationInitialAcceptance(
                expiresAt: expiresAt,
                acceptedAt: acceptedAt
            )
            guard try self.makeOperationCapacity(
                in: db,
                deviceID: context.authenticatedDeviceID,
                at: acceptedAt
            ) else { return .capacity }

            // Both the caller's HostDB mutations and this applied journal row
            // commit or roll back together.
            let originalResult = try apply(db)
            guard originalResult.count <= hostOperationPayloadLimit else {
                throw HarcHostError.operationPayloadTooLarge
            }
            try self.insertAppliedOperation(
                key: key,
                exactRequestBytes: exactRequestBytes,
                requestFingerprint: requestFingerprint,
                preparedEffect: nil,
                originalResult: originalResult,
                expiresAt: expiresAt,
                acceptedAt: acceptedAt,
                in: db
            )
            return .accepted(originalResult)
        }

        switch disposition {
        case .accepted(let result): return .accepted(originalResult: result)
        case .exactReplay(let result): return .exactReplay(originalResult: result)
        case .prepared: throw HarcHostError.operationPreparedRequiresRecovery
        case .requestConflict: throw HarcHostError.replayConflict
        case .capacity: throw HarcHostError.operationCapacityExhausted
        }
    }

    /// Durably journals the exact effect description before a future executor
    /// touches another database, the filesystem, keychain, or a remote system.
    /// An exact prepared replay means the executor must inspect that system by
    /// `operationID`; it must never blindly repeat a non-idempotent effect.
    package func prepareExternalOperationEffect(
        context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        messageType: String,
        operationID: OperationID,
        issuedAt: Date,
        expiresAt: Date,
        exactRequestBytes: Data,
        preparedEffect: Data
    ) async throws -> HostPreparedOperationDisposition {
        try await prepareExternalOperationEffect(
            context: context,
            requiredScope: requiredScope,
            messageType: messageType,
            operationID: operationID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: exactRequestBytes,
            preparedEffect: preparedEffect,
            at: now()
        )
    }

    /// Deterministic `@testable` seam. Production initial acceptance always
    /// derives its time from the store's injected clock.
    func prepareExternalOperationEffect(
        context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        messageType: String,
        operationID: OperationID,
        issuedAt: Date,
        expiresAt: Date,
        exactRequestBytes: Data,
        preparedEffect: Data,
        at date: Date
    ) async throws -> HostPreparedOperationDisposition {
        try await repairSecurityRegistryOnReopen()
        let acceptedAt = date
        try Self.validateOperationEnvelopeShape(
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            acceptedAt: acceptedAt,
            exactRequestBytes: exactRequestBytes
        )
        guard preparedEffect.count <= hostOperationPayloadLimit else {
            throw HarcHostError.operationPayloadTooLarge
        }
        let key = try operationReplayKey(
            context: context,
            messageType: messageType,
            operationID: operationID
        )
        let requestFingerprint = Self.digest(exactRequestBytes)

        let disposition: PreparedOperationDatabaseDisposition = try await dbQueue.write { db in
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: requiredScope,
                objectOwner: nil,
                at: acceptedAt
            )
            if let row = try self.operationRow(for: key, in: db) {
                guard try self.operationRequestMatches(
                    row,
                    exactRequestBytes: exactRequestBytes,
                    requestFingerprint: requestFingerprint
                ) else {
                    try self.auditOperationRequestConflict(
                        in: db,
                        context: context,
                        at: acceptedAt
                    )
                    return .requestConflict
                }
                switch row["application_state"] as String {
                case "prepared":
                    guard row["prepared_effect"] as Data? == preparedEffect else {
                        return .effectConflict
                    }
                    return .exactPrepared(preparedEffect)
                case "applied":
                    if let durableEffect = row["prepared_effect"] as Data?,
                       durableEffect != preparedEffect {
                        return .effectConflict
                    }
                    return .alreadyApplied(try self.validatedOperationResult(row))
                default:
                    throw HarcHostError.databaseFailure("Unknown processed operation state.")
                }
            }

            try Self.validateOperationInitialAcceptance(
                expiresAt: expiresAt,
                acceptedAt: acceptedAt
            )
            guard try self.makeOperationCapacity(
                in: db,
                deviceID: context.authenticatedDeviceID,
                at: acceptedAt
            ) else { return .capacity }
            try db.execute(
                sql: """
                    INSERT INTO processed_operations (
                        library_id, host_authority_id, message_type,
                        signer_kind, signer_identity, operation_id,
                        exact_request_bytes, request_fingerprint,
                        application_state, prepared_effect,
                        result_fingerprint, original_result,
                        command_expires_at, accepted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?, NULL, NULL, ?, ?)
                    """,
                arguments: self.operationArguments(for: key) + [
                    exactRequestBytes,
                    requestFingerprint,
                    preparedEffect,
                    Self.unixTime(expiresAt),
                    Self.unixTime(acceptedAt),
                ]
            )
            return .prepared
        }

        switch disposition {
        case .prepared: return .prepared
        case .exactPrepared(let effect): return .exactPreparedReplay(preparedEffect: effect)
        case .alreadyApplied(let result): return .alreadyApplied(originalResult: result)
        case .requestConflict: throw HarcHostError.replayConflict
        case .effectConflict: throw HarcHostError.preparedEffectConflict
        case .capacity: throw HarcHostError.operationCapacityExhausted
        }
    }

    /// Completes a prepared journal row only after a trusted executor has
    /// reconciled the external effect by the durable operation identity. This
    /// transition is restart-safe: if the process dies before this call, the
    /// row remains `prepared`; after it commits, exact retries return the
    /// original result and do not apply the effect again.
    package func markPreparedOperationApplied(
        key: HostOperationReplayKey,
        exactRequestBytes: Data,
        preparedEffect: Data,
        originalResult: Data
    ) async throws -> HostOperationReplayDisposition {
        try await repairSecurityRegistryOnReopen()
        guard exactRequestBytes.count <= hostOperationPayloadLimit,
              preparedEffect.count <= hostOperationPayloadLimit,
              originalResult.count <= hostOperationPayloadLimit else {
            throw HarcHostError.operationPayloadTooLarge
        }
        let requestFingerprint = Self.digest(exactRequestBytes)
        let disposition: CompletePreparedOperationDatabaseDisposition = try await dbQueue.write { db in
            guard let row = try self.operationRow(for: key, in: db) else { return .missing }
            guard try self.operationRequestMatches(
                row,
                exactRequestBytes: exactRequestBytes,
                requestFingerprint: requestFingerprint
            ) else { return .requestConflict }
            guard row["prepared_effect"] as Data? == preparedEffect else {
                return .effectConflict
            }
            switch row["application_state"] as String {
            case "prepared":
                try db.execute(
                    sql: """
                        UPDATE processed_operations
                        SET application_state = 'applied',
                            result_fingerprint = ?, original_result = ?
                        WHERE library_id = ? AND host_authority_id = ?
                          AND message_type = ? AND signer_kind = ?
                          AND signer_identity = ? AND operation_id = ?
                          AND application_state = 'prepared'
                        """,
                    arguments: [Self.digest(originalResult), originalResult]
                        + self.operationArguments(for: key)
                )
                guard db.changesCount == 1 else {
                    throw HarcHostError.databaseFailure("Prepared operation transition was lost.")
                }
                return .accepted(originalResult)
            case "applied":
                let stored = try self.validatedOperationResult(row)
                guard stored == originalResult else { return .resultConflict }
                return .exactReplay(stored)
            default:
                throw HarcHostError.databaseFailure("Unknown processed operation state.")
            }
        }
        switch disposition {
        case .accepted(let result): return .accepted(originalResult: result)
        case .exactReplay(let result): return .exactReplay(originalResult: result)
        case .missing: throw HarcHostError.operationPreparedRequiresRecovery
        case .requestConflict: throw HarcHostError.replayConflict
        case .effectConflict: throw HarcHostError.preparedEffectConflict
        case .resultConflict: throw HarcHostError.operationResultConflict
        }
    }

    /// Validates the envelope invariants that are safe to apply to both a
    /// first-seen command and an exact replay. Expiry is intentionally checked
    /// only after the durable replay lookup: expiry supplements persistent
    /// replay detection and must not erase an accepted command's identity.
    private static func validateOperationEnvelopeShape(
        issuedAt: Date,
        expiresAt: Date,
        acceptedAt: Date,
        exactRequestBytes: Data
    ) throws {
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              acceptedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 7 * 24 * 60 * 60 else {
            throw HarcHostError.commandExpired
        }
        guard issuedAt.timeIntervalSince(acceptedAt) <= 5 * 60 else {
            throw HarcHostError.commandIssuedInFuture
        }
        guard exactRequestBytes.count <= hostOperationPayloadLimit else {
            throw HarcHostError.operationPayloadTooLarge
        }
    }

    private static func validateOperationInitialAcceptance(
        expiresAt: Date,
        acceptedAt: Date
    ) throws {
        guard acceptedAt < expiresAt else { throw HarcHostError.commandExpired }
    }

    nonisolated private func operationReplayKey(
        context: AuthenticatedDeviceContext,
        messageType: String,
        operationID: OperationID
    ) throws -> HostOperationReplayKey {
        try HostOperationReplayKey(
            libraryID: context.libraryID,
            hostAuthorityID: context.hostAuthorityID,
            messageType: messageType,
            signer: .device(context.authenticatedDeviceID),
            operationID: operationID
        )
    }

    nonisolated private func operationArguments(
        for key: HostOperationReplayKey
    ) -> StatementArguments {
        [
            key.libraryID.description,
            key.hostAuthorityID.rawBytes,
            key.messageType,
            key.signer.databaseKind,
            key.signer.databaseIdentity,
            key.operationID.description,
        ]
    }

    nonisolated private func operationRow(
        for key: HostOperationReplayKey,
        in db: Database
    ) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT exact_request_bytes, request_fingerprint,
                       application_state, prepared_effect,
                       result_fingerprint, original_result
                FROM processed_operations
                WHERE library_id = ? AND host_authority_id = ?
                  AND message_type = ? AND signer_kind = ?
                  AND signer_identity = ? AND operation_id = ?
                """,
            arguments: operationArguments(for: key)
        )
    }

    nonisolated private func operationRequestMatches(
        _ row: Row,
        exactRequestBytes: Data,
        requestFingerprint: Data
    ) throws -> Bool {
        let storedRequest = row["exact_request_bytes"] as Data
        let storedFingerprint = row["request_fingerprint"] as Data
        guard storedFingerprint == Self.digest(storedRequest) else {
            throw HarcHostError.databaseFailure("Stored operation request fingerprint mismatch.")
        }
        return storedRequest == exactRequestBytes && storedFingerprint == requestFingerprint
    }

    nonisolated private func validatedOperationResult(_ row: Row) throws -> Data {
        guard let storedResult = row["original_result"] as Data?,
              let storedFingerprint = row["result_fingerprint"] as Data?,
              storedFingerprint == Self.digest(storedResult) else {
            throw HarcHostError.databaseFailure("Stored operation result fingerprint mismatch.")
        }
        return storedResult
    }

    nonisolated private func auditOperationRequestConflict(
        in db: Database,
        context: AuthenticatedDeviceContext,
        at acceptedAt: Date
    ) throws {
        try insertAuditEvent(
            in: db,
            occurredAt: acceptedAt,
            severity: .security,
            category: "operation-replay",
            code: "request-fingerprint-conflict",
            deviceID: context.authenticatedDeviceID
        )
        try pruneAuditEvents(in: db, at: acceptedAt)
    }

    nonisolated private func makeOperationCapacity(
        in db: Database,
        deviceID: DeviceID,
        at acceptedAt: Date
    ) throws -> Bool {
        // Replay identity is permanent. Applied rows retain their exact result
        // because an exact replay must be able to return it even after command
        // expiry. There is therefore no currently safe payload/result
        // tombstoning rule; capacity exhaustion fails closed instead of
        // deleting the evidence that distinguishes replay from equivocation.
        let retainedCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM processed_operations
                WHERE signer_kind = 'device' AND signer_identity = ?
                """,
            arguments: [deviceID.rawBytes]
        ) ?? 0
        guard retainedCount < operationMaximumRowsPerDevice else {
            try insertAuditEvent(
                in: db,
                occurredAt: acceptedAt,
                severity: .warning,
                category: "operation-replay",
                code: "capacity-exhausted",
                deviceID: deviceID
            )
            try pruneAuditEvents(in: db, at: acceptedAt)
            return false
        }
        return true
    }

    nonisolated private func insertAppliedOperation(
        key: HostOperationReplayKey,
        exactRequestBytes: Data,
        requestFingerprint: Data,
        preparedEffect: Data?,
        originalResult: Data,
        expiresAt: Date,
        acceptedAt: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO processed_operations (
                    library_id, host_authority_id, message_type,
                    signer_kind, signer_identity, operation_id,
                    exact_request_bytes, request_fingerprint,
                    application_state, prepared_effect,
                    result_fingerprint, original_result,
                    command_expires_at, accepted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'applied', ?, ?, ?, ?, ?)
                """,
            arguments: operationArguments(for: key) + [
                exactRequestBytes,
                requestFingerprint,
                preparedEffect,
                Self.digest(originalResult),
                originalResult,
                Self.unixTime(expiresAt),
                Self.unixTime(acceptedAt),
            ]
        )
    }
}

extension HarcHostStore {
    nonisolated func insertAuditEvent(
        in db: Database,
        occurredAt: Date,
        severity: HostAuditSeverity,
        category: String,
        code: String,
        deviceID: DeviceID?,
        aggregationKey: String? = nil
    ) throws {
        let eventTime = Self.unixTime(occurredAt)
        if let aggregationKey,
           let row = try Row.fetchOne(
               db,
               sql: """
                   SELECT id, aggregate_count FROM audit_events
                   WHERE aggregation_key = ? AND occurred_at >= ?
                   ORDER BY id DESC LIMIT 1
                   """,
               arguments: [aggregationKey, eventTime - 60]
           ) {
            let id = row["id"] as Int64
            let count = row["aggregate_count"] as Int64
            try db.execute(
                sql: "UPDATE audit_events SET aggregate_count = ?, occurred_at = ? WHERE id = ?",
                arguments: [count + 1, eventTime, id]
            )
            return
        }
        try db.execute(
            sql: """
                INSERT INTO audit_events (
                    occurred_at, severity, category, code, device_id,
                    aggregation_key, aggregate_count
                ) VALUES (?, ?, ?, ?, ?, ?, 1)
                """,
            arguments: [
                eventTime,
                severity.rawValue,
                category,
                code,
                deviceID?.rawBytes,
                aggregationKey,
            ]
        )
    }

    nonisolated func pruneAuditEvents(in db: Database, at date: Date) throws {
        let ageThreshold = Self.unixTime(date.addingTimeInterval(-30 * 24 * 60 * 60))
        try db.execute(
            sql: "DELETE FROM audit_events WHERE occurred_at < ?",
            arguments: [ageThreshold]
        )
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_events") ?? 0
        let overflow = count - auditMaximumRows
        if overflow > 0 {
            try db.execute(
                sql: """
                    DELETE FROM audit_events WHERE id IN (
                        SELECT id FROM audit_events ORDER BY occurred_at, id LIMIT ?
                    )
                    """,
                arguments: [overflow]
            )
        }
    }

    public func pruneAuditEvents() async throws {
        let pruneAt = now()
        try await dbQueue.write { db in
            try self.pruneAuditEvents(in: db, at: pruneAt)
        }
    }

    public func auditEvents(limit: Int = 100) async throws -> [HostAuditEvent] {
        let boundedLimit = max(1, min(limit, 1_000))
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, occurred_at, severity, category, code,
                           device_id, aggregate_count
                    FROM audit_events ORDER BY id DESC LIMIT ?
                    """,
                arguments: [boundedLimit]
            )
            return try rows.map { row in
                guard let severity = HostAuditSeverity(rawValue: row["severity"] as String) else {
                    throw HarcHostError.databaseFailure("Unknown audit severity.")
                }
                let deviceBytes = row["device_id"] as Data?
                return HostAuditEvent(
                    id: row["id"],
                    occurredAt: Self.date(row["occurred_at"] as Double),
                    severity: severity,
                    category: row["category"],
                    code: row["code"],
                    deviceID: try deviceBytes.map(DeviceID.init),
                    aggregateCount: try Self.unsigned(row["aggregate_count"] as Int64, field: "auditAggregateCount")
                )
            }
        }
    }
}
