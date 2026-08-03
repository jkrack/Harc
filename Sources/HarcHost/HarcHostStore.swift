import CryptoKit
import Darwin
import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcTransfer

/// Sole owner of `HarcHost.db`. The actor is transport-independent: loopback,
/// future gRPC, HTTPS, and authenticated local IPC all call this same service.
public actor HarcHostStore {
    enum DeferredServingBootstrapState: Equatable, Sendable {
        case active
        case awaitingSecurityPreflight
        case securityReconciled
    }

    private enum BootstrapMode: Sendable {
        case immediate
        case deferredServing
    }

    nonisolated let dbQueue: DatabaseQueue
    nonisolated let stagingRoot: URL
    nonisolated let stagingDirectory: HostStagingDirectory
    nonisolated let expectedMetadata: HarcHostMetadata
    nonisolated let highWaterMarkStore: any SecurityRegistryHighWaterMarkStore
    nonisolated let localOSAuthenticationBoundary: any HostLocalOSAuthenticationBoundary
    nonisolated let securityFailureInjector: any SecurityRegistryFailureInjector
    nonisolated let stagingFailureInjector: any StagingFailureInjector
    nonisolated let quotaPolicy: HostStagingQuotaPolicy
    nonisolated let capacityProvider: any HostVolumeCapacityProvider
    nonisolated let auditMaximumRows: Int
    nonisolated let operationMaximumRowsPerDevice: Int
    nonisolated let now: @Sendable () -> Date
    nonisolated let authorityMutationCoordinator: HostAuthorityMutationCoordinator
    var securityRegistryTransitionActive = false
    var activeSecurityRegistryRepair: ActiveSecurityRegistryRepair?
    var activeStagingWrites: Set<HostActiveStagingWrite> = []
    var deferredServingBootstrapState: DeferredServingBootstrapState

    public nonisolated var dbReader: any DatabaseReader { dbQueue }

    public static func defaultDatabaseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harc/HarcHost.db")
    }

    public static func defaultStagingRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harc/RemoteUploadStaging", isDirectory: true)
    }

    public static func onDisk(
        databaseURL: URL = defaultDatabaseURL(),
        stagingRoot: URL = defaultStagingRoot(),
        metadata: HarcHostMetadata,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore,
        localOSAuthenticationBoundary: any HostLocalOSAuthenticationBoundary = RejectingHostLocalOSAuthenticationBoundary(),
        securityFailureInjector: any SecurityRegistryFailureInjector = NoSecurityRegistryFailureInjector(),
        stagingFailureInjector: any StagingFailureInjector = NoStagingFailureInjector(),
        quotaPolicy: HostStagingQuotaPolicy = HostStagingQuotaPolicy(),
        capacityProvider: any HostVolumeCapacityProvider = FileSystemHostVolumeCapacityProvider(),
        auditMaximumRows: Int = 100_000,
        operationMaximumRowsPerDevice: Int = 100_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> HarcHostStore {
        do {
            try ensureHostGeneratedDirectory(databaseURL.deletingLastPathComponent())
            try ensureHostGeneratedDirectory(stagingRoot)
        } catch let error as HarcHostError {
            throw error
        } catch {
            throw HarcHostError.databaseOpenFailed(error.localizedDescription)
        }

        let queue: DatabaseQueue
        do {
            var configuration = Configuration()
            configuration.busyMode = .timeout(5)
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA synchronous = FULL")
            }
            queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        } catch {
            throw HarcHostError.databaseOpenFailed(error.localizedDescription)
        }
        return try await make(
            queue: queue,
            stagingRoot: stagingRoot,
            metadata: metadata,
            highWaterMarkStore: highWaterMarkStore,
            localOSAuthenticationBoundary: localOSAuthenticationBoundary,
            securityFailureInjector: securityFailureInjector,
            stagingFailureInjector: stagingFailureInjector,
            quotaPolicy: quotaPolicy,
            capacityProvider: capacityProvider,
            auditMaximumRows: auditMaximumRows,
            operationMaximumRowsPerDevice: operationMaximumRowsPerDevice,
            now: now,
            bootstrapMode: .immediate
        )
    }

    /// Production serving open. Schema/resource setup and an exact read-only
    /// identity check run here, but neither durable security journal is repaired.
    /// The serving runtime must hold `withServingRecoverySecurityExclusion`,
    /// preflight both journals, reconcile them, and complete the deferred
    /// bootstrap before opening a listener.
    package static func onDiskDeferredForServing(
        databaseURL: URL = defaultDatabaseURL(),
        stagingRoot: URL = defaultStagingRoot(),
        metadata: HarcHostMetadata,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore,
        localOSAuthenticationBoundary: any HostLocalOSAuthenticationBoundary = RejectingHostLocalOSAuthenticationBoundary(),
        securityFailureInjector: any SecurityRegistryFailureInjector = NoSecurityRegistryFailureInjector(),
        stagingFailureInjector: any StagingFailureInjector = NoStagingFailureInjector(),
        quotaPolicy: HostStagingQuotaPolicy = HostStagingQuotaPolicy(),
        capacityProvider: any HostVolumeCapacityProvider = FileSystemHostVolumeCapacityProvider(),
        auditMaximumRows: Int = 100_000,
        operationMaximumRowsPerDevice: Int = 100_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> HarcHostStore {
        do {
            try ensureHostGeneratedDirectory(databaseURL.deletingLastPathComponent())
            try ensureHostGeneratedDirectory(stagingRoot)
        } catch let error as HarcHostError {
            throw error
        } catch {
            throw HarcHostError.databaseOpenFailed(error.localizedDescription)
        }

        let queue: DatabaseQueue
        do {
            var configuration = Configuration()
            configuration.busyMode = .timeout(5)
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA synchronous = FULL")
            }
            queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        } catch {
            throw HarcHostError.databaseOpenFailed(error.localizedDescription)
        }
        return try await make(
            queue: queue,
            stagingRoot: stagingRoot,
            metadata: metadata,
            highWaterMarkStore: highWaterMarkStore,
            localOSAuthenticationBoundary: localOSAuthenticationBoundary,
            securityFailureInjector: securityFailureInjector,
            stagingFailureInjector: stagingFailureInjector,
            quotaPolicy: quotaPolicy,
            capacityProvider: capacityProvider,
            auditMaximumRows: auditMaximumRows,
            operationMaximumRowsPerDevice: operationMaximumRowsPerDevice,
            now: now,
            bootstrapMode: .deferredServing
        )
    }

    public static func inMemory(
        stagingRoot: URL,
        metadata: HarcHostMetadata,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore = InMemorySecurityRegistryHighWaterMarkStore(),
        localOSAuthenticationBoundary: any HostLocalOSAuthenticationBoundary = RejectingHostLocalOSAuthenticationBoundary(),
        securityFailureInjector: any SecurityRegistryFailureInjector = NoSecurityRegistryFailureInjector(),
        stagingFailureInjector: any StagingFailureInjector = NoStagingFailureInjector(),
        quotaPolicy: HostStagingQuotaPolicy = HostStagingQuotaPolicy(),
        capacityProvider: any HostVolumeCapacityProvider = FileSystemHostVolumeCapacityProvider(),
        auditMaximumRows: Int = 100_000,
        operationMaximumRowsPerDevice: Int = 100_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> HarcHostStore {
        try ensureHostGeneratedDirectory(stagingRoot)
        let queue: DatabaseQueue
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA synchronous = FULL")
            }
            queue = try DatabaseQueue(configuration: configuration)
        } catch {
            throw HarcHostError.databaseOpenFailed(error.localizedDescription)
        }
        return try await make(
            queue: queue,
            stagingRoot: stagingRoot,
            metadata: metadata,
            highWaterMarkStore: highWaterMarkStore,
            localOSAuthenticationBoundary: localOSAuthenticationBoundary,
            securityFailureInjector: securityFailureInjector,
            stagingFailureInjector: stagingFailureInjector,
            quotaPolicy: quotaPolicy,
            capacityProvider: capacityProvider,
            auditMaximumRows: auditMaximumRows,
            operationMaximumRowsPerDevice: operationMaximumRowsPerDevice,
            now: now,
            bootstrapMode: .immediate
        )
    }

    private static func make(
        queue: DatabaseQueue,
        stagingRoot: URL,
        metadata: HarcHostMetadata,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore,
        localOSAuthenticationBoundary: any HostLocalOSAuthenticationBoundary,
        securityFailureInjector: any SecurityRegistryFailureInjector,
        stagingFailureInjector: any StagingFailureInjector,
        quotaPolicy: HostStagingQuotaPolicy,
        capacityProvider: any HostVolumeCapacityProvider,
        auditMaximumRows: Int,
        operationMaximumRowsPerDevice: Int,
        now: @escaping @Sendable () -> Date,
        bootstrapMode: BootstrapMode
    ) async throws -> HarcHostStore {
        guard auditMaximumRows > 0, operationMaximumRowsPerDevice > 0 else {
            throw HarcHostError.databaseFailure("Retention limits must be positive.")
        }
        do {
            try DatabaseMigrator.harcHostMigrator().migrate(queue)
        } catch {
            throw HarcHostError.migrationFailed(error.localizedDescription)
        }
        let trustedStagingDirectory: HostStagingDirectory
        do {
            trustedStagingDirectory = try HostStagingDirectory(root: stagingRoot)
        } catch let error as HarcHostError {
            throw error
        } catch {
            throw HarcHostError.unsafeStagingRoot
        }
        let initialBootstrapState: DeferredServingBootstrapState
        switch bootstrapMode {
        case .immediate:
            initialBootstrapState = .active
        case .deferredServing:
            initialBootstrapState = .awaitingSecurityPreflight
        }
        let store = HarcHostStore(
            dbQueue: queue,
            stagingDirectory: trustedStagingDirectory,
            metadata: metadata,
            highWaterMarkStore: highWaterMarkStore,
            localOSAuthenticationBoundary: localOSAuthenticationBoundary,
            securityFailureInjector: securityFailureInjector,
            stagingFailureInjector: stagingFailureInjector,
            quotaPolicy: quotaPolicy,
            capacityProvider: capacityProvider,
            auditMaximumRows: auditMaximumRows,
            operationMaximumRowsPerDevice: operationMaximumRowsPerDevice,
            now: now,
            deferredServingBootstrapState: initialBootstrapState
        )
        try await store.bootstrap(mode: bootstrapMode)
        return store
    }

    private init(
        dbQueue: DatabaseQueue,
        stagingDirectory: HostStagingDirectory,
        metadata: HarcHostMetadata,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore,
        localOSAuthenticationBoundary: any HostLocalOSAuthenticationBoundary,
        securityFailureInjector: any SecurityRegistryFailureInjector,
        stagingFailureInjector: any StagingFailureInjector,
        quotaPolicy: HostStagingQuotaPolicy,
        capacityProvider: any HostVolumeCapacityProvider,
        auditMaximumRows: Int,
        operationMaximumRowsPerDevice: Int,
        now: @escaping @Sendable () -> Date,
        deferredServingBootstrapState: DeferredServingBootstrapState
    ) {
        self.dbQueue = dbQueue
        self.stagingDirectory = stagingDirectory
        self.stagingRoot = stagingDirectory.rootURL
        self.expectedMetadata = metadata
        self.highWaterMarkStore = highWaterMarkStore
        self.localOSAuthenticationBoundary = localOSAuthenticationBoundary
        self.securityFailureInjector = securityFailureInjector
        self.stagingFailureInjector = stagingFailureInjector
        self.quotaPolicy = quotaPolicy
        self.capacityProvider = capacityProvider
        self.auditMaximumRows = auditMaximumRows
        self.operationMaximumRowsPerDevice = operationMaximumRowsPerDevice
        self.now = now
        self.authorityMutationCoordinator = HostAuthorityMutationCoordinator()
        self.deferredServingBootstrapState = deferredServingBootstrapState
    }

    private func bootstrap(mode: BootstrapMode) async throws {
        try Self.ensureSafeStagingRoot(stagingRoot)
        switch mode {
        case .immediate:
            try await initializeOrValidateMetadata()
            try await repairSecurityRegistryOnReopen()
        case .deferredServing:
            try await validateExistingMetadataForDeferredServing()
            return
        }
        try await pruneAuthenticationJournalOnReopen()
        try await validateUploadPersistenceOnReopen()
        try await reconcileStagingJournalOnReopen()
        try await pruneAuditEvents()
    }

    package func completeDeferredServingBootstrap() async throws {
        guard deferredServingBootstrapState == .securityReconciled else {
            throw HarcHostError.deferredServingBootstrapRequired
        }
        try await pruneAuthenticationJournalOnReopen()
        try await validateUploadPersistenceOnReopen()
        try await reconcileStagingJournalOnReopen()
        try await pruneAuditEvents()
        deferredServingBootstrapState = .active
    }

    package func requiresDeferredServingBootstrap() throws -> Bool {
        switch deferredServingBootstrapState {
        case .active:
            return false
        case .awaitingSecurityPreflight:
            return true
        case .securityReconciled:
            // A partially completed startup must be reopened and preflighted
            // from a fresh SQLite snapshot; it cannot skip directly to serving.
            throw HarcHostError.deferredServingBootstrapRequired
        }
    }

    package func requireServingBootstrapActive() throws {
        guard deferredServingBootstrapState == .active else {
            throw HarcHostError.deferredServingBootstrapRequired
        }
    }

    package func requireDeferredServingTransportPreflightAllowed() throws {
        guard deferredServingBootstrapState == .awaitingSecurityPreflight else {
            throw HarcHostError.deferredServingBootstrapRequired
        }
    }

    package func requireDeferredServingTransportReconcileAllowed() throws {
        guard deferredServingBootstrapState == .securityReconciled else {
            throw HarcHostError.deferredServingBootstrapRequired
        }
    }

    package nonisolated func withEmergencyTransportSecurityExclusion<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await authorityMutationCoordinator.withExclusiveMutation(
            .emergencyTransport,
            operation: operation
        )
    }

    package nonisolated func withServingRecoverySecurityExclusion<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await authorityMutationCoordinator.withExclusiveMutation(
            .servingRecovery,
            operation: operation
        )
    }
}

// MARK: - Shared encoding and SQLite helpers

extension HarcHostStore {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }

    static func sqliteInteger(_ value: UInt64, field: String) throws -> Int64 {
        guard value <= UInt64(Int64.max) else {
            throw HarcHostError.databaseFailure("\(field) exceeds SQLite's signed integer range.")
        }
        return Int64(value)
    }

    static func unsigned(_ value: Int64, field: String) throws -> UInt64 {
        guard value >= 0 else {
            throw HarcHostError.databaseFailure("\(field) is negative.")
        }
        return UInt64(value)
    }

    static func unixTime(_ date: Date) -> Double { date.timeIntervalSince1970 }
    static func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func ensureHostGeneratedDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw HarcHostError.unsafeStagingRoot }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw HarcHostError.unsafeStagingRoot
            }
            try validateOwnedDirectory(url)
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HarcHostError.unsafeStagingRoot
        }
        try validateOwnedDirectory(url)
    }

    static func ensureSafeStagingRoot(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HarcHostError.unsafeStagingRoot
        }
        try validateOwnedDirectory(url)
    }

    private static func validateOwnedDirectory(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid(),
              (information.st_mode & 0o022) == 0 else {
            throw HarcHostError.unsafeStagingRoot
        }
    }
}

// MARK: - Shared host-authority mutation boundary

extension HarcHostStore {
    /// Inserts a fresh emergency intent or performs the sole legal durable mode
    /// transition, planned -> emergency. Device flags and credential
    /// invalidation share this exact transaction, so an idempotent retry cannot
    /// observe an intent without its security consequences.
    package func beginOrEscalateEmergencyTransportRotation(
        compromisedSPKISHA256: Data,
        retirementFloorUnixMilliseconds: UInt64,
        at date: Date
    ) async throws -> HostTransportRotationIntent {
        guard compromisedSPKISHA256.count == SHA256.byteCount else {
            throw HarcHostError.invalidTransportSet("emergency compromised SPKI")
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.transportRotationStateMismatch
        }
        let requestedFloor = try Self.sqliteInteger(
            retirementFloorUnixMilliseconds,
            field: "rotationRetirementFloorUnixMilliseconds"
        )
        let timestamp = Self.unixTime(date)

        return try await dbQueue.write { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_security_mutations"
            ) == 0 else {
                throw HarcHostError.hostAuthorityMutationConflict
            }
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_transport_set_publications"
            ) == 0 else {
                throw HarcHostError.transportSetTransitionInProgress
            }
            guard let currentFloor = try Int64.fetchOne(
                db,
                sql: "SELECT leaf_retirement_floor FROM host_metadata WHERE singleton = 1"
            ) else {
                throw HarcHostError.metadataMismatch
            }

            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_transport_rotation_intent WHERE singleton = 1"
            ) {
                let intent = try Self.hostTransportRotationIntent(from: row)
                guard intent.oldTLSSPKISHA256 == compromisedSPKISHA256,
                      intent.retirementFloorUnixMilliseconds
                        == retirementFloorUnixMilliseconds,
                      currentFloor == requestedFloor else {
                    throw HarcHostError.transportRotationStateMismatch
                }
                switch intent.mode {
                case .planned:
                    guard intent.startedMode == .planned,
                          intent.emergencyEscalatedAt == nil,
                          date >= intent.createdAt else {
                        throw HarcHostError.transportRotationStateMismatch
                    }
                    try db.execute(
                        sql: """
                            UPDATE host_transport_rotation_intent
                               SET mode = 'emergency', emergency_escalated_at = ?
                             WHERE singleton = 1
                               AND started_mode = 'planned'
                               AND mode = 'planned'
                               AND emergency_escalated_at IS NULL
                            """,
                        arguments: [timestamp]
                    )
                    guard db.changesCount == 1 else {
                        throw HarcHostError.transportRotationStateMismatch
                    }
                case .emergency:
                    guard (intent.startedMode == .emergency
                            && intent.emergencyEscalatedAt == nil)
                            || (intent.startedMode == .planned
                                && intent.emergencyEscalatedAt != nil) else {
                        throw HarcHostError.transportRotationStateMismatch
                    }
                }
            } else {
                guard currentFloor == requestedFloor else {
                    throw HarcHostError.transportSetTransitionInProgress
                }
                try db.execute(
                    sql: """
                        INSERT INTO host_transport_rotation_intent (
                            singleton, started_mode, mode, old_spki_sha256,
                            new_spki_sha256, retirement_floor_unix_ms,
                            created_at, emergency_escalated_at
                        ) VALUES (1, 'emergency', 'emergency', ?, NULL, ?, ?, NULL)
                        """,
                    arguments: [compromisedSPKISHA256, requestedFloor, timestamp]
                )
            }

            try db.execute(
                sql: """
                    UPDATE devices
                       SET trust_repair_required = 1, updated_at = ?
                     WHERE status = 'active' AND trust_repair_required = 0
                    """,
                arguments: [timestamp]
            )
            try db.execute(
                sql: """
                    UPDATE session_tokens
                       SET invalidated_at = MAX(?, issued_at),
                           invalidation_reason = 'emergencyTransportRotation'
                     WHERE invalidated_at IS NULL
                    """,
                arguments: [timestamp]
            )
            try db.execute(
                sql: """
                    UPDATE background_capabilities
                       SET invalidated_at = ?, state = 'invalidated'
                     WHERE invalidated_at IS NULL
                    """,
                arguments: [timestamp]
            )
            guard let finalRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_transport_rotation_intent WHERE singleton = 1"
            ) else {
                throw HarcHostError.transportRotationStateMismatch
            }
            return try Self.hostTransportRotationIntent(from: finalRow)
        }
    }

    private static func hostTransportRotationIntent(
        from row: Row
    ) throws -> HostTransportRotationIntent {
        guard let startedMode = HostTransportRotationMode(
            rawValue: row["started_mode"] as String
        ), let mode = HostTransportRotationMode(rawValue: row["mode"] as String) else {
            throw HarcHostError.transportRotationStateMismatch
        }
        let createdAt = Self.date(row["created_at"] as Double)
        let escalatedAt = (row["emergency_escalated_at"] as Double?).map {
            Self.date($0)
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              escalatedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
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
            createdAt: createdAt,
            emergencyEscalatedAt: escalatedAt
        )
    }
}

// MARK: - Metadata and authorization

extension HarcHostStore {
    private func validateExistingMetadataForDeferredServing() async throws {
        let expected = expectedMetadata
        let matches = try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_metadata WHERE singleton = 1"
            ) else {
                return false
            }
            return (row["library_id"] as String) == expected.libraryID.description
                && (row["host_authority_id"] as Data) == expected.hostAuthorityID.rawBytes
                && (row["host_state_id"] as String) == expected.hostStateID.description
        }
        guard matches else { throw HarcHostError.metadataMismatch }
    }

    private func initializeOrValidateMetadata() async throws {
        let metadata = expectedMetadata
        let currentTime = Self.unixTime(now())
        let transportEpoch = try Self.sqliteInteger(metadata.highestTransportSetEpoch, field: "highestTransportSetEpoch")
        let leafFloor = try Self.sqliteInteger(metadata.leafRetirementFloor, field: "leafRetirementFloor")

        enum Result { case inserted, matches, mismatch }
        let result: Result = try await dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM host_metadata WHERE singleton = 1") else {
                try db.execute(
                    sql: """
                        INSERT INTO host_metadata (
                            singleton, library_id, host_authority_id, host_state_id,
                            control_port, upload_port, highest_transport_set_epoch,
                            leaf_retirement_floor, security_registry_revision,
                            created_at, updated_at
                        ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                        """,
                    arguments: [
                        metadata.libraryID.description,
                        metadata.hostAuthorityID.rawBytes,
                        metadata.hostStateID.description,
                        metadata.controlPort.map { Int64($0) },
                        metadata.uploadPort.map { Int64($0) },
                        transportEpoch,
                        leafFloor,
                        currentTime,
                        currentTime,
                    ]
                )
                return .inserted
            }
            // Mutable ports and transport lifecycle fields are reconciled by
            // `HostTransportLifecycle` before it issues the only snapshot
            // accepted by either public listener constructor. This gate proves
            // the immutable canonical identity tuple; otherwise a legitimate
            // N -> N+1 commit would make restart recovery impossible to open.
            let matches = (row["library_id"] as String) == metadata.libraryID.description
                && (row["host_authority_id"] as Data) == metadata.hostAuthorityID.rawBytes
                && (row["host_state_id"] as String) == metadata.hostStateID.description
            return matches ? .matches : .mismatch
        }
        if case .mismatch = result { throw HarcHostError.metadataMismatch }
    }

    public func metadata() async throws -> HarcHostMetadata {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM host_metadata WHERE singleton = 1") else {
                throw HarcHostError.metadataMismatch
            }
            guard let libraryUUID = UUID(uuidString: row["library_id"] as String),
                  let stateUUID = UUID(uuidString: row["host_state_id"] as String) else {
                throw HarcHostError.metadataMismatch
            }
            return HarcHostMetadata(
                libraryID: LibraryID(libraryUUID),
                hostAuthorityID: try HostAuthorityID(row["host_authority_id"] as Data),
                hostStateID: HostStateID(stateUUID),
                controlPort: (row["control_port"] as Int64?).flatMap(UInt16.init(exactly:)),
                uploadPort: (row["upload_port"] as Int64?).flatMap(UInt16.init(exactly:)),
                highestTransportSetEpoch: try Self.unsigned(row["highest_transport_set_epoch"] as Int64, field: "highestTransportSetEpoch"),
                leafRetirementFloor: try Self.unsigned(row["leaf_retirement_floor"] as Int64, field: "leafRetirementFloor")
            )
        }
    }

    public func registryRevision() async throws -> UInt64 {
        try await dbQueue.read { db in
            guard let revision = try Int64.fetchOne(
                db,
                sql: "SELECT security_registry_revision FROM host_metadata WHERE singleton = 1"
            ) else { throw HarcHostError.metadataMismatch }
            return try Self.unsigned(revision, field: "securityRegistryRevision")
        }
    }

    nonisolated func authorizeInDatabase(
        _ db: Database,
        context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        objectOwner: DeviceID?,
        at date: Date
    ) throws -> AuthorizedDeviceContext {
        guard context.libraryID == expectedMetadata.libraryID,
              context.hostAuthorityID == expectedMetadata.hostAuthorityID else {
            throw HarcHostError.grantMismatch
        }
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT registry_entry_json, trust_repair_required
                FROM devices WHERE device_id = ?
                """,
            arguments: [context.authenticatedDeviceID.rawBytes]
        ) else {
            throw HarcHostError.unknownDevice
        }
        guard row["trust_repair_required"] as Int == 0 else {
            throw HarcHostError.emergencyTrustRepairRequired
        }
        let entry = try Self.decode(DeviceRegistryEntry.self, from: row["registry_entry_json"] as Data)
        guard entry.libraryID == expectedMetadata.libraryID,
              entry.hostAuthorityID == expectedMetadata.hostAuthorityID,
              entry.deviceID == context.authenticatedDeviceID,
              entry.devicePublicKey.deviceID == context.authenticatedDeviceID else {
            throw HarcHostError.grantMismatch
        }
        guard entry.status == .active else { throw HarcHostError.deviceRevoked }
        guard entry.currentGrantID == context.grantID,
              entry.currentGrantEpoch == context.grantEpoch else {
            throw HarcHostError.grantMismatch
        }
        if let expiry = entry.grantExpiresAt, date >= expiry { throw HarcHostError.grantExpired }
        guard entry.currentScopes.contains(requiredScope) else {
            throw HarcHostError.missingScope(requiredScope)
        }
        if let objectOwner, objectOwner != context.authenticatedDeviceID {
            throw HarcHostError.objectOwnershipMismatch
        }
        return AuthorizedDeviceContext(
            authenticatedDeviceID: context.authenticatedDeviceID,
            grantID: context.grantID,
            grantEpoch: context.grantEpoch,
            requiredScope: requiredScope
        )
    }

    public func authorize(
        _ context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        objectOwner: DeviceID? = nil
    ) async throws -> AuthorizedDeviceContext {
        try await authorize(
            context,
            requiredScope: requiredScope,
            objectOwner: objectOwner,
            at: now()
        )
    }

    /// Deterministic `@testable` seam. Production callers must use the public
    /// overload, whose authorization time comes only from the injected clock.
    func authorize(
        _ context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        objectOwner: DeviceID? = nil,
        at date: Date
    ) async throws -> AuthorizedDeviceContext {
        try await repairSecurityRegistryOnReopen()
        return try await dbQueue.read { db in
            try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: requiredScope,
                objectOwner: objectOwner,
                at: date
            )
        }
    }
}

public struct HostAuthorizer: Sendable {
    private let store: HarcHostStore

    public init(store: HarcHostStore) { self.store = store }

    public func authorize(
        _ context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        objectOwner: DeviceID? = nil
    ) async throws -> AuthorizedDeviceContext {
        try await store.authorize(
            context,
            requiredScope: requiredScope,
            objectOwner: objectOwner
        )
    }

    /// Deterministic `@testable` seam mirroring `HarcHostStore.authorize`.
    func authorize(
        _ context: AuthenticatedDeviceContext,
        requiredScope: AuthorizationScope,
        objectOwner: DeviceID? = nil,
        at date: Date
    ) async throws -> AuthorizedDeviceContext {
        try await store.authorize(
            context,
            requiredScope: requiredScope,
            objectOwner: objectOwner,
            at: date
        )
    }
}
