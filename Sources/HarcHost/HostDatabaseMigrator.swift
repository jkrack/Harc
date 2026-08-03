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

        // PR 6 replaces the pairing placeholders with durable claim state and
        // adds the short-lived challenge/session journal. Bearer secrets are
        // never persisted: every token column contains a domain-separated
        // SHA-256 binding. Legacy placeholder attempts remain version 0 and
        // are intentionally ineligible for the protocol service.
        migrator.registerMigration("v4_pairing_and_sessions") { db in
            try db.execute(sql: """
                ALTER TABLE pairing_attempts
                    ADD COLUMN protocol_state_version INTEGER NOT NULL DEFAULT 0
                        CHECK (protocol_state_version IN (0, 1));
                ALTER TABLE pairing_attempts
                    ADD COLUMN device_public_key_x963 BLOB
                        CHECK (device_public_key_x963 IS NULL
                            OR length(device_public_key_x963) = 65);
                ALTER TABLE pairing_attempts
                    ADD COLUMN device_label TEXT;
                ALTER TABLE pairing_attempts
                    ADD COLUMN client_nonce BLOB
                        CHECK (client_nonce IS NULL OR length(client_nonce) = 32);
                ALTER TABLE pairing_attempts
                    ADD COLUMN host_nonce BLOB
                        CHECK (host_nonce IS NULL OR length(host_nonce) = 32);
                ALTER TABLE pairing_attempts
                    ADD COLUMN tls_spki_sha256 BLOB
                        CHECK (tls_spki_sha256 IS NULL OR length(tls_spki_sha256) = 32);
                ALTER TABLE pairing_attempts
                    ADD COLUMN host_authority_public_key_x963 BLOB
                        CHECK (host_authority_public_key_x963 IS NULL
                            OR length(host_authority_public_key_x963) = 65);
                ALTER TABLE pairing_attempts
                    ADD COLUMN protocol_major INTEGER
                        CHECK (protocol_major IS NULL
                            OR protocol_major BETWEEN 0 AND 65535);
                ALTER TABLE pairing_attempts
                    ADD COLUMN protocol_minor INTEGER
                        CHECK (protocol_minor IS NULL
                            OR protocol_minor BETWEEN 0 AND 65535);
                ALTER TABLE pairing_attempts
                    ADD COLUMN proof_signature_raw BLOB
                        CHECK (proof_signature_raw IS NULL
                            OR length(proof_signature_raw) = 64);
                ALTER TABLE pairing_attempts
                    ADD COLUMN sas_digest BLOB
                        CHECK (sas_digest IS NULL OR length(sas_digest) = 32);
                ALTER TABLE pairing_attempts
                    ADD COLUMN sas_word_indexes_json BLOB;
                ALTER TABLE pairing_attempts
                    ADD COLUMN sas_words_json BLOB;
                ALTER TABLE pairing_attempts
                    ADD COLUMN proof_verified_at REAL;
                ALTER TABLE pairing_attempts
                    ADD COLUMN exact_grant_bytes BLOB;
                ALTER TABLE pairing_attempts
                    ADD COLUMN terminal_at REAL;

                CREATE UNIQUE INDEX pairing_attempts_one_v1_claim_per_ticket
                    ON pairing_attempts(ticket_id)
                    WHERE protocol_state_version = 1;
                CREATE INDEX pairing_attempts_state_expiry
                    ON pairing_attempts(state, expires_at, claim_id);

                CREATE TRIGGER pairing_attempts_v1_validate_insert
                BEFORE INSERT ON pairing_attempts
                FOR EACH ROW
                WHEN NEW.protocol_state_version = 1 AND (
                    NEW.claimant_token_binding_sha256 IS NULL
                    OR NEW.requested_scopes_json IS NULL
                    OR NEW.device_public_key_x963 IS NULL
                    OR NEW.device_label IS NULL
                    OR length(CAST(NEW.device_label AS BLOB)) NOT BETWEEN 1 AND 256
                    OR NEW.client_nonce IS NULL
                    OR NEW.host_nonce IS NULL
                    OR NEW.tls_spki_sha256 IS NULL
                    OR NEW.host_authority_public_key_x963 IS NULL
                    OR NEW.protocol_major != 1
                    OR NEW.protocol_minor IS NULL
                    OR (
                        NEW.state IN ('proofVerified', 'awaitingApproval', 'approved')
                        AND (
                            NEW.proof_signature_raw IS NULL
                            OR NEW.sas_digest IS NULL
                            OR NEW.sas_word_indexes_json IS NULL
                            OR NEW.sas_words_json IS NULL
                            OR NEW.proof_verified_at IS NULL
                        )
                    )
                    OR (NEW.state = 'approved' AND NEW.exact_grant_bytes IS NULL)
                    OR (NEW.state = 'approved' AND length(NEW.exact_grant_bytes) = 0)
                    OR (
                        NEW.state IN ('reserved', 'proofVerified', 'awaitingApproval')
                        AND NEW.terminal_at IS NOT NULL
                    )
                    OR (
                        NEW.state IN ('approved', 'denied', 'expired', 'cancelled')
                        AND NEW.terminal_at IS NULL
                    )
                    OR (
                        NEW.state = 'reserved'
                        AND (
                            NEW.proof_signature_raw IS NOT NULL
                            OR NEW.sas_digest IS NOT NULL
                            OR NEW.sas_word_indexes_json IS NOT NULL
                            OR NEW.sas_words_json IS NOT NULL
                            OR NEW.proof_verified_at IS NOT NULL
                        )
                    )
                    OR (NEW.state != 'approved' AND NEW.exact_grant_bytes IS NOT NULL)
                )
                BEGIN
                    SELECT RAISE(ABORT, 'invalid v1 pairing attempt');
                END;

                CREATE TRIGGER pairing_attempts_v1_validate_update
                BEFORE UPDATE ON pairing_attempts
                FOR EACH ROW
                WHEN (OLD.protocol_state_version = 1
                      OR NEW.protocol_state_version = 1) AND (
                    NEW.claimant_token_binding_sha256 IS NULL
                    OR NEW.requested_scopes_json IS NULL
                    OR NEW.device_public_key_x963 IS NULL
                    OR NEW.device_label IS NULL
                    OR length(CAST(NEW.device_label AS BLOB)) NOT BETWEEN 1 AND 256
                    OR NEW.client_nonce IS NULL
                    OR NEW.host_nonce IS NULL
                    OR NEW.tls_spki_sha256 IS NULL
                    OR NEW.host_authority_public_key_x963 IS NULL
                    OR NEW.protocol_major != 1
                    OR NEW.protocol_minor IS NULL
                    OR NEW.device_id IS NOT OLD.device_id
                    OR NEW.device_public_key_x963 IS NOT OLD.device_public_key_x963
                    OR NEW.device_label IS NOT OLD.device_label
                    OR NEW.requested_scopes_json IS NOT OLD.requested_scopes_json
                    OR NEW.client_nonce IS NOT OLD.client_nonce
                    OR NEW.host_nonce IS NOT OLD.host_nonce
                    OR NEW.tls_spki_sha256 IS NOT OLD.tls_spki_sha256
                    OR NEW.host_authority_public_key_x963
                        IS NOT OLD.host_authority_public_key_x963
                    OR NEW.protocol_major IS NOT OLD.protocol_major
                    OR NEW.protocol_minor IS NOT OLD.protocol_minor
                    OR NEW.claimant_token_binding_sha256
                        IS NOT OLD.claimant_token_binding_sha256
                    OR NEW.claim_id IS NOT OLD.claim_id
                    OR NEW.ticket_id IS NOT OLD.ticket_id
                    OR NEW.protocol_state_version IS NOT OLD.protocol_state_version
                    OR NEW.created_at IS NOT OLD.created_at
                    OR NEW.expires_at IS NOT OLD.expires_at
                    OR (
                        OLD.proof_signature_raw IS NOT NULL
                        AND NEW.proof_signature_raw IS NOT OLD.proof_signature_raw
                    )
                    OR (
                        OLD.sas_digest IS NOT NULL
                        AND NEW.sas_digest IS NOT OLD.sas_digest
                    )
                    OR (
                        OLD.sas_word_indexes_json IS NOT NULL
                        AND NEW.sas_word_indexes_json IS NOT OLD.sas_word_indexes_json
                    )
                    OR (
                        OLD.sas_words_json IS NOT NULL
                        AND NEW.sas_words_json IS NOT OLD.sas_words_json
                    )
                    OR (
                        OLD.proof_verified_at IS NOT NULL
                        AND NEW.proof_verified_at IS NOT OLD.proof_verified_at
                    )
                    OR (
                        OLD.exact_grant_bytes IS NOT NULL
                        AND NEW.exact_grant_bytes IS NOT OLD.exact_grant_bytes
                    )
                    OR (
                        OLD.terminal_at IS NOT NULL
                        AND NEW.terminal_at IS NOT OLD.terminal_at
                    )
                    OR NOT (
                        NEW.state = OLD.state
                        OR (
                            OLD.state = 'reserved'
                            AND NEW.state IN (
                                'proofVerified', 'awaitingApproval',
                                'expired', 'cancelled'
                            )
                        )
                        OR (
                            OLD.state = 'proofVerified'
                            AND NEW.state IN (
                                'awaitingApproval', 'expired', 'cancelled'
                            )
                        )
                        OR (
                            OLD.state = 'awaitingApproval'
                            AND NEW.state IN (
                                'approved', 'denied', 'expired', 'cancelled'
                            )
                        )
                    )
                    OR (
                        NEW.state IN ('proofVerified', 'awaitingApproval', 'approved')
                        AND (
                            NEW.proof_signature_raw IS NULL
                            OR NEW.sas_digest IS NULL
                            OR NEW.sas_word_indexes_json IS NULL
                            OR NEW.sas_words_json IS NULL
                            OR NEW.proof_verified_at IS NULL
                        )
                    )
                    OR (NEW.state = 'approved' AND NEW.exact_grant_bytes IS NULL)
                    OR (NEW.state = 'approved' AND length(NEW.exact_grant_bytes) = 0)
                    OR (
                        NEW.state IN ('reserved', 'proofVerified', 'awaitingApproval')
                        AND NEW.terminal_at IS NOT NULL
                    )
                    OR (
                        NEW.state IN ('approved', 'denied', 'expired', 'cancelled')
                        AND NEW.terminal_at IS NULL
                    )
                    OR (
                        NEW.state = 'reserved'
                        AND (
                            NEW.proof_signature_raw IS NOT NULL
                            OR NEW.sas_digest IS NOT NULL
                            OR NEW.sas_word_indexes_json IS NOT NULL
                            OR NEW.sas_words_json IS NOT NULL
                            OR NEW.proof_verified_at IS NOT NULL
                        )
                    )
                    OR (NEW.state != 'approved' AND NEW.exact_grant_bytes IS NOT NULL)
                )
                BEGIN
                    SELECT RAISE(ABORT, 'invalid v1 pairing attempt');
                END;

                CREATE TABLE preauth_attempts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation TEXT NOT NULL
                        CHECK (operation IN ('pairingBegin', 'sessionBegin')),
                    source_binding_sha256 BLOB NOT NULL
                        CHECK (length(source_binding_sha256) = 32),
                    subject_binding_sha256 BLOB NOT NULL
                        CHECK (length(subject_binding_sha256) = 32),
                    occurred_at REAL NOT NULL
                );
                CREATE INDEX preauth_attempts_window
                    ON preauth_attempts(operation, source_binding_sha256,
                        subject_binding_sha256, occurred_at);
                CREATE TRIGGER preauth_attempts_immutable_update
                BEFORE UPDATE ON preauth_attempts
                BEGIN
                    SELECT RAISE(ABORT, 'pre-auth attempt rows are immutable');
                END;

                CREATE TABLE session_challenges (
                    challenge_id TEXT PRIMARY KEY,
                    source_binding_sha256 BLOB NOT NULL
                        CHECK (length(source_binding_sha256) = 32),
                    subject_binding_sha256 BLOB NOT NULL
                        CHECK (length(subject_binding_sha256) = 32),
                    is_admitted INTEGER NOT NULL CHECK (is_admitted IN (0, 1)),
                    device_id BLOB CHECK (device_id IS NULL OR length(device_id) = 32),
                    grant_id TEXT,
                    grant_epoch INTEGER CHECK (grant_epoch IS NULL OR grant_epoch > 0),
                    device_public_key_x963 BLOB
                        CHECK (device_public_key_x963 IS NULL
                            OR length(device_public_key_x963) = 65),
                    exact_grant_bytes BLOB NOT NULL CHECK (length(exact_grant_bytes) > 0),
                    server_nonce BLOB NOT NULL CHECK (length(server_nonce) = 32),
                    tls_spki_sha256 BLOB NOT NULL CHECK (length(tls_spki_sha256) = 32),
                    exact_capabilities_bytes BLOB NOT NULL
                        CHECK (length(exact_capabilities_bytes) BETWEEN 1 AND 65536),
                    capabilities_sha256 BLOB NOT NULL
                        CHECK (length(capabilities_sha256) = 32),
                    protocol_major INTEGER NOT NULL CHECK (protocol_major = 1),
                    protocol_minor INTEGER NOT NULL
                        CHECK (protocol_minor BETWEEN 0 AND 65535),
                    selected_codec TEXT NOT NULL
                        CHECK (length(selected_codec) BETWEEN 1 AND 64),
                    selected_container TEXT NOT NULL
                        CHECK (length(selected_container) BETWEEN 1 AND 64),
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    CHECK (expires_at > created_at AND expires_at <= created_at + 30),
                    CHECK (
                        (is_admitted = 0 AND device_id IS NULL
                            AND grant_id IS NULL AND grant_epoch IS NULL
                            AND device_public_key_x963 IS NULL)
                        OR
                        (is_admitted = 1 AND device_id IS NOT NULL
                            AND grant_id IS NOT NULL AND grant_epoch IS NOT NULL
                            AND device_public_key_x963 IS NOT NULL)
                    )
                );
                CREATE INDEX session_challenges_outstanding
                    ON session_challenges(source_binding_sha256,
                        subject_binding_sha256, expires_at);
                CREATE TRIGGER session_challenges_immutable_update
                BEFORE UPDATE ON session_challenges
                BEGIN
                    SELECT RAISE(ABORT, 'session challenge rows are immutable');
                END;

                CREATE TABLE session_tokens (
                    token_id TEXT PRIMARY KEY,
                    token_binding_sha256 BLOB NOT NULL
                        CHECK (length(token_binding_sha256) = 32),
                    device_id BLOB NOT NULL REFERENCES devices(device_id),
                    grant_id TEXT NOT NULL,
                    grant_epoch INTEGER NOT NULL CHECK (grant_epoch > 0),
                    tls_spki_sha256 BLOB NOT NULL CHECK (length(tls_spki_sha256) = 32),
                    exact_capabilities_bytes BLOB NOT NULL
                        CHECK (length(exact_capabilities_bytes) BETWEEN 1 AND 65536),
                    capabilities_sha256 BLOB NOT NULL
                        CHECK (length(capabilities_sha256) = 32),
                    protocol_major INTEGER NOT NULL CHECK (protocol_major = 1),
                    protocol_minor INTEGER NOT NULL
                        CHECK (protocol_minor BETWEEN 0 AND 65535),
                    selected_codec TEXT NOT NULL
                        CHECK (length(selected_codec) BETWEEN 1 AND 64),
                    selected_container TEXT NOT NULL
                        CHECK (length(selected_container) BETWEEN 1 AND 64),
                    issued_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    invalidated_at REAL,
                    invalidation_reason TEXT,
                    CHECK (expires_at > issued_at AND expires_at <= issued_at + 1800),
                    CHECK (
                        (invalidated_at IS NULL AND invalidation_reason IS NULL)
                        OR (invalidated_at IS NOT NULL
                            AND invalidated_at >= issued_at
                            AND length(invalidation_reason) > 0)
                    )
                );
                CREATE INDEX session_tokens_device_grant
                    ON session_tokens(device_id, grant_id, grant_epoch, expires_at);
                CREATE INDEX session_tokens_expiry
                    ON session_tokens(expires_at, invalidated_at);
                CREATE TRIGGER session_tokens_validate_update
                BEFORE UPDATE ON session_tokens
                FOR EACH ROW
                WHEN NEW.token_id IS NOT OLD.token_id
                    OR NEW.token_binding_sha256 IS NOT OLD.token_binding_sha256
                    OR NEW.device_id IS NOT OLD.device_id
                    OR NEW.grant_id IS NOT OLD.grant_id
                    OR NEW.grant_epoch IS NOT OLD.grant_epoch
                    OR NEW.tls_spki_sha256 IS NOT OLD.tls_spki_sha256
                    OR NEW.exact_capabilities_bytes
                        IS NOT OLD.exact_capabilities_bytes
                    OR NEW.capabilities_sha256 IS NOT OLD.capabilities_sha256
                    OR NEW.protocol_major IS NOT OLD.protocol_major
                    OR NEW.protocol_minor IS NOT OLD.protocol_minor
                    OR NEW.selected_codec IS NOT OLD.selected_codec
                    OR NEW.selected_container IS NOT OLD.selected_container
                    OR NEW.issued_at IS NOT OLD.issued_at
                    OR NEW.expires_at IS NOT OLD.expires_at
                    OR (
                        OLD.invalidated_at IS NOT NULL
                        AND (
                            NEW.invalidated_at IS NOT OLD.invalidated_at
                            OR NEW.invalidation_reason IS NOT OLD.invalidation_reason
                        )
                    )
                BEGIN
                    SELECT RAISE(ABORT, 'invalid session token update');
                END;
                """)
        }

        // PR 6 publishes authority-signed transport sets through a restart-
        // safe three-phase journal. Exact signed bytes and exact leaf DER are
        // immutable provenance; Keychain remains the anti-rollback mark.
        migrator.registerMigration("v5_transport_set_lifecycle") { db in
            try db.execute(sql: """
                -- v4 temporarily placed negotiated capabilities in the
                -- unauthenticated BeginSession challenge. Preserve deployed
                -- rows losslessly, but make both legacy columns nullable and
                -- all-or-none so corrected BeginSession stores neither. They
                -- are migration baggage only; OpenSession owns this evidence.
                ALTER TABLE session_challenges RENAME TO session_challenges_v4;
                DROP INDEX session_challenges_outstanding;
                DROP TRIGGER session_challenges_immutable_update;
                CREATE TABLE session_challenges (
                    challenge_id TEXT PRIMARY KEY,
                    source_binding_sha256 BLOB NOT NULL
                        CHECK (length(source_binding_sha256) = 32),
                    subject_binding_sha256 BLOB NOT NULL
                        CHECK (length(subject_binding_sha256) = 32),
                    is_admitted INTEGER NOT NULL CHECK (is_admitted IN (0, 1)),
                    device_id BLOB CHECK (device_id IS NULL OR length(device_id) = 32),
                    grant_id TEXT,
                    grant_epoch INTEGER CHECK (grant_epoch IS NULL OR grant_epoch > 0),
                    device_public_key_x963 BLOB
                        CHECK (device_public_key_x963 IS NULL
                            OR length(device_public_key_x963) = 65),
                    exact_grant_bytes BLOB NOT NULL CHECK (length(exact_grant_bytes) > 0),
                    server_nonce BLOB NOT NULL CHECK (length(server_nonce) = 32),
                    tls_spki_sha256 BLOB NOT NULL CHECK (length(tls_spki_sha256) = 32),
                    exact_capabilities_bytes BLOB
                        CHECK (exact_capabilities_bytes IS NULL
                            OR length(exact_capabilities_bytes) BETWEEN 1 AND 65536),
                    capabilities_sha256 BLOB
                        CHECK (capabilities_sha256 IS NULL
                            OR length(capabilities_sha256) = 32),
                    protocol_major INTEGER NOT NULL CHECK (protocol_major = 1),
                    protocol_minor INTEGER NOT NULL
                        CHECK (protocol_minor BETWEEN 0 AND 65535),
                    selected_codec TEXT
                        CHECK (selected_codec IS NULL
                            OR length(selected_codec) BETWEEN 1 AND 64),
                    selected_container TEXT
                        CHECK (selected_container IS NULL
                            OR length(selected_container) BETWEEN 1 AND 64),
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    CHECK (expires_at > created_at AND expires_at <= created_at + 30),
                    CHECK (
                        (exact_capabilities_bytes IS NULL
                            AND capabilities_sha256 IS NULL
                            AND selected_codec IS NULL
                            AND selected_container IS NULL)
                        OR
                        (exact_capabilities_bytes IS NOT NULL
                            AND capabilities_sha256 IS NOT NULL
                            AND selected_codec IS NOT NULL
                            AND selected_container IS NOT NULL)
                    ),
                    CHECK (
                        (is_admitted = 0 AND device_id IS NULL
                            AND grant_id IS NULL AND grant_epoch IS NULL
                            AND device_public_key_x963 IS NULL)
                        OR
                        (is_admitted = 1 AND device_id IS NOT NULL
                            AND grant_id IS NOT NULL AND grant_epoch IS NOT NULL
                            AND device_public_key_x963 IS NOT NULL)
                    )
                );
                INSERT INTO session_challenges
                    SELECT * FROM session_challenges_v4;
                DROP TABLE session_challenges_v4;
                CREATE INDEX session_challenges_outstanding
                    ON session_challenges(source_binding_sha256,
                        subject_binding_sha256, expires_at);
                CREATE TRIGGER session_challenges_immutable_update
                BEFORE UPDATE ON session_challenges
                BEGIN
                    SELECT RAISE(ABORT, 'session challenge rows are immutable');
                END;

                ALTER TABLE devices
                    ADD COLUMN trust_repair_required INTEGER NOT NULL DEFAULT 0
                        CHECK (trust_repair_required IN (0, 1));

                CREATE TABLE host_transport_sets (
                    epoch INTEGER PRIMARY KEY CHECK (epoch > 0),
                    exact_signed_bytes BLOB NOT NULL
                        CHECK (length(exact_signed_bytes) BETWEEN 1 AND 4096),
                    object_id BLOB NOT NULL UNIQUE CHECK (length(object_id) = 32),
                    publication_kind TEXT NOT NULL CHECK (publication_kind IN (
                        'legacy', 'initial', 'stableRenewal',
                        'plannedOverlap', 'plannedFinal', 'emergency'
                    )),
                    issued_at_unix_ms INTEGER NOT NULL CHECK (issued_at_unix_ms >= 0),
                    published_at REAL NOT NULL,
                    retirement_floor_unix_ms INTEGER NOT NULL
                        CHECK (retirement_floor_unix_ms >= 0)
                );

                CREATE TABLE pending_transport_set_publications (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    previous_epoch INTEGER NOT NULL CHECK (previous_epoch >= 0),
                    next_epoch INTEGER NOT NULL UNIQUE CHECK (next_epoch > 0),
                    expected_previous_object_id BLOB
                        CHECK (expected_previous_object_id IS NULL
                            OR length(expected_previous_object_id) = 32),
                    exact_signed_bytes BLOB NOT NULL
                        CHECK (length(exact_signed_bytes) BETWEEN 1 AND 4096),
                    object_id BLOB NOT NULL UNIQUE CHECK (length(object_id) = 32),
                    publication_kind TEXT NOT NULL CHECK (publication_kind IN (
                        'initial', 'stableRenewal',
                        'plannedOverlap', 'plannedFinal', 'emergency'
                    )),
                    expected_active_spki_sha256 BLOB NOT NULL
                        CHECK (length(expected_active_spki_sha256) = 32),
                    secondary_spki_sha256 BLOB
                        CHECK (secondary_spki_sha256 IS NULL
                            OR length(secondary_spki_sha256) = 32),
                    retirement_floor_unix_ms INTEGER NOT NULL
                        CHECK (retirement_floor_unix_ms >= 0),
                    created_at REAL NOT NULL,
                    CHECK (next_epoch = previous_epoch + 1),
                    CHECK (
                        (previous_epoch = 0 AND expected_previous_object_id IS NULL)
                        OR
                        (previous_epoch > 0 AND expected_previous_object_id IS NOT NULL)
                    ),
                    CHECK (secondary_spki_sha256 IS NULL
                        OR secondary_spki_sha256 != expected_active_spki_sha256)
                );

                CREATE TABLE host_tls_leaves (
                    transport_epoch INTEGER NOT NULL
                        REFERENCES host_transport_sets(epoch),
                    tls_spki_sha256 BLOB NOT NULL CHECK (length(tls_spki_sha256) = 32),
                    certificate_der BLOB NOT NULL
                        CHECK (length(certificate_der) BETWEEN 1 AND 16384),
                    certificate_sha256 BLOB NOT NULL CHECK (length(certificate_sha256) = 32),
                    serial_number BLOB NOT NULL
                        CHECK (length(serial_number) BETWEEN 1 AND 20),
                    not_before_unix_ms INTEGER NOT NULL CHECK (not_before_unix_ms >= 0),
                    not_after_unix_ms INTEGER NOT NULL CHECK (not_after_unix_ms > 0),
                    created_at REAL NOT NULL,
                    PRIMARY KEY (transport_epoch, tls_spki_sha256),
                    UNIQUE (certificate_sha256),
                    CHECK (not_after_unix_ms > not_before_unix_ms)
                );

                CREATE TABLE host_transport_rotation_intent (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    started_mode TEXT NOT NULL
                        CHECK (started_mode IN ('planned', 'emergency')),
                    mode TEXT NOT NULL CHECK (mode IN ('planned', 'emergency')),
                    old_spki_sha256 BLOB NOT NULL CHECK (length(old_spki_sha256) = 32),
                    new_spki_sha256 BLOB
                        CHECK (new_spki_sha256 IS NULL OR length(new_spki_sha256) = 32),
                    retirement_floor_unix_ms INTEGER NOT NULL
                        CHECK (retirement_floor_unix_ms >= 0),
                    created_at REAL NOT NULL,
                    emergency_escalated_at REAL,
                    CHECK (new_spki_sha256 IS NULL OR new_spki_sha256 != old_spki_sha256),
                    CHECK (
                        (started_mode = 'planned' AND mode = 'planned'
                            AND emergency_escalated_at IS NULL)
                        OR
                        (started_mode = 'planned' AND mode = 'emergency'
                            AND emergency_escalated_at IS NOT NULL
                            AND emergency_escalated_at >= created_at)
                        OR
                        (started_mode = 'emergency' AND mode = 'emergency'
                            AND emergency_escalated_at IS NULL)
                    )
                );

                INSERT INTO host_transport_sets (
                    epoch, exact_signed_bytes, object_id, publication_kind,
                    issued_at_unix_ms, published_at, retirement_floor_unix_ms
                )
                SELECT highest_transport_set_epoch,
                       exact_transport_set_bytes,
                       transport_set_object_sha256,
                       'legacy', 0, updated_at, leaf_retirement_floor
                  FROM host_metadata
                 WHERE singleton = 1
                   AND highest_transport_set_epoch > 0
                   AND exact_transport_set_bytes IS NOT NULL
                   AND transport_set_object_sha256 IS NOT NULL;

                CREATE TRIGGER host_metadata_transport_validate_insert
                BEFORE INSERT ON host_metadata
                FOR EACH ROW
                WHEN NOT (
                    (NEW.highest_transport_set_epoch = 0
                        AND NEW.exact_transport_set_bytes IS NULL
                        AND NEW.transport_set_object_sha256 IS NULL)
                    OR
                    (NEW.highest_transport_set_epoch > 0
                        AND NEW.exact_transport_set_bytes IS NOT NULL
                        AND length(NEW.exact_transport_set_bytes) BETWEEN 1 AND 4096
                        AND NEW.transport_set_object_sha256 IS NOT NULL
                        AND length(NEW.transport_set_object_sha256) = 32)
                )
                BEGIN
                    SELECT RAISE(ABORT, 'invalid host transport metadata');
                END;

                CREATE TRIGGER host_metadata_transport_validate_update
                BEFORE UPDATE ON host_metadata
                FOR EACH ROW
                WHEN NEW.highest_transport_set_epoch < OLD.highest_transport_set_epoch
                    OR NEW.highest_transport_set_epoch > OLD.highest_transport_set_epoch + 1
                    OR NEW.leaf_retirement_floor < OLD.leaf_retirement_floor
                    OR NOT (
                        (NEW.highest_transport_set_epoch = 0
                            AND NEW.exact_transport_set_bytes IS NULL
                            AND NEW.transport_set_object_sha256 IS NULL)
                        OR
                        (NEW.highest_transport_set_epoch > 0
                            AND NEW.exact_transport_set_bytes IS NOT NULL
                            AND length(NEW.exact_transport_set_bytes) BETWEEN 1 AND 4096
                            AND NEW.transport_set_object_sha256 IS NOT NULL
                            AND length(NEW.transport_set_object_sha256) = 32)
                    )
                    OR (
                        NEW.highest_transport_set_epoch = OLD.highest_transport_set_epoch
                        AND (
                            NEW.exact_transport_set_bytes IS NOT OLD.exact_transport_set_bytes
                            OR NEW.transport_set_object_sha256
                                IS NOT OLD.transport_set_object_sha256
                        )
                    )
                    OR (
                        NEW.highest_transport_set_epoch = OLD.highest_transport_set_epoch + 1
                        AND NOT EXISTS (
                            SELECT 1 FROM host_transport_sets
                             WHERE epoch = NEW.highest_transport_set_epoch
                               AND exact_signed_bytes = NEW.exact_transport_set_bytes
                               AND object_id = NEW.transport_set_object_sha256
                        )
                    )
                BEGIN
                    SELECT RAISE(ABORT, 'invalid host transport metadata transition');
                END;

                CREATE TRIGGER host_transport_sets_immutable_update
                BEFORE UPDATE ON host_transport_sets
                BEGIN
                    SELECT RAISE(ABORT, 'transport-set history is immutable');
                END;
                CREATE TRIGGER host_transport_sets_immutable_delete
                BEFORE DELETE ON host_transport_sets
                BEGIN
                    SELECT RAISE(ABORT, 'transport-set history is immutable');
                END;

                CREATE TRIGGER pending_transport_sets_immutable_update
                BEFORE UPDATE ON pending_transport_set_publications
                BEGIN
                    SELECT RAISE(ABORT, 'pending transport-set binding is immutable');
                END;

                CREATE TRIGGER host_tls_leaves_immutable_update
                BEFORE UPDATE ON host_tls_leaves
                BEGIN
                    SELECT RAISE(ABORT, 'TLS leaf provenance is immutable');
                END;
                CREATE TRIGGER host_tls_leaves_immutable_delete
                BEFORE DELETE ON host_tls_leaves
                BEGIN
                    SELECT RAISE(ABORT, 'TLS leaf provenance is immutable');
                END;

                CREATE TRIGGER host_rotation_intent_immutable_binding
                BEFORE UPDATE ON host_transport_rotation_intent
                FOR EACH ROW
                WHEN NEW.started_mode IS NOT OLD.started_mode
                    OR (
                        NEW.mode IS NOT OLD.mode
                        AND NOT (
                            OLD.started_mode = 'planned'
                            AND OLD.mode = 'planned'
                            AND NEW.mode = 'emergency'
                        )
                    )
                    OR NEW.old_spki_sha256 IS NOT OLD.old_spki_sha256
                    OR OLD.new_spki_sha256 IS NOT NULL
                       AND NEW.new_spki_sha256 IS NOT OLD.new_spki_sha256
                    OR NEW.retirement_floor_unix_ms IS NOT OLD.retirement_floor_unix_ms
                    OR NEW.created_at IS NOT OLD.created_at
                    OR (
                        NEW.emergency_escalated_at IS NOT OLD.emergency_escalated_at
                        AND NOT (
                            OLD.started_mode = 'planned'
                            AND OLD.mode = 'planned'
                            AND NEW.mode = 'emergency'
                            AND OLD.emergency_escalated_at IS NULL
                            AND NEW.emergency_escalated_at IS NOT NULL
                        )
                    )
                BEGIN
                    SELECT RAISE(ABORT, 'rotation intent binding is immutable');
                END;

                CREATE TRIGGER pending_security_rejects_emergency_transport
                BEFORE INSERT ON pending_security_mutations
                FOR EACH ROW
                WHEN EXISTS (
                    SELECT 1 FROM host_transport_rotation_intent
                    WHERE singleton = 1 AND mode = 'emergency'
                )
                BEGIN
                    SELECT RAISE(ABORT,
                        'security mutation conflicts with emergency transport rotation');
                END;

                CREATE TRIGGER emergency_transport_rejects_pending_security_insert
                BEFORE INSERT ON host_transport_rotation_intent
                FOR EACH ROW
                WHEN NEW.mode = 'emergency'
                    AND EXISTS (SELECT 1 FROM pending_security_mutations)
                BEGIN
                    SELECT RAISE(ABORT,
                        'emergency transport rotation conflicts with security mutation');
                END;

                CREATE TRIGGER emergency_transport_rejects_pending_security_update
                BEFORE UPDATE OF mode ON host_transport_rotation_intent
                FOR EACH ROW
                WHEN OLD.mode = 'planned' AND NEW.mode = 'emergency'
                    AND EXISTS (SELECT 1 FROM pending_security_mutations)
                BEGIN
                    SELECT RAISE(ABORT,
                        'emergency transport rotation conflicts with security mutation');
                END;
                """)
        }

        return migrator
    }
}
