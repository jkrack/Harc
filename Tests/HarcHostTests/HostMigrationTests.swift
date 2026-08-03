import Foundation
import GRDB
import Testing
@testable import HarcHost

@Suite("HarcHost database migrations")
struct HostMigrationTests {
    @Test("fresh migration creates every PR3 authority and ingest boundary")
    func freshMigration() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.harcHostMigrator().migrate(queue)
        let tables = try queue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
        }
        let required: Set<String> = [
            "host_metadata",
            "devices",
            "grants",
            "revocations",
            "pending_security_mutations",
            "pairing_tickets",
            "pairing_attempts",
            "processed_operations",
            "uploads",
            "upload_generations",
            "chunk_declarations",
            "staged_chunks",
            "upload_batches",
            "background_capabilities",
            "bound_exact_objects",
            "publication_journal",
            "audit_events",
        ]
        #expect(required.isSubset(of: tables))

        let publicationColumns = try queue.read { db in
            try Set(Row.fetchAll(db, sql: "PRAGMA table_info(publication_journal)")
                .compactMap { $0["name"] as String? })
        }
        #expect(Set([
            "publication_relative_path",
            "resume_state",
            "authorized_device_id",
            "authorized_grant_id",
            "authorized_grant_epoch",
            "accepted_upload_generation",
            "authorized_at",
            "signed_manifest_object_sha256",
            "canonical_wav_byte_length",
            "canonical_revision",
            "change_cursor",
            "durable_commit_at",
            "receipt_id",
            "manifest_sidecar_synchronized_at",
            "receipt_sidecar_synchronized_at",
            "temporary_synchronized_at",
            "audio_renamed_at",
            "audio_directory_synchronized_at",
            "processing_scheduled_at",
            "retry_count",
            "created_at",
            "legacy_quarantined",
            "canonical_artifact_device_number",
            "canonical_artifact_inode_number",
            "canonical_artifact_owner_user_id",
            "canonical_artifact_posix_mode",
            "canonical_artifact_link_count",
            "canonical_artifact_file_byte_count",
            "canonical_artifact_change_time_seconds",
            "canonical_artifact_change_time_nanoseconds",
        ]).isSubset(of: publicationColumns))
    }

    @Test("v3 quarantines published v2 rows without manufacturing artifact identity")
    func v2PublishedPublicationIsQuarantined() throws {
        let queue = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcHostMigrator()
        try migrator.migrate(queue, upTo: "v2_canonical_publication")

        let uploadID = "00000000-0000-0000-0000-000000000711"
        try seedV2Publication(
            in: queue,
            uploadID: uploadID,
            state: "audioPublished"
        )

        try migrator.migrate(queue)
        let row = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID]
            )
        }
        #expect(row?["state"] as String? == "failedRecoverable")
        #expect(row?["resume_state"] as String? == "audioPublished")
        #expect(row?["legacy_quarantined"] as Int? == 1)
        #expect(row?["last_error_code"] as String?
            == "legacy-publication-artifact-identity-unavailable")
        #expect(row?["canonical_artifact_device_number"] as Data? == nil)
        #expect(row?["canonical_artifact_change_time_nanoseconds"] as Int64? == nil)
    }

    @Test("v3 preserves pre-publication v2 recovery rows without artifact identity")
    func v2AudioRenamedPublicationRemainsRecoverable() throws {
        let queue = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcHostMigrator()
        try migrator.migrate(queue, upTo: "v2_canonical_publication")

        let uploadID = "00000000-0000-0000-0000-000000000721"
        try seedV2Publication(
            in: queue,
            uploadID: uploadID,
            state: "audioRenamed"
        )

        try migrator.migrate(queue)
        let row = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID]
            )
        }
        #expect(row?["state"] as String? == "audioRenamed")
        #expect(row?["resume_state"] as String? == nil)
        #expect(row?["legacy_quarantined"] as Int? == 0)
        #expect(row?["canonical_artifact_inode_number"] as Data? == nil)
    }

    @Test("v3 rejects audioPublished without a complete artifact identity")
    func v3RejectsMissingPublishedArtifactIdentity() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.harcHostMigrator().migrate(queue)
        let uploadID = "00000000-0000-0000-0000-000000000731"
        try seedV2Publication(
            in: queue,
            uploadID: uploadID,
            state: "audioRenamed"
        )

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE publication_journal
                        SET state = 'audioPublished'
                        WHERE upload_id = ?
                        """,
                    arguments: [uploadID]
                )
            }
        }
    }

    @Test("v3 acquires artifact identity only with publication and keeps it immutable")
    func v3ArtifactIdentityIsAtomicAndImmutable() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.harcHostMigrator().migrate(queue)
        let uploadID = "00000000-0000-0000-0000-000000000741"
        try seedV2Publication(
            in: queue,
            uploadID: uploadID,
            state: "audioRenamed"
        )
        let one = Data([0, 0, 0, 0, 0, 0, 0, 1])
        let byteCount = Data([0, 0, 0, 0, 0, 0, 0, 76])

        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE publication_journal
                    SET state = 'audioPublished',
                        canonical_artifact_device_number = ?,
                        canonical_artifact_inode_number = ?,
                        canonical_artifact_owner_user_id = 501,
                        canonical_artifact_posix_mode = 33152,
                        canonical_artifact_link_count = ?,
                        canonical_artifact_file_byte_count = ?,
                        canonical_artifact_change_time_seconds = 100,
                        canonical_artifact_change_time_nanoseconds = 200
                    WHERE upload_id = ?
                    """,
                arguments: [one, one, one, byteCount, uploadID]
            )
        }

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE publication_journal
                        SET canonical_artifact_change_time_nanoseconds = 201
                        WHERE upload_id = ?
                        """,
                    arguments: [uploadID]
                )
            }
        }
        let nanoseconds = try queue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT canonical_artifact_change_time_nanoseconds
                    FROM publication_journal WHERE upload_id = ?
                    """,
                arguments: [uploadID]
            )
        }
        #expect(nanoseconds == 200)
    }

    @Test("v2 preserves and quarantines an unverifiable v1 publication row")
    func v1PublicationRowIsPreserved() throws {
        let queue = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcHostMigrator()
        try migrator.migrate(queue, upTo: "v1_host_core")

        let uploadID = "00000000-0000-0000-0000-000000000701"
        let owner = Data(repeating: 7, count: 32)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO devices (
                        device_id, public_key_x963, registry_entry_json, status,
                        current_grant_id, current_grant_epoch, scopes_json,
                        grant_issued_at, created_at, updated_at
                    ) VALUES (?, ?, ?, 'active', ?, 1, ?, 100, 100, 100)
                    """,
                arguments: [
                    owner,
                    Data(repeating: 4, count: 65),
                    Data("{}".utf8),
                    "00000000-0000-0000-0000-000000000702",
                    Data("[]".utf8),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO uploads (
                        upload_id, owner_device_id, origin_device_id,
                        origin_recording_uuid, profile_json, profile_sha256,
                        attempt_json, attempt_status, journal_state,
                        current_generation, generation_expires_at, began_at,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', 'assembling', 1, 500, 100, 100, 150)
                    """,
                arguments: [
                    uploadID,
                    owner,
                    owner,
                    "00000000-0000-0000-0000-000000000703",
                    Data("{}".utf8),
                    Data(repeating: 8, count: 32),
                    Data("{}".utf8),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO publication_journal (
                        upload_id, state, host_generated_temporary_name,
                        canonical_recording_id, canonical_pcm_sha256,
                        canonical_frame_count, updated_at
                    ) VALUES (?, 'assembling', '.harc-legacy.partial', ?, ?, 16, 150)
                    """,
                arguments: [
                    uploadID,
                    "00000000-0000-0000-0000-000000000704",
                    Data(repeating: 9, count: 32),
                ]
            )
        }

        try migrator.migrate(queue)
        let row = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID]
            )
        }
        #expect(row != nil)
        #expect(row?["state"] as String? == "failedRecoverable")
        #expect(row?["resume_state"] as String? == "assembling")
        #expect(row?["legacy_quarantined"] as Int? == 1)
        #expect(row?["last_error_code"] as String?
            == "legacy-publication-requires-operator-recovery")
    }

    @Test("seeded pre-v1 host fixture is preserved during upgrade")
    func seededUpgrade() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE legacy_host_bootstrap (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO legacy_host_bootstrap (value) VALUES ('preserve-me')")
        }
        try DatabaseMigrator.harcHostMigrator().migrate(queue)
        let preserved = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM legacy_host_bootstrap")
        }
        #expect(preserved == "preserve-me")
    }

    @Test("migrator and store reopen are idempotent")
    func idempotentReopen() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()

        let first = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await first.registryRevision() == 0)
        let firstTables = try await first.schemaTableNames()
        _ = first

        let second = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await second.schemaTableNames() == firstTables)
        #expect(try await second.metadata() == fixture.metadata)
    }
}

private extension HostMigrationTests {
    func seedV2Publication(
        in queue: DatabaseQueue,
        uploadID: String,
        state: String
    ) throws {
        let owner = Data(repeating: 0x17, count: 32)
        let grantID = "00000000-0000-0000-0000-000000000712"
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO devices (
                        device_id, public_key_x963, registry_entry_json, status,
                        current_grant_id, current_grant_epoch, scopes_json,
                        grant_issued_at, created_at, updated_at
                    ) VALUES (?, ?, ?, 'active', ?, 1, ?, 100, 100, 100)
                    """,
                arguments: [
                    owner,
                    Data(repeating: 0x04, count: 65),
                    Data("{}".utf8),
                    grantID,
                    Data("[]".utf8),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO uploads (
                        upload_id, owner_device_id, origin_device_id,
                        origin_recording_uuid, profile_json, profile_sha256,
                        attempt_json, attempt_status, journal_state,
                        current_generation, generation_expires_at, began_at,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, 1, 500, 100, 100, 150)
                    """,
                arguments: [
                    uploadID,
                    owner,
                    owner,
                    "00000000-0000-0000-0000-000000000713",
                    Data("{}".utf8),
                    Data(repeating: 0x18, count: 32),
                    Data("{}".utf8),
                    state,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO publication_journal (
                        upload_id, state, host_generated_temporary_name,
                        canonical_recording_id, canonical_pcm_sha256,
                        canonical_frame_count, updated_at,
                        publication_relative_path, authorized_device_id,
                        authorized_grant_id, authorized_grant_epoch,
                        accepted_upload_generation, authorized_at,
                        signed_manifest_object_sha256,
                        canonical_wav_byte_length, created_at
                    ) VALUES (
                        ?, ?, '.harc-v2.partial', ?, ?, 16, 150,
                        ?, ?, ?, 1, 1, 100, ?, 76, 100
                    )
                    """,
                arguments: [
                    uploadID,
                    state,
                    "00000000-0000-0000-0000-000000000714",
                    Data(repeating: 0x19, count: 32),
                    "2026/2026-08-03/00000000-0000-0000-0000-000000000714.wav",
                    owner,
                    grantID,
                    Data(repeating: 0x20, count: 32),
                ]
            )
        }
    }
}
