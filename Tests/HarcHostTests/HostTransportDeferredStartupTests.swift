import Foundation
import GRDB
import HarcDomain
@testable import HarcIdentity
import HarcProtocol
import Testing
@testable import HarcHost

// These tests exercise process-global Security.framework key and certificate
// fixtures. Serial execution prevents one cleanup from racing another bind.
@Suite("Host transport deferred startup", .serialized)
struct HostTransportDeferredStartupTests: Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("transport preflight is read-only across the exact pending publication")
    func transportPreflightIsReadOnly() async throws {
        let crypto = InMemoryHostCryptographicStateStore()
        let state = try await crypto.loadOrCreate(libraryID: .random())
        let paths = try makeDiskPaths("read-only-transport")
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: crypto,
            tuple: state.tuple
        )
        let initialized = try await initializeHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater
        )
        let pending = try makeTransportSet(state: state, epoch: 1)
        try await initialized.prepareTransportSetPublication(
            pending,
            kind: .initial,
            expectedActiveSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: now
        )

        let deferred = try await openDeferredHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater
        )
        let boundary = DeferredStartupRecordingBoundary()
        let lifecycle = HostTransportLifecycle(
            store: deferred,
            cryptographicStateStore: crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: boundary,
            now: { now }
        )
        let beforeDatabase = try await deferred.transportDatabaseSnapshot()
        let beforeInspection = try await crypto.inspect(requiredTuple: state.tuple)
        let beforeFacts = HostTransportCryptographicPreflightFacts(beforeInspection)

        let plan = try await lifecycle.preflightDeferredServingTransport(
            inspection: beforeInspection
        )

        let afterDatabase = try await deferred.transportDatabaseSnapshot()
        let afterInspection = try await crypto.inspect(requiredTuple: state.tuple)
        #expect(plan.database == beforeDatabase)
        #expect(plan.protectedFacts == beforeFacts)
        #expect(afterDatabase == beforeDatabase)
        #expect(HostTransportCryptographicPreflightFacts(afterInspection) == beforeFacts)
        #expect(afterDatabase.pending != nil)
        #expect(afterInspection.highestIssuedTransportSetEpoch == 0)
        #expect(await boundary.activatedRoles().isEmpty)
    }

    @Test("corrupt transport preflight prevents security-journal reconciliation")
    func corruptTransportPreventsSecurityReconciliation() async throws {
        let crypto = InMemoryHostCryptographicStateStore()
        let state = try await crypto.loadOrCreate(libraryID: .random())
        let paths = try makeDiskPaths("corrupt-transport")
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: crypto,
            tuple: state.tuple
        )
        let crashingStore = try await initializeHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater,
            securityFailureInjector: OneShotSecurityFailureInjector(.afterPendingMutation)
        )
        let deviceKey = SoftwareP256SigningKey()
        let grant = try DeviceGrantClaims(
            libraryID: state.tuple.libraryID,
            hostAuthorityID: state.tuple.hostAuthorityID,
            grantID: .random(),
            deviceID: deviceKey.publicKey.deviceID,
            devicePublicKey: deviceKey.publicKey,
            scopes: [.recordingUploadOwn],
            grantEpoch: .initial,
            issuedAt: now,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        await #expect(throws: InjectedHostCrash.security(.afterPendingMutation)) {
            try await crashingStore.seedDeviceGrantForTesting(
                grant,
                exactGrantBytes: Data("pending-security-grant".utf8)
            )
        }

        let signed = try makeTransportSet(state: state, epoch: 1)
        try await crashingStore.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_transport_set_publications (
                        singleton, previous_epoch, next_epoch,
                        expected_previous_object_id, exact_signed_bytes,
                        object_id, publication_kind,
                        expected_active_spki_sha256, secondary_spki_sha256,
                        retirement_floor_unix_ms, created_at
                    ) VALUES (1, 0, 1, NULL, ?, ?, 'initial', ?, NULL, 0, ?)
                    """,
                arguments: [
                    signed.exactSignedBytes,
                    Data(repeating: 0xe1, count: 32),
                    state.activeTLSIdentity.tlsSPKISHA256,
                    now.timeIntervalSince1970,
                ]
            )
        }

        let deferred = try await openDeferredHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater
        )
        let boundary = DeferredStartupRecordingBoundary()
        await #expect(throws: HarcHostError.transportSetPendingMismatch) {
            _ = try await HostTransportResidentRuntime.start(
                store: deferred,
                cryptographicStateStore: crypto,
                transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
                generationBoundary: boundary,
                canonicalTuple: state.tuple,
                now: { now }
            )
        }

        let inspection = try await crypto.inspect(requiredTuple: state.tuple)
        #expect(inspection.securityRegistryRevision == 0)
        #expect(inspection.highestIssuedTransportSetEpoch == 0)
        #expect(try await deferred.registryRevision() == 0)
        #expect(try await pendingSecurityMutationCount(in: deferred) == 1)
        #expect(try await deferred.deviceRegistryEntry(deviceID: grant.deviceID) == nil)
        #expect(try await deferred.requiresDeferredServingBootstrap())
        #expect(await boundary.activatedRoles().isEmpty)
    }

    @Test("pending transport recovers exactly with either the old or new protected mark")
    func pendingTransportRecoversWithOldOrNewMark() async throws {
        for protectedMarkAlreadyAdvanced in [false, true] {
            let crypto = InMemoryHostCryptographicStateStore()
            let state = try await crypto.loadOrCreate(libraryID: .random())
            let paths = try makeDiskPaths(
                protectedMarkAlreadyAdvanced ? "pending-mark-new" : "pending-mark-old"
            )
            defer { try? FileManager.default.removeItem(at: paths.directory) }
            let highWater = KeychainSecurityRegistryHighWaterMarkStore(
                cryptographicStateStore: crypto,
                tuple: state.tuple
            )
            let initialized = try await initializeHostDB(
                paths: paths,
                metadata: metadata(for: state.tuple),
                highWaterMarkStore: highWater
            )
            let pending = try makeTransportSet(state: state, epoch: 1)
            try await initialized.prepareTransportSetPublication(
                pending,
                kind: .initial,
                expectedActiveSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256,
                secondarySPKISHA256: nil,
                retirementFloorUnixMilliseconds: 0,
                at: now
            )
            if protectedMarkAlreadyAdvanced {
                _ = try await crypto.advanceHighestIssuedTransportSetEpoch(
                    for: state.tuple,
                    from: 0,
                    to: 1
                )
            }

            let deferred = try await openDeferredHostDB(
                paths: paths,
                metadata: metadata(for: state.tuple),
                highWaterMarkStore: highWater
            )
            let lifecycle = HostTransportLifecycle(
                store: deferred,
                cryptographicStateStore: crypto,
                transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
                generationBoundary: DeferredStartupRecordingBoundary(),
                now: { now }
            )
            let inspection = try await crypto.inspect(requiredTuple: state.tuple)
            let securityPlan = try await deferred.preflightSecurityRegistry(
                protectedRevision: inspection.securityRegistryRevision
            )
            let plan = try await lifecycle.preflightDeferredServingTransport(
                inspection: inspection
            )
            try await deferred.reconcileSecurityRegistry(using: securityPlan)
            try await lifecycle.reconcileDeferredServingTransport(
                using: plan,
                expectedSecurityRegistryRevision:
                    securityPlan.pendingRevision ?? securityPlan.databaseRevision
            )

            let database = try await deferred.transportDatabaseSnapshot()
            let recovered = try await crypto.inspect(requiredTuple: state.tuple)
            #expect(database.epoch == 1)
            #expect(database.pending == nil)
            #expect(database.exactSignedBytes == pending.exactSignedBytes)
            #expect(recovered.highestIssuedTransportSetEpoch == 1)
        }
    }

    @Test("a stale HostDB plan fails before the protected transport mark changes")
    func staleDatabasePlanFailsBeforeTransportMarkChanges() async throws {
        let crypto = InMemoryHostCryptographicStateStore()
        let state = try await crypto.loadOrCreate(libraryID: .random())
        let paths = try makeDiskPaths("stale-plan")
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: crypto,
            tuple: state.tuple
        )
        let initialized = try await initializeHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater
        )
        let pending = try makeTransportSet(state: state, epoch: 1)
        try await initialized.prepareTransportSetPublication(
            pending,
            kind: .initial,
            expectedActiveSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: now
        )
        let deferred = try await openDeferredHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater
        )
        let lifecycle = HostTransportLifecycle(
            store: deferred,
            cryptographicStateStore: crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: DeferredStartupRecordingBoundary(),
            now: { now }
        )
        let inspection = try await crypto.inspect(requiredTuple: state.tuple)
        let securityPlan = try await deferred.preflightSecurityRegistry(
            protectedRevision: inspection.securityRegistryRevision
        )
        let plan = try await lifecycle.preflightDeferredServingTransport(
            inspection: inspection
        )
        try await deferred.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM pending_transport_set_publications WHERE singleton = 1"
            )
        }
        try await deferred.reconcileSecurityRegistry(using: securityPlan)

        await #expect(throws: HarcHostError.deferredServingPreflightMismatch) {
            try await lifecycle.reconcileDeferredServingTransport(
                using: plan,
                expectedSecurityRegistryRevision:
                    securityPlan.pendingRevision ?? securityPlan.databaseRevision
            )
        }
        let protected = try await crypto.inspect(requiredTuple: state.tuple)
        let database = try await deferred.transportDatabaseSnapshot()
        #expect(protected.highestIssuedTransportSetEpoch == 0)
        #expect(database.epoch == 0)
        #expect(database.pending == nil)
    }

    @Test("initial pending TLS creation is preflighted without mutation and recovered by startup")
    func initialPendingTLSCreationRecoversAtStartup() async throws {
        let cryptoFixture = try await makePendingInitialTLSCreationFixture()
        defer { cryptoFixture.keys.deleteAllBestEffort() }
        let paths = try makeDiskPaths("pending-initial-tls")
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: cryptoFixture.crypto,
            tuple: cryptoFixture.tuple
        )
        _ = try await initializeHostDB(
            paths: paths,
            metadata: metadata(for: cryptoFixture.tuple),
            highWaterMarkStore: highWater
        )
        let deferred = try await openDeferredHostDB(
            paths: paths,
            metadata: metadata(for: cryptoFixture.tuple),
            highWaterMarkStore: highWater
        )
        let boundary = DeferredStartupRecordingBoundary()
        let lifecycle = HostTransportLifecycle(
            store: deferred,
            cryptographicStateStore: cryptoFixture.crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: boundary,
            now: { now }
        )
        let recordBefore = try #require(await cryptoFixture.backend.loadRecord())
        let inspection = try await cryptoFixture.crypto.inspect(
            requiredTuple: cryptoFixture.tuple
        )
        #expect(inspection.activeTLSPublicKey == nil)
        #expect(inspection.pendingTLSKeyCreation?.targetRole == .tlsServer)
        _ = try await lifecycle.preflightDeferredServingTransport(
            inspection: inspection
        )
        #expect(await cryptoFixture.backend.loadRecord() == recordBefore)
        let stillPending = try await cryptoFixture.crypto.inspect(
            requiredTuple: cryptoFixture.tuple
        )
        #expect(stillPending.pendingTLSKeyCreation?.targetRole == .tlsServer)

        let runtime = try await HostTransportResidentRuntime.start(
            store: deferred,
            cryptographicStateStore: cryptoFixture.crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: boundary,
            canonicalTuple: cryptoFixture.tuple,
            now: { now }
        )
        let status = try #require(await runtime.generationStatus())
        let recovered = try await cryptoFixture.crypto.inspect(
            requiredTuple: cryptoFixture.tuple
        )
        let database = try await deferred.transportDatabaseSnapshot()
        #expect(recovered.activeTLSPublicKey != nil)
        #expect(recovered.pendingTLSKeyCreation == nil)
        #expect(recovered.highestIssuedTransportSetEpoch == 1)
        #expect(database.epoch == 1)
        #expect(database.pending == nil)
        #expect(status.transportEpoch == 1)
        #expect(Set(await boundary.activatedRoles()) == Set(HostTransportListenerRole.allCases))
        #expect(await boundary.observedBindErrors() == [.leaseAlreadyBound])
        #expect(!(try await deferred.requiresDeferredServingBootstrap()))

        await runtime.shutdown()
        #expect(await boundary.stopCount() == 1)
    }

    @Test("an impossible protected role matrix is rejected without repair")
    func impossibleRoleMatrixFailsPreflight() async throws {
        let crypto = InMemoryHostCryptographicStateStore()
        let initial = try await crypto.loadOrCreate(libraryID: .random())
        let staged = try await crypto.stageReplacementTLSIdentity(
            for: initial.tuple,
            expectedActivePublicKey: initial.activeTLSIdentity.publicKey
        )
        let paths = try makeDiskPaths("impossible-roles")
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: crypto,
            tuple: staged.tuple
        )
        _ = try await initializeHostDB(
            paths: paths,
            metadata: metadata(for: staged.tuple),
            highWaterMarkStore: highWater
        )
        let deferred = try await openDeferredHostDB(
            paths: paths,
            metadata: metadata(for: staged.tuple),
            highWaterMarkStore: highWater
        )
        let lifecycle = HostTransportLifecycle(
            store: deferred,
            cryptographicStateStore: crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: DeferredStartupRecordingBoundary(),
            now: { now }
        )
        let before = try await crypto.inspect(requiredTuple: staged.tuple)

        await #expect(throws: HarcHostError.transportRotationStateMismatch) {
            _ = try await lifecycle.preflightDeferredServingTransport(
                inspection: before
            )
        }

        let after = try await crypto.inspect(requiredTuple: staged.tuple)
        #expect(HostTransportCryptographicPreflightFacts(after)
            == HostTransportCryptographicPreflightFacts(before))
        #expect(after.stagedTLSPublicKey != nil)
    }

    @Test("direct prepare cannot bypass deferred bootstrap")
    func directPrepareOnDeferredStoreFails() async throws {
        let crypto = InMemoryHostCryptographicStateStore()
        let state = try await crypto.loadOrCreate(libraryID: .random())
        let paths = try makeDiskPaths("direct-prepare")
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: crypto,
            tuple: state.tuple
        )
        _ = try await initializeHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater
        )
        let deferred = try await openDeferredHostDB(
            paths: paths,
            metadata: metadata(for: state.tuple),
            highWaterMarkStore: highWater
        )
        let boundary = DeferredStartupRecordingBoundary()
        let lifecycle = HostTransportLifecycle(
            store: deferred,
            cryptographicStateStore: crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: boundary,
            now: { now }
        )

        await #expect(throws: HarcHostError.deferredServingBootstrapRequired) {
            _ = try await lifecycle.prepareForServing()
        }
        #expect(try await deferred.requiresDeferredServingBootstrap())
        #expect(await boundary.activatedRoles().isEmpty)
    }

    @Test("canonical tuple mismatch fails before a runtime claim is taken")
    func canonicalTupleMismatchPrecedesRuntimeClaim() async throws {
        let crypto = InMemoryHostCryptographicStateStore()
        let state = try await crypto.loadOrCreate(libraryID: .random())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcDeferredTuple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory.appendingPathComponent("staging"),
            metadata: metadata(for: state.tuple),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { now }
        )
        let mismatchedTuple = HostCryptographicStateTuple(
            libraryID: .random(),
            hostAuthorityID: state.tuple.hostAuthorityID,
            hostStateID: state.tuple.hostStateID
        )

        await #expect(throws: HarcHostError.metadataMismatch) {
            _ = try await HostTransportResidentRuntime.start(
                store: store,
                cryptographicStateStore: crypto,
                transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
                generationBoundary: DeferredStartupRecordingBoundary(),
                canonicalTuple: mismatchedTuple,
                now: { now }
            )
        }

        let proofNoClaimWasTaken = try await HostTransportAuthorityRuntimeRegistry.shared
            .claim(mismatchedTuple)
        await proofNoClaimWasTaken.release()
    }

    private func makeDiskPaths(_ label: String) throws -> DeferredStartupDiskPaths {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HarcDeferredStartup-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return DeferredStartupDiskPaths(
            directory: directory,
            databaseURL: directory.appendingPathComponent("HarcHost.db"),
            stagingRoot: directory.appendingPathComponent("staging", isDirectory: true)
        )
    }

    private func metadata(
        for tuple: HostCryptographicStateTuple
    ) -> HarcHostMetadata {
        HarcHostMetadata(
            libraryID: tuple.libraryID,
            hostAuthorityID: tuple.hostAuthorityID,
            hostStateID: tuple.hostStateID
        )
    }

    private func initializeHostDB(
        paths: DeferredStartupDiskPaths,
        metadata: HarcHostMetadata,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore,
        securityFailureInjector: any SecurityRegistryFailureInjector =
            NoSecurityRegistryFailureInjector()
    ) async throws -> HarcHostStore {
        try await HarcHostStore.onDisk(
            databaseURL: paths.databaseURL,
            stagingRoot: paths.stagingRoot,
            metadata: metadata,
            highWaterMarkStore: highWaterMarkStore,
            securityFailureInjector: securityFailureInjector,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { now }
        )
    }

    private func openDeferredHostDB(
        paths: DeferredStartupDiskPaths,
        metadata: HarcHostMetadata,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore
    ) async throws -> HarcHostStore {
        try await HarcHostStore.onDiskDeferredForServing(
            databaseURL: paths.databaseURL,
            stagingRoot: paths.stagingRoot,
            metadata: metadata,
            highWaterMarkStore: highWaterMarkStore,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { now }
        )
    }

    private func makeTransportSet(
        state: HostCryptographicState,
        epoch: UInt64
    ) throws -> HostValidatedTransportSet {
        let nowMilliseconds = UInt64(now.timeIntervalSince1970 * 1_000)
        let entry = try HostValidatedTransportSetEntry(
            tlsSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256,
            notBeforeUnixMilliseconds: nowMilliseconds - 300_000,
            notAfterUnixMilliseconds: nowMilliseconds + 30 * 24 * 60 * 60 * 1_000
        )
        return try TestHostTransportSetProtocolBoundaryV1().issueTransportSet(
            HostTransportSetIssueRequest(
                libraryID: state.tuple.libraryID,
                hostAuthorityID: state.tuple.hostAuthorityID,
                setEpoch: epoch,
                issuedAtUnixMilliseconds: nowMilliseconds,
                entries: [entry],
                hostAuthoritySigner: state.authorityIdentity
            )
        )
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

    private func makePendingInitialTLSCreationFixture() async throws
        -> DeferredStartupPendingTLSCreationFixture
    {
        let backend = DeferredStartupFailFirstReplaceBackend()
        let keys = DeferredStartupPermanentTLSKeyBag()
        let authority = HostProtectedP256SigningKey.keychainSoftware(
            SoftwareP256SigningKey()
        )
        let libraryID = LibraryID.random()
        let hostStateID = HostStateID.random()
        let tuple = HostCryptographicStateTuple(
            libraryID: libraryID,
            hostAuthorityID: authority.publicKey.hostAuthorityID,
            hostStateID: hostStateID
        )
        let crypto = KeychainHostCryptographicStateStore(
            backend: backend,
            authorityKeyFactory: HostProtectedP256SigningKeyFactory { authority },
            tlsKeyFactory: permanentTLSKeyFactory(keys: keys),
            hostStateIDFactory: { hostStateID },
            persistentSecurityKeyLoader: { applicationTag, protection in
                .securityFramework(
                    try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                        applicationTag: applicationTag,
                        protection: protection
                    )
                )
            }
        )
        do {
            _ = try await crypto.loadOrCreate(libraryID: libraryID)
            throw DeferredStartupFixtureError.expectedInitialCreationCrash
        } catch DeferredStartupInjectedRecordFailure.replace {
            // The exact creation intent and its permanent key are now durable.
        } catch {
            keys.deleteAllBestEffort()
            throw error
        }
        return DeferredStartupPendingTLSCreationFixture(
            backend: backend,
            keys: keys,
            crypto: crypto,
            tuple: tuple
        )
    }

    private func permanentTLSKeyFactory(
        keys: DeferredStartupPermanentTLSKeyBag
    ) -> HostProtectedP256SigningKeyFactory {
        let prefix = "com.harc.tests.deferred-startup.\(UUID().uuidString.lowercased())"
        return HostProtectedP256SigningKeyFactory(
            makeKey: {
                .securityFramework(try keys.createLegacyKey())
            },
            permanentLifecycle: HostPermanentTLSKeyLifecycle(
                applicationTag: { tuple, generation in
                    Data("\(prefix).\(tuple.hostStateID).g\(generation)".utf8)
                },
                loadIfPresent: { applicationTag in
                    try keys.loadIfPresent(applicationTag: applicationTag)
                        .map { .securityFramework($0) }
                },
                loadOrCreate: { applicationTag in
                    .securityFramework(
                        try keys.loadOrCreate(applicationTag: applicationTag)
                    )
                },
                deleteAndConfirmAbsent: { applicationTag, protection, publicKey in
                    try HostSecurityP256SigningKey
                        .deleteLegacyKeychainTestFixtureAndConfirmAbsent(
                            applicationTag: applicationTag,
                            protection: protection,
                            expectedPublicKey: publicKey
                        )
                }
            )
        )
    }
}

private struct DeferredStartupDiskPaths {
    let directory: URL
    let databaseURL: URL
    let stagingRoot: URL
}

private struct DeferredStartupPendingTLSCreationFixture {
    let backend: DeferredStartupFailFirstReplaceBackend
    let keys: DeferredStartupPermanentTLSKeyBag
    let crypto: KeychainHostCryptographicStateStore
    let tuple: HostCryptographicStateTuple
}

private enum DeferredStartupInjectedRecordFailure: Error {
    case replace
}

private enum DeferredStartupFixtureError: Error {
    case expectedInitialCreationCrash
}

private actor DeferredStartupFailFirstReplaceBackend:
    HostCryptographicStateRecordBackend
{
    private var record: Data?
    private var shouldFailReplacement = true

    func loadRecord() -> Data? { record }

    func insertRecordIfAbsent(_ record: Data) -> Bool {
        guard self.record == nil else { return false }
        self.record = record
        return true
    }

    func replaceRecord(expected: Data, with replacement: Data) throws -> Bool {
        guard record == expected else { return false }
        if shouldFailReplacement {
            shouldFailReplacement = false
            throw DeferredStartupInjectedRecordFailure.replace
        }
        record = replacement
        return true
    }
}

private final class DeferredStartupPermanentTLSKeyBag: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [HostSecurityP256SigningKey] = []

    func createLegacyKey() throws -> HostSecurityP256SigningKey {
        let key = try HostSecurityP256SigningKey.createLegacyKeychainTestFixture(
            applicationTag: Data(
                "com.harc.tests.deferred-startup.legacy.\(UUID().uuidString)".utf8
            )
        )
        remember(key)
        return key
    }

    func loadIfPresent(
        applicationTag: Data
    ) throws -> HostSecurityP256SigningKey? {
        try HostSecurityP256SigningKey.loadLegacyKeychainTestFixtureIfPresent(
            applicationTag: applicationTag
        )
    }

    func loadOrCreate(
        applicationTag: Data
    ) throws -> HostSecurityP256SigningKey {
        if let existing = try loadIfPresent(applicationTag: applicationTag) {
            remember(existing)
            return existing
        }
        let key = try HostSecurityP256SigningKey
            .loadOrCreateLegacyKeychainTestFixture(applicationTag: applicationTag)
        remember(key)
        return key
    }

    func deleteAllBestEffort() {
        lock.lock()
        let snapshot = keys
        keys.removeAll()
        lock.unlock()
        snapshot.forEach { $0.deletePersistentKeyBestEffort() }
    }

    private func remember(_ key: HostSecurityP256SigningKey) {
        lock.lock()
        if !keys.contains(where: { $0.applicationTag == key.applicationTag }) {
            keys.append(key)
        }
        lock.unlock()
    }
}

private actor DeferredStartupRecordingBoundary: HostTransportGenerationBoundary {
    private var roles: [HostTransportListenerRole] = []
    private var certificateDERs: [Data] = []
    private var bindErrors: [HostTransportGenerationError] = []
    private var immediateStops = 0

    func withdrawAdvertisementAndDrainGeneration() async throws {
        deleteCertificates()
    }

    func activateGeneration(
        _ generation: HostTransportServingGeneration
    ) async throws {
        let grpc = try await generation.grpcControl.consume(for: .grpcControl)
        let grpcCertificateDER = try await grpc.bindServerIdentity(
            for: .grpcControl
        ) { identity in
            identity.certificate.certificateDER
        }
        roles.append(.grpcControl)
        certificateDERs.append(grpcCertificateDER)
        do {
            _ = try await grpc.bindServerIdentity(for: .grpcControl) { _ in () }
            throw DeferredStartupBoundaryError.expectedDoubleBindRejection
        } catch let error as HostTransportGenerationError {
            bindErrors.append(error)
        }

        let upload = try await generation.backgroundUpload.consume(
            for: .backgroundUpload
        )
        let uploadCertificateDER = try await upload.bindServerIdentity(
            for: .backgroundUpload
        ) { identity in
            identity.certificate.certificateDER
        }
        roles.append(.backgroundUpload)
        certificateDERs.append(uploadCertificateDER)
    }

    func stopGenerationImmediately() async {
        immediateStops += 1
        deleteCertificates()
    }

    func activatedRoles() -> [HostTransportListenerRole] { roles }
    func observedBindErrors() -> [HostTransportGenerationError] { bindErrors }
    func stopCount() -> Int { immediateStops }

    private func deleteCertificates() {
        var seen = Set<Data>()
        for der in certificateDERs where seen.insert(der).inserted {
            HostTLSSigningIdentity.deleteInstalledServerCertificateBestEffort(
                certificateDER: der
            )
        }
        certificateDERs.removeAll()
    }
}

private enum DeferredStartupBoundaryError: Error {
    case expectedDoubleBindRejection
}
