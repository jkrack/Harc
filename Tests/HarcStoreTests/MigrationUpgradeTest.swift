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
}
