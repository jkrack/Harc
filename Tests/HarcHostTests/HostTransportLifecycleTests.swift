import Foundation
import GRDB
import HarcDomain
@testable import HarcIdentity
import HarcProtocol
import Testing
@testable import HarcHost

// Security.framework's process-global certificate/identity lookup is not a
// concurrency-isolated test fixture. Serialize this suite so one test cannot
// remove its temporary Keychain material while another is resolving identity.
@Suite("Host transport-set lifecycle", .serialized)
struct HostTransportLifecycleTests {
    @Test("pending N+1 is advanced in Keychain and atomically applied on reopen")
    func pendingRecoveryAdvancesThenApplies() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let verified = try makeSet(state: fixture.state, epoch: 1, now: fixture.now)
        try await fixture.store.prepareTransportSetPublication(
            verified,
            kind: .initial,
            expectedActiveSPKISHA256: fixture.state.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: fixture.now
        )

        await #expect(throws: HostCryptographicStateError.self) {
            try await fixture.lifecycle.prepareForServing()
        }

        let database = try await fixture.store.transportDatabaseSnapshot()
        let protected = try await fixture.crypto.load(requiredTuple: fixture.state.tuple)
        #expect(database.epoch == 1)
        #expect(database.pending == nil)
        #expect(database.exactSignedBytes == verified.exactSignedBytes)
        #expect(protected.highestIssuedTransportSetEpoch == 1)
        #expect(try await historyCount(fixture.store) == 1)
    }

    @Test("a pending set whose Keychain mark already advanced applies without re-advancing")
    func pendingRecoveryAppliesAfterMark() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let verified = try makeSet(state: fixture.state, epoch: 1, now: fixture.now)
        try await fixture.store.prepareTransportSetPublication(
            verified,
            kind: .initial,
            expectedActiveSPKISHA256: fixture.state.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: fixture.now
        )
        _ = try await fixture.crypto.advanceHighestIssuedTransportSetEpoch(
            for: fixture.state.tuple,
            from: 0,
            to: 1
        )

        await #expect(throws: HostCryptographicStateError.self) {
            try await fixture.lifecycle.prepareForServing()
        }
        let database = try await fixture.store.transportDatabaseSnapshot()
        #expect(database.epoch == 1)
        #expect(database.pending == nil)
        #expect(try await historyCount(fixture.store) == 1)
    }

    @Test("a corrupt pending object binding is never advanced or discarded")
    func corruptPendingFailsClosed() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let verified = try makeSet(state: fixture.state, epoch: 1, now: fixture.now)
        try await fixture.store.dbQueue.write { db in
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
                    verified.exactSignedBytes,
                    Data(repeating: 0xe1, count: 32),
                    fixture.state.activeTLSIdentity.tlsSPKISHA256,
                    fixture.now.timeIntervalSince1970,
                ]
            )
        }

        await #expect(throws: HarcHostError.transportSetPendingMismatch) {
            try await fixture.lifecycle.prepareForServing()
        }
        let database = try await fixture.store.transportDatabaseSnapshot()
        let protected = try await fixture.crypto.load(requiredTuple: fixture.state.tuple)
        #expect(database.epoch == 0)
        #expect(database.pending != nil)
        #expect(protected.highestIssuedTransportSetEpoch == 0)
        #expect(try await historyCount(fixture.store) == 0)
    }

    @Test("an expired but valid pending set is applied exactly, then refreshed before readiness")
    func expiredPendingPublishesFreshSuccessor() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let nowMilliseconds = UInt64(fixture.now.timeIntervalSince1970 * 1_000)
        let expired = try makeSet(
            state: fixture.state,
            epoch: 1,
            now: fixture.now,
            notBefore: nowMilliseconds - 86_400_000,
            notAfter: nowMilliseconds - 60_000
        )
        try await fixture.store.prepareTransportSetPublication(
            expired,
            kind: .initial,
            expectedActiveSPKISHA256: fixture.state.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: fixture.now
        )

        await #expect(throws: HostCryptographicStateError.self) {
            try await fixture.lifecycle.prepareForServing()
        }

        let database = try await fixture.store.transportDatabaseSnapshot()
        let protected = try await fixture.crypto.load(requiredTuple: fixture.state.tuple)
        let exact = try #require(database.exactSignedBytes)
        let fresh = try VerifiedHostTransportSetV1.decode(
            exact,
            hostAuthorityPublicKey: protected.authorityIdentity.publicKey
        )
        #expect(database.epoch == 2)
        #expect(protected.highestIssuedTransportSetEpoch == 2)
        #expect(fresh.transportSet.setEpoch == 2)
        #expect(fresh.transportSet.entries[0].notAfterUnixMilliseconds > nowMilliseconds)
        #expect(try await historyCount(fixture.store) == 2)
    }

    @Test("a Keychain mark ahead of HostDB without the exact pending row fails closed")
    func rollbackFailsClosed() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.crypto.advanceHighestIssuedTransportSetEpoch(
            for: fixture.state.tuple,
            from: 0,
            to: 1
        )

        do {
            _ = try await fixture.lifecycle.prepareForServing()
            Issue.record("Expected transport rollback to fail closed")
        } catch let error as HarcHostError {
            #expect(error == .transportSetRollback(databaseEpoch: 0, highWaterEpoch: 1))
        }
    }

    @Test("only one publisher can reserve the singleton next-epoch journal")
    func concurrentPendingPublisher() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let verified = try makeSet(state: fixture.state, epoch: 1, now: fixture.now)

        async let first = reserveOnce(fixture.store, verified: verified, state: fixture.state)
        async let second = reserveOnce(fixture.store, verified: verified, state: fixture.state)
        let wins = await [first, second].filter { $0 }.count
        #expect(wins == 1)
        let snapshot = try await fixture.store.transportDatabaseSnapshot()
        #expect(snapshot.pending != nil)
    }

    @Test("capability floor advancement is atomic and pauses behind a pending publication")
    func capabilityFloorSerialization() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try makeSet(state: fixture.state, epoch: 1, now: fixture.now)
        try await fixture.store.prepareTransportSetPublication(
            first,
            kind: .initial,
            expectedActiveSPKISHA256: fixture.state.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: fixture.now
        )
        _ = try await fixture.crypto.advanceHighestIssuedTransportSetEpoch(
            for: fixture.state.tuple,
            from: 0,
            to: 1
        )
        let pendingSnapshot = try await fixture.store.transportDatabaseSnapshot()
        let pending = try #require(pendingSnapshot.pending)
        try await fixture.store.applyPendingTransportSetPublication(
            expected: pending,
            verified: first,
            at: fixture.now
        )
        let requestedFloor: UInt64 = 2_000_000_900_000
        let reservation = try await fixture.store.reserveCapabilityTransportWindow(
            expectedEpoch: 1,
            expectedObjectID: first.objectID,
            proposedRetirementFloorUnixMilliseconds: requestedFloor,
            extendRetirementFloor: true,
            at: fixture.now
        )
        #expect(reservation.retirementFloorUnixMilliseconds == requestedFloor)
        await #expect(throws: HarcHostError.transportSetTransitionInProgress) {
            try await fixture.store.beginPlannedTransportRotation(
                oldSPKISHA256: fixture.state.activeTLSIdentity.tlsSPKISHA256,
                retirementFloorUnixMilliseconds: 0,
                at: fixture.now
            )
        }

        let currentState = try await fixture.crypto.load(requiredTuple: fixture.state.tuple)
        let second = try makeSet(state: currentState, epoch: 2, now: fixture.now)
        try await fixture.store.prepareTransportSetPublication(
            second,
            kind: .stableRenewal,
            expectedActiveSPKISHA256: currentState.activeTLSIdentity.tlsSPKISHA256,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: requestedFloor,
            at: fixture.now
        )
        await #expect(throws: HarcHostError.transportSetTransitionInProgress) {
            try await fixture.store.reserveCapabilityTransportWindow(
                expectedEpoch: 1,
                expectedObjectID: first.objectID,
                proposedRetirementFloorUnixMilliseconds: requestedFloor + 1,
                extendRetirementFloor: true,
                at: fixture.now
            )
        }
    }

    @Test("planned rotation publishes overlap before drained cutover and one-key final")
    func plannedRotation() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let initial = try await fixture.lifecycle.prepareForServing()
        let reopened = try await fixture.lifecycle.prepareForServing()
        #expect(
            reopened.serverIdentity.certificate.certificateDER
                == initial.serverIdentity.certificate.certificateDER
        )
        #expect(try await historyCount(fixture.store) == 1)
        let oldSPKI = initial.serverIdentity.certificate.tlsSPKISHA256
        let overlap = try await fixture.lifecycle.beginPlannedRotation()
        #expect(overlap.verifiedTransportSet.setEpoch == 2)
        #expect(overlap.verifiedTransportSet.entries.count == 2)
        #expect(overlap.serverIdentity.certificate.tlsSPKISHA256 == oldSPKI)

        let final = try await fixture.lifecycle.completePlannedRotation()
        #expect(final.verifiedTransportSet.setEpoch == 3)
        #expect(final.verifiedTransportSet.entries.count == 1)
        #expect(final.serverIdentity.certificate.tlsSPKISHA256 != oldSPKI)
        #expect(
            await fixture.boundary.events == [
                .activateStarted(epoch: 1),
                .listenerBound(epoch: 1, role: .grpcControl),
                .listenerBound(epoch: 1, role: .backgroundUpload),
                .advertised(epoch: 1),
                .withdrawAdvertisementAndDrain(epoch: 1),
                .activateStarted(epoch: 2),
                .listenerBound(epoch: 2, role: .grpcControl),
                .listenerBound(epoch: 2, role: .backgroundUpload),
                .advertised(epoch: 2),
                .withdrawAdvertisementAndDrain(epoch: 2),
                .activateStarted(epoch: 3),
                .listenerBound(epoch: 3, role: .grpcControl),
                .listenerBound(epoch: 3, role: .backgroundUpload),
                .advertised(epoch: 3),
            ]
        )
        let protected = try await fixture.crypto.load(requiredTuple: fixture.state.tuple)
        #expect(protected.stagedTLSIdentity == nil)
        #expect(protected.retiringTLSIdentity == nil)
        #expect(try await fixture.store.transportRotationIntent() == nil)
        #expect(try await historyCount(fixture.store) == 3)
        deleteCertificate(initial.serverIdentity.certificate.certificateDER)
        deleteCertificate(overlap.serverIdentity.certificate.certificateDER)
        deleteCertificate(final.serverIdentity.certificate.certificateDER)
    }

    @Test("capability reservation and planned publication are serialized across awaits")
    func capabilityReservationSerializesWithRotation() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let initial = try await fixture.lifecycle.prepareForServing()
        let expiry = fixture.now.addingTimeInterval(24 * 60 * 60)

        async let rotation = fixture.lifecycle.beginPlannedRotation()
        async let reservation = fixture.lifecycle.reserveTransportForCapability(
            expiringAt: expiry
        )
        let (overlap, capability) = try await (rotation, reservation)

        #expect(overlap.verifiedTransportSet.setEpoch == 2)
        #expect(overlap.verifiedTransportSet.entries.count == 2)
        #expect(capability.minimumTransportSetEpoch == 1
            || capability.minimumTransportSetEpoch == 2)
        if capability.minimumTransportSetEpoch == 1 {
            #expect(
                overlap.retirementFloorUnixMilliseconds
                    == capability.retirementFloorUnixMilliseconds
            )
            #expect(capability.exactSignedTransportSet
                == initial.verifiedTransportSet.exactSignedBytes)
        } else {
            #expect(capability.exactSignedTransportSet
                == overlap.verifiedTransportSet.exactSignedBytes)
        }
        #expect(try await fixture.store.transportDatabaseSnapshot().pending == nil)
        deleteCertificate(initial.serverIdentity.certificate.certificateDER)
        deleteCertificate(overlap.serverIdentity.certificate.certificateDER)
    }

    @Test("restart binds an already-staged replacement instead of minting another key")
    func plannedRotationRecoversAfterStagingBeforeBinding() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let initial = try await fixture.lifecycle.prepareForServing()
        let oldSPKI = fixture.state.activeTLSIdentity.tlsSPKISHA256
        try await fixture.store.beginPlannedTransportRotation(
            oldSPKISHA256: oldSPKI,
            retirementFloorUnixMilliseconds: 0,
            at: fixture.now
        )
        let stagedState = try await fixture.crypto.stageReplacementTLSIdentity(
            for: fixture.state.tuple,
            expectedActivePublicKey: fixture.state.activeTLSIdentity.publicKey
        )
        let staged = try #require(stagedState.stagedTLSIdentity)

        // Simulate process death after the permanent key record CAS but before
        // HostDB received the replacement SPKI binding.
        let reopenedBoundary = RecordingGenerationBoundary()
        let reopened = HostTransportLifecycle(
            store: fixture.store,
            cryptographicStateStore: fixture.crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: reopenedBoundary,
            now: { fixture.now }
        )
        let overlap = try await reopened.prepareForServing()
        let recoveredState = try await fixture.crypto.load(
            requiredTuple: fixture.state.tuple
        )
        let intent = try #require(try await fixture.store.transportRotationIntent())
        #expect(recoveredState.stagedTLSIdentity?.publicKey == staged.publicKey)
        #expect(intent.newTLSSPKISHA256 == staged.tlsSPKISHA256)
        #expect(overlap.verifiedTransportSet.setEpoch == 2)
        #expect(
            Set(overlap.verifiedTransportSet.entries.map {
                $0.tlsSPKISHA256
            })
                == Set([oldSPKI, staged.tlsSPKISHA256])
        )

        let final = try await reopened.completePlannedRotation()
        #expect(
            await reopenedBoundary.events.filter(\.isDrainEvent).count == 1
        )
        #expect(final.serverIdentity.certificate.tlsSPKISHA256 == staged.tlsSPKISHA256)
        deleteCertificate(initial.serverIdentity.certificate.certificateDER)
        deleteCertificate(overlap.serverIdentity.certificate.certificateDER)
        deleteCertificate(final.serverIdentity.certificate.certificateDER)
    }

    @Test("a protected transition key without its HostDB intent fails closed")
    func orphanedTransitionKeyDetectsHostDBRollback() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let initial = try await fixture.lifecycle.prepareForServing()
        _ = try await fixture.crypto.stageReplacementTLSIdentity(
            for: fixture.state.tuple,
            expectedActivePublicKey: fixture.state.activeTLSIdentity.publicKey
        )

        let reopenedBoundary = RecordingGenerationBoundary()
        let reopened = HostTransportLifecycle(
            store: fixture.store,
            cryptographicStateStore: fixture.crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: reopenedBoundary,
            now: { fixture.now }
        )
        await #expect(throws: HarcHostError.transportRotationStateMismatch) {
            try await reopened.prepareForServing()
        }
        #expect(try await fixture.store.transportRotationIntent() == nil)
        #expect(await reopenedBoundary.events.isEmpty)
        deleteCertificate(initial.serverIdentity.certificate.certificateDER)
    }

    @Test("emergency rotation drains first and publishes only the replacement key")
    func emergencyRotation() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let initial = try await fixture.lifecycle.prepareForServing()
        let emergency = try await fixture.lifecycle.performEmergencyRotation()
        #expect(
            await fixture.boundary.events.filter(\.isDrainEvent).count == 1
        )
        #expect(emergency.verifiedTransportSet.setEpoch == 2)
        #expect(emergency.verifiedTransportSet.entries.count == 1)
        #expect(
            emergency.serverIdentity.certificate.tlsSPKISHA256
                != initial.serverIdentity.certificate.tlsSPKISHA256
        )
        let protected = try await fixture.crypto.load(requiredTuple: fixture.state.tuple)
        #expect(protected.stagedTLSIdentity == nil)
        #expect(protected.retiringTLSIdentity == nil)
        #expect(try await fixture.store.transportRotationIntent() == nil)
        #expect(try await historyCount(fixture.store) == 2)
        deleteCertificate(initial.serverIdentity.certificate.certificateDER)
        deleteCertificate(emergency.serverIdentity.certificate.certificateDER)
    }

    @Test("listener leases are role-bound, one-shot, and stale after activation")
    func listenerLeaseGuards() async throws {
        let fixture = try await makePermanentFixture(
            activationMode: .probeLeaseGuardsThenConsumeBoth
        )
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let ready = try await fixture.lifecycle.prepareForServing()
        #expect(
            await fixture.boundary.observedLeaseErrors == [
                .wrongRole,
                .leaseAlreadyBound,
                .leaseAlreadyConsumed,
            ]
        )
        let generation = try #require(await fixture.boundary.generations.first)
        await #expect(throws: HostTransportGenerationError.staleLease) {
            try await generation.grpcControl.consume(for: .grpcControl)
        }
        await #expect(throws: HostTransportGenerationError.staleLease) {
            try await generation.backgroundUpload.consume(for: .backgroundUpload)
        }
        #expect(await fixture.lifecycle.generationStatus()?.generationID == generation.generationID)

        deleteCertificate(ready.serverIdentity.certificate.certificateDER)
    }

    @Test("partial listener activation stops immediately and invalidates every lease")
    func partialActivationFailsClosed() async throws {
        let fixture = try await makePermanentFixture(
            activationMode: .consumeOnlyGRPC
        )
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        await #expect(throws: HostTransportGenerationError.incompleteActivation) {
            try await fixture.lifecycle.prepareForServing()
        }
        #expect(await fixture.lifecycle.generationStatus() == nil)
        #expect(
            await fixture.boundary.events == [
                .activateStarted(epoch: 1),
                .listenerBound(epoch: 1, role: .grpcControl),
                .stopImmediately(epoch: nil),
            ]
        )

        let failedGeneration = try #require(await fixture.boundary.generations.first)
        await #expect(throws: HostTransportGenerationError.staleLease) {
            try await failedGeneration.grpcControl.consume(for: .grpcControl)
        }
        await #expect(throws: HostTransportGenerationError.staleLease) {
            try await failedGeneration.backgroundUpload.consume(for: .backgroundUpload)
        }

        await fixture.boundary.setActivationMode(.consumeBoth)
        let recovered = try await fixture.lifecycle.prepareForServing()
        let recoveredGeneration = try #require(await fixture.boundary.generations.last)
        #expect(recoveredGeneration.generationID != failedGeneration.generationID)
        #expect(await fixture.lifecycle.generationStatus()?.generationID
            == recoveredGeneration.generationID)
        #expect(try await historyCount(fixture.store) == 1)

        for certificateDER in await fixture.boundary.boundCertificateDERs() {
            deleteCertificate(certificateDER)
        }
        deleteCertificate(recovered.serverIdentity.certificate.certificateDER)
    }

    @Test("unexpected termination invalidates only the exact reported generation")
    func unexpectedTerminationIsGenerationScoped() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let initialReady = try await fixture.lifecycle.prepareForServing()
        let initialGeneration = try #require(
            await fixture.boundary.generations.first
        )
        await initialGeneration.terminationReporter
            .reportUnexpectedTermination()

        #expect(await fixture.lifecycle.generationStatus() == nil)
        await #expect(throws:
            HostTransportGenerationError.generationNotPrepared
        ) {
            try await fixture.lifecycle.reserveTransportForCapability(
                expiringAt: fixture.clock.now.addingTimeInterval(60)
            )
        }

        let recoveredReady = try await fixture.lifecycle.prepareForServing()
        let recoveredGeneration = try #require(
            await fixture.boundary.generations.last
        )
        #expect(
            recoveredGeneration.generationID
                != initialGeneration.generationID
        )

        // A duplicate delayed report from the old transport cannot clear the
        // replacement generation.
        await initialGeneration.terminationReporter
            .reportUnexpectedTermination()
        #expect(
            await fixture.lifecycle.generationStatus()?.generationID
                == recoveredGeneration.generationID
        )

        await recoveredGeneration.terminationReporter
            .reportUnexpectedTermination()
        #expect(await fixture.lifecycle.generationStatus() == nil)

        for certificateDER in await fixture.boundary.boundCertificateDERs() {
            deleteCertificate(certificateDER)
        }
        deleteCertificate(
            initialReady.serverIdentity.certificate.certificateDER
        )
        deleteCertificate(
            recoveredReady.serverIdentity.certificate.certificateDER
        )
    }

    @Test("resident scheduler wakes and recovers after terminal generation report")
    func residentSchedulerRecoversUnexpectedTermination() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let runtime = try await HostTransportResidentRuntime.start(
            store: fixture.store,
            cryptographicStateStore: fixture.crypto,
            transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
            generationBoundary: fixture.boundary,
            canonicalTuple: fixture.state.tuple,
            now: { fixture.clock.now }
        )
        do {
            await fixture.boundary.waitForGenerationCount(1)
            let initialGeneration = try #require(
                await fixture.boundary.generations.first
            )

            await initialGeneration.terminationReporter
                .reportUnexpectedTermination()
            await fixture.boundary.waitForGenerationCount(2)
            await runtime.handleSystemWake()

            let recoveredGeneration = try #require(
                await fixture.boundary.generations.last
            )
            #expect(
                recoveredGeneration.generationID
                    != initialGeneration.generationID
            )
            #expect(
                await runtime.generationStatus()?.generationID
                    == recoveredGeneration.generationID
            )
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }

        for certificateDER in await fixture.boundary.boundCertificateDERs() {
            deleteCertificate(certificateDER)
        }
    }

    @Test("validity hard stop takes the host offline once and clears generation state")
    func renewalHardStopFailsClosed() async throws {
        let fixture = try await makePermanentFixture()
        defer {
            fixture.keys.deleteAllBestEffort()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let ready = try await fixture.lifecycle.prepareForServing()
        let status = try #require(await fixture.lifecycle.generationStatus())
        fixture.clock.set(status.hardStopAt.addingTimeInterval(1))

        #expect(await fixture.lifecycle.enforceRenewalHardStopIfNeeded())
        #expect(!(await fixture.lifecycle.enforceRenewalHardStopIfNeeded()))
        #expect(await fixture.lifecycle.generationStatus() == nil)
        #expect(await fixture.boundary.events.last == .stopImmediately(epoch: 1))
        await #expect(throws: HostTransportGenerationError.generationNotPrepared) {
            try await fixture.lifecycle.reserveTransportForCapability(
                expiringAt: fixture.clock.now.addingTimeInterval(60)
            )
        }

        deleteCertificate(ready.serverIdentity.certificate.certificateDER)
    }

    private struct Fixture {
        let directory: URL
        let now: Date
        let crypto: InMemoryHostCryptographicStateStore
        let state: HostCryptographicState
        let store: HarcHostStore
        let boundary: RecordingGenerationBoundary
        let lifecycle: HostTransportLifecycle
    }

    private struct PermanentFixture {
        let directory: URL
        let now: Date
        let keys: PermanentHostTLSKeyBag
        let crypto: KeychainHostCryptographicStateStore
        let state: HostCryptographicState
        let store: HarcHostStore
        let boundary: RecordingGenerationBoundary
        let clock: LockedTestClock
        let lifecycle: HostTransportLifecycle
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcTransportLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let crypto = InMemoryHostCryptographicStateStore()
        let state = try await crypto.loadOrCreate(libraryID: .random())
        let metadata = HarcHostMetadata(
            libraryID: state.tuple.libraryID,
            hostAuthorityID: state.tuple.hostAuthorityID,
            hostStateID: state.tuple.hostStateID
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory.appendingPathComponent("staging"),
            metadata: metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { now }
        )
        let boundary = RecordingGenerationBoundary()
        return Fixture(
            directory: directory,
            now: now,
            crypto: crypto,
            state: state,
            store: store,
            boundary: boundary,
            lifecycle: HostTransportLifecycle(
                store: store,
                cryptographicStateStore: crypto,
                transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
                generationBoundary: boundary,
                now: { now }
            )
        )
    }

    private func makePermanentFixture(
        activationMode: RecordingGenerationActivationMode = .consumeBoth
    ) async throws -> PermanentFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcTransportRotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys = PermanentHostTLSKeyBag()
        let crypto = KeychainHostCryptographicStateStore(
            backend: InMemoryHostCryptographicStateRecordBackend(),
            tlsKeyFactory: HostProtectedP256SigningKeyFactory(
                makeKey: {
                    .securityFramework(try keys.create())
                },
                permanentLifecycle: HostPermanentTLSKeyLifecycle(
                    applicationTag: { tuple, generation in
                        keys.applicationTag(for: tuple, generation: generation)
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
                    deleteAndConfirmAbsent: {
                        applicationTag,
                        protection,
                        publicKey in
                        try keys.deleteAndConfirmAbsent(
                            applicationTag: applicationTag,
                            protection: protection,
                            publicKey: publicKey
                        )
                    }
                )
            ),
            persistentSecurityKeyLoader: { applicationTag, protection in
                .securityFramework(
                    try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                        applicationTag: applicationTag,
                        protection: protection
                    )
                )
            }
        )
        let state = try await crypto.loadOrCreate(libraryID: .random())
        let metadata = HarcHostMetadata(
            libraryID: state.tuple.libraryID,
            hostAuthorityID: state.tuple.hostAuthorityID,
            hostStateID: state.tuple.hostStateID
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory.appendingPathComponent("staging"),
            metadata: metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { now }
        )
        let boundary = RecordingGenerationBoundary(activationMode: activationMode)
        let clock = LockedTestClock(now)
        return PermanentFixture(
            directory: directory,
            now: now,
            keys: keys,
            crypto: crypto,
            state: state,
            store: store,
            boundary: boundary,
            clock: clock,
            lifecycle: HostTransportLifecycle(
                store: store,
                cryptographicStateStore: crypto,
                transportSetProtocol: TestHostTransportSetProtocolBoundaryV1(),
                generationBoundary: boundary,
                now: { clock.now }
            )
        )
    }

    private func makeSet(
        state: HostCryptographicState,
        epoch: UInt64,
        now: Date,
        notBefore: UInt64? = nil,
        notAfter: UInt64? = nil
    ) throws -> HostValidatedTransportSet {
        let nowMilliseconds = UInt64(now.timeIntervalSince1970 * 1_000)
        let entry = try HostValidatedTransportSetEntry(
            tlsSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256,
            notBeforeUnixMilliseconds: notBefore ?? nowMilliseconds - 300_000,
            // Default fixtures are comfortably outside the production
            // seven-day proactive-renewal window. Tests exercising expiry or
            // renewal pass an explicit boundary.
            notAfterUnixMilliseconds: notAfter
                ?? nowMilliseconds + (30 * 86_400_000)
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

    private func reserveOnce(
        _ store: HarcHostStore,
        verified: HostValidatedTransportSet,
        state: HostCryptographicState
    ) async -> Bool {
        do {
            try await store.prepareTransportSetPublication(
                verified,
                kind: .initial,
                expectedActiveSPKISHA256: state.activeTLSIdentity.tlsSPKISHA256,
                secondarySPKISHA256: nil,
                retirementFloorUnixMilliseconds: 0,
                at: Date(timeIntervalSince1970: 2_000_000_000)
            )
            return true
        } catch {
            return false
        }
    }

    private func historyCount(_ store: HarcHostStore) async throws -> Int {
        try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host_transport_sets") ?? 0
        }
    }

    private func deleteCertificate(_ der: Data) {
        HostTLSSigningIdentity.deleteInstalledServerCertificateBestEffort(
            certificateDER: der
        )
    }
}

private enum RecordingGenerationActivationMode: Sendable {
    case consumeBoth
    case consumeOnlyGRPC
    case probeLeaseGuardsThenConsumeBoth
}

private enum RecordingGenerationEvent: Equatable, Sendable {
    case activateStarted(epoch: UInt64)
    case listenerBound(epoch: UInt64, role: HostTransportListenerRole)
    case advertised(epoch: UInt64)
    case withdrawAdvertisementAndDrain(epoch: UInt64?)
    case stopImmediately(epoch: UInt64?)

    var isDrainEvent: Bool {
        if case .withdrawAdvertisementAndDrain = self { return true }
        return false
    }
}

private enum RecordingGenerationBoundaryError: Error {
    case expectedWrongRoleRejection
    case expectedDoubleConsumeRejection
}

private actor RecordingGenerationBoundary: HostTransportGenerationBoundary {
    private var activationMode: RecordingGenerationActivationMode
    private var activeEpoch: UInt64?
    private var certificateDERs: [Data] = []
    private(set) var events: [RecordingGenerationEvent] = []
    private(set) var generations: [HostTransportServingGeneration] = []
    private(set) var observedLeaseErrors: [HostTransportGenerationError] = []
    private var generationCountWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    init(
        activationMode: RecordingGenerationActivationMode = .consumeBoth
    ) {
        self.activationMode = activationMode
    }

    func setActivationMode(_ activationMode: RecordingGenerationActivationMode) {
        self.activationMode = activationMode
    }

    func waitForGenerationCount(_ count: Int) async {
        guard generations.count < count else { return }
        await withCheckedContinuation { continuation in
            generationCountWaiters.append((count, continuation))
        }
    }

    func withdrawAdvertisementAndDrainGeneration() async throws {
        events.append(.withdrawAdvertisementAndDrain(epoch: activeEpoch))
        activeEpoch = nil
    }

    func activateGeneration(
        _ generation: HostTransportServingGeneration
    ) async throws {
        events.append(.activateStarted(epoch: generation.transportEpoch))
        generations.append(generation)
        let readyWaiters = generationCountWaiters.filter {
            generations.count >= $0.count
        }
        generationCountWaiters.removeAll {
            generations.count >= $0.count
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }

        switch activationMode {
        case .consumeBoth:
            try await bind(
                generation.grpcControl,
                for: .grpcControl,
                epoch: generation.transportEpoch
            )
            try await bind(
                generation.backgroundUpload,
                for: .backgroundUpload,
                epoch: generation.transportEpoch
            )

        case .consumeOnlyGRPC:
            try await bind(
                generation.grpcControl,
                for: .grpcControl,
                epoch: generation.transportEpoch
            )
            return

        case .probeLeaseGuardsThenConsumeBoth:
            do {
                _ = try await generation.grpcControl.consume(
                    for: .backgroundUpload
                )
                throw RecordingGenerationBoundaryError.expectedWrongRoleRejection
            } catch let error as HostTransportGenerationError {
                observedLeaseErrors.append(error)
            }
            let material = try await generation.grpcControl.consume(for: .grpcControl)
            try await bindMaterial(
                material,
                for: .grpcControl,
                epoch: generation.transportEpoch
            )
            do {
                try await bindMaterial(
                    material,
                    for: .grpcControl,
                    epoch: generation.transportEpoch
                )
                throw RecordingGenerationBoundaryError.expectedDoubleConsumeRejection
            } catch let error as HostTransportGenerationError {
                observedLeaseErrors.append(error)
            }
            do {
                _ = try await generation.grpcControl.consume(for: .grpcControl)
                throw RecordingGenerationBoundaryError.expectedDoubleConsumeRejection
            } catch let error as HostTransportGenerationError {
                observedLeaseErrors.append(error)
            }
            try await bind(
                generation.backgroundUpload,
                for: .backgroundUpload,
                epoch: generation.transportEpoch
            )
        }

        activeEpoch = generation.transportEpoch
        events.append(.advertised(epoch: generation.transportEpoch))
    }

    func stopGenerationImmediately() async {
        events.append(.stopImmediately(epoch: activeEpoch))
        activeEpoch = nil
    }

    func boundCertificateDERs() -> [Data] {
        var seen = Set<Data>()
        return certificateDERs.filter { seen.insert($0).inserted }
    }

    private func bind(
        _ lease: HostTransportListenerLease,
        for role: HostTransportListenerRole,
        epoch: UInt64
    ) async throws {
        let material = try await lease.consume(for: role)
        try await bindMaterial(material, for: role, epoch: epoch)
    }

    private func bindMaterial(
        _ material: HostTransportListenerMaterial,
        for role: HostTransportListenerRole,
        epoch: UInt64
    ) async throws {
        let certificateDER = try await material.bindServerIdentity(for: role) {
            $0.certificate.certificateDER
        }
        certificateDERs.append(certificateDER)
        events.append(.listenerBound(epoch: epoch, role: role))
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

private final class PermanentHostTLSKeyBag: @unchecked Sendable {
    private let lock = NSLock()
    private let applicationTagPrefix =
        "com.harc.tests.rotation.\(UUID().uuidString.lowercased())"
    private var keys: [HostSecurityP256SigningKey] = []

    func applicationTag(
        for tuple: HostCryptographicStateTuple,
        generation: UInt64
    ) -> Data {
        Data(
            "\(applicationTagPrefix).\(tuple.hostStateID.rawValue.uuidString.lowercased()).g\(generation)"
                .utf8
        )
    }

    func create() throws -> HostSecurityP256SigningKey {
        let key = try HostSecurityP256SigningKey.createLegacyKeychainTestFixture(
            applicationTag: Data(
                "\(applicationTagPrefix).legacy.\(UUID().uuidString.lowercased())".utf8
            )
        )
        remember(key)
        return key
    }

    func loadIfPresent(
        applicationTag: Data
    ) throws -> HostSecurityP256SigningKey? {
        let key = try HostSecurityP256SigningKey
            .loadLegacyKeychainTestFixtureIfPresent(applicationTag: applicationTag)
        if let key { remember(key) }
        return key
    }

    func loadOrCreate(
        applicationTag: Data
    ) throws -> HostSecurityP256SigningKey {
        let key = try HostSecurityP256SigningKey
            .loadOrCreateLegacyKeychainTestFixture(applicationTag: applicationTag)
        remember(key)
        return key
    }

    func deleteAndConfirmAbsent(
        applicationTag: Data,
        protection: InstallationKeyProtection,
        publicKey: P256X963PublicKey
    ) throws {
        try HostSecurityP256SigningKey
            .deleteLegacyKeychainTestFixtureAndConfirmAbsent(
                applicationTag: applicationTag,
                protection: protection,
                expectedPublicKey: publicKey
            )
    }

    private func remember(_ key: HostSecurityP256SigningKey) {
        lock.lock()
        keys.append(key)
        lock.unlock()
    }

    func deleteAllBestEffort() {
        lock.lock()
        let snapshot = keys
        lock.unlock()
        snapshot.forEach { $0.deletePersistentKeyBestEffort() }
    }
}
