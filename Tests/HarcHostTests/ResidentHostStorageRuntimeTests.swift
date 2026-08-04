import Foundation
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity
@testable import HarcStore

@Suite("Resident Host storage runtime")
struct ResidentHostStorageRuntimeTests {
    @Test("fresh enable binds canonical metadata HostDB keys and listener ports")
    func freshEnableAndDormantReenable() async throws {
        let paths = try Paths()
        defer { paths.remove() }
        let crypto = InMemoryHostCryptographicStateStore()
        let ports = try HarcHostListenerPorts(
            controlPort: 48_483,
            uploadPort: 48_484
        )
        let configuration = paths.configuration(ports: ports)

        let first = try await HarcResidentHostStorageRuntime.start(
            configuration: configuration,
            cryptographicStateStore: crypto
        )
        let canonical = try await first.recordingStore.libraryMetadata()
        let host = try await first.hostStore.metadata()
        #expect(canonical.writerMode == .host)
        #expect(canonical.libraryID == first.tuple.libraryID)
        #expect(canonical.hostAuthorityID == first.tuple.hostAuthorityID)
        #expect(canonical.hostStateID == first.tuple.hostStateID)
        #expect(host.libraryID == first.tuple.libraryID)
        #expect(host.hostAuthorityID == first.tuple.hostAuthorityID)
        #expect(host.hostStateID == first.tuple.hostStateID)
        #expect(try await first.hostStore.listenerPorts() == ports)

        let originalTuple = first.tuple
        try await first.disableHostMode()
        #expect(try await first.recordingStore.libraryMetadata().writerMode == .standalone)

        let second = try await HarcResidentHostStorageRuntime.start(
            configuration: configuration,
            cryptographicStateStore: crypto
        )
        #expect(second.tuple == originalTuple)
        #expect(try await second.recordingStore.libraryMetadata().writerMode == .host)
        try await second.disableHostMode()
    }

    @Test("Host marker recovery requires the exact existing protected tuple")
    func recoversCrashMarker() async throws {
        let paths = try Paths()
        defer { paths.remove() }
        let crypto = InMemoryHostCryptographicStateStore()
        let standalone = try await RecordingStore.onDisk(url: paths.canonicalDB)
        let metadata = try await standalone.libraryMetadata()
        let state = try await crypto.loadOrCreate(libraryID: metadata.libraryID)
        let lease = try await standalone.enableHostMode(
            expectedLibraryID: state.tuple.libraryID,
            hostAuthorityID: state.tuple.hostAuthorityID,
            hostStateID: state.tuple.hostStateID
        )
        _ = try await HarcHostStore.onDisk(
            databaseURL: paths.hostDB,
            stagingRoot: paths.staging,
            metadata: HarcHostMetadata(
                libraryID: state.tuple.libraryID,
                hostAuthorityID: state.tuple.hostAuthorityID,
                hostStateID: state.tuple.hostStateID,
                controlPort: 48_483,
                uploadPort: 48_484
            ),
            highWaterMarkStore: InMemorySecurityRegistryHighWaterMarkStore()
        )
        try await standalone.abandonHostLeaseForTesting(lease)

        let recovered = try await HarcResidentHostStorageRuntime.start(
            configuration: paths.configuration(
                ports: try HarcHostListenerPorts(
                    controlPort: 48_483,
                    uploadPort: 48_484
                )
            ),
            cryptographicStateStore: crypto
        )
        #expect(recovered.tuple == state.tuple)
        #expect(try await recovered.recordingStore.libraryMetadata().writerMode == .host)
        try await recovered.disableHostMode()
    }

    @Test("startup failure rolls a fresh canonical transition back to Standalone")
    func rollsBackFreshTransition() async throws {
        let paths = try Paths()
        defer { paths.remove() }
        let canonical = try await RecordingStore.onDisk(url: paths.canonicalDB)
        let libraryID = try await canonical.libraryMetadata().libraryID
        let crypto = InMemoryHostCryptographicStateStore()
        _ = try await crypto.loadOrCreate(libraryID: libraryID)

        let conflictingHostURL = paths.root
            .appendingPathComponent("host-as-directory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: conflictingHostURL,
            withIntermediateDirectories: true
        )
        let configuration = HarcResidentHostStorageConfiguration(
            canonicalDatabaseURL: paths.canonicalDB,
            hostDatabaseURL: conflictingHostURL,
            stagingRoot: paths.staging,
            listenerPorts: try HarcHostListenerPorts(
                controlPort: 48_483,
                uploadPort: 48_484
            )
        )

        await #expect(throws: (any Error).self) {
            try await HarcResidentHostStorageRuntime.start(
                configuration: configuration,
                cryptographicStateStore: crypto
            )
        }
        #expect(try RecordingStore.inspectLibraryMetadata(
            onDiskAt: paths.canonicalDB
        ).writerMode == .standalone)
    }
}

private struct Paths {
    let root: URL
    let canonicalDB: URL
    let hostDB: URL
    let staging: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HarcResidentHostStorageTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        canonicalDB = root.appendingPathComponent("Harc.db")
        hostDB = root.appendingPathComponent("HarcHost.db")
        staging = root.appendingPathComponent("staging", isDirectory: true)
    }

    func configuration(
        ports: HarcHostListenerPorts
    ) -> HarcResidentHostStorageConfiguration {
        HarcResidentHostStorageConfiguration(
            canonicalDatabaseURL: canonicalDB,
            hostDatabaseURL: hostDB,
            stagingRoot: staging,
            listenerPorts: ports
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
