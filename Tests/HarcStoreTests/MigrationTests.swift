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
            #expect(tables.contains("people"))
            #expect(tables.contains("transcript_chunks"))
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
            try db.execute(
                sql: """
                    INSERT INTO recordings
                        (wav_path, canonical_uuid, started_at, title,
                         transcript_text, pinned, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    "/tmp/fake.wav",
                    UUID().uuidString.lowercased(),
                    now,
                    "Meeting with Alice",
                    "discussing quarterly earnings",
                    now,
                    now,
                ]
            )

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
                INSERT INTO recordings
                    (wav_path, canonical_uuid, started_at, pinned, created_at, updated_at)
                VALUES (?, ?, ?, 0, ?, ?)
                """,
                arguments: [
                    "/tmp/v9-fixture.wav",
                    UUID().uuidString.lowercased(),
                    Date(),
                    Date(),
                    Date(),
                ]
            )
            let recID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO speaker_embeddings
                (recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind, prototype_uuid)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    recID,
                    0,
                    Data(repeating: 0xAA, count: 1024),
                    3,
                    4500,
                    "wespeaker_v2",
                    UUID().uuidString.lowercased(),
                ]
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

    @Test("v14 creates sessions tables with unique membership and cascades")
    func v14SessionsSchema() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            #expect(tables.contains("sessions"))
            #expect(tables.contains("session_recordings"))

            // Seed two recordings + a session.
            for path in ["/tmp/v14-a.wav", "/tmp/v14-b.wav"] {
                try db.execute(
                    sql: """
                    INSERT INTO recordings
                        (wav_path, canonical_uuid, started_at, pinned, created_at, updated_at)
                    VALUES (?, ?, ?, 0, ?, ?)
                    """,
                    arguments: [
                        path,
                        UUID().uuidString.lowercased(),
                        Date(),
                        Date(),
                        Date(),
                    ]
                )
            }
            try db.execute(
                sql: "INSERT INTO sessions (day, created_at, updated_at) VALUES (?, ?, ?)",
                arguments: ["2026-07-31", Date(), Date()]
            )
            let sid = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO session_recordings (session_id, recording_id, position) VALUES (?, 1, 0)",
                arguments: [sid]
            )
            try db.execute(
                sql: "INSERT INTO session_recordings (session_id, recording_id, position) VALUES (?, 2, 1)",
                arguments: [sid]
            )

            // A recording can belong to only one session.
            try db.execute(
                sql: "INSERT INTO sessions (day, created_at, updated_at) VALUES (?, ?, ?)",
                arguments: ["2026-07-31", Date(), Date()]
            )
            let sid2 = db.lastInsertedRowID
            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: "INSERT INTO session_recordings (session_id, recording_id, position) VALUES (?, 1, 0)",
                    arguments: [sid2]
                )
            }

            // Deleting the session cascades its join rows.
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sid])
            let joinCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_recordings") ?? -1
            #expect(joinCount == 0)

            // Recordings survive session deletion.
            let recCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings") ?? -1
            #expect(recCount == 2)
        }
    }

    @Test("v14 join rows cascade when a recording is hard-deleted")
    func v14RecordingCascade() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            for path in ["/tmp/v14-c.wav", "/tmp/v14-d.wav"] {
                try db.execute(
                    sql: """
                    INSERT INTO recordings
                        (wav_path, canonical_uuid, started_at, pinned, created_at, updated_at)
                    VALUES (?, ?, ?, 0, ?, ?)
                    """,
                    arguments: [
                        path,
                        UUID().uuidString.lowercased(),
                        Date(),
                        Date(),
                        Date(),
                    ]
                )
            }
            try db.execute(
                sql: "INSERT INTO sessions (day, created_at, updated_at) VALUES (?, ?, ?)",
                arguments: ["2026-07-31", Date(), Date()]
            )
            let sid = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO session_recordings (session_id, recording_id, position) VALUES (?, 1, 0)",
                arguments: [sid]
            )
            try db.execute(sql: "DELETE FROM recordings WHERE id = 1")
            let joinCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_recordings") ?? -1
            #expect(joinCount == 0)
        }
    }

    @Test("v15 adds notes_markdown to recordings and sessions")
    func v15NotesColumns() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            for table in ["recordings", "sessions"] {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
                #expect(columns.contains("notes_markdown"), "\(table) should carry notes_markdown")
            }
        }
    }

    @Test("v16 creates canonical identity, metadata, and an empty change log")
    func v16CanonicalIdentitySchema() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
            #expect(tables.contains("library_metadata"))
            #expect(tables.contains("library_changes"))

            let recordingColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .compactMap { $0["name"] as String? }
            for column in [
                "canonical_uuid",
                "origin_device_id",
                "origin_recording_uuid",
                "canonical_pcm_sha256",
                "canonical_pcm_frames",
                "revision",
                "processing_state",
                "processing_failure_detail",
                "projection_state",
                "projection_failure_detail",
                "projection_version",
            ] {
                #expect(recordingColumns.contains(column), "recordings should carry \(column)")
            }

            let fetchedMetadata = try Row.fetchOne(db, sql: "SELECT * FROM library_metadata")
            let metadata = try #require(fetchedMetadata)
            #expect(metadata["id"] as Int64? == 1)
            #expect((metadata["library_uuid"] as String?)?.count == 36)
            #expect(metadata["writer_mode"] as String? == "standalone")
            #expect((metadata["host_authority_id"] as Data?) == nil)
            #expect((metadata["host_state_uuid"] as String?) == nil)
            #expect(metadata["current_change_cursor"] as Int64? == 0)

            let metadataCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_metadata")
            let changeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_changes")
            #expect(metadataCount == 1)
            #expect(changeCount == 0)

            let recordingIndexes = try Row.fetchAll(db, sql: "PRAGMA index_list(recordings)")
                .compactMap { $0["name"] as String? }
            #expect(recordingIndexes.contains("recordings_canonical_uuid_uq"))
            #expect(recordingIndexes.contains("recordings_origin_identity_uq"))
        }
    }

    @Test("v16 guards canonical identity shape and the singleton metadata row")
    func v16CanonicalIdentityGuards() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            let now = Date()
            let validInsert = """
                INSERT INTO recordings
                    (wav_path, canonical_uuid, origin_device_id,
                     origin_recording_uuid, canonical_pcm_sha256,
                     canonical_pcm_frames, revision, started_at, pinned,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """
            let validCanonicalUUID = UUID().uuidString.lowercased()
            let validOriginUUID = UUID().uuidString.lowercased()
            let validDeviceID = Data(repeating: 0x11, count: 32)
            let validPCMHash = Data(repeating: 0x22, count: 32)

            try db.execute(
                sql: validInsert,
                arguments: [
                    "/tmp/v16-valid.wav",
                    validCanonicalUUID,
                    validDeviceID,
                    validOriginUUID,
                    validPCMHash,
                    16_000,
                    1,
                    now,
                    now,
                    now,
                ]
            )

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: "UPDATE recordings SET projection_state = 'ready' WHERE wav_path = ?",
                    arguments: ["/tmp/v16-valid.wav"]
                )
            }
            try db.execute(
                sql: """
                    UPDATE recordings
                    SET projection_state = 'ready', projection_version = 1
                    WHERE wav_path = ?
                    """,
                arguments: ["/tmp/v16-valid.wav"]
            )
            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: "UPDATE recordings SET projection_state = 'unknownLegacy' WHERE wav_path = ?",
                    arguments: ["/tmp/v16-valid.wav"]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                        INSERT INTO recordings
                            (wav_path, started_at, pinned, created_at, updated_at)
                        VALUES (?, ?, 0, ?, ?)
                        """,
                    arguments: ["/tmp/v16-empty-default.wav", now, now, now]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-short-uuid.wav",
                        "too-short",
                        nil,
                        nil,
                        nil,
                        nil,
                        1,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-unpaired-frames.wav",
                        UUID().uuidString.lowercased(),
                        nil,
                        nil,
                        nil,
                        16_000,
                        1,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-zero-frames.wav",
                        UUID().uuidString.lowercased(),
                        nil,
                        nil,
                        validPCMHash,
                        0,
                        1,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-half-origin.wav",
                        UUID().uuidString.lowercased(),
                        validDeviceID,
                        nil,
                        nil,
                        nil,
                        1,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-short-device.wav",
                        UUID().uuidString.lowercased(),
                        Data(repeating: 0x33, count: 31),
                        UUID().uuidString.lowercased(),
                        nil,
                        nil,
                        1,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-short-hash.wav",
                        UUID().uuidString.lowercased(),
                        nil,
                        nil,
                        Data(repeating: 0x44, count: 31),
                        16_000,
                        1,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-zero-revision.wav",
                        UUID().uuidString.lowercased(),
                        nil,
                        nil,
                        nil,
                        nil,
                        0,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: validInsert,
                    arguments: [
                        "/tmp/v16-unpaired-audio.wav",
                        UUID().uuidString.lowercased(),
                        nil,
                        nil,
                        validPCMHash,
                        nil,
                        1,
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                        INSERT INTO library_metadata
                            (id, library_uuid, writer_mode, current_change_cursor, updated_at)
                        VALUES (2, ?, 'standalone', 0, ?)
                        """,
                    arguments: [UUID().uuidString.lowercased(), now]
                )
            }
        }
    }

    @Test("v16 enforces unique canonical and origin identities")
    func v16CanonicalIdentityUniqueness() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            let now = Date()
            let canonicalUUID = UUID().uuidString.lowercased()
            let originDeviceID = Data(repeating: 0x55, count: 32)
            let originRecordingUUID = UUID().uuidString.lowercased()
            let insert = """
                INSERT INTO recordings
                    (wav_path, canonical_uuid, origin_device_id,
                     origin_recording_uuid, started_at, pinned, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                """

            try db.execute(
                sql: insert,
                arguments: [
                    "/tmp/v16-origin-a.wav",
                    canonicalUUID,
                    originDeviceID,
                    originRecordingUUID,
                    now,
                    now,
                    now,
                ]
            )

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: insert,
                    arguments: [
                        "/tmp/v16-canonical-duplicate.wav",
                        canonicalUUID,
                        Data(repeating: 0x66, count: 32),
                        UUID().uuidString.lowercased(),
                        now,
                        now,
                        now,
                    ]
                )
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: insert,
                    arguments: [
                        "/tmp/v16-origin-duplicate.wav",
                        UUID().uuidString.lowercased(),
                        originDeviceID,
                        originRecordingUUID,
                        now,
                        now,
                        now,
                    ]
                )
            }
        }
    }

    @Test("v11 adds semantic chunk table and recording index timestamp")
    func v11SemanticChunkSchema() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let recordingColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .compactMap { $0["name"] as String? }
            #expect(recordingColumns.contains("chunks_indexed_at"))

            let chunkColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(transcript_chunks)")
                .compactMap { $0["name"] as String? }
            #expect(chunkColumns.contains("recording_id"))
            #expect(chunkColumns.contains("ordinal"))
            #expect(chunkColumns.contains("text"))
            #expect(chunkColumns.contains("embedding"))
            #expect(chunkColumns.contains("embedding_model_id"))

            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(transcript_chunks)")
                .compactMap { $0["name"] as String? }
            #expect(indexes.contains("idx_transcript_chunks_recording"))
            #expect(indexes.contains("idx_transcript_chunks_model"))
        }
    }

    @Test("v11 tolerates databases that already ran the old v10 semantic migration")
    func v11ToleratesLegacySemanticSchema() throws {
        let dbq = try DatabaseQueue()

        var legacy = DatabaseMigrator()
        legacy.registerMigration("v1_recordings_and_fts") { db in
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
        legacy.registerMigration("v6_speaker_embeddings") { db in
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
        legacy.registerMigration("v10_semantic_transcript_chunks") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "chunks_indexed_at", .integer)
            }
            try db.create(table: "transcript_chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recording_id", .integer)
                    .notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("embedding", .blob).notNull()
                t.column("embedding_model_id", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.uniqueKey(["recording_id", "ordinal"])
            }
            try db.execute(sql: """
                CREATE INDEX idx_transcript_chunks_recording
                ON transcript_chunks(recording_id)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_transcript_chunks_model
                ON transcript_chunks(embedding_model_id)
                """)
        }
        try legacy.migrate(dbq)

        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            #expect(tables.contains("people"))
            #expect(tables.contains("transcript_chunks"))

            let applied = try String.fetchAll(db, sql:
                "SELECT identifier FROM grdb_migrations ORDER BY identifier"
            )
            #expect(applied.contains("v10_semantic_transcript_chunks"))
            #expect(applied.contains("v10_people"))
            #expect(applied.contains("v11_semantic_transcript_chunks"))
        }
    }
}
