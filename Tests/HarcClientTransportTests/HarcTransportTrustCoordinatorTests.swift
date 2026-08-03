#if canImport(Network)
import Foundation
import Testing
@testable import HarcClientTransport

@Suite("Pinned transport trust coordinator")
struct HarcTransportTrustCoordinatorTests {
    @Test("pairing accepts only the exact QR transport set")
    func pairingUsesExactQRSet() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let qrSet = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let coordinator = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet: qrSet.exactSignedBytes,
            hostAuthorityPublicKey: authority.publicKey,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let exactLeaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: qrSet.exactSignedBytes
        )

        let accepted = try await coordinator.validateServerLeaf(
            certificateDER: exactLeaf
        )
        #expect(accepted.transportSetEpoch == 1)
        #expect(accepted.exactTransportSet == qrSet.exactSignedBytes)

        let newerSet = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 2
        )
        let newerLeaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: newerSet.exactSignedBytes
        )
        await #expect(
            throws: HarcTransportTrustError.pairingTransportSetMismatch
        ) {
            try await coordinator.validateServerLeaf(certificateDER: newerLeaf)
        }
    }

    @Test("a covering higher set is committed and reloaded before acceptance")
    func durableAdvanceAndReload() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let oldTLS = try TransportTrustFixtures.tlsKey(0x41)
        let newTLS = try TransportTrustFixtures.tlsKey(0x42)
        let oldSet = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [oldTLS],
            epoch: 1
        )
        let coveringSet = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [oldTLS, newTLS],
            epoch: 2
        )
        let persistence = TransportTrustTestPersistence(
            state: try TransportTrustFixtures.persistedState(
                authorityKey: authority,
                verifiedSet: oldSet
            )
        )
        let coordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: persistence,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let leaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: newTLS,
            exactTransportSet: coveringSet.exactSignedBytes
        )

        let accepted = try await coordinator.validateServerLeaf(
            certificateDER: leaf
        )

        #expect(accepted.transportSetEpoch == 2)
        #expect(await persistence.persistedEpochs == [2])
        #expect(
            await persistence.currentState()?.exactHighestTransportSet
                == coveringSet.exactSignedBytes
        )
    }

    @Test("a signed lower epoch is rejected as rollback")
    func rejectsRollback() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let lower = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let highest = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 2
        )
        let persistence = TransportTrustTestPersistence(
            state: try TransportTrustFixtures.persistedState(
                authorityKey: authority,
                verifiedSet: highest
            )
        )
        let coordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: persistence,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let leaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: lower.exactSignedBytes
        )

        await #expect(
            throws: HarcTransportTrustError.transportSetRollback(
                stored: 2,
                presented: 1
            )
        ) {
            try await coordinator.validateServerLeaf(certificateDER: leaf)
        }
        #expect(await persistence.persistedEpochs.isEmpty)
    }

    @Test("different exact bytes at the highest epoch are equivocation")
    func rejectsEqualEpochEquivocation() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let stored = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 2
        )
        let equivocating = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 2,
            issuedAt: TransportTrustFixtures.nowMilliseconds - 119_000
        )
        let persistence = TransportTrustTestPersistence(
            state: try TransportTrustFixtures.persistedState(
                authorityKey: authority,
                verifiedSet: stored
            )
        )
        let coordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: persistence,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let leaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: equivocating.exactSignedBytes
        )

        await #expect(
            throws: HarcTransportTrustError.transportSetEquivocation(epoch: 2)
        ) {
            try await coordinator.validateServerLeaf(certificateDER: leaf)
        }
        #expect(await persistence.persistedEpochs.isEmpty)
    }

    @Test("candidate SPKI coverage is required before persistence")
    func coveragePrecedesCommit() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let storedTLS = try TransportTrustFixtures.tlsKey(0x41)
        let unlistedTLS = try TransportTrustFixtures.tlsKey(0x42)
        let stored = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [storedTLS],
            epoch: 1
        )
        let candidate = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [storedTLS],
            epoch: 2
        )
        let persistence = TransportTrustTestPersistence(
            state: try TransportTrustFixtures.persistedState(
                authorityKey: authority,
                verifiedSet: stored
            )
        )
        let coordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: persistence,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let leaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: unlistedTLS,
            exactTransportSet: candidate.exactSignedBytes
        )

        await #expect(
            throws: HarcTransportTrustError.observedSPKINotAuthorized
        ) {
            try await coordinator.validateServerLeaf(certificateDER: leaf)
        }
        #expect(await persistence.persistedEpochs.isEmpty)
    }

    @Test("persistence failure and a missing durable write both fail closed")
    func persistenceFailuresRejectTrust() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let initial = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let candidate = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 2
        )
        let initialState = try TransportTrustFixtures.persistedState(
            authorityKey: authority,
            verifiedSet: initial
        )
        let leaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: candidate.exactSignedBytes
        )

        let failing = TransportTrustTestPersistence(
            state: initialState,
            failPersist: true
        )
        let failingCoordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: failing,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        await #expect(throws: TransportTrustTestPersistenceError.forcedFailure) {
            try await failingCoordinator.validateServerLeaf(certificateDER: leaf)
        }

        let lying = TransportTrustTestPersistence(
            state: initialState,
            ignorePersist: true
        )
        let lyingCoordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: lying,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        await #expect(
            throws: HarcTransportTrustError.durableCommitNotObserved(
                expectedEpoch: 2,
                actualEpoch: 1
            )
        ) {
            try await lyingCoordinator.validateServerLeaf(certificateDER: leaf)
        }
    }

    @Test("concurrent higher-epoch handshakes are serialized across await points")
    func concurrentUpdatesAreSerialized() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let first = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let second = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 2
        )
        let third = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 3
        )
        let persistence = TransportTrustTestPersistence(
            state: try TransportTrustFixtures.persistedState(
                authorityKey: authority,
                verifiedSet: first
            ),
            blockFirstPersist: true
        )
        let coordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: persistence,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let secondLeaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: second.exactSignedBytes
        )
        let thirdLeaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: third.exactSignedBytes
        )

        let secondTask = Task {
            try await coordinator.validateServerLeaf(certificateDER: secondLeaf)
        }
        for _ in 0..<10_000 {
            if await persistence.isFirstPersistBlocked() { break }
            await Task.yield()
        }
        #expect(await persistence.isFirstPersistBlocked())

        let thirdTask = Task {
            try await coordinator.validateServerLeaf(certificateDER: thirdLeaf)
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(await persistence.maximumConcurrentPersists == 1)

        await persistence.releaseFirstPersist()
        #expect((try await secondTask.value).transportSetEpoch == 2)
        #expect((try await thirdTask.value).transportSetEpoch == 3)
        #expect(await persistence.persistedEpochs == [2, 3])
        #expect(await persistence.maximumConcurrentPersists == 1)
    }
}
#endif
