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

        // Virtual day sessions: a grouping row over untouched recordings.
        // A session never owns audio or transcripts — it has its own title
        // and combined summary, and points at member recordings through
        // `session_recordings`. Members are same-local-day by construction
        // (enforced in `createSession`), which also guarantees all members
        // share one day directory for the OKF `session-*.md` projection.
        migrator.registerMigration("v14_sessions") { db in
            try db.create(table: "sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("day", .text).notNull()  // "YYYY-MM-DD", local TZ at creation
                t.column("title", .text)
                t.column("summary_markdown", .text)
                t.column("action_items_markdown", .text)
                t.column("summary_model_id", .text)
                t.column("summary_generated_at", .integer)  // Unix ms
                t.column("summary_source_word_count", .integer)
                t.column("summary_status_kind", .text)
                t.column("summary_status_message", .text)
                t.column("summary_status_updated_at", .integer)  // Unix ms
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_sessions_day", on: "sessions", columns: ["day"])

            try db.create(table: "session_recordings") { t in
                t.column("session_id", .integer)
                    .notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("recording_id", .integer)
                    .notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.primaryKey(["session_id", "recording_id"])
            }
            // A recording belongs to at most one session. Overlapping
            // sessions would make the OKF projection and the detail pane
            // ambiguous for no product win.
            try db.create(
                index: "idx_session_recordings_recording",
                on: "session_recordings",
                columns: ["recording_id"],
                options: .unique
            )
        }

        // Free-form notes on recordings and sessions — the enrichment
        // channel. Users edit them in the detail pane; agents append through
        // harc-mcp's append_note (append-only there, so an agent can never
        // destroy what a user wrote). Projected as an OKF `## Notes` section.
        // Deliberately NOT mirrored into recordings_fts: search stays over
        // transcripts.
        migrator.registerMigration("v15_notes") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "notes_markdown", .text)
            }
            try db.alter(table: "sessions") { t in
                t.add(column: "notes_markdown", .text)
            }
        }

        // Stable public library/recording identity. Keep this migration
        // additive: `recordings` is the external-content table for FTS and is
        // referenced by several child tables. Rebuilding or renaming it would
        // put those triggers and foreign keys at risk during an upgrade.
        migrator.registerMigration("v16_canonical_library_identity") { db in
            try db.execute(sql: """
                CREATE TABLE library_metadata (
                    id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                    library_uuid TEXT NOT NULL UNIQUE CHECK (length(library_uuid) = 36),
                    writer_mode TEXT NOT NULL CHECK (writer_mode IN ('standalone', 'host')),
                    host_authority_id BLOB,
                    host_state_uuid TEXT,
                    current_change_cursor INTEGER NOT NULL DEFAULT 0
                        CHECK (current_change_cursor >= 0),
                    updated_at DATETIME NOT NULL,
                    CHECK (host_authority_id IS NULL OR length(host_authority_id) = 32),
                    CHECK (host_state_uuid IS NULL OR length(host_state_uuid) = 36),
                    CHECK (
                        (host_authority_id IS NULL AND host_state_uuid IS NULL)
                        OR (host_authority_id IS NOT NULL AND host_state_uuid IS NOT NULL)
                    ),
                    CHECK (
                        writer_mode <> 'host'
                        OR (host_authority_id IS NOT NULL AND host_state_uuid IS NOT NULL)
                    )
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO library_metadata
                        (id, library_uuid, writer_mode, current_change_cursor, updated_at)
                    VALUES (1, ?, 'standalone', 0, ?)
                    """,
                arguments: [UUID().uuidString.lowercased(), Date()]
            )

            // SQLite cannot add a NOT NULL column whose default is a fresh
            // random UUID per existing row. Add a temporary empty default,
            // backfill every legacy row below, then install guards which reject
            // that sentinel on all future inserts/updates.
            try db.alter(table: "recordings") { t in
                t.add(column: "canonical_uuid", .text).notNull().defaults(to: "")
                t.add(column: "origin_device_id", .blob)
                t.add(column: "origin_recording_uuid", .text)
                t.add(column: "canonical_pcm_sha256", .blob)
                t.add(column: "canonical_pcm_frames", .integer)
                t.add(column: "revision", .integer).notNull().defaults(to: 1)
                t.add(column: "processing_state", .text).notNull().defaults(to: "ready")
                t.add(column: "processing_failure_detail", .text)
                t.add(column: "projection_state", .text).notNull().defaults(to: "unknownLegacy")
                t.add(column: "projection_failure_detail", .text)
                t.add(column: "projection_version", .integer)
            }

            let legacyRecordingIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM recordings ORDER BY id"
            )
            for recordingID in legacyRecordingIDs {
                try db.execute(
                    sql: "UPDATE recordings SET canonical_uuid = ? WHERE id = ?",
                    arguments: [UUID().uuidString.lowercased(), recordingID]
                )
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX recordings_canonical_uuid_uq
                ON recordings(canonical_uuid)
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX recordings_origin_identity_uq
                ON recordings(origin_device_id, origin_recording_uuid)
                WHERE origin_device_id IS NOT NULL
                  AND origin_recording_uuid IS NOT NULL
                """)

            // Constraint triggers are used because SQLite cannot attach the
            // required per-row checks while adding columns to a populated table.
            // They validate both future inserts and identity-bearing updates.
            let recordingIdentityIsInvalid = """
                length(NEW.canonical_uuid) <> 36
                OR (
                    (NEW.origin_device_id IS NULL AND NEW.origin_recording_uuid IS NOT NULL)
                    OR (NEW.origin_device_id IS NOT NULL AND NEW.origin_recording_uuid IS NULL)
                )
                OR (NEW.origin_device_id IS NOT NULL AND length(NEW.origin_device_id) <> 32)
                OR (NEW.origin_recording_uuid IS NOT NULL AND length(NEW.origin_recording_uuid) <> 36)
                OR (
                    (NEW.canonical_pcm_sha256 IS NULL AND NEW.canonical_pcm_frames IS NOT NULL)
                    OR (NEW.canonical_pcm_sha256 IS NOT NULL AND NEW.canonical_pcm_frames IS NULL)
                )
                OR (NEW.canonical_pcm_sha256 IS NOT NULL AND length(NEW.canonical_pcm_sha256) <> 32)
                OR (NEW.canonical_pcm_frames IS NOT NULL AND NEW.canonical_pcm_frames <= 0)
                OR NEW.revision < 1
                OR NEW.processing_state NOT IN (
                    'pending', 'transcribing', 'projecting', 'ready',
                    'degraded', 'failedRecoverable'
                )
                OR (
                    NEW.processing_failure_detail IS NOT NULL
                    AND NEW.processing_state NOT IN ('degraded', 'failedRecoverable')
                )
                OR NEW.projection_state NOT IN (
                    'unknownLegacy', 'pending', 'projecting', 'ready',
                    'degraded', 'failedRecoverable'
                )
                OR (
                    NEW.projection_state = 'unknownLegacy'
                    AND (NEW.projection_version IS NOT NULL OR NEW.projection_failure_detail IS NOT NULL)
                )
                OR (
                    NEW.projection_state = 'ready'
                    AND (NEW.projection_version IS NULL OR NEW.projection_version < 1)
                )
                OR (NEW.projection_version IS NOT NULL AND NEW.projection_version < 1)
                OR (
                    NEW.projection_failure_detail IS NOT NULL
                    AND NEW.projection_state NOT IN ('degraded', 'failedRecoverable')
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER recordings_v16_validate_insert
                BEFORE INSERT ON recordings
                FOR EACH ROW
                WHEN \(recordingIdentityIsInvalid)
                BEGIN
                    SELECT RAISE(ABORT, 'invalid canonical recording identity');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER recordings_v16_validate_update
                BEFORE UPDATE OF canonical_uuid, origin_device_id,
                    origin_recording_uuid, canonical_pcm_sha256,
                    canonical_pcm_frames, revision, processing_state,
                    processing_failure_detail, projection_state,
                    projection_failure_detail, projection_version
                ON recordings
                FOR EACH ROW
                WHEN \(recordingIdentityIsInvalid)
                BEGIN
                    SELECT RAISE(ABORT, 'invalid canonical recording identity');
                END
                """)

            // The log deliberately starts empty on upgrade. Initial clients
            // obtain legacy rows (and soft-deleted tombstones) from an anchored
            // snapshot of the canonical tables; only post-v16 mutations append
            // changes.
            try db.execute(sql: """
                CREATE TABLE library_changes (
                    cursor INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity_type TEXT NOT NULL,
                    entity_uuid TEXT NOT NULL CHECK (length(entity_uuid) = 36),
                    revision INTEGER NOT NULL CHECK (revision >= 1),
                    operation TEXT NOT NULL CHECK (operation IN ('upsert', 'tombstone')),
                    changed_at DATETIME NOT NULL,
                    is_tombstone INTEGER NOT NULL CHECK (is_tombstone IN (0, 1)),
                    CHECK (is_tombstone = (operation = 'tombstone')),
                    UNIQUE (entity_type, entity_uuid, revision)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX library_changes_entity_cursor_idx
                ON library_changes(entity_type, entity_uuid, cursor)
                """)
            try db.execute(sql: """
                CREATE INDEX library_changes_changed_at_idx
                ON library_changes(changed_at)
                """)
        }

        // Durable idempotency boundary for signed remote metadata commands.
        // The Host journals initial acceptance in Host.db before entering this
        // transaction; this table lets a restarted Host reconcile the exact
        // canonical result by operation identity without applying it twice.
        migrator.registerMigration("v17_canonical_metadata_operations") { db in
            try db.execute(sql: """
                CREATE TABLE canonical_metadata_operations (
                    operation_id TEXT PRIMARY KEY NOT NULL
                        CHECK (length(operation_id) = 36),
                    exact_request_sha256 BLOB NOT NULL
                        CHECK (length(exact_request_sha256) = 32),
                    result_json BLOB NOT NULL,
                    recorded_at DATETIME NOT NULL
                )
                """)
        }

        // Stable host-authoritative speaker identities and the durable intake
        // journal for client-computed voice observations. Existing local row
        // IDs remain intact; stable UUIDs are the only IDs sent over the wire.
        migrator.registerMigration("v18_speaker_identity_sync") { db in
            try db.alter(table: "speaker_embeddings") { table in
                table.add(column: "prototype_uuid", .text).notNull().defaults(to: "")
            }
            let legacyPrototypes = try Row.fetchAll(
                db,
                sql: "SELECT recording_id, speaker_index FROM speaker_embeddings ORDER BY recording_id, speaker_index"
            )
            for row in legacyPrototypes {
                try db.execute(
                    sql: "UPDATE speaker_embeddings SET prototype_uuid = ? WHERE recording_id = ? AND speaker_index = ?",
                    arguments: [
                        UUID().uuidString.lowercased(),
                        row["recording_id"] as Int64,
                        row["speaker_index"] as Int,
                    ]
                )
            }
            try db.execute(sql: "CREATE UNIQUE INDEX speaker_embeddings_prototype_uuid_uq ON speaker_embeddings(prototype_uuid)")
            try db.execute(sql: """
                CREATE TRIGGER speaker_embeddings_v18_validate_prototype_insert
                BEFORE INSERT ON speaker_embeddings FOR EACH ROW
                WHEN length(NEW.prototype_uuid) <> 36
                BEGIN
                    SELECT RAISE(ABORT, 'invalid speaker prototype identity');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER speaker_embeddings_v18_validate_prototype_update
                BEFORE UPDATE OF prototype_uuid ON speaker_embeddings FOR EACH ROW
                WHEN length(NEW.prototype_uuid) <> 36
                BEGIN
                    SELECT RAISE(ABORT, 'invalid speaker prototype identity');
                END
                """)

            try db.alter(table: "people") { table in
                table.add(column: "stable_uuid", .text).notNull().defaults(to: "")
                table.add(column: "profile_revision", .integer).notNull().defaults(to: 1)
            }
            let personIDs = try Int64.fetchAll(db, sql: "SELECT id FROM people ORDER BY id")
            for personID in personIDs {
                try db.execute(
                    sql: "UPDATE people SET stable_uuid = ? WHERE id = ?",
                    arguments: [UUID().uuidString.lowercased(), personID]
                )
            }
            try db.execute(sql: "CREATE UNIQUE INDEX people_stable_uuid_uq ON people(stable_uuid)")
            try db.execute(sql: """
                CREATE TRIGGER people_v18_validate_stable_uuid_insert
                BEFORE INSERT ON people FOR EACH ROW
                WHEN length(NEW.stable_uuid) <> 36 OR NEW.profile_revision < 1
                BEGIN
                    SELECT RAISE(ABORT, 'invalid stable speaker identity');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER people_v18_validate_stable_uuid_update
                BEFORE UPDATE OF stable_uuid, profile_revision ON people FOR EACH ROW
                WHEN length(NEW.stable_uuid) <> 36 OR NEW.profile_revision < 1
                BEGIN
                    SELECT RAISE(ABORT, 'invalid stable speaker identity');
                END
                """)

            try db.execute(sql: """
                CREATE TABLE speaker_identity_metadata (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    pack_revision INTEGER NOT NULL CHECK(pack_revision > 0),
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(
                sql: "INSERT INTO speaker_identity_metadata (singleton, pack_revision, updated_at) VALUES (1, 1, ?)",
                arguments: [Date().timeIntervalSince1970]
            )

            try db.execute(sql: """
                CREATE TABLE speaker_embedding_observations (
                    operation_uuid TEXT PRIMARY KEY CHECK(length(operation_uuid) = 36),
                    request_sha256 BLOB NOT NULL CHECK(length(request_sha256) = 32),
                    canonical_recording_uuid TEXT NOT NULL CHECK(length(canonical_recording_uuid) = 36),
                    speaker_index INTEGER NOT NULL CHECK(speaker_index >= 0),
                    source_device_id BLOB NOT NULL CHECK(length(source_device_id) = 32),
                    model_id TEXT NOT NULL CHECK(length(model_id) BETWEEN 1 AND 128),
                    dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096),
                    quantized_embedding BLOB NOT NULL,
                    quantization_scale REAL NOT NULL CHECK(quantization_scale > 0),
                    segment_count INTEGER NOT NULL CHECK(segment_count > 0),
                    speech_duration_ms INTEGER NOT NULL CHECK(speech_duration_ms > 0),
                    source_pack_revision INTEGER,
                    proposed_person_uuid TEXT,
                    proposed_score REAL,
                    disposition TEXT NOT NULL CHECK(disposition IN ('matched', 'noMatch', 'pendingReview')),
                    decided_person_uuid TEXT,
                    decided_score REAL,
                    received_at REAL NOT NULL,
                    result_json BLOB NOT NULL,
                    CHECK(length(quantized_embedding) = dimensions),
                    CHECK(source_pack_revision IS NULL OR source_pack_revision > 0),
                    CHECK((proposed_person_uuid IS NULL) = (proposed_score IS NULL)),
                    CHECK((decided_person_uuid IS NULL) = (decided_score IS NULL))
                )
                """)
            try db.execute(sql: """
                CREATE INDEX speaker_embedding_observations_recording_idx
                ON speaker_embedding_observations(canonical_recording_uuid, speaker_index)
                """)
        }

        migrator.registerMigration("v19_capture_integrity") { db in
            try db.alter(table: "recordings") { table in
                table.add(column: "capture_integrity", .blob)
                table.add(column: "capture_discontinuities", .blob)
            }
        }

        migrator.registerMigration("v20_speaker_confirmation_provenance") { db in
            try db.execute(sql: """
                ALTER TABLE person_speakers ADD COLUMN is_user_confirmed INTEGER
                    NOT NULL DEFAULT 1 CHECK(is_user_confirmed IN (0, 1))
                """)
            // Automatic assignment and observation were committed together using
            // the same timestamp. Later explicit confirmations have a new stamp.
            // Preserve labels; remove only inferred links from enrollment evidence.
            try db.execute(sql: """
                UPDATE person_speakers SET is_user_confirmed = 0
                WHERE EXISTS (
                    SELECT 1 FROM speaker_embedding_observations o
                    JOIN recordings r ON r.canonical_uuid = o.canonical_recording_uuid
                    WHERE r.id = person_speakers.recording_id
                      AND o.speaker_index = person_speakers.speaker_index
                      AND o.disposition = 'matched'
                      AND o.received_at = person_speakers.confirmed_at
                )
                """)
            if db.changesCount > 0 {
                try db.execute(sql: "UPDATE people SET profile_revision = profile_revision + 1")
                try db.execute(sql: "UPDATE speaker_identity_metadata SET pack_revision = pack_revision + 1")
            }
        }

        migrator.registerMigration("v21_immutable_speaker_evidence") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_evidence_snapshots (
                    evidence_sha256 BLOB PRIMARY KEY NOT NULL CHECK(length(evidence_sha256) = 32),
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    snapshot_json BLOB NOT NULL CHECK(length(snapshot_json) BETWEEN 1 AND 16384),
                    retained_at REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX speaker_evidence_snapshots_recording_idx
                ON speaker_evidence_snapshots(recording_id)
                """)
            try db.execute(sql: """
                CREATE TRIGGER speaker_evidence_snapshots_no_update
                BEFORE UPDATE ON speaker_evidence_snapshots
                BEGIN SELECT RAISE(ABORT, 'Speaker evidence snapshots are immutable'); END
                """)
            // No legacy backfill: a recording/index cannot establish the exact
            // processing artifact or producer for its historical observations.
        }

        migrator.registerMigration("v22_confirmed_speaker_evidence") { db in
            try db.execute(sql: """
                CREATE TABLE confirmed_speaker_evidence (
                    evidence_sha256 BLOB PRIMARY KEY NOT NULL
                        REFERENCES speaker_evidence_snapshots(evidence_sha256) ON DELETE CASCADE,
                    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    prototype_uuid TEXT NOT NULL UNIQUE CHECK(length(prototype_uuid) = 36),
                    confirmed_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX confirmed_speaker_evidence_person_idx ON confirmed_speaker_evidence(person_id)")
        }

        migrator.registerMigration("v23_speaker_confirmation_tokens") { db in
            try db.execute(sql: "ALTER TABLE confirmed_speaker_evidence ADD COLUMN confirmation_uuid TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000' CHECK(length(confirmation_uuid) = 36)")
            try db.execute(sql: "UPDATE confirmed_speaker_evidence SET confirmation_uuid = prototype_uuid")
        }

        migrator.registerMigration("v24_current_speaker_evidence") { db in
            try db.execute(sql: """
                CREATE TABLE current_speaker_evidence (
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    speaker_index INTEGER NOT NULL CHECK(speaker_index >= 0),
                    evidence_sha256 BLOB NOT NULL REFERENCES speaker_evidence_snapshots(evidence_sha256),
                    PRIMARY KEY(recording_id, speaker_index)
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER current_speaker_evidence_artifact_changed
                AFTER UPDATE OF json_path, canonical_pcm_sha256, canonical_uuid ON recordings
                WHEN NEW.json_path IS NOT OLD.json_path OR NEW.canonical_pcm_sha256 IS NOT OLD.canonical_pcm_sha256
                    OR NEW.canonical_uuid IS NOT OLD.canonical_uuid
                BEGIN DELETE FROM current_speaker_evidence WHERE recording_id = NEW.id; END
                """)
        }

        migrator.registerMigration("v25_bound_speaker_enrollment_sources") { db in
            try db.execute(sql: """
                CREATE TABLE bound_speaker_enrollment_sources (
                    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                INSERT INTO bound_speaker_enrollment_sources(recording_id)
                SELECT DISTINCT e.recording_id FROM confirmed_speaker_evidence c
                JOIN speaker_evidence_snapshots e ON e.evidence_sha256 = c.evidence_sha256
                """)
            if db.changesCount > 0 {
                try db.execute(sql: """
                    UPDATE people SET profile_revision = profile_revision + 1
                    WHERE id IN (SELECT ps.person_id FROM person_speakers ps
                        JOIN bound_speaker_enrollment_sources b ON b.recording_id = ps.recording_id)
                    """)
                try db.execute(sql: "UPDATE speaker_identity_metadata SET pack_revision = pack_revision + 1")
            }
        }

        migrator.registerMigration("v26_speaker_assignment_history") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_assignment_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    recording_revision INTEGER NOT NULL,
                    artifact_sha256 BLOB,
                    assignments_json BLOB NOT NULL,
                    archived_at REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER speaker_assignment_history_immutable BEFORE UPDATE ON speaker_assignment_history
                BEGIN SELECT RAISE(ABORT, 'speaker assignment history is immutable'); END
                """)
        }

        migrator.registerMigration("v27_published_speaker_recognition_pack") { db in
            try db.execute(sql: """
                CREATE TABLE published_speaker_recognition_pack (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    pack_payload BLOB NOT NULL
                )
                """)
            // Older hosts generated different validity dates under the same revision.
            // Invalidate those client payloads before the first durable publication.
            try RecordingStore.bumpSpeakerRecognitionPackRevision(in: db,
                at: Date().timeIntervalSince1970)
        }

        migrator.registerMigration("v28_unmapped_speaker_observations") { db in
            try db.execute(sql: """
                CREATE TABLE unmapped_speaker_observations (
                    operation_uuid TEXT PRIMARY KEY,
                    canonical_recording_uuid TEXT NOT NULL,
                    source_device_id BLOB NOT NULL CHECK(length(source_device_id) = 32),
                    request_sha256 BLOB NOT NULL CHECK(length(request_sha256) = 32),
                    request_json BLOB NOT NULL,
                    received_at REAL NOT NULL,
                    result_json BLOB NOT NULL
                )
                """)
        }

        migrator.registerMigration("v29_selected_speaker_cluster_map") { db in
            try db.execute(sql: """
                CREATE TABLE selected_speaker_cluster_map (
                    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
                    map_json BLOB NOT NULL,
                    map_sha256 BLOB NOT NULL CHECK(length(map_sha256) = 32),
                    projection_sha256 BLOB NOT NULL CHECK(length(projection_sha256) = 32)
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER selected_speaker_cluster_map_invalidated
                AFTER UPDATE OF json_path, canonical_pcm_sha256, canonical_uuid, origin_device_id, origin_recording_uuid ON recordings
                WHEN NEW.json_path IS NOT OLD.json_path OR NEW.canonical_pcm_sha256 IS NOT OLD.canonical_pcm_sha256
                    OR NEW.canonical_uuid IS NOT OLD.canonical_uuid OR NEW.origin_device_id IS NOT OLD.origin_device_id
                    OR NEW.origin_recording_uuid IS NOT OLD.origin_recording_uuid
                BEGIN DELETE FROM selected_speaker_cluster_map WHERE recording_id = NEW.id; END
                """)
        }

        migrator.registerMigration("v30_bound_speaker_observation_provenance") { db in
            try db.execute(sql: """
                CREATE TABLE bound_speaker_observation_provenance (
                    operation_uuid TEXT PRIMARY KEY REFERENCES speaker_embedding_observations(operation_uuid) ON DELETE CASCADE,
                    evidence_sha256 BLOB NOT NULL REFERENCES speaker_evidence_snapshots(evidence_sha256) ON DELETE CASCADE,
                    cluster_map_sha256 BLOB NOT NULL CHECK(length(cluster_map_sha256) = 32),
                    request_json BLOB NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER bound_speaker_observation_provenance_no_update
                BEFORE UPDATE ON bound_speaker_observation_provenance
                BEGIN SELECT RAISE(ABORT, 'Bound speaker provenance is immutable'); END
                """)
        }

        migrator.registerMigration("v31_selected_edge_artifact_source") { db in
            try db.execute(sql: """
                CREATE TABLE selected_edge_artifact_source (
                    recording_id INTEGER PRIMARY KEY REFERENCES selected_speaker_cluster_map(recording_id) ON DELETE CASCADE,
                    signed_metadata_path TEXT NOT NULL,
                    bundle_path TEXT NOT NULL,
                    signed_metadata_sha256 BLOB NOT NULL CHECK(length(signed_metadata_sha256) = 32),
                    bundle_sha256 BLOB NOT NULL CHECK(length(bundle_sha256) = 32)
                )
                """)
        }

        migrator.registerMigration("v32_host_speaker_processing_outcome") { db in
            try db.execute(sql: """
                CREATE TABLE host_speaker_decision_provenance (
                    operation_uuid TEXT PRIMARY KEY REFERENCES speaker_embedding_observations(operation_uuid) ON DELETE CASCADE,
                    evidence_sha256 BLOB NOT NULL REFERENCES speaker_evidence_snapshots(evidence_sha256)
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER host_speaker_decision_provenance_no_update
                BEFORE UPDATE ON host_speaker_decision_provenance
                BEGIN SELECT RAISE(ABORT, 'Host speaker decision provenance is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TABLE host_speaker_processing_outcome (
                    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
                    outcome_json BLOB NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER host_speaker_outcome_invalidated
                AFTER UPDATE OF json_path, canonical_pcm_sha256, canonical_uuid, processing_state ON recordings
                WHEN NEW.json_path IS NOT OLD.json_path OR NEW.canonical_pcm_sha256 IS NOT OLD.canonical_pcm_sha256
                    OR NEW.canonical_uuid IS NOT OLD.canonical_uuid OR NEW.processing_state != 'ready'
                BEGIN DELETE FROM host_speaker_processing_outcome WHERE recording_id = NEW.id; END
                """)
        }

        migrator.registerMigration("v33_host_speaker_review_queue") { db in
            try db.execute(sql: """
                CREATE TABLE host_speaker_review_queue (
                    recording_id INTEGER PRIMARY KEY REFERENCES host_speaker_processing_outcome(recording_id) ON DELETE CASCADE,
                    job_uuid TEXT NOT NULL UNIQUE,
                    expected_outcome_json BLOB NOT NULL,
                    eligible_at REAL NOT NULL,
                    failure_count INTEGER NOT NULL DEFAULT 0 CHECK(failure_count BETWEEN 0 AND 8)
                );
                CREATE INDEX host_speaker_review_due ON host_speaker_review_queue(eligible_at, recording_id);
                CREATE TRIGGER host_speaker_review_superseded
                AFTER UPDATE OF outcome_json ON host_speaker_processing_outcome
                WHEN NEW.outcome_json IS NOT OLD.outcome_json
                BEGIN DELETE FROM host_speaker_review_queue WHERE recording_id = NEW.recording_id; END;
                """)
        }
        return migrator
    }
}
