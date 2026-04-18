import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("DatabaseMigrator")
struct MigrationTests {
    @Test("harcMigrator creates recordings table + FTS virtual table")
    func migrationCreatesTables() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            #expect(tables.contains("recordings"))
            #expect(tables.contains("recordings_fts"))
        }
    }

    @Test("migration is idempotent — second run is a no-op")
    func migrationIdempotent() throws {
        let dbq = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcMigrator()
        try migrator.migrate(dbq)
        // Second run should not throw.
        try migrator.migrate(dbq)

        try dbq.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' AND name='recordings'"
            )
            #expect(tables.count == 1)
        }
    }

    @Test("FTS sync reflects inserts into recordings")
    func ftsSyncOnInsert() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            let now = Date()
            var rec = Recording(
                wavPath: "/tmp/fake.wav",
                startedAt: now,
                title: "Meeting with Alice",
                transcriptText: "discussing quarterly earnings"
            )
            try rec.insert(db)

            let matches = try Row.fetchAll(db, sql:
                "SELECT rowid, title FROM recordings_fts WHERE recordings_fts MATCH 'quarterly'"
            )
            #expect(matches.count == 1)
        }
    }
}
