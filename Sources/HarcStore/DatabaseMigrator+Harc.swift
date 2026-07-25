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

        migrator.registerMigration("v7_summary") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "summary_markdown", .text)
                t.add(column: "action_items_markdown", .text)
                t.add(column: "summary_model_id", .text)
                t.add(column: "summary_generated_at", .integer)  // Unix ms
                t.add(column: "summary_source_word_count", .integer)
            }
        }

        migrator.registerMigration("v8_summary_status") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "summary_status_kind", .text)
                t.add(column: "summary_status_message", .text)
                t.add(column: "summary_status_updated_at", .integer)  // Unix ms
            }
        }

        migrator.registerMigration("v9_speaker_embeddings_wespeaker") { db in
            // The v6 stub-embedder rows are 192-dim mel statistics — wrong
            // shape and wrong semantics for the WeSpeaker v2 vectors that
            // replace them. New recordings repopulate; pre-existing recordings
            // stay un-fingerprinted (no automatic backfill — see design doc).
            try db.execute(sql: "DELETE FROM speaker_embeddings")

            try db.alter(table: "speaker_embeddings") { t in
                // Versioned embedder identity. NULL means "unknown / pre-v9";
                // SpeakerReIDService filters to the current kind only, so old
                // rows are effectively invisible. New writes always set this.
                t.add(column: "embedder_kind", .text)
            }
        }

        migrator.registerMigration("v10_people") { db in
            try db.execute(sql: """
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    display_name TEXT NOT NULL,
                    match_threshold REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX people_display_name_idx ON people(display_name COLLATE NOCASE)")

            try db.execute(sql: """
                CREATE TABLE person_speakers (
                    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    speaker_index INTEGER NOT NULL,
                    confirmed_at REAL NOT NULL,
                    PRIMARY KEY (recording_id, speaker_index)
                )
                """)
            try db.execute(sql: "CREATE INDEX person_speakers_person_idx ON person_speakers(person_id)")

            try db.execute(sql: """
                CREATE TABLE pending_suggestions (
                    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    speaker_index INTEGER NOT NULL,
                    score REAL NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (person_id, recording_id, speaker_index)
                )
                """)
            try db.execute(sql: "CREATE INDEX pending_suggestions_recording_idx ON pending_suggestions(recording_id, speaker_index)")

            try db.execute(sql: """
                CREATE TABLE dismissed_suggestions (
                    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    speaker_index INTEGER NOT NULL,
                    dismissed_at REAL NOT NULL,
                    PRIMARY KEY (person_id, recording_id, speaker_index)
                )
                """)
        }

        migrator.registerMigration("v11_semantic_transcript_chunks") { db in
            let recordingColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .compactMap { $0["name"] as String? }
            if !recordingColumns.contains("chunks_indexed_at") {
                try db.alter(table: "recordings") { t in
                    t.add(column: "chunks_indexed_at", .integer)  // Unix ms; NULL = not indexed or stale
                }
            }

            let hasTranscriptChunks = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'transcript_chunks'
                )
                """) ?? false
            if !hasTranscriptChunks {
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
                    t.column("created_at", .integer).notNull()  // Unix ms
                    t.uniqueKey(["recording_id", "ordinal"])
                }
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_transcript_chunks_recording
                ON transcript_chunks(recording_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_transcript_chunks_model
                ON transcript_chunks(embedding_model_id)
                """)
        }

        // v12 originally created the `knowledge_chunks` table and the
        // `knowledge_vec1` virtual table for semantic search. That feature
        // (HarcContext + SQLiteVec1) has been removed. The migration is kept
        // registered as a no-op so migration ordering/identity stays stable
        // for databases that already applied it; fresh databases simply skip
        // the now-unused knowledge tables.
        migrator.registerMigration("v12_knowledge_chunks_vec1") { _ in }

        // Which STT model produced a transcript, and when. Without this there
        // is no way to tell a transcript made by the current engine from one
        // made two engines ago, so "re-transcribe what's stale" has nothing to
        // filter on and the only options are re-doing everything or nothing.
        //
        // NULL means "transcribed before provenance was tracked", which is
        // treated as stale — those are the oldest transcripts and the ones a
        // model upgrade helps most.
        migrator.registerMigration("v13_stt_provenance") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .compactMap { $0["name"] as String? }
            if !columns.contains("stt_model_id") {
                try db.alter(table: "recordings") { t in
                    t.add(column: "stt_model_id", .text)
                }
            }
            if !columns.contains("transcribed_at") {
                try db.alter(table: "recordings") { t in
                    t.add(column: "transcribed_at", .integer)  // Unix ms
                }
            }
        }

        return migrator
    }
}
