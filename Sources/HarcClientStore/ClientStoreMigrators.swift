import GRDB

enum ClientStoreMigrators {
    static func transfer() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_harc_transfer_store") { db in
            try db.execute(sql: """
                CREATE TABLE trust_namespaces (
                    library_id TEXT NOT NULL,
                    host_authority_id BLOB NOT NULL CHECK(length(host_authority_id) = 32),
                    authority_public_key_x963 BLOB NOT NULL
                        CHECK(length(authority_public_key_x963) = 65),
                    highest_transport_epoch INTEGER NOT NULL
                        CHECK(highest_transport_epoch > 0),
                    exact_transport_set BLOB NOT NULL CHECK(length(exact_transport_set) > 0),
                    first_seen_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (library_id, host_authority_id)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE grant_slots (
                    library_id TEXT NOT NULL,
                    host_authority_id BLOB NOT NULL CHECK(length(host_authority_id) = 32),
                    grant_epoch INTEGER NOT NULL CHECK(grant_epoch > 0),
                    grant_id TEXT NOT NULL,
                    device_id BLOB NOT NULL CHECK(length(device_id) = 32),
                    device_public_key_x963 BLOB NOT NULL
                        CHECK(length(device_public_key_x963) = 65),
                    protocol_major INTEGER NOT NULL
                        CHECK(protocol_major >= 0 AND protocol_major <= 65535),
                    protocol_minor INTEGER NOT NULL
                        CHECK(protocol_minor >= 0 AND protocol_minor <= 65535),
                    scopes_json BLOB NOT NULL CHECK(length(scopes_json) > 0),
                    issued_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER,
                    minimum_compatible_protocol_minor INTEGER NOT NULL
                        CHECK(minimum_compatible_protocol_minor >= 0
                              AND minimum_compatible_protocol_minor <= 65535),
                    maximum_compatible_protocol_minor INTEGER NOT NULL
                        CHECK(maximum_compatible_protocol_minor >= 0
                              AND maximum_compatible_protocol_minor <= 65535),
                    status TEXT NOT NULL,
                    exact_grant BLOB NOT NULL CHECK(length(exact_grant) > 0),
                    stored_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (library_id, host_authority_id, grant_epoch),
                    FOREIGN KEY (library_id, host_authority_id)
                        REFERENCES trust_namespaces(library_id, host_authority_id)
                        ON DELETE RESTRICT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE adoption_history (
                    adoption_id TEXT PRIMARY KEY,
                    library_id TEXT NOT NULL,
                    host_authority_id BLOB NOT NULL CHECK(length(host_authority_id) = 32),
                    grant_epoch INTEGER NOT NULL CHECK(grant_epoch > 0),
                    adopted_at_ms INTEGER NOT NULL,
                    ended_at_ms INTEGER,
                    FOREIGN KEY (library_id, host_authority_id)
                        REFERENCES trust_namespaces(library_id, host_authority_id)
                        ON DELETE RESTRICT,
                    FOREIGN KEY (library_id, host_authority_id, grant_epoch)
                        REFERENCES grant_slots(library_id, host_authority_id, grant_epoch)
                        ON DELETE RESTRICT
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX one_active_adoption
                ON adoption_history((1))
                WHERE ended_at_ms IS NULL
                """)
            try db.execute(sql: """
                CREATE INDEX adoption_history_tuple
                ON adoption_history(library_id, host_authority_id, adopted_at_ms)
                """)

            try db.execute(sql: """
                CREATE TABLE finalized_captures (
                    origin_device_id BLOB NOT NULL CHECK(length(origin_device_id) = 32),
                    origin_recording_uuid TEXT NOT NULL,
                    finalized_capture_json BLOB NOT NULL,
                    master_path TEXT NOT NULL,
                    master_file_state TEXT NOT NULL,
                    persisted_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (origin_device_id, origin_recording_uuid)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE recording_outbox (
                    origin_device_id BLOB NOT NULL,
                    origin_recording_uuid TEXT NOT NULL,
                    upload_id TEXT,
                    state TEXT NOT NULL,
                    state_machine_json BLOB NOT NULL,
                    failure_code TEXT,
                    failure_detail TEXT,
                    integrity_block_code TEXT,
                    integrity_block_detail TEXT,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (origin_device_id, origin_recording_uuid),
                    FOREIGN KEY (origin_device_id, origin_recording_uuid)
                        REFERENCES finalized_captures(origin_device_id, origin_recording_uuid)
                        ON DELETE RESTRICT,
                    FOREIGN KEY (upload_id)
                        REFERENCES upload_attempts(upload_id)
                        ON DELETE RESTRICT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE exact_objects (
                    object_sha256 BLOB PRIMARY KEY CHECK(length(object_sha256) = 32),
                    kind TEXT NOT NULL,
                    exact_bytes BLOB NOT NULL CHECK(length(exact_bytes) > 0),
                    persisted_at_ms INTEGER NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE upload_attempts (
                    upload_id TEXT PRIMARY KEY,
                    origin_device_id BLOB NOT NULL,
                    origin_recording_uuid TEXT NOT NULL,
                    library_id TEXT NOT NULL,
                    host_authority_id BLOB NOT NULL CHECK(length(host_authority_id) = 32),
                    generation INTEGER NOT NULL CHECK(generation > 0),
                    attempt_json BLOB NOT NULL,
                    reconciliation_json BLOB,
                    state TEXT NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    bound_manifest_sha256 BLOB,
                    terminal_reason TEXT,
                    updated_at_ms INTEGER NOT NULL,
                    FOREIGN KEY (origin_device_id, origin_recording_uuid)
                        REFERENCES finalized_captures(origin_device_id, origin_recording_uuid)
                        ON DELETE RESTRICT,
                    FOREIGN KEY (library_id, host_authority_id)
                        REFERENCES trust_namespaces(library_id, host_authority_id)
                        ON DELETE RESTRICT,
                    FOREIGN KEY (bound_manifest_sha256)
                        REFERENCES exact_objects(object_sha256)
                        ON DELETE RESTRICT
                )
                """)
            try db.execute(sql: """
                CREATE INDEX upload_attempts_origin
                ON upload_attempts(origin_device_id, origin_recording_uuid, updated_at_ms)
                """)

            try db.execute(sql: """
                CREATE TABLE upload_chunks (
                    upload_id TEXT NOT NULL,
                    chunk_index INTEGER NOT NULL CHECK(chunk_index >= 0),
                    chunk_id TEXT NOT NULL,
                    descriptor_json BLOB NOT NULL,
                    encoded_path TEXT NOT NULL,
                    file_state TEXT NOT NULL,
                    outbox_state TEXT NOT NULL,
                    state_machine_json BLOB NOT NULL,
                    durable_ack_sha256 BLOB,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (upload_id, chunk_index),
                    UNIQUE (upload_id, chunk_id),
                    FOREIGN KEY (upload_id) REFERENCES upload_attempts(upload_id)
                        ON DELETE RESTRICT,
                    FOREIGN KEY (durable_ack_sha256)
                        REFERENCES exact_objects(object_sha256)
                        ON DELETE RESTRICT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE upload_batches (
                    batch_id TEXT PRIMARY KEY,
                    upload_id TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK(generation > 0),
                    descriptor_json BLOB NOT NULL,
                    body_path TEXT NOT NULL,
                    body_sha256 BLOB NOT NULL CHECK(length(body_sha256) = 32),
                    body_byte_count INTEGER NOT NULL CHECK(body_byte_count > 0),
                    opaque_capability_credential BLOB NOT NULL
                        CHECK(length(opaque_capability_credential) > 0),
                    capability_bindings BLOB NOT NULL CHECK(length(capability_bindings) > 0),
                    capability_expires_at_ms INTEGER NOT NULL,
                    file_state TEXT NOT NULL,
                    state TEXT NOT NULL,
                    durable_ack_sha256 BLOB,
                    updated_at_ms INTEGER NOT NULL,
                    FOREIGN KEY (upload_id) REFERENCES upload_attempts(upload_id)
                        ON DELETE RESTRICT,
                    FOREIGN KEY (durable_ack_sha256)
                        REFERENCES exact_objects(object_sha256)
                        ON DELETE RESTRICT
                )
                """)
            try db.execute(sql: """
                CREATE INDEX upload_batches_upload
                ON upload_batches(upload_id, generation)
                """)

            try db.execute(sql: """
                CREATE TABLE background_task_mappings (
                    session_identifier TEXT NOT NULL,
                    task_identifier INTEGER NOT NULL,
                    batch_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (session_identifier, task_identifier),
                    FOREIGN KEY (batch_id) REFERENCES upload_batches(batch_id)
                        ON DELETE RESTRICT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE transfer_conflicts (
                    conflict_id TEXT PRIMARY KEY,
                    origin_device_id BLOB,
                    origin_recording_uuid TEXT,
                    upload_id TEXT,
                    code TEXT NOT NULL,
                    detail TEXT,
                    local_exact_bytes BLOB,
                    remote_exact_bytes BLOB,
                    created_at_ms INTEGER NOT NULL,
                    resolved_at_ms INTEGER
                )
                """)

            // PR 3 intentionally cannot make cleanup eligible. PR 5 adds the
            // verified-receipt transaction and migrates this CHECK constraint.
            try db.execute(sql: """
                CREATE TABLE cleanup_intents (
                    origin_device_id BLOB NOT NULL,
                    origin_recording_uuid TEXT NOT NULL,
                    requested_at_ms INTEGER NOT NULL,
                    state TEXT NOT NULL DEFAULT 'awaitingVerifiedReceipt'
                        CHECK(state = 'awaitingVerifiedReceipt'),
                    verified_receipt_sha256 BLOB CHECK(verified_receipt_sha256 IS NULL),
                    PRIMARY KEY (origin_device_id, origin_recording_uuid),
                    FOREIGN KEY (origin_device_id, origin_recording_uuid)
                        REFERENCES finalized_captures(origin_device_id, origin_recording_uuid)
                        ON DELETE RESTRICT
                )
                """)
        }
        migrator.registerMigration("v2_upload_attempt_supersession_proof") { db in
            // Attempt rows are immutable history even after their recording is
            // rebound. This edge is the durable high-water proof that an older
            // upload ID can never be reopened after its replacement later
            // expires or is abandoned.
            try db.execute(sql: """
                CREATE TABLE upload_attempt_supersessions (
                    superseded_upload_id TEXT PRIMARY KEY,
                    replacement_upload_id TEXT NOT NULL UNIQUE,
                    origin_device_id BLOB NOT NULL CHECK(length(origin_device_id) = 32),
                    origin_recording_uuid TEXT NOT NULL,
                    superseded_at_ms INTEGER NOT NULL,
                    CHECK(superseded_upload_id != replacement_upload_id),
                    FOREIGN KEY (superseded_upload_id)
                        REFERENCES upload_attempts(upload_id) ON DELETE RESTRICT,
                    FOREIGN KEY (replacement_upload_id)
                        REFERENCES upload_attempts(upload_id) ON DELETE RESTRICT,
                    FOREIGN KEY (origin_device_id, origin_recording_uuid)
                        REFERENCES finalized_captures(origin_device_id, origin_recording_uuid)
                        ON DELETE RESTRICT
                )
                """)
        }
        return migrator
    }

    static func libraryCache() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_harc_library_cache") { db in
            try db.execute(sql: """
                CREATE TABLE cache_cursor (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    library_id TEXT NOT NULL,
                    change_cursor INTEGER NOT NULL CHECK(change_cursor >= 0),
                    updated_at_ms INTEGER NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE cached_recordings (
                    library_id TEXT NOT NULL,
                    canonical_recording_id TEXT NOT NULL,
                    entity_revision INTEGER NOT NULL CHECK(entity_revision > 0),
                    recording_payload BLOB NOT NULL,
                    cached_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (library_id, canonical_recording_id)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE cached_tombstones (
                    library_id TEXT NOT NULL,
                    canonical_recording_id TEXT NOT NULL,
                    entity_revision INTEGER NOT NULL CHECK(entity_revision > 0),
                    tombstone_payload BLOB NOT NULL,
                    cached_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (library_id, canonical_recording_id)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE offline_metadata_mutations (
                    operation_id TEXT PRIMARY KEY,
                    library_id TEXT NOT NULL,
                    canonical_recording_id TEXT NOT NULL,
                    expected_revision INTEGER NOT NULL CHECK(expected_revision > 0),
                    mutation_kind TEXT NOT NULL,
                    exact_payload BLOB NOT NULL CHECK(length(exact_payload) > 0),
                    state TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE library_conflicts (
                    conflict_id TEXT PRIMARY KEY,
                    operation_id TEXT,
                    library_id TEXT NOT NULL,
                    canonical_recording_id TEXT NOT NULL,
                    expected_revision INTEGER NOT NULL CHECK(expected_revision > 0),
                    current_revision INTEGER NOT NULL CHECK(current_revision > 0),
                    current_value_payload BLOB NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    resolved_at_ms INTEGER,
                    FOREIGN KEY (operation_id)
                        REFERENCES offline_metadata_mutations(operation_id)
                        ON DELETE SET NULL
                )
                """)
        }
        return migrator
    }
}
