import Foundation
import Testing
@testable import HarcHost

@Suite("Host listener port persistence")
struct HostListenerPortPersistenceTests {
    @Test("listener pairs reject zero and shared ports")
    func validatesPair() throws {
        #expect(throws: HarcHostError.invalidListenerPort(field: "controlPort")) {
            try HarcHostListenerPorts(controlPort: 0, uploadPort: 8_444)
        }
        #expect(throws: HarcHostError.invalidListenerPort(field: "uploadPort")) {
            try HarcHostListenerPorts(controlPort: 8_443, uploadPort: 0)
        }
        #expect(throws: HarcHostError.listenerPortsMustBeDistinct) {
            try HarcHostListenerPorts(controlPort: 8_443, uploadPort: 8_443)
        }
    }

    @Test("first binding persists and an ordinary restart must reuse it")
    func persistsAcrossRestart() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let ports = try HarcHostListenerPorts(controlPort: 48_483, uploadPort: 48_484)

        let first = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await first.listenerPorts() == nil)
        try await first.persistListenerPorts(ports)
        try await first.persistListenerPorts(ports)
        #expect(try await first.listenerPorts() == ports)

        let second = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await second.listenerPorts() == ports)
        await #expect(throws: HarcHostError.listenerPortPersistenceConflict) {
            try await second.persistListenerPorts(
                HarcHostListenerPorts(controlPort: 48_493, uploadPort: 48_494)
            )
        }
    }

    @Test("partial persisted state fails closed")
    func rejectsPartialState() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partialMetadata = HarcHostMetadata(
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            hostStateID: fixture.hostStateID,
            controlPort: 48_483
        )
        let store = try await HarcHostStore.onDisk(
            databaseURL: directory.appendingPathComponent("HarcHost.db"),
            stagingRoot: directory.appendingPathComponent("staging", isDirectory: true),
            metadata: partialMetadata,
            highWaterMarkStore: InMemorySecurityRegistryHighWaterMarkStore(),
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        await #expect(throws: HarcHostError.listenerPortPersistenceConflict) {
            try await store.listenerPorts()
        }
    }
}
