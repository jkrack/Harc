import Foundation
import HarcDomain
import Testing
@testable import HarcIdentity

@Suite("HarcIdentity protected host cryptographic state")
struct HostCryptographicStateTests {
    @Test("load-or-create persists distinct authority and TLS keys through an injectable backend")
    func persistenceAndSeparateKeyRoles() async throws {
        let backend = InMemoryHostCryptographicStateRecordBackend()
        let hostStateID = HostStateID(
            try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        )
        let libraryID = LibraryID.random()
        let firstStore = KeychainHostCryptographicStateStore(
            backend: backend,
            hostStateIDFactory: { hostStateID }
        )

        let first = try await firstStore.loadOrCreate(libraryID: libraryID)
        #expect(first.tuple.libraryID == libraryID)
        #expect(first.tuple.hostStateID == hostStateID)
        #expect(first.tuple.hostAuthorityID == first.authorityIdentity.hostAuthorityID)
        #expect(first.authorityIdentity.publicKey != first.tlsIdentity.publicKey)
        #expect(first.authorityIdentity.keyProtection == .keychainSoftware)
        #expect(first.tlsIdentity.keyProtection == .keychainSoftware)
        #expect(first.securityRegistryRevision == 0)
        #expect(first.highestIssuedTransportSetEpoch == 0)

        let digest = P256SHA256Digest(hashing: Data("host-key-persistence".utf8))
        let authoritySignature = try first.authorityIdentity.sign(digest: digest)
        let tlsSignature = try first.tlsIdentity.sign(digest: digest)
        #expect(first.authorityIdentity.publicKey.isValidSignature(authoritySignature, for: digest))
        #expect(first.tlsIdentity.publicKey.isValidSignature(tlsSignature, for: digest))
        #expect(!first.tlsIdentity.publicKey.isValidSignature(authoritySignature, for: digest))
        #expect(!first.authorityIdentity.publicKey.isValidSignature(tlsSignature, for: digest))

        let reopenedStore = KeychainHostCryptographicStateStore(backend: backend)
        let reopened = try await reopenedStore.load(requiredTuple: first.tuple)
        #expect(reopened.tuple == first.tuple)
        #expect(reopened.authorityIdentity.publicKey == first.authorityIdentity.publicKey)
        #expect(reopened.tlsIdentity.publicKey == first.tlsIdentity.publicKey)

        let idempotent = try await reopenedStore.loadOrCreate(libraryID: libraryID)
        #expect(idempotent.tuple == first.tuple)
        #expect(idempotent.authorityIdentity.publicKey == first.authorityIdentity.publicKey)
        #expect(idempotent.tlsIdentity.publicKey == first.tlsIdentity.publicKey)
    }

    @Test("registry and transport marks advance independently by exactly one and persist")
    func monotonicMarks() async throws {
        let backend = InMemoryHostCryptographicStateRecordBackend()
        let store = KeychainHostCryptographicStateStore(backend: backend)
        let initial = try await store.loadOrCreate(libraryID: .random())

        let registryOne = try await store.advanceSecurityRegistryRevision(
            for: initial.tuple,
            from: 0,
            to: 1
        )
        #expect(registryOne.securityRegistryRevision == 1)
        #expect(registryOne.highestIssuedTransportSetEpoch == 0)

        let transportOne = try await store.advanceHighestIssuedTransportSetEpoch(
            for: initial.tuple,
            from: 0,
            to: 1
        )
        #expect(transportOne.securityRegistryRevision == 1)
        #expect(transportOne.highestIssuedTransportSetEpoch == 1)

        await #expect(throws: HostCryptographicStateError.self) {
            try await store.advanceSecurityRegistryRevision(
                for: initial.tuple,
                from: 0,
                to: 1
            )
        }
        await #expect(throws: HostCryptographicStateError.self) {
            try await store.advanceSecurityRegistryRevision(
                for: initial.tuple,
                from: 1,
                to: 3
            )
        }
        await #expect(throws: HostCryptographicStateError.self) {
            try await store.advanceHighestIssuedTransportSetEpoch(
                for: initial.tuple,
                from: 1,
                to: 0
            )
        }

        let reopened = KeychainHostCryptographicStateStore(backend: backend)
        let persisted = try await reopened.load(requiredTuple: initial.tuple)
        #expect(persisted.securityRegistryRevision == 1)
        #expect(persisted.highestIssuedTransportSetEpoch == 1)
    }

    @Test("every state read and mark transition is bound to the exact host tuple")
    func tupleBinding() async throws {
        let store = InMemoryHostCryptographicStateStore()
        let state = try await store.loadOrCreate(libraryID: .random())

        let wrongLibrary = LibraryID.random()
        await #expect(throws: HostCryptographicStateError.self) {
            try await store.loadOrCreate(libraryID: wrongLibrary)
        }

        let wrongAuthority = HostCryptographicStateTuple(
            libraryID: state.tuple.libraryID,
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0xa1, count: 32)),
            hostStateID: state.tuple.hostStateID
        )
        await #expect(throws: HostCryptographicStateError.self) {
            try await store.load(requiredTuple: wrongAuthority)
        }
        await #expect(throws: HostCryptographicStateError.self) {
            try await store.advanceSecurityRegistryRevision(
                for: wrongAuthority,
                from: 0,
                to: 1
            )
        }

        let wrongState = HostCryptographicStateTuple(
            libraryID: state.tuple.libraryID,
            hostAuthorityID: state.tuple.hostAuthorityID,
            hostStateID: .random()
        )
        await #expect(throws: HostCryptographicStateError.self) {
            try await store.advanceHighestIssuedTransportSetEpoch(
                for: wrongState,
                from: 0,
                to: 1
            )
        }

        let unchanged = try await store.load(requiredTuple: state.tuple)
        #expect(unchanged.securityRegistryRevision == 0)
        #expect(unchanged.highestIssuedTransportSetEpoch == 0)
    }

    @Test("known record loss and malformed persistence fail closed without replacement")
    func recordLossAndCorruption() async throws {
        let expected = HostCryptographicStateTuple(
            libraryID: .random(),
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x72, count: 32)),
            hostStateID: .random()
        )
        let missingBackend = InMemoryHostCryptographicStateRecordBackend()
        let missingStore = KeychainHostCryptographicStateStore(backend: missingBackend)

        do {
            _ = try await missingStore.load(requiredTuple: expected)
            Issue.record("Expected a missing known host record to fail closed")
        } catch let error as HostCryptographicStateError {
            #expect(error == .keyRecordMissing(expected: expected))
        }
        #expect(await missingBackend.loadRecord() == nil)

        let corruptBytes = Data("not-a-host-key-record".utf8)
        let corruptBackend = InMemoryHostCryptographicStateRecordBackend(record: corruptBytes)
        let corruptStore = KeychainHostCryptographicStateStore(backend: corruptBackend)
        do {
            _ = try await corruptStore.loadOrCreate(libraryID: .random())
            Issue.record("Expected malformed state to fail closed")
        } catch let error as HostCryptographicStateError {
            #expect(error == .corruptRecord)
        }
        #expect(await corruptBackend.loadRecord() == corruptBytes)
    }

    @Test("lost private material and key-role aliasing are rejected on reopen")
    func privateKeyLossAndRoleCollision() async throws {
        let keyLossBackend = InMemoryHostCryptographicStateRecordBackend()
        let keyLossStore = KeychainHostCryptographicStateStore(backend: keyLossBackend)
        let state = try await keyLossStore.loadOrCreate(libraryID: .random())
        let originalBytes = try #require(await keyLossBackend.loadRecord())

        var keyLossObject = try #require(
            JSONSerialization.jsonObject(with: originalBytes) as? [String: Any]
        )
        var authority = try #require(keyLossObject["authorityKey"] as? [String: Any])
        authority["material"] = Data([0x01]).base64EncodedString()
        keyLossObject["authorityKey"] = authority
        let keyLossBytes = try JSONSerialization.data(withJSONObject: keyLossObject)
        #expect(await keyLossBackend.replaceRecord(expected: originalBytes, with: keyLossBytes))

        do {
            _ = try await keyLossStore.load(requiredTuple: state.tuple)
            Issue.record("Expected unavailable private material to fail closed")
        } catch let error as HostCryptographicStateError {
            #expect(error == .privateKeyUnavailable(role: .authoritySigning))
        }

        let collisionBackend = InMemoryHostCryptographicStateRecordBackend()
        let collisionStore = KeychainHostCryptographicStateStore(backend: collisionBackend)
        let collisionState = try await collisionStore.loadOrCreate(libraryID: .random())
        let collisionOriginal = try #require(await collisionBackend.loadRecord())
        var collisionObject = try #require(
            JSONSerialization.jsonObject(with: collisionOriginal) as? [String: Any]
        )
        collisionObject["tlsKey"] = collisionObject["authorityKey"]
        let collisionBytes = try JSONSerialization.data(withJSONObject: collisionObject)
        #expect(
            await collisionBackend.replaceRecord(
                expected: collisionOriginal,
                with: collisionBytes
            )
        )

        do {
            _ = try await collisionStore.load(requiredTuple: collisionState.tuple)
            Issue.record("Expected aliased key roles to fail closed")
        } catch let error as HostCryptographicStateError {
            #expect(error == .keyRoleCollision)
        }
    }

    @Test("compare-and-swap permits only one concurrent mark winner")
    func concurrentMarkCAS() async throws {
        let backend = InMemoryHostCryptographicStateRecordBackend()
        let firstStore = KeychainHostCryptographicStateStore(backend: backend)
        let secondStore = KeychainHostCryptographicStateStore(backend: backend)
        let state = try await firstStore.loadOrCreate(libraryID: .random())

        async let firstWon = markRegistryOnce(firstStore, tuple: state.tuple)
        async let secondWon = markRegistryOnce(secondStore, tuple: state.tuple)
        let wins = await [firstWon, secondWon].filter { $0 }.count
        #expect(wins == 1)

        let persisted = try await firstStore.load(requiredTuple: state.tuple)
        #expect(persisted.securityRegistryRevision == 1)
    }

    private func markRegistryOnce(
        _ store: KeychainHostCryptographicStateStore,
        tuple: HostCryptographicStateTuple
    ) async -> Bool {
        do {
            _ = try await store.advanceSecurityRegistryRevision(
                for: tuple,
                from: 0,
                to: 1
            )
            return true
        } catch {
            return false
        }
    }
}
