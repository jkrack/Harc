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
            #expect(tables.contains("transcript_chunks"))
        }
    }

    @Test("v10 adds semantic chunk table and recording index timestamp")
    func v10SemanticChunkSchema() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let recordingCols = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .compactMap { $0["name"] as String? }
            #expect(recordingCols.contains("chunks_indexed_at"))

            let chunkCols = try Row.fetchAll(db, sql: "PRAGMA table_info(transcript_chunks)")
                .compactMap { $0["name"] as String? }
            #expect(chunkCols.contains("recording_id"))
            #expect(chunkCols.contains("ordinal"))
            #expect(chunkCols.contains("embedding"))
            #expect(chunkCols.contains("embedding_model_id"))
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

    @Test("v9 wipes stub embeddings and adds embedder_kind column")
    func v9WipesEmbeddingsAndAddsKindColumn() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        // Seed a v6-shape row directly via SQL — test that embedder_kind column
        // now exists and can be set.
        try dbq.write { db in
            try db.execute(
                sql: """
                INSERT INTO recordings (wav_path, started_at, pinned, created_at, updated_at)
                VALUES (?, ?, 0, ?, ?)
                """,
                arguments: ["/tmp/v9-fixture.wav", Date(), Date(), Date()]
            )
            let recID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO speaker_embeddings
                (recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [recID, 0, Data(repeating: 0xAA, count: 1024), 3, 4500, "wespeaker_v2"]
            )
        }

        try dbq.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(speaker_embeddings)")
            let names = cols.compactMap { $0["name"] as String? }
            #expect(names.contains("embedder_kind"), "v9 should add embedder_kind column; got \(names)")

            let rows = try Row.fetchAll(db, sql: "SELECT speaker_index, embedder_kind FROM speaker_embeddings")
            #expect(rows.count == 1)
            #expect(rows[0]["embedder_kind"] as String? == "wespeaker_v2")
        }
    }

    @Test("v9 deletes pre-existing v6 rows when running on a v8 fixture")
    func v9DeletesPreExistingStubRows() throws {
        let dbq = try DatabaseQueue()

        // Stand up a v1..v8 migrator manually, seed a row, then run the full
        // (v1..v9) migrator over the same DB and assert v9's DELETE wiped it.
        var partial = DatabaseMigrator()
        let full = DatabaseMigrator.harcMigrator()
        // Replay the registered migrations in the same order, stopping at v8.
        // Easier: run the full migrator now (which already includes v9), then
        // we can't seed a pre-v9 row to test the DELETE. So we go the other
        // direction: build a stripped-down v8 migrator inline.
        partial.registerMigration("v1_recordings_and_fts") { db in
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
        }
        partial.registerMigration("v6_speaker_embeddings") { db in
            try db.create(table: "speaker_embeddings") { t in
                t.column("recording_id", .integer).notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("speaker_index", .integer).notNull()
                t.column("embedding", .blob).notNull()
                t.column("segment_count", .integer).notNull()
                t.column("total_ms", .integer).notNull()
                t.primaryKey(["recording_id", "speaker_index"])
            }
        }
        try partial.migrate(dbq)

        // Seed a recording + a stub-shaped 192-dim row.
        try dbq.write { db in
            try db.execute(
                sql: """
                INSERT INTO recordings (wav_path, started_at, pinned, created_at, updated_at)
                VALUES (?, ?, 0, ?, ?)
                """,
                arguments: ["/tmp/old.wav", Date(), Date(), Date()]
            )
            let recID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO speaker_embeddings
                (recording_id, speaker_index, embedding, segment_count, total_ms)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [recID, 0, Data(repeating: 0xCC, count: 768), 5, 8000]
            )

            let preCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embeddings") ?? -1
            #expect(preCount == 1, "expected 1 stub row before v9 runs, got \(preCount)")
        }

        // Now run the full migrator — its v9 step should DELETE the row and
        // add the embedder_kind column.
        try full.migrate(dbq)

        try dbq.read { db in
            let postCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embeddings") ?? -1
            #expect(postCount == 0, "v9 should wipe pre-existing stub rows; got \(postCount)")

            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(speaker_embeddings)")
            let names = cols.compactMap { $0["name"] as String? }
            #expect(names.contains("embedder_kind"))
        }
    }
}
