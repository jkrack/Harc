import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("Migration upgrade path")
struct MigrationUpgradeTest {
    /// Real users are upgrading from a v12 database. v13 alters a live table,
    /// so prove the columns land and existing rows survive untouched.
    @Test("a v12 database upgrades to v13 without losing rows")
    func upgradesFromV12() throws {
        let url = URL(fileURLWithPath: "/tmp/harc-mig-\(UUID().uuidString.prefix(8)).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let dbq = try DatabaseQueue(path: url.path)
        // Stop at v12 — the shipped v0.7.3 schema.
        try DatabaseMigrator.harcMigrator().migrate(dbq, upTo: "v12_knowledge_chunks_vec1")

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO recordings (wav_path, started_at, title, transcript_text,
                                        pinned, created_at, updated_at)
                VALUES ('/tmp/pre-existing.wav', 1700000000, 'Recorded before the upgrade',
                        'words captured under the old schema', 0, 1700000000, 1700000000)
                """)
        }

        // Apply the rest, as the app does on launch after updating.
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .compactMap { $0["name"] as String? }
            #expect(columns.contains("stt_model_id"))
            #expect(columns.contains("transcribed_at"))

            let row = try Row.fetchOne(db, sql: "SELECT * FROM recordings")
            let text: String? = row?["transcript_text"]
            let title: String? = row?["title"]
            #expect(text == "words captured under the old schema")
            #expect(title == "Recorded before the upgrade")
            // New columns read as NULL — i.e. stale, due for reprocessing.
            #expect((row?["stt_model_id"] as String?) == nil)
        }

        // Re-running migrations is a no-op, not an error.
        try DatabaseMigrator.harcMigrator().migrate(dbq)
        let finalCount = try dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings")
        }
        #expect(finalCount == 1)
    }

    @Test("a populated v15 database gains stable identity without rebuilding recordings")
    func upgradesPopulatedV15ToV16() throws {
        let dbq = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcMigrator()
        try migrator.migrate(dbq, upTo: "v15_notes")

        let activePath = "/tmp/v15-active.wav"
        let deletedPath = "/tmp/v15-deleted.wav"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deletedAt = now.addingTimeInterval(60)

        let (activeID, deletedID, ftsTriggersBefore): (Int64, Int64, Set<String>) = try dbq.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recordings
                        (wav_path, txt_path, json_path, started_at, title,
                         transcript_text, pinned, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    activePath,
                    "/tmp/v15-active.md",
                    "/tmp/v15-active.json",
                    now,
                    "Legacy active",
                    "legacyanchor active transcript",
                    now,
                    now,
                ]
            )
            let activeID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO recordings
                        (wav_path, txt_path, json_path, started_at, title,
                         transcript_text, pinned, deleted_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                    """,
                arguments: [
                    deletedPath,
                    "/tmp/v15-deleted.md",
                    "/tmp/v15-deleted.json",
                    now.addingTimeInterval(30),
                    "Legacy deleted",
                    "legacydeleted transcript",
                    deletedAt,
                    now,
                    now,
                ]
            )
            let deletedID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO speaker_embeddings
                        (recording_id, speaker_index, embedding, segment_count,
                         total_ms, embedder_kind)
                    VALUES (?, 0, ?, 2, 2000, 'wespeaker_v2')
                    """,
                arguments: [activeID, Data(repeating: 0xA1, count: 1024)]
            )
            try db.execute(
                sql: """
                    INSERT INTO transcript_chunks
                        (recording_id, ordinal, start_ms, end_ms, text,
                         embedding, embedding_model_id, created_at)
                    VALUES (?, 0, 0, 1000, 'legacy chunk', ?, 'test-v1', ?)
                    """,
                arguments: [activeID, Data(repeating: 0xB2, count: 16), 1_800_000_000_000 as Int64]
            )
            try db.execute(
                sql: """
                    INSERT INTO people (display_name, created_at, updated_at)
                    VALUES ('Legacy Person', ?, ?)
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]
            )
            let personID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO person_speakers
                        (person_id, recording_id, speaker_index, confirmed_at)
                    VALUES (?, ?, 0, ?)
                    """,
                arguments: [personID, activeID, now.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    INSERT INTO sessions (day, title, created_at, updated_at)
                    VALUES ('2027-01-15', 'Legacy session', ?, ?)
                    """,
                arguments: [now, now]
            )
            let sessionID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO session_recordings (session_id, recording_id, position)
                    VALUES (?, ?, 0), (?, ?, 1)
                    """,
                arguments: [sessionID, activeID, sessionID, deletedID]
            )

            let ftsHitCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM recordings_fts WHERE recordings_fts MATCH 'legacyanchor'"
            )
            #expect(ftsHitCount == 1)
            let triggerNames = try Set(
                String.fetchAll(
                    db,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'trigger' AND name LIKE '__recordings_fts_%'
                        ORDER BY name
                        """
                )
            )
            #expect(!triggerNames.isEmpty)
            return (activeID, deletedID, triggerNames)
        }

        try migrator.migrate(dbq)

        let (libraryUUID, canonicalUUIDs): (String, [String]) = try dbq.read { db in
            let fetchedMetadata = try Row.fetchOne(db, sql: "SELECT * FROM library_metadata")
            let metadata = try #require(fetchedMetadata)
            let libraryUUID: String = metadata["library_uuid"]
            #expect(libraryUUID.count == 36)
            #expect(metadata["id"] as Int64? == 1)
            #expect(metadata["writer_mode"] as String? == "standalone")
            #expect((metadata["host_authority_id"] as Data?) == nil)
            #expect((metadata["host_state_uuid"] as String?) == nil)
            #expect(metadata["current_change_cursor"] as Int64? == 0)

            let rows = try Row.fetchAll(db, sql: "SELECT * FROM recordings ORDER BY id")
            #expect(rows.count == 2)
            let canonicalUUIDs = rows.compactMap { $0["canonical_uuid"] as String? }
            #expect(canonicalUUIDs.count == 2)
            #expect(Set(canonicalUUIDs).count == 2)
            #expect(canonicalUUIDs.allSatisfy { $0.count == 36 })
            #expect(rows.allSatisfy { ($0["revision"] as Int64?) == 1 })
            #expect(rows.allSatisfy { ($0["processing_state"] as String?) == "ready" })
            #expect(rows.allSatisfy { ($0["processing_failure_detail"] as String?) == nil })
            #expect(rows.allSatisfy { ($0["projection_state"] as String?) == "unknownLegacy" })
            #expect(rows.allSatisfy { ($0["projection_failure_detail"] as String?) == nil })
            #expect(rows.allSatisfy { ($0["projection_version"] as Int64?) == nil })
            #expect(rows.allSatisfy { ($0["origin_device_id"] as Data?) == nil })
            #expect(rows.allSatisfy { ($0["origin_recording_uuid"] as String?) == nil })
            #expect(rows.allSatisfy { ($0["canonical_pcm_sha256"] as Data?) == nil })
            #expect(rows.allSatisfy { ($0["canonical_pcm_frames"] as Int64?) == nil })

            let paths = rows.compactMap { $0["wav_path"] as String? }
            #expect(paths == [activePath, deletedPath])
            #expect((rows[0]["deleted_at"] as Date?) == nil)
            #expect((rows[1]["deleted_at"] as Date?) != nil)
            #expect((rows[0]["id"] as Int64?) == activeID)
            #expect((rows[1]["id"] as Int64?) == deletedID)

            let changeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_changes")
            #expect(changeCount == 0, "legacy rows come from the anchored snapshot, not synthetic changes")

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embeddings") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_chunks") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person_speakers") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_recordings") == 2)
            let foreignKeyFailures = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            #expect(foreignKeyFailures.isEmpty)

            let ftsHitCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM recordings_fts WHERE recordings_fts MATCH 'legacyanchor'"
            )
            #expect(ftsHitCount == 1)
            let ftsTriggersAfter = try Set(
                String.fetchAll(
                    db,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'trigger' AND name LIKE '__recordings_fts_%'
                        ORDER BY name
                        """
                )
            )
            #expect(ftsTriggersAfter == ftsTriggersBefore)

            return (libraryUUID, canonicalUUIDs)
        }

        // DatabaseMigrator must not generate replacement IDs when it is run
        // again against an already-upgraded library.
        try migrator.migrate(dbq)
        try dbq.read { db in
            let repeatedLibraryUUID = try String.fetchOne(
                db,
                sql: "SELECT library_uuid FROM library_metadata WHERE id = 1"
            )
            let repeatedCanonicalUUIDs = try String.fetchAll(
                db,
                sql: "SELECT canonical_uuid FROM recordings ORDER BY id"
            )
            #expect(repeatedLibraryUUID == libraryUUID)
            #expect(repeatedCanonicalUUIDs == canonicalUUIDs)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_changes") == 0)
        }
    }
}
