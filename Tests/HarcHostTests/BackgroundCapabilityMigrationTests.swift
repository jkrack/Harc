import Foundation
import GRDB
import Testing
@testable import HarcHost

@Suite("Background capability binding migration")
struct BackgroundCapabilityMigrationTests {
    @Test("v6 installs the one-to-one binding table and immutable triggers")
    func freshSchemaContract() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.harcHostMigrator().migrate(queue)

        let facts = try queue.read { db in
            let columns = try Set(Row.fetchAll(
                db,
                sql: "PRAGMA table_info(background_capability_bindings)"
            ).compactMap { $0["name"] as String? })
            let foreignKeys = try Row.fetchAll(
                db,
                sql: "PRAGMA foreign_key_list(background_capability_bindings)"
            )
            let triggers = try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"
            ))
            return (columns, foreignKeys, triggers)
        }

        #expect(facts.0 == Set([
            "capability_id",
            "binding_version",
            "library_id",
            "host_authority_id",
            "minimum_transport_set_epoch",
            "http_method",
            "http_path",
            "exact_body_sha256",
            "exact_body_length",
            "byte_ceiling",
            "issued_at",
            "expires_at",
        ]))
        #expect(facts.1.count == 1)
        #expect(facts.1.first?["table"] as String? == "background_capabilities")
        #expect(facts.1.first?["from"] as String? == "capability_id")
        #expect(facts.1.first?["to"] as String? == "capability_id")
        #expect(facts.1.first?["on_delete"] as String? == "CASCADE")
        #expect(facts.2.isSuperset(of: [
            "background_capability_bindings_validate_insert",
            "background_capability_bindings_immutable_update",
            "background_capabilities_immutable_binding_update",
            "upload_batches_immutable_binding_update",
        ]))
    }

    @Test("v5 credentials are not promoted into usable v6 bindings")
    func legacyCapabilitiesRemainUnbound() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = DatabaseMigrator.harcHostMigrator()
        try migrator.migrate(queue, upTo: "v5_transport_set_lifecycle")

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO background_capabilities (
                        capability_id, upload_id, batch_id, owner_device_id,
                        grant_id, grant_epoch, generation,
                        capability_binding_sha256, expires_at, invalidated_at,
                        state, created_at
                    ) VALUES (?, ?, NULL, ?, ?, 1, 1, ?, 200, NULL, 'issued', 100)
                    """,
                arguments: [
                    "00000000-0000-0000-0000-000000000601",
                    "00000000-0000-0000-0000-000000000602",
                    Data(repeating: 0x61, count: 32),
                    "00000000-0000-0000-0000-000000000603",
                    Data(repeating: 0x62, count: 32),
                ]
            )
        }

        try migrator.migrate(queue)
        let usableCount = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                      FROM background_capabilities AS capability
                      JOIN background_capability_bindings AS binding
                        ON binding.capability_id = capability.capability_id
                    """
            )
        }
        #expect(usableCount == 0)
    }

    @Test("binding facts are immutable while parent deletion still cascades")
    func immutableFactsAndRetentionDeletion() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: configuration)
        try DatabaseMigrator.harcHostMigrator().migrate(queue)

        let libraryID = "00000000-0000-0000-0000-000000000611"
        let uploadID = "00000000-0000-0000-0000-000000000612"
        let batchID = "00000000-0000-0000-0000-000000000613"
        let capabilityID = "00000000-0000-0000-0000-000000000614"
        let owner = Data(repeating: 0x63, count: 32)
        let authority = Data(repeating: 0x64, count: 32)
        let bodyHash = Data(repeating: 0x65, count: 32)

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO host_metadata (
                        singleton, library_id, host_authority_id, host_state_id,
                        control_port, upload_port,
                        highest_transport_set_epoch, exact_transport_set_bytes,
                        transport_set_object_sha256, leaf_retirement_floor,
                        security_registry_revision, created_at, updated_at
                    ) VALUES (1, ?, ?, ?, NULL, NULL, 1, ?, ?, 0, 0, 100, 100)
                    """,
                arguments: [
                    libraryID,
                    authority,
                    "00000000-0000-0000-0000-000000000615",
                    Data([0x01]),
                    Data(repeating: 0x66, count: 32),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO upload_batches (
                        batch_id, upload_id, owner_device_id, generation,
                        descriptor_json, body_sha256, body_length,
                        exact_ack_bytes, state, created_at, updated_at
                    ) VALUES (?, ?, ?, 1, ?, ?, 25, NULL, 'awaiting-upload', 100, 100)
                    """,
                arguments: [batchID, uploadID, owner, Data([0x01]), bodyHash]
            )
            try db.execute(
                sql: """
                    INSERT INTO background_capabilities (
                        capability_id, upload_id, batch_id, owner_device_id,
                        grant_id, grant_epoch, generation,
                        capability_binding_sha256, expires_at, invalidated_at,
                        state, created_at
                    ) VALUES (?, ?, ?, ?, ?, 1, 1, ?, 200, NULL, 'issued', 100)
                    """,
                arguments: [
                    capabilityID,
                    uploadID,
                    batchID,
                    owner,
                    "00000000-0000-0000-0000-000000000616",
                    Data(repeating: 0x67, count: 32),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO background_capability_bindings (
                        capability_id, binding_version, library_id,
                        host_authority_id, minimum_transport_set_epoch,
                        http_method, http_path, exact_body_sha256,
                        exact_body_length, byte_ceiling, issued_at, expires_at
                    ) VALUES (?, 1, ?, ?, 1, 'PUT', ?, ?, 25, 25, 100, 200)
                    """,
                arguments: [
                    capabilityID,
                    libraryID,
                    authority,
                    "/v1/uploads/\(uploadID)/batches/\(batchID)",
                    bodyHash,
                ]
            )
        }

        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE background_capability_bindings
                           SET http_method = 'POST'
                         WHERE capability_id = ?
                        """,
                    arguments: [capabilityID]
                )
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE upload_batches SET descriptor_json = ? WHERE batch_id = ?",
                    arguments: [Data([0x02]), batchID]
                )
            }
        }

        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM background_capabilities WHERE capability_id = ?",
                arguments: [capabilityID]
            )
        }
        let childCount = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM background_capability_bindings"
            )
        }
        #expect(childCount == 0)
    }
}
