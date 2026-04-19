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
                "SELECT rowid, transcript_text FROM recordings_fts WHERE recordings_fts MATCH 'quarterly'"
            )
            #expect(matches.count == 1)
        }
    }

    @Test("v4 migration reindexes pre-existing rows into the new FTS table")
    func v4ReindexesExistingRows() throws {
        let dbq = try DatabaseQueue()

        // Stand up a pre-v4 migrator so we can seed a row before v4 runs.
        var preV4 = DatabaseMigrator()
        preV4.registerMigration("v1_recordings_and_fts") { db in
            try db.create(table: "recordings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("wav_path", .text).notNull().unique()
                t.column("txt_path", .text)
                t.column("json_path", .text)
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("title", .text)
                t.column("transcript_text", .text)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("deleted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(virtualTable: "recordings_fts", using: FTS5()) { t in
                t.synchronize(withTable: "recordings")
                t.column("title")
                t.column("transcript_text")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }
        preV4.registerMigration("v2_suggested_title") { db in
            try db.alter(table: "recordings") { t in t.add(column: "suggested_title", .text) }
        }
        preV4.registerMigration("v3_tags") { db in
            try db.alter(table: "recordings") { t in t.add(column: "tags", .text) }
        }
        try preV4.migrate(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO recordings
                  (wav_path, started_at, transcript_text, pinned, created_at, updated_at)
                VALUES (?, ?, ?, 0, ?, ?)
                """, arguments: ["/tmp/x.wav", Date(), "quarterly planning renewals", Date(), Date()])
        }

        // Apply the full migrator (v4 runs on top).
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let hit = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM recordings_fts WHERE recordings_fts MATCH 'quarterly'
                """)
            #expect(hit == 1)
        }
    }
}
