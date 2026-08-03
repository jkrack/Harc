import Foundation
import GRDB
import Testing
@testable import HarcHost

@Suite("HarcHost database migrations")
struct HostMigrationTests {
    @Test("fresh migration creates every PR3 authority and ingest boundary")
    func freshMigration() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.harcHostMigrator().migrate(queue)
        let tables = try queue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
        }
        let required: Set<String> = [
            "host_metadata",
            "devices",
            "grants",
            "revocations",
            "pending_security_mutations",
            "pairing_tickets",
            "pairing_attempts",
            "processed_operations",
            "uploads",
            "upload_generations",
            "chunk_declarations",
            "staged_chunks",
            "upload_batches",
            "background_capabilities",
            "bound_exact_objects",
            "publication_journal",
            "audit_events",
        ]
        #expect(required.isSubset(of: tables))
    }

    @Test("seeded pre-v1 host fixture is preserved during upgrade")
    func seededUpgrade() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE legacy_host_bootstrap (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO legacy_host_bootstrap (value) VALUES ('preserve-me')")
        }
        try DatabaseMigrator.harcHostMigrator().migrate(queue)
        let preserved = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM legacy_host_bootstrap")
        }
        #expect(preserved == "preserve-me")
    }

    @Test("migrator and store reopen are idempotent")
    func idempotentReopen() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()

        let first = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await first.registryRevision() == 0)
        let firstTables = try await first.schemaTableNames()
        _ = first

        let second = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await second.schemaTableNames() == firstTables)
        #expect(try await second.metadata() == fixture.metadata)
    }
}
