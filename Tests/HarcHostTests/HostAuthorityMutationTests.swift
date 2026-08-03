import Foundation
import GRDB
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity
import HarcTransfer

@Suite("Host authority mutation boundary")
struct HostAuthorityMutationTests {
    @Test("v5 permits only planned-to-emergency escalation and rejects reciprocal journal overlap")
    func v5RotationIntentGuards() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.harcHostMigrator().migrate(queue)

        let columns = try queue.read { db in
            try Set(Row.fetchAll(
                db,
                sql: "PRAGMA table_info(host_transport_rotation_intent)"
            ).compactMap { $0["name"] as String? })
        }
        #expect(columns.contains("started_mode"))
        #expect(columns.contains("emergency_escalated_at"))

        let oldSPKI = Data(repeating: 0x41, count: 32)
        let deviceID = Data(repeating: 0x42, count: 32)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO host_transport_rotation_intent (
                        singleton, started_mode, mode, old_spki_sha256,
                        new_spki_sha256, retirement_floor_unix_ms,
                        created_at, emergency_escalated_at
                    ) VALUES (1, 'planned', 'planned', ?, NULL, 0, 100, NULL)
                    """,
                arguments: [oldSPKI]
            )
            try db.execute(
                sql: """
                    INSERT INTO pending_security_mutations (
                        singleton, registry_revision, mutation_kind, device_id,
                        mutation_json, created_at
                    ) VALUES (1, 1, 'issueGrant', ?, ?, 101)
                    """,
                arguments: [deviceID, Data([0x01])]
            )
        }

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE host_transport_rotation_intent
                           SET mode = 'emergency', emergency_escalated_at = 102
                         WHERE singleton = 1
                        """
                )
            }
        }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM pending_security_mutations")
            try db.execute(
                sql: """
                    UPDATE host_transport_rotation_intent
                       SET mode = 'emergency', emergency_escalated_at = 102
                     WHERE singleton = 1
                    """
            )
        }
        let escalated = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM host_transport_rotation_intent WHERE singleton = 1"
            )
        }
        #expect(escalated?["started_mode"] as String? == "planned")
        #expect(escalated?["mode"] as String? == "emergency")
        #expect(escalated?["emergency_escalated_at"] as Double? == 102)

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO pending_security_mutations (
                            singleton, registry_revision, mutation_kind,
                            device_id, mutation_json, created_at
                        ) VALUES (1, 1, 'issueGrant', ?, ?, 103)
                        """,
                    arguments: [deviceID, Data([0x01])]
                )
            }
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE host_transport_rotation_intent
                           SET mode = 'planned', emergency_escalated_at = NULL
                         WHERE singleton = 1
                        """
                )
            }
        }
        for immutableMutation in [
            "UPDATE host_transport_rotation_intent SET started_mode = 'emergency' WHERE singleton = 1",
            "UPDATE host_transport_rotation_intent SET old_spki_sha256 = zeroblob(32) WHERE singleton = 1",
            "UPDATE host_transport_rotation_intent SET retirement_floor_unix_ms = 1 WHERE singleton = 1",
            "UPDATE host_transport_rotation_intent SET created_at = 99 WHERE singleton = 1",
        ] {
            #expect(throws: (any Error).self) {
                try queue.write { db in
                    try db.execute(sql: immutableMutation)
                }
            }
        }
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE host_transport_rotation_intent
                       SET new_spki_sha256 = ? WHERE singleton = 1
                    """,
                arguments: [Data(repeating: 0x43, count: 32)]
            )
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE host_transport_rotation_intent
                           SET new_spki_sha256 = ? WHERE singleton = 1
                        """,
                    arguments: [Data(repeating: 0x44, count: 32)]
                )
            }
        }

        try queue.write { db in
            try db.execute(sql: "DELETE FROM host_transport_rotation_intent")
            try db.execute(
                sql: """
                    INSERT INTO pending_security_mutations (
                        singleton, registry_revision, mutation_kind,
                        device_id, mutation_json, created_at
                    ) VALUES (1, 1, 'issueGrant', ?, ?, 104)
                    """,
                arguments: [deviceID, Data([0x01])]
            )
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO host_transport_rotation_intent (
                            singleton, started_mode, mode, old_spki_sha256,
                            new_spki_sha256, retirement_floor_unix_ms,
                            created_at, emergency_escalated_at
                        ) VALUES (1, 'emergency', 'emergency', ?, NULL, 0, 105, NULL)
                        """,
                    arguments: [oldSPKI]
                )
            }
        }
    }

    @Test("emergency intent atomically gates devices and invalidates live credentials")
    func emergencyIntentAppliesSecurityConsequencesAtomically() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("authority-emergency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rotationDate = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: InMemorySecurityRegistryHighWaterMarkStore(),
            localOSAuthenticationBoundary: AllowingHostLocalOSAuthenticationBoundary(),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { rotationDate }
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("initial-grant".utf8)
        )

        let uploadID = UploadID.random()
        let origin = OriginRecordingID(
            deviceID: fixture.deviceID,
            recordingUUID: UUID()
        )
        _ = try await store.beginUpload(
            context: fixture.context(for: grant),
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO background_capabilities (
                        capability_id, upload_id, owner_device_id, grant_id,
                        grant_epoch, generation, capability_binding_sha256,
                        expires_at, state, created_at
                    ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, 'issued', ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    uploadID.description,
                    fixture.deviceID.rawBytes,
                    grant.grantID.description,
                    Int64(grant.grantEpoch.rawValue),
                    Data(repeating: 0x43, count: 32),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(100)),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(2)),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO session_tokens (
                        token_id, token_binding_sha256, device_id, grant_id,
                        grant_epoch, tls_spki_sha256, exact_capabilities_bytes,
                        capabilities_sha256, protocol_major, protocol_minor,
                        selected_codec, selected_container, issued_at, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0, 'opus', 'ogg', ?, ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    Data(repeating: 0x44, count: 32),
                    fixture.deviceID.rawBytes,
                    grant.grantID.description,
                    Int64(grant.grantEpoch.rawValue),
                    Data(repeating: 0x45, count: 32),
                    Data([0x01]),
                    Data(repeating: 0x46, count: 32),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(3)),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(100)),
                ]
            )
        }

        let compromisedSPKI = Data(repeating: 0x47, count: 32)
        let intent = try await store.withEmergencyTransportSecurityExclusion {
            try await store.beginOrEscalateEmergencyTransportRotation(
                compromisedSPKISHA256: compromisedSPKI,
                retirementFloorUnixMilliseconds: 0,
                at: rotationDate
            )
        }
        #expect(intent.startedMode == .emergency)
        #expect(intent.mode == .emergency)
        #expect(intent.oldTLSSPKISHA256 == compromisedSPKI)
        #expect(intent.newTLSSPKISHA256 == nil)
        #expect(intent.createdAt == rotationDate)

        let consequences = try await store.dbQueue.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT trust_repair_required FROM devices WHERE device_id = ?",
                    arguments: [fixture.deviceID.rawBytes]
                ),
                try Row.fetchOne(
                    db,
                    sql: "SELECT invalidated_at, invalidation_reason FROM session_tokens"
                ),
                try Row.fetchOne(
                    db,
                    sql: "SELECT invalidated_at, state FROM background_capabilities"
                )
            )
        }
        #expect(consequences.0 == 1)
        #expect(consequences.1?["invalidation_reason"] as String?
            == "emergencyTransportRotation")
        #expect(consequences.1?["invalidated_at"] as Double?
            == HarcHostStore.unixTime(rotationDate))
        #expect(consequences.2?["state"] as String? == "invalidated")
        #expect(consequences.2?["invalidated_at"] as Double?
            == HarcHostStore.unixTime(rotationDate))

        let replay = try await store.withEmergencyTransportSecurityExclusion {
            try await store.beginOrEscalateEmergencyTransportRotation(
                compromisedSPKISHA256: compromisedSPKI,
                retirementFloorUnixMilliseconds: 0,
                at: rotationDate.addingTimeInterval(1)
            )
        }
        #expect(replay == intent)

        let current = try #require(
            try await store.deviceRegistryEntry(deviceID: fixture.deviceID)
        )
        let replacement = try current.replacingScopesAfterLocalAuthorization(
            [.recordingUploadOwn, .recordingReadOwn, .libraryMetadataRead],
            issuedAt: rotationDate.addingTimeInterval(2)
        )
        await #expect(throws: HarcHostError.hostAuthorityMutationConflict) {
            try await store.replaceDeviceGrant(
                replacement.grant,
                exactGrantBytes: Data("replacement-grant".utf8)
            )
        }
    }

    @Test("planned rotation escalates once without rebinding its durable intent")
    func plannedRotationEscalatesInPlace() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("authority-escalation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        let createdAt = fixture.beganAt
        let escalatedAt = createdAt.addingTimeInterval(5)
        let oldSPKI = Data(repeating: 0x51, count: 32)
        let newSPKI = Data(repeating: 0x52, count: 32)
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO host_transport_rotation_intent (
                        singleton, started_mode, mode, old_spki_sha256,
                        new_spki_sha256, retirement_floor_unix_ms,
                        created_at, emergency_escalated_at
                    ) VALUES (1, 'planned', 'planned', ?, ?, 0, ?, NULL)
                    """,
                arguments: [oldSPKI, newSPKI, HarcHostStore.unixTime(createdAt)]
            )
        }

        await #expect(throws: HarcHostError.transportRotationStateMismatch) {
            _ = try await store.withEmergencyTransportSecurityExclusion {
                try await store.beginOrEscalateEmergencyTransportRotation(
                    compromisedSPKISHA256: oldSPKI,
                    retirementFloorUnixMilliseconds: 0,
                    at: createdAt.addingTimeInterval(-1)
                )
            }
        }
        let escalated = try await store.withEmergencyTransportSecurityExclusion {
            try await store.beginOrEscalateEmergencyTransportRotation(
                compromisedSPKISHA256: oldSPKI,
                retirementFloorUnixMilliseconds: 0,
                at: escalatedAt
            )
        }
        #expect(escalated.startedMode == .planned)
        #expect(escalated.mode == .emergency)
        #expect(escalated.oldTLSSPKISHA256 == oldSPKI)
        #expect(escalated.newTLSSPKISHA256 == newSPKI)
        #expect(escalated.retirementFloorUnixMilliseconds == 0)
        #expect(escalated.createdAt == createdAt)
        #expect(escalated.emergencyEscalatedAt == escalatedAt)

        let replay = try await store.withEmergencyTransportSecurityExclusion {
            try await store.beginOrEscalateEmergencyTransportRotation(
                compromisedSPKISHA256: oldSPKI,
                retirementFloorUnixMilliseconds: 0,
                at: escalatedAt.addingTimeInterval(1)
            )
        }
        #expect(replay == escalated)
    }

    @Test("deferred serving preflight is read-only and reconciles only its exact plan")
    func deferredServingPreflightIsReadOnly() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("authority-preflight-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let grant = try fixture.grant()

        do {
            let crashing = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                securityFailureInjector:
                    OneShotSecurityFailureInjector(.afterPendingMutation),
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            await #expect(throws: InjectedHostCrash.security(.afterPendingMutation)) {
                try await crashing.seedDeviceGrantForTesting(
                    grant,
                    exactGrantBytes: Data("pending-grant".utf8)
                )
            }
        }

        let deferred = try await HarcHostStore.onDiskDeferredForServing(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await deferred.registryRevision() == 0)
        #expect(await highWater.loadRegistryRevision() == 0)
        #expect(try await pendingSecurityMutationCount(in: deferred) == 1)
        #expect(try await deferred.deviceRegistryEntry(deviceID: fixture.deviceID) == nil)

        await #expect(throws: HarcHostError.deferredServingBootstrapRequired) {
            try await deferred.completeDeferredServingBootstrap()
        }
        await #expect(throws: HarcHostError.deferredServingPreflightMismatch) {
            _ = try await deferred.preflightSecurityRegistry(protectedRevision: 1)
        }
        #expect(try await deferred.registryRevision() == 0)
        #expect(await highWater.loadRegistryRevision() == 0)
        #expect(try await pendingSecurityMutationCount(in: deferred) == 1)

        let stalePlan = try await deferred.preflightSecurityRegistry(
            protectedRevision: 0
        )
        await highWater.replaceForTesting(1)
        await #expect(throws: HarcHostError.deferredServingPreflightMismatch) {
            try await deferred.withServingRecoverySecurityExclusion {
                try await deferred.reconcileSecurityRegistry(using: stalePlan)
            }
        }
        #expect(try await deferred.registryRevision() == 0)
        #expect(try await pendingSecurityMutationCount(in: deferred) == 1)
        await highWater.replaceForTesting(0)

        try await deferred.withServingRecoverySecurityExclusion {
            let plan = try await deferred.preflightSecurityRegistry(
                protectedRevision: 0
            )
            #expect(plan.databaseRevision == 0)
            #expect(plan.pendingRevision == 1)
            #expect(plan.exactPendingMutationJSON != nil)
            try await deferred.reconcileSecurityRegistry(using: plan)
        }
        #expect(try await deferred.registryRevision() == 1)
        #expect(await highWater.loadRegistryRevision() == 1)
        #expect(try await pendingSecurityMutationCount(in: deferred) == 0)
        #expect(try await deferred.deviceRegistryEntry(deviceID: fixture.deviceID) != nil)
        try await deferred.completeDeferredServingBootstrap()

        await #expect(throws: HarcHostError.deferredServingBootstrapRequired) {
            _ = try await deferred.preflightSecurityRegistry(protectedRevision: 1)
        }
    }

    @Test("authority coordinator admits queued mutations in FIFO order")
    func authorityCoordinatorIsFIFO() async throws {
        let coordinator = HostAuthorityMutationCoordinator()
        let probe = AuthorityMutationProbe()

        let first = Task {
            try await coordinator.withExclusiveMutation(.securityRegistry) {
                await probe.record("first-enter")
                await probe.waitForRelease()
                await probe.record("first-exit")
            }
        }
        await probe.waitForFirstEntry()

        let second = Task {
            try await coordinator.withExclusiveMutation(.emergencyTransport) {
                await probe.record("second")
            }
        }
        try await waitForQueuedMutationCount(1, coordinator: coordinator)

        let third = Task {
            try await coordinator.withExclusiveMutation(.servingRecovery) {
                await probe.record("third")
            }
        }
        try await waitForQueuedMutationCount(2, coordinator: coordinator)

        #expect(await probe.events == ["first-enter"])
        await probe.releaseFirst()
        try await first.value
        try await second.value
        try await third.value
        #expect(await probe.events == [
            "first-enter", "first-exit", "second", "third",
        ])
    }

    private func pendingSecurityMutationCount(
        in store: HarcHostStore
    ) async throws -> Int {
        try await store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_security_mutations"
            ) ?? 0
        }
    }

    private func waitForQueuedMutationCount(
        _ expectedCount: Int,
        coordinator: HostAuthorityMutationCoordinator
    ) async throws {
        for _ in 0..<10_000 {
            if await coordinator.queuedMutationCountForTesting() == expectedCount {
                return
            }
            await Task.yield()
        }
        throw AuthorityMutationTestError.waiterDidNotQueue(expectedCount)
    }
}

private enum AuthorityMutationTestError: Error {
    case waiterDidNotQueue(Int)
}

private struct AllowingHostLocalOSAuthenticationBoundary:
    HostLocalOSAuthenticationBoundary
{
    func authorizeInitialGrantExpansion(
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind,
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool { true }

    func authorizeGrantScopeChange(
        for deviceID: DeviceID,
        currentScopes: [AuthorizationScope],
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool { true }

    func authorizeSameKeyReadoption(
        for deviceID: DeviceID
    ) async throws -> Bool { true }
}

private actor AuthorityMutationProbe {
    private(set) var events: [String] = []
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    func record(_ event: String) {
        events.append(event)
        if event == "first-enter" {
            let waiters = firstEntryWaiters
            firstEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitForFirstEntry() async {
        if events.contains("first-enter") { return }
        await withCheckedContinuation { firstEntryWaiters.append($0) }
    }

    func waitForRelease() async {
        if releaseRequested { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func releaseFirst() {
        releaseRequested = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
