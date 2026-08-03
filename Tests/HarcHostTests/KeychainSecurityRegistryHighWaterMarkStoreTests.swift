import HarcDomain
import HarcIdentity
import Testing
@testable import HarcHost

@Suite("HarcHost Keychain security-registry high-water adapter")
struct KeychainSecurityRegistryHighWaterMarkStoreTests {
    @Test("the security journal adapter advances the tuple-bound protected mark")
    func advancesProtectedMark() async throws {
        let stateStore = InMemoryHostCryptographicStateStore()
        let state = try await stateStore.loadOrCreate(libraryID: .random())
        let metadata = HarcHostMetadata(
            libraryID: state.tuple.libraryID,
            hostAuthorityID: state.tuple.hostAuthorityID,
            hostStateID: state.tuple.hostStateID
        )
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: stateStore,
            metadata: metadata
        )

        #expect(try await highWater.loadRegistryRevision() == 0)
        try await highWater.advanceRegistryRevision(from: 0, to: 1)
        #expect(try await highWater.loadRegistryRevision() == 1)

        let persisted = try await stateStore.load(requiredTuple: state.tuple)
        #expect(persisted.securityRegistryRevision == 1)
        #expect(persisted.highestIssuedTransportSetEpoch == 0)
    }

    @Test("the adapter fails closed when host metadata names another tuple")
    func rejectsTupleMismatch() async throws {
        let stateStore = InMemoryHostCryptographicStateStore()
        let state = try await stateStore.loadOrCreate(libraryID: .random())
        let wrongMetadata = HarcHostMetadata(
            libraryID: state.tuple.libraryID,
            hostAuthorityID: state.tuple.hostAuthorityID,
            hostStateID: .random()
        )
        let highWater = KeychainSecurityRegistryHighWaterMarkStore(
            cryptographicStateStore: stateStore,
            metadata: wrongMetadata
        )

        await #expect(throws: HostCryptographicStateError.self) {
            try await highWater.loadRegistryRevision()
        }
        await #expect(throws: HostCryptographicStateError.self) {
            try await highWater.advanceRegistryRevision(from: 0, to: 1)
        }

        let unchanged = try await stateStore.load(requiredTuple: state.tuple)
        #expect(unchanged.securityRegistryRevision == 0)
    }
}
