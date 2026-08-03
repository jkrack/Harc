import Darwin
import Foundation
import GRDB
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Canonical library metadata inspection")
struct LibraryMetadataInspectionTests {
    @Test("Host metadata is inspectable before recovery without changing disk state")
    func hostMetadataBeforeRecoveryOpen() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let authorityID = try HostAuthorityID(Data(repeating: 0x71, count: 32))
        let stateID = HostStateID.random()
        let expected = try await prepareHostDatabase(
            at: fixture.databaseURL,
            authorityID: authorityID,
            stateID: stateID
        )
        let beforeInspection = try diskSnapshot(at: fixture.root)

        let inspected = try RecordingStore.inspectLibraryMetadata(
            onDiskAt: fixture.databaseURL
        )

        #expect(inspected == expected)
        #expect(inspected.writerMode == .host)
        #expect(inspected.hostAuthorityID == authorityID)
        #expect(inspected.hostStateID == stateID)
        #expect(try diskSnapshot(at: fixture.root) == beforeInspection)

        let recovered = try await RecordingStore.recoverHostMode(
            onDiskAt: fixture.databaseURL,
            expectedLibraryID: inspected.libraryID,
            hostAuthorityID: try #require(inspected.hostAuthorityID),
            hostStateID: try #require(inspected.hostStateID),
            waitForLock: false
        )
        #expect(try await recovered.store.libraryMetadata() == inspected)
        try await recovered.store.disableHostMode(recovered.lease)
    }

    @Test("Standalone metadata is reported without changing disk state")
    func standaloneMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let expected = try await prepareStandaloneDatabase(at: fixture.databaseURL)
        let beforeInspection = try diskSnapshot(at: fixture.root)

        let inspected = try RecordingStore.inspectLibraryMetadata(
            onDiskAt: fixture.databaseURL
        )

        #expect(inspected == expected)
        #expect(inspected.writerMode == .standalone)
        #expect(inspected.hostAuthorityID == nil)
        #expect(inspected.hostStateID == nil)
        #expect(try diskSnapshot(at: fixture.root) == beforeInspection)
    }

    @Test("A missing database is reported and is not created")
    func missingDatabase() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let beforeInspection = try diskSnapshot(at: fixture.root)

        do {
            _ = try RecordingStore.inspectLibraryMetadata(
                onDiskAt: fixture.databaseURL
            )
            Issue.record("Inspection must not create a missing canonical database")
        } catch let error as StoreError {
            #expect(
                error == .databaseOpenFailed(
                    "Canonical library metadata inspection requires an existing database file"
                )
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        #expect(try diskSnapshot(at: fixture.root) == beforeInspection)
    }

    @Test("A legacy database without canonical metadata is not migrated")
    func missingMetadataTable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        do {
            let database = try DatabaseQueue(path: fixture.databaseURL.path)
            try database.write { db in
                try db.create(table: "legacy_recordings") { table in
                    table.autoIncrementedPrimaryKey("id")
                }
            }
        }
        let beforeInspection = try diskSnapshot(at: fixture.root)

        do {
            _ = try RecordingStore.inspectLibraryMetadata(
                onDiskAt: fixture.databaseURL
            )
            Issue.record("Inspection must not migrate a legacy database")
        } catch let error as StoreError {
            #expect(error == .invalidData("Canonical library metadata table is missing"))
        }

        #expect(try diskSnapshot(at: fixture.root) == beforeInspection)
        var readOnlyConfiguration = Configuration()
        readOnlyConfiguration.readonly = true
        readOnlyConfiguration.foreignKeysEnabled = false
        let verificationDatabase = try DatabaseQueue(
            path: fixture.databaseURL.path,
            configuration: readOnlyConfiguration
        )
        let tables = try verificationDatabase.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
        }
        #expect(tables == ["legacy_recordings", "sqlite_sequence"])
    }

    @Test("Corrupt canonical metadata fails without repair or mutation")
    func corruptMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await prepareStandaloneDatabase(at: fixture.databaseURL)
        do {
            let database = try DatabaseQueue(path: fixture.databaseURL.path)
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE library_metadata SET library_uuid = ? WHERE id = 1",
                    arguments: ["zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"]
                )
            }
        }
        let beforeInspection = try diskSnapshot(at: fixture.root)

        do {
            _ = try RecordingStore.inspectLibraryMetadata(
                onDiskAt: fixture.databaseURL
            )
            Issue.record("Inspection must reject corrupt canonical metadata")
        } catch let error as StoreError {
            #expect(error == .invalidData("Canonical library metadata is invalid"))
        }

        #expect(try diskSnapshot(at: fixture.root) == beforeInspection)
    }

    private func prepareStandaloneDatabase(
        at databaseURL: URL
    ) async throws -> LibraryMetadata {
        let store = try await RecordingStore.onDisk(url: databaseURL)
        return try await store.libraryMetadata()
    }

    private func prepareHostDatabase(
        at databaseURL: URL,
        authorityID: HostAuthorityID,
        stateID: HostStateID
    ) async throws -> LibraryMetadata {
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let libraryID = try await store.libraryMetadata().libraryID
        let lease = try await store.enableHostMode(
            expectedLibraryID: libraryID,
            hostAuthorityID: authorityID,
            hostStateID: stateID,
            waitForLock: false
        )
        let metadata = try await store.libraryMetadata()
        try await store.abandonHostLeaseForTesting(lease)
        return metadata
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "harc-library-inspection-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        guard chmod(root.path, 0o700) == 0 else {
            throw StoreError.invalidData("Could not restrict inspection fixture")
        }
        return Fixture(
            root: root,
            databaseURL: root.appendingPathComponent("Harc.db")
        )
    }

    private func diskSnapshot(at root: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var snapshot: [String: Data] = [:]
        for name in names.sorted() {
            let url = root.appendingPathComponent(name)
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else { continue }
            snapshot[name] = try Data(contentsOf: url)
        }
        return snapshot
    }

    private struct Fixture {
        let root: URL
        let databaseURL: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
