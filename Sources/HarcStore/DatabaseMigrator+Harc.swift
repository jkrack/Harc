import Foundation
import GRDB

extension DatabaseMigrator {
    /// Harc's schema migrations. Call `try harcMigrator().migrate(dbQueue)` on
    /// store init.
    public static func harcMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_recordings_and_fts") { db in
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

            try db.create(
                virtualTable: "recordings_fts",
                using: FTS5()
            ) { t in
                t.synchronize(withTable: "recordings")
                t.column("title")
                t.column("transcript_text")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        migrator.registerMigration("v2_suggested_title") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "suggested_title", .text)
            }
        }

        migrator.registerMigration("v3_tags") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "tags", .text)  // JSON-encoded [String]; nil means no tags
            }
        }

        migrator.registerMigration("v4_fts_transcript_only") { db in
            // GRDB's synchronize triggers outlive the virtual table — drop them first.
            try db.execute(sql: "DROP TRIGGER IF EXISTS __recordings_fts_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS __recordings_fts_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS __recordings_fts_au")

            // Drop the v1 combined-column FTS table.
            try db.execute(sql: "DROP TABLE IF EXISTS recordings_fts")

            // Recreate on transcript_text only, Porter over unicode61, diacritic-folded.
            try db.create(virtualTable: "recordings_fts", using: FTS5()) { t in
                t.synchronize(withTable: "recordings")
                t.column("transcript_text")
                t.tokenizer = .porter(wrapping: .unicode61(diacritics: .removeLegacy))
            }

            // Backfill existing rows: `synchronize` only installs triggers for
            // future writes; `rebuild` reads every row and repopulates the FTS
            // index using those same trigger projections.
            try db.execute(sql: "INSERT INTO recordings_fts(recordings_fts) VALUES('rebuild')")
        }

        migrator.registerMigration("v5_speaker_names") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "speaker_names", .text)  // JSON-encoded [String: String]; nil means no overrides
            }
        }

        migrator.registerMigration("v6_speaker_embeddings") { db in
            // One vector per (recording, diarized speaker index). Stored as a
            // packed Float32 BLOB — 192 dims × 4 bytes = 768 B at current
            // embedder setting. See HarcVoiceprint.EmbeddingBlob for layout.
            // Cascade-delete follows the recording's lifecycle; if a
            // recording is re-transcribed we delete the old rows first.
            try db.create(table: "speaker_embeddings") { t in
                t.column("recording_id", .integer)
                    .notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("speaker_index", .integer).notNull()
                t.column("embedding", .blob).notNull()
                t.column("segment_count", .integer).notNull()
                t.column("total_ms", .integer).notNull()
                t.primaryKey(["recording_id", "speaker_index"])
            }
            try db.create(
                index: "idx_speaker_embeddings_recording",
                on: "speaker_embeddings",
                columns: ["recording_id"]
            )
        }

        return migrator
    }
}
