import GRDB

public extension DatabaseMigrator {
    /// The PR 3 host-state schema. It intentionally contains opaque byte slots
    /// for PR 4 signed objects and PR 5 receipts without interpreting either.
    static func harcHostMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_host_core") { db in
            try db.execute(sql: """
                CREATE TABLE host_metadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    library_id TEXT NOT NULL,
                    host_authority_id BLOB NOT NULL CHECK (length(host_authority_id) = 32),
                    host_state_id TEXT NOT NULL,
                    control_port INTEGER,
                    upload_port INTEGER,
                    highest_transport_set_epoch INTEGER NOT NULL DEFAULT 0 CHECK (highest_transport_set_epoch >= 0),
                    exact_transport_set_bytes BLOB,
                    transport_set_object_sha256 BLOB CHECK (transport_set_object_sha256 IS NULL OR length(transport_set_object_sha256) = 32),
                    leaf_retirement_floor INTEGER NOT NULL DEFAULT 0 CHECK (leaf_retirement_floor >= 0),
                    security_registry_revision INTEGER NOT NULL DEFAULT 0 CHECK (security_registry_revision >= 0),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE devices (
                    device_id BLOB PRIMARY KEY CHECK (length(device_id) = 32),
                    public_key_x963 BLOB NOT NULL CHECK (length(public_key_x963) = 65),
                    label TEXT,
                    registry_entry_json BLOB NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
                    current_grant_id TEXT NOT NULL,
                    current_grant_epoch INTEGER NOT NULL CHECK (current_grant_epoch > 0),
                    scopes_json BLOB NOT NULL,
                    grant_issued_at REAL NOT NULL,
                    grant_expires_at REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE grants (
                    grant_id TEXT NOT NULL,
                    grant_epoch INTEGER NOT NULL CHECK (grant_epoch > 0),
                    device_id BLOB NOT NULL REFERENCES devices(device_id),
                    claims_json BLOB NOT NULL,
                    exact_grant_bytes BLOB NOT NULL CHECK (length(exact_grant_bytes) > 0),
                    scopes_json BLOB NOT NULL,
                    issued_at REAL NOT NULL,
                    expires_at REAL,
                    is_current INTEGER NOT NULL CHECK (is_current IN (0, 1)),
                    PRIMARY KEY (grant_id, grant_epoch)
                );
                CREATE UNIQUE INDEX grants_one_current_per_device
                    ON grants(device_id) WHERE is_current = 1;

                CREATE TABLE revocations (
                    revocation_id TEXT PRIMARY KEY,
                    device_id BLOB NOT NULL REFERENCES devices(device_id),
                    grant_id TEXT NOT NULL,
                    prior_grant_epoch INTEGER NOT NULL,
                    new_grant_epoch INTEGER NOT NULL,
                    reason_code TEXT NOT NULL,
                    claims_json BLOB NOT NULL,
                    exact_revocation_bytes BLOB NOT NULL CHECK (length(exact_revocation_bytes) > 0),
                    issued_at REAL NOT NULL
                );

                CREATE TABLE pending_security_mutations (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    registry_revision INTEGER NOT NULL UNIQUE CHECK (registry_revision > 0),
                    mutation_kind TEXT NOT NULL,
                    device_id BLOB NOT NULL CHECK (length(device_id) = 32),
                    mutation_json BLOB NOT NULL,
                    created_at REAL NOT NULL
                );

                CREATE TABLE pairing_tickets (
                    ticket_id TEXT PRIMARY KEY,
                    ticket_secret_binding_sha256 BLOB NOT NULL CHECK (length(ticket_secret_binding_sha256) = 32),
                    client_kind TEXT NOT NULL CHECK (client_kind IN ('mobile', 'macClient')),
                    state TEXT NOT NULL CHECK (state IN ('issued', 'reserved', 'approved', 'consumed', 'expired', 'cancelled')),
                    issued_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    reserved_device_id BLOB,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE pairing_attempts (
                    claim_id TEXT PRIMARY KEY,
                    ticket_id TEXT NOT NULL REFERENCES pairing_tickets(ticket_id),
                    device_id BLOB NOT NULL CHECK (length(device_id) = 32),
                    state TEXT NOT NULL CHECK (state IN ('reserved', 'proofVerified', 'awaitingApproval', 'approved', 'denied', 'expired', 'cancelled')),
                    claimant_token_binding_sha256 BLOB CHECK (claimant_token_binding_sha256 IS NULL OR length(claimant_token_binding_sha256) = 32),
                    requested_scopes_json BLOB,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE processed_operations (
                    library_id TEXT NOT NULL,
                    host_authority_id BLOB NOT NULL CHECK (length(host_authority_id) = 32),
                    message_type TEXT NOT NULL,
                    signer_kind TEXT NOT NULL CHECK (signer_kind IN ('host', 'device')),
                    signer_identity BLOB NOT NULL CHECK (length(signer_identity) = 32),
                    operation_id TEXT NOT NULL,
                    exact_request_bytes BLOB NOT NULL,
                    request_fingerprint BLOB NOT NULL CHECK (length(request_fingerprint) = 32),
                    application_state TEXT NOT NULL CHECK (application_state IN ('prepared', 'applied')),
                    prepared_effect BLOB,
                    result_fingerprint BLOB CHECK (result_fingerprint IS NULL OR length(result_fingerprint) = 32),
                    original_result BLOB,
                    command_expires_at REAL NOT NULL,
                    accepted_at REAL NOT NULL,
                    CHECK (
                        (application_state = 'prepared'
                            AND prepared_effect IS NOT NULL
                            AND result_fingerprint IS NULL
                            AND original_result IS NULL)
                        OR
                        (application_state = 'applied'
                            AND result_fingerprint IS NOT NULL
                            AND original_result IS NOT NULL)
                    ),
                    PRIMARY KEY (library_id, host_authority_id, message_type, signer_kind, signer_identity, operation_id)
                );
                CREATE INDEX processed_operations_device_retention
                    ON processed_operations(signer_kind, signer_identity, command_expires_at);

                CREATE TABLE uploads (
                    upload_id TEXT PRIMARY KEY,
                    owner_device_id BLOB NOT NULL REFERENCES devices(device_id),
                    origin_device_id BLOB NOT NULL CHECK (length(origin_device_id) = 32),
                    origin_recording_uuid TEXT NOT NULL,
                    profile_json BLOB NOT NULL,
                    profile_sha256 BLOB NOT NULL CHECK (length(profile_sha256) = 32),
                    attempt_json BLOB NOT NULL,
                    attempt_status TEXT NOT NULL,
                    journal_state TEXT NOT NULL,
                    current_generation INTEGER NOT NULL CHECK (current_generation > 0),
                    generation_expires_at REAL NOT NULL,
                    block_reason TEXT,
                    bound_manifest_object_sha256 BLOB CHECK (bound_manifest_object_sha256 IS NULL OR length(bound_manifest_object_sha256) = 32),
                    exact_manifest_bytes BLOB,
                    canonical_recording_id TEXT,
                    publication_relative_path TEXT,
                    publication_linked_at REAL,
                    receipt_object_sha256 BLOB CHECK (receipt_object_sha256 IS NULL OR length(receipt_object_sha256) = 32),
                    exact_receipt_bytes BLOB,
                    terminal_reason TEXT,
                    terminal_at REAL,
                    began_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(origin_device_id, origin_recording_uuid, upload_id)
                );
                CREATE INDEX uploads_owner_status ON uploads(owner_device_id, attempt_status);
                CREATE INDEX uploads_origin ON uploads(origin_device_id, origin_recording_uuid);

                CREATE TABLE upload_generations (
                    upload_id TEXT NOT NULL REFERENCES uploads(upload_id),
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    began_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    terminal_reason TEXT,
                    terminal_at REAL,
                    PRIMARY KEY (upload_id, generation)
                );

                CREATE TABLE chunk_declarations (
                    upload_id TEXT NOT NULL REFERENCES uploads(upload_id),
                    chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
                    chunk_id TEXT NOT NULL,
                    origin_device_id BLOB NOT NULL CHECK (length(origin_device_id) = 32),
                    origin_recording_uuid TEXT NOT NULL,
                    canonical_start_frame INTEGER NOT NULL CHECK (canonical_start_frame >= 0),
                    canonical_frame_count INTEGER NOT NULL CHECK (canonical_frame_count > 0),
                    canonical_end_frame_exclusive INTEGER NOT NULL CHECK (canonical_end_frame_exclusive > 0),
                    canonical_sample_rate INTEGER NOT NULL,
                    canonical_channel_count INTEGER NOT NULL,
                    canonical_pcm_encoding TEXT NOT NULL,
                    codec TEXT NOT NULL,
                    container TEXT NOT NULL,
                    codec_parameters_json BLOB NOT NULL,
                    encoded_byte_length INTEGER NOT NULL CHECK (encoded_byte_length > 0),
                    encoded_sha256 BLOB NOT NULL CHECK (length(encoded_sha256) = 32),
                    canonical_decoded_byte_length INTEGER NOT NULL CHECK (canonical_decoded_byte_length > 0),
                    canonical_decoded_sha256 BLOB NOT NULL CHECK (length(canonical_decoded_sha256) = 32),
                    descriptor_json BLOB NOT NULL,
                    declared_at REAL NOT NULL,
                    PRIMARY KEY (upload_id, chunk_index),
                    UNIQUE(upload_id, chunk_id)
                );

                CREATE TABLE staged_chunks (
                    upload_id TEXT NOT NULL,
                    chunk_index INTEGER NOT NULL,
                    chunk_id TEXT NOT NULL,
                    owner_device_id BLOB NOT NULL CHECK (length(owner_device_id) = 32),
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    authenticated_grant_id TEXT NOT NULL,
                    authenticated_grant_epoch INTEGER NOT NULL CHECK (authenticated_grant_epoch > 0),
                    generated_relative_path TEXT NOT NULL UNIQUE,
                    expected_encoded_length INTEGER NOT NULL CHECK (expected_encoded_length > 0),
                    expected_encoded_sha256 BLOB NOT NULL CHECK (length(expected_encoded_sha256) = 32),
                    persisted_encoded_length INTEGER,
                    persisted_encoded_sha256 BLOB,
                    status TEXT NOT NULL CHECK (status IN ('writing', 'durable', 'rejected', 'reaping')),
                    rejected_reason TEXT,
                    file_synchronized_at REAL,
                    durable_acknowledged_at REAL,
                    object_deleted_at REAL,
                    reap_claim_id TEXT,
                    reap_prior_status TEXT CHECK (reap_prior_status IS NULL OR reap_prior_status IN ('writing', 'durable', 'rejected')),
                    reap_claimed_at REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    CHECK (
                        (status = 'reaping'
                            AND reap_claim_id IS NOT NULL
                            AND reap_prior_status IS NOT NULL
                            AND reap_claimed_at IS NOT NULL)
                        OR
                        (status != 'reaping'
                            AND reap_claim_id IS NULL
                            AND reap_prior_status IS NULL
                            AND reap_claimed_at IS NULL)
                    ),
                    PRIMARY KEY (upload_id, chunk_index),
                    FOREIGN KEY (upload_id, chunk_index) REFERENCES chunk_declarations(upload_id, chunk_index)
                );
                CREATE INDEX staged_chunks_quota ON staged_chunks(status, object_deleted_at, owner_device_id);

                CREATE TABLE upload_batches (
                    batch_id TEXT PRIMARY KEY,
                    upload_id TEXT NOT NULL REFERENCES uploads(upload_id),
                    owner_device_id BLOB NOT NULL CHECK (length(owner_device_id) = 32),
                    generation INTEGER NOT NULL,
                    descriptor_json BLOB NOT NULL,
                    body_sha256 BLOB NOT NULL CHECK (length(body_sha256) = 32),
                    body_length INTEGER NOT NULL,
                    exact_ack_bytes BLOB,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE background_capabilities (
                    capability_id TEXT PRIMARY KEY,
                    upload_id TEXT NOT NULL REFERENCES uploads(upload_id),
                    batch_id TEXT REFERENCES upload_batches(batch_id),
                    owner_device_id BLOB NOT NULL CHECK (length(owner_device_id) = 32),
                    grant_id TEXT NOT NULL,
                    grant_epoch INTEGER NOT NULL,
                    generation INTEGER NOT NULL,
                    capability_binding_sha256 BLOB NOT NULL CHECK (length(capability_binding_sha256) = 32),
                    expires_at REAL NOT NULL,
                    invalidated_at REAL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL
                );

                CREATE TABLE bound_exact_objects (
                    object_sha256 BLOB PRIMARY KEY CHECK (length(object_sha256) = 32),
                    upload_id TEXT NOT NULL REFERENCES uploads(upload_id),
                    object_kind TEXT NOT NULL,
                    exact_bytes BLOB NOT NULL CHECK (length(exact_bytes) > 0),
                    bound_at REAL NOT NULL,
                    UNIQUE(upload_id, object_kind)
                );

                CREATE TABLE publication_journal (
                    upload_id TEXT PRIMARY KEY REFERENCES uploads(upload_id),
                    state TEXT NOT NULL,
                    host_generated_temporary_name TEXT,
                    canonical_recording_id TEXT,
                    canonical_pcm_sha256 BLOB CHECK (canonical_pcm_sha256 IS NULL OR length(canonical_pcm_sha256) = 32),
                    canonical_frame_count INTEGER,
                    exact_receipt_bytes BLOB,
                    receipt_object_sha256 BLOB CHECK (receipt_object_sha256 IS NULL OR length(receipt_object_sha256) = 32),
                    last_error_code TEXT,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE audit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    occurred_at REAL NOT NULL,
                    severity TEXT NOT NULL,
                    category TEXT NOT NULL,
                    code TEXT NOT NULL,
                    device_id BLOB,
                    aggregation_key TEXT,
                    aggregate_count INTEGER NOT NULL DEFAULT 1 CHECK (aggregate_count > 0)
                );
                CREATE INDEX audit_events_retention ON audit_events(occurred_at, id);
                CREATE INDEX audit_events_aggregation ON audit_events(aggregation_key, occurred_at);
                """)
        }

        // PR 5 turns the placeholder publication row into a restart journal.
        // Every value needed to resume after client/session loss is durable in
        // HostDB; paths remain host-generated and relative to the configured
        // canonical root.
        migrator.registerMigration("v2_canonical_publication") { db in
            try db.execute(sql: """
                ALTER TABLE publication_journal
                    ADD COLUMN publication_relative_path TEXT;
                ALTER TABLE publication_journal
                    ADD COLUMN resume_state TEXT;
                ALTER TABLE publication_journal
                    ADD COLUMN authorized_device_id BLOB
                        CHECK (authorized_device_id IS NULL OR length(authorized_device_id) = 32);
                ALTER TABLE publication_journal
                    ADD COLUMN authorized_grant_id TEXT;
                ALTER TABLE publication_journal
                    ADD COLUMN authorized_grant_epoch INTEGER
                        CHECK (authorized_grant_epoch IS NULL OR authorized_grant_epoch > 0);
                ALTER TABLE publication_journal
                    ADD COLUMN accepted_upload_generation INTEGER
                        CHECK (accepted_upload_generation IS NULL OR accepted_upload_generation > 0);
                ALTER TABLE publication_journal
                    ADD COLUMN authorized_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN signed_manifest_object_sha256 BLOB
                        CHECK (signed_manifest_object_sha256 IS NULL OR length(signed_manifest_object_sha256) = 32);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_wav_byte_length INTEGER
                        CHECK (canonical_wav_byte_length IS NULL OR canonical_wav_byte_length > 44);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_revision INTEGER
                        CHECK (canonical_revision IS NULL OR canonical_revision > 0);
                ALTER TABLE publication_journal
                    ADD COLUMN change_cursor INTEGER
                        CHECK (change_cursor IS NULL OR change_cursor > 0);
                ALTER TABLE publication_journal
                    ADD COLUMN durable_commit_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN receipt_id TEXT;
                ALTER TABLE publication_journal
                    ADD COLUMN manifest_sidecar_synchronized_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN receipt_sidecar_synchronized_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN temporary_synchronized_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN audio_renamed_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN audio_directory_synchronized_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN processing_scheduled_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0
                        CHECK (retry_count >= 0);
                ALTER TABLE publication_journal
                    ADD COLUMN created_at REAL;
                ALTER TABLE publication_journal
                    ADD COLUMN legacy_quarantined INTEGER NOT NULL DEFAULT 0
                        CHECK (legacy_quarantined IN (0, 1));

                UPDATE publication_journal SET created_at = updated_at
                    WHERE created_at IS NULL;

                -- V1 never recorded the instant or grant that authorized
                -- canonical publication. Current upload/device/staging rows
                -- cannot retroactively prove that historical decision, even
                -- when their values happen to agree. Preserve every pre-v2
                -- row, but quarantine all of them instead of manufacturing a
                -- trusted recovery plan from later mutable state.
                UPDATE publication_journal
                SET resume_state = state,
                    state = 'failedRecoverable',
                    last_error_code = 'legacy-publication-requires-operator-recovery',
                    legacy_quarantined = 1;

                CREATE INDEX publication_journal_state_updated
                    ON publication_journal(state, updated_at, upload_id);

                CREATE TRIGGER publication_journal_v2_validate_insert
                BEFORE INSERT ON publication_journal
                FOR EACH ROW
                WHEN NEW.legacy_quarantined NOT IN (0, 1)
                OR (NEW.legacy_quarantined = 1 AND NEW.state != 'failedRecoverable')
                OR (NEW.legacy_quarantined = 0 AND (
                NEW.state NOT IN (
                    'assembling', 'temporarySynchronized', 'audioRenamed',
                    'audioPublished', 'recordingCommitted', 'receiptPrepared',
                    'receipted', 'processing', 'complete', 'failedRecoverable'
                )
                OR NEW.created_at IS NULL
                OR NEW.authorized_device_id IS NULL
                OR NEW.authorized_grant_id IS NULL
                OR NEW.authorized_grant_epoch IS NULL
                OR NEW.accepted_upload_generation IS NULL
                OR NEW.authorized_at IS NULL
                OR NEW.signed_manifest_object_sha256 IS NULL
                ))
                BEGIN
                    SELECT RAISE(ABORT, 'invalid canonical publication journal');
                END;

                CREATE TRIGGER publication_journal_v2_validate_update
                BEFORE UPDATE ON publication_journal
                FOR EACH ROW
                WHEN NEW.legacy_quarantined NOT IN (0, 1)
                OR (NEW.legacy_quarantined = 1 AND NEW.state != 'failedRecoverable')
                OR (NEW.legacy_quarantined = 0 AND (
                NEW.state NOT IN (
                    'assembling', 'temporarySynchronized', 'audioRenamed',
                    'audioPublished', 'recordingCommitted', 'receiptPrepared',
                    'receipted', 'processing', 'complete', 'failedRecoverable'
                )
                OR NEW.created_at IS NULL
                OR NEW.authorized_device_id IS NULL
                OR NEW.authorized_grant_id IS NULL
                OR NEW.authorized_grant_epoch IS NULL
                OR NEW.accepted_upload_generation IS NULL
                OR NEW.authorized_at IS NULL
                OR NEW.signed_manifest_object_sha256 IS NULL
                ))
                BEGIN
                    SELECT RAISE(ABORT, 'invalid canonical publication journal');
                END;
                """)
        }

        // Artifact identity is first captured from the descriptor-bound WAV
        // in the same transaction that advances audioRenamed ->
        // audioPublished. Pre-v3 rows already at or beyond publication cannot
        // prove which inode was committed, so they are preserved but
        // quarantined instead of manufacturing identity from a mutable path.
        migrator.registerMigration("v3_canonical_artifact_identity") { db in
            try db.execute(sql: """
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_device_number BLOB
                        CHECK (canonical_artifact_device_number IS NULL
                            OR length(canonical_artifact_device_number) = 8);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_inode_number BLOB
                        CHECK (canonical_artifact_inode_number IS NULL
                            OR length(canonical_artifact_inode_number) = 8);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_owner_user_id INTEGER
                        CHECK (canonical_artifact_owner_user_id IS NULL
                            OR canonical_artifact_owner_user_id BETWEEN 0 AND 4294967295);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_posix_mode INTEGER
                        CHECK (canonical_artifact_posix_mode IS NULL
                            OR canonical_artifact_posix_mode BETWEEN 0 AND 4294967295);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_link_count BLOB
                        CHECK (canonical_artifact_link_count IS NULL
                            OR length(canonical_artifact_link_count) = 8);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_file_byte_count BLOB
                        CHECK (canonical_artifact_file_byte_count IS NULL
                            OR length(canonical_artifact_file_byte_count) = 8);
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_change_time_seconds INTEGER;
                ALTER TABLE publication_journal
                    ADD COLUMN canonical_artifact_change_time_nanoseconds INTEGER
                        CHECK (canonical_artifact_change_time_nanoseconds IS NULL
                            OR canonical_artifact_change_time_nanoseconds
                                BETWEEN 0 AND 999999999);

                UPDATE publication_journal
                SET resume_state = CASE
                        WHEN state = 'failedRecoverable' THEN resume_state
                        ELSE state
                    END,
                    state = 'failedRecoverable',
                    last_error_code =
                        'legacy-publication-artifact-identity-unavailable',
                    legacy_quarantined = 1,
                    updated_at = updated_at
                WHERE legacy_quarantined = 0
                  AND (
                    state IN (
                        'audioPublished', 'recordingCommitted',
                        'receiptPrepared', 'receipted', 'processing', 'complete'
                    )
                    OR (
                        state = 'failedRecoverable'
                        AND resume_state IN (
                            'audioPublished', 'recordingCommitted',
                            'receiptPrepared', 'receipted', 'processing', 'complete'
                        )
                    )
                  );

                CREATE TRIGGER publication_journal_v3_artifact_identity_insert
                BEFORE INSERT ON publication_journal
                FOR EACH ROW
                WHEN NEW.legacy_quarantined = 0 AND (
                    (
                        (NEW.canonical_artifact_device_number IS NULL)
                        + (NEW.canonical_artifact_inode_number IS NULL)
                        + (NEW.canonical_artifact_owner_user_id IS NULL)
                        + (NEW.canonical_artifact_posix_mode IS NULL)
                        + (NEW.canonical_artifact_link_count IS NULL)
                        + (NEW.canonical_artifact_file_byte_count IS NULL)
                        + (NEW.canonical_artifact_change_time_seconds IS NULL)
                        + (NEW.canonical_artifact_change_time_nanoseconds IS NULL)
                    ) NOT IN (0, 8)
                    OR (
                        NEW.state IN (
                            'audioPublished', 'recordingCommitted',
                            'receiptPrepared', 'receipted', 'processing', 'complete'
                        )
                        AND NEW.canonical_artifact_device_number IS NULL
                    )
                    OR (
                        NEW.state = 'failedRecoverable'
                        AND NEW.resume_state IN (
                            'audioPublished', 'recordingCommitted',
                            'receiptPrepared', 'receipted', 'processing', 'complete'
                        )
                        AND NEW.canonical_artifact_device_number IS NULL
                    )
                )
                BEGIN
                    SELECT RAISE(ABORT, 'invalid canonical artifact identity');
                END;

                CREATE TRIGGER publication_journal_v3_artifact_identity_update
                BEFORE UPDATE ON publication_journal
                FOR EACH ROW
                WHEN NEW.legacy_quarantined = 0 AND (
                    (
                        (NEW.canonical_artifact_device_number IS NULL)
                        + (NEW.canonical_artifact_inode_number IS NULL)
                        + (NEW.canonical_artifact_owner_user_id IS NULL)
                        + (NEW.canonical_artifact_posix_mode IS NULL)
                        + (NEW.canonical_artifact_link_count IS NULL)
                        + (NEW.canonical_artifact_file_byte_count IS NULL)
                        + (NEW.canonical_artifact_change_time_seconds IS NULL)
                        + (NEW.canonical_artifact_change_time_nanoseconds IS NULL)
                    ) NOT IN (0, 8)
                    OR (
                        NEW.state IN (
                            'audioPublished', 'recordingCommitted',
                            'receiptPrepared', 'receipted', 'processing', 'complete'
                        )
                        AND NEW.canonical_artifact_device_number IS NULL
                    )
                    OR (
                        NEW.state = 'failedRecoverable'
                        AND NEW.resume_state IN (
                            'audioPublished', 'recordingCommitted',
                            'receiptPrepared', 'receipted', 'processing', 'complete'
                        )
                        AND NEW.canonical_artifact_device_number IS NULL
                    )
                    OR (
                        OLD.canonical_artifact_device_number IS NULL
                        AND NEW.canonical_artifact_device_number IS NOT NULL
                        AND NOT (
                            OLD.state = 'audioRenamed'
                            AND NEW.state = 'audioPublished'
                        )
                    )
                    OR (
                        OLD.canonical_artifact_device_number IS NOT NULL
                        AND (
                            NEW.canonical_artifact_device_number
                                IS NOT OLD.canonical_artifact_device_number
                            OR NEW.canonical_artifact_inode_number
                                IS NOT OLD.canonical_artifact_inode_number
                            OR NEW.canonical_artifact_owner_user_id
                                IS NOT OLD.canonical_artifact_owner_user_id
                            OR NEW.canonical_artifact_posix_mode
                                IS NOT OLD.canonical_artifact_posix_mode
                            OR NEW.canonical_artifact_link_count
                                IS NOT OLD.canonical_artifact_link_count
                            OR NEW.canonical_artifact_file_byte_count
                                IS NOT OLD.canonical_artifact_file_byte_count
                            OR NEW.canonical_artifact_change_time_seconds
                                IS NOT OLD.canonical_artifact_change_time_seconds
                            OR NEW.canonical_artifact_change_time_nanoseconds
                                IS NOT OLD.canonical_artifact_change_time_nanoseconds
                        )
                    )
                )
                BEGIN
                    SELECT RAISE(ABORT, 'invalid canonical artifact identity');
                END;
                """)
        }

        return migrator
    }
}
