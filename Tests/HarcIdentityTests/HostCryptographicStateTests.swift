import Foundation
import HarcDomain
import Security
import Testing
@testable import HarcIdentity

@Suite("HarcIdentity protected host cryptographic state")
struct HostCryptographicStateTests {
    @Test("production host record works without Data Protection Keychain entitlement")
    func productionLegacyKeychainRecord() async throws {
        let service = "com.harc.tests.host-state.\(UUID().uuidString.lowercased())"
        let account = "record"
        let cleanupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { SecItemDelete(cleanupQuery as CFDictionary) }
        let backend = SecurityHostCryptographicStateRecordBackend(
            service: service,
            account: account
        )
        let first = Data("host-state-v1".utf8)
        let second = Data("host-state-v2".utf8)

        #expect(try await backend.loadRecord() == nil)
        #expect(try await backend.insertRecordIfAbsent(first))
        #expect(try await backend.loadRecord() == first)
        #expect(try await backend.replaceRecord(expected: first, with: second))
        #expect(try await backend.loadRecord() == second)
    }

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
        #expect(first.authorityIdentity.publicKey.isValidSignature(authoritySignature, for: digest))
        #expect(!first.tlsIdentity.publicKey.isValidSignature(authoritySignature, for: digest))

        let reopenedStore = KeychainHostCryptographicStateStore(backend: backend)
        let reopened = try await reopenedStore.load(requiredTuple: first.tuple)
        #expect(reopened.tuple == first.tuple)
        #expect(reopened.authorityIdentity.publicKey == first.authorityIdentity.publicKey)
        #expect(reopened.tlsIdentity.publicKey == first.tlsIdentity.publicKey)

        let idempotent = try await reopenedStore.loadOrCreate(libraryID: libraryID)
        #expect(idempotent.tuple == first.tuple)
        #expect(idempotent.authorityIdentity.publicKey == first.authorityIdentity.publicKey)
        #expect(idempotent.tlsIdentity.publicKey == first.tlsIdentity.publicKey)

        let inspection = try await reopenedStore.inspect(requiredTuple: first.tuple)
        #expect(inspection.activeTLSPublicKey == first.activeTLSIdentity.publicKey)
        #expect(inspection.stagedTLSPublicKey == nil)
        #expect(inspection.retiringTLSPublicKey == nil)
        #expect(inspection.pendingTLSKeyCreation == nil)
        #expect(inspection.pendingTLSKeyDeletions.isEmpty)
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
        collisionObject["activeTLSKey"] = collisionObject["authorityKey"]
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

    @Test("v1 records migrate atomically to protected-record v3")
    func v1RecordMigration() async throws {
        let backend = InMemoryHostCryptographicStateRecordBackend()
        let firstStore = KeychainHostCryptographicStateStore(backend: backend)
        let original = try await firstStore.loadOrCreate(libraryID: .random())
        let v2Bytes = try #require(await backend.loadRecord())
        var legacy = try #require(
            JSONSerialization.jsonObject(with: v2Bytes) as? [String: Any]
        )
        legacy["formatVersion"] = 1
        legacy["tlsKey"] = legacy.removeValue(forKey: "activeTLSKey")
        legacy.removeValue(forKey: "stagedTLSKey")
        legacy.removeValue(forKey: "retiringTLSKey")
        legacy.removeValue(forKey: "nextTLSKeyGeneration")
        legacy.removeValue(forKey: "pendingTLSKeyCreation")
        legacy.removeValue(forKey: "pendingTLSKeyDeletions")
        let v1Bytes = try JSONSerialization.data(withJSONObject: legacy)
        #expect(await backend.replaceRecord(expected: v2Bytes, with: v1Bytes))

        let reopened = KeychainHostCryptographicStateStore(backend: backend)
        let migrated = try await reopened.load(requiredTuple: original.tuple)
        #expect(migrated.activeTLSIdentity.publicKey == original.activeTLSIdentity.publicKey)
        #expect(migrated.tlsIdentity.publicKey == original.activeTLSIdentity.publicKey)
        #expect(migrated.stagedTLSIdentity == nil)
        #expect(migrated.retiringTLSIdentity == nil)

        let persisted = try #require(await backend.loadRecord())
        let object = try #require(
            JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        )
        #expect(object["formatVersion"] as? Int == 3)
        #expect(object["activeTLSKey"] != nil)
        #expect(object["tlsKey"] == nil)
        #expect(object["nextTLSKeyGeneration"] as? Int == 1)
        #expect(object["pendingTLSKeyCreation"] == nil)
        #expect((object["pendingTLSKeyDeletions"] as? [Any])?.isEmpty == true)
    }

    @Test("v2 records migrate atomically to protected-record v3")
    func v2RecordMigration() async throws {
        let backend = InMemoryHostCryptographicStateRecordBackend()
        let store = KeychainHostCryptographicStateStore(backend: backend)
        let original = try await store.loadOrCreate(libraryID: .random())
        let v3Bytes = try #require(await backend.loadRecord())
        var v2 = try #require(
            JSONSerialization.jsonObject(with: v3Bytes) as? [String: Any]
        )
        v2["formatVersion"] = 2
        v2.removeValue(forKey: "nextTLSKeyGeneration")
        v2.removeValue(forKey: "pendingTLSKeyCreation")
        v2.removeValue(forKey: "pendingTLSKeyDeletions")
        let v2Bytes = try JSONSerialization.data(withJSONObject: v2)
        #expect(await backend.replaceRecord(expected: v3Bytes, with: v2Bytes))

        let reopened = KeychainHostCryptographicStateStore(backend: backend)
        let migrated = try await reopened.load(requiredTuple: original.tuple)
        #expect(migrated.activeTLSIdentity.publicKey == original.activeTLSIdentity.publicKey)
        let persisted = try #require(await backend.loadRecord())
        let object = try #require(
            JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        )
        #expect(object["formatVersion"] as? Int == 3)
        #expect(object["nextTLSKeyGeneration"] as? Int == 1)
    }

    @Test("staged promotion and retirement preserve distinct atomic key roles")
    func tlsKeyLifecycle() async throws {
        let store = InMemoryHostCryptographicStateStore()
        let initial = try await store.loadOrCreate(libraryID: .random())
        let oldKey = initial.activeTLSIdentity.publicKey

        let staged = try await store.stageReplacementTLSIdentity(
            for: initial.tuple,
            expectedActivePublicKey: oldKey
        )
        let newKey = try #require(staged.stagedTLSIdentity).publicKey
        #expect(newKey != oldKey)
        #expect(staged.retiringTLSIdentity == nil)
        await #expect(throws: HostCryptographicStateError.self) {
            try await store.stageReplacementTLSIdentity(
                for: initial.tuple,
                expectedActivePublicKey: oldKey
            )
        }

        let promoted = try await store.promoteStagedTLSIdentity(
            for: initial.tuple,
            expectedActivePublicKey: oldKey,
            expectedStagedPublicKey: newKey
        )
        #expect(promoted.activeTLSIdentity.publicKey == newKey)
        #expect(promoted.tlsIdentity.publicKey == newKey)
        #expect(promoted.stagedTLSIdentity == nil)
        #expect(promoted.retiringTLSIdentity?.publicKey == oldKey)

        let finalized = try await store.finalizeRetiringTLSIdentity(
            for: initial.tuple,
            expectedRetiringPublicKey: oldKey
        )
        #expect(finalized.activeTLSIdentity.publicKey == newKey)
        #expect(finalized.retiringTLSIdentity == nil)
    }

    @Test("unpublished staged keys can be discarded without changing active identity")
    func discardStagedTLSKey() async throws {
        let store = InMemoryHostCryptographicStateStore()
        let initial = try await store.loadOrCreate(libraryID: .random())
        let staged = try await store.stageReplacementTLSIdentity(
            for: initial.tuple,
            expectedActivePublicKey: initial.activeTLSIdentity.publicKey
        )
        let stagedKey = try #require(staged.stagedTLSIdentity).publicKey
        let discarded = try await store.discardStagedTLSIdentity(
            for: initial.tuple,
            expectedStagedPublicKey: stagedKey
        )
        #expect(discarded.activeTLSIdentity.publicKey == initial.activeTLSIdentity.publicKey)
        #expect(discarded.stagedTLSIdentity == nil)
        #expect(discarded.retiringTLSIdentity == nil)
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
