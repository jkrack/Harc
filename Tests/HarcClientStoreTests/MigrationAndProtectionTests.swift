import Foundation
import GRDB
import Testing
@testable import HarcClientStore

@Suite("HarcClientStore migrations and storage boundaries")
struct MigrationAndProtectionTests {
    @Test("Foundation availability probes can distinguish storage policies")
    func policyAwareProtectedDataProbe() {
        let attributes = FoundationClientStoreStorageAttributes { policy in
            policy == .transfer
        }
        #expect(attributes.isProtectedDataAvailable(for: .transfer))
        #expect(!attributes.isProtectedDataAvailable(for: .libraryCache))
    }

    @Test("fresh stores create separate purpose-limited schemas")
    func freshAndSeparated() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let locations = try ClientStoreLocations(rootDirectory: root)

        let transfer = try HarcTransferStore(
            databaseURL: locations.transferDatabase,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        let cache = try HarcLibraryCache(
            databaseURL: locations.libraryCacheDatabase,
            storageAttributes: attributes
        )

        #expect(transfer.databaseURL != cache.databaseURL)
        #expect(
            transfer.databaseURL.deletingLastPathComponent()
                != cache.databaseURL.deletingLastPathComponent()
        )
        #expect(throws: ClientStoreError.self) {
            try HarcLibraryCache(
                databaseURL: locations.transferDatabase,
                storageAttributes: attributes
            )
        }
        #expect(FileManager.default.fileExists(atPath: transfer.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: cache.databaseURL.path))

        let transferTables = try tableNames(at: transfer.databaseURL)
        let cacheTables = try tableNames(at: cache.databaseURL)
        #expect(transferTables.contains("trust_namespaces"))
        #expect(transferTables.contains("finalized_captures"))
        #expect(transferTables.contains("background_task_mappings"))
        #expect(transferTables.contains("upload_attempt_supersessions"))
        #expect(transferTables.contains("verified_recording_receipts"))
        #expect(transferTables.contains("upload_begin_intents"))
        #expect(transferTables.contains("cleanup_intents"))
        #expect(!transferTables.contains("cached_recordings"))
        #expect(!transferTables.contains("offline_metadata_mutations"))
        #expect(cacheTables.contains("cache_cursor"))
        #expect(cacheTables.contains("cached_recordings"))
        #expect(cacheTables.contains("cached_tombstones"))
        #expect(cacheTables.contains("offline_metadata_mutations"))
        #expect(!cacheTables.contains("trust_namespaces"))
        #expect(!cacheTables.contains("upload_batches"))

        let cacheColumns = try allColumnNames(at: cache.databaseURL)
        #expect(!cacheColumns.contains { $0.localizedCaseInsensitiveContains("path") })
        #expect(!cacheColumns.contains { $0.localizedCaseInsensitiveContains("url") })

        let transferSchema = try schemaSQL(at: transfer.databaseURL).lowercased()
        #expect(!transferSchema.contains("transcript"))
        #expect(!transferSchema.contains("speaker_text"))
        #expect(!transferSchema.contains("summary_markdown"))

        let policies = Set(attributes.events.map(\.policy))
        #expect(policies.contains(.transfer))
        #expect(policies.contains(.libraryCache))
        #expect(attributes.events.contains { event in
            if case .database(let url) = event.artifact {
                return url == locations.transferDatabase
            }
            return false
        })
        #expect(attributes.events.contains { event in
            if case .database(let url) = event.artifact {
                return url == locations.libraryCacheDatabase
            }
            return false
        })
    }

    @Test("seeded pre-v1 databases preserve data and migrations are idempotent")
    func seededUpgradeAndIdempotency() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locations = try ClientStoreLocations(rootDirectory: root)

        for url in [locations.transferDatabase, locations.libraryCacheDatabase] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let seed = try DatabaseQueue(path: url.path)
            try seed.write { db in
                try db.execute(sql: "CREATE TABLE pre_v1_seed (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO pre_v1_seed(id, value) VALUES (1, 'preserve-me')")
            }
        }

        let attributes = RecordingStorageAttributes()
        do {
            _ = try HarcTransferStore(
                databaseURL: locations.transferDatabase,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
            _ = try HarcLibraryCache(
                databaseURL: locations.libraryCacheDatabase,
                storageAttributes: attributes
            )
        }
        // Reopening applies the same migrators again as a no-op.
        do {
            _ = try HarcTransferStore(
                databaseURL: locations.transferDatabase,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
            _ = try HarcLibraryCache(
                databaseURL: locations.libraryCacheDatabase,
                storageAttributes: attributes
            )
        }

        for url in [locations.transferDatabase, locations.libraryCacheDatabase] {
            let db = try DatabaseQueue(path: url.path)
            let value = try db.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM pre_v1_seed WHERE id = 1")
            }
            #expect(value == "preserve-me")
            let migrationCount = try db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")
            }
            #expect(migrationCount == (url == locations.transferDatabase ? 4 : 1))
        }
    }

    @Test("v2 cleanup intents migrate without becoming deletion eligible")
    func v2CleanupIntentMigration() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = try ClientStoreLocations(rootDirectory: root)
        try FileManager.default.createDirectory(
            at: locations.transferDirectory,
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: locations.transferDatabase.path)
        try ClientStoreMigrators.transfer().migrate(
            queue,
            upTo: "v2_upload_attempt_supersession_proof"
        )
        let origin = ClientStoreFixtures.origin()
        let requestedAtMS = try ClientStoreCoding.milliseconds(
            ClientStoreFixtures.baseDate
        )
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO finalized_captures (
                        origin_device_id, origin_recording_uuid,
                        finalized_capture_json, master_path,
                        master_file_state, persisted_at_ms
                    ) VALUES (?, ?, ?, ?, 'present', ?)
                    """,
                arguments: [
                    origin.deviceID.rawBytes,
                    origin.recordingUUID.uuidString.lowercased(),
                    try ClientStoreCoding.encode(
                        ClientStoreFixtures.capture(origin: origin)
                    ),
                    root.appendingPathComponent("master.wav").path,
                    requestedAtMS,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO cleanup_intents (
                        origin_device_id, origin_recording_uuid,
                        requested_at_ms, state, verified_receipt_sha256
                    ) VALUES (?, ?, ?, 'awaitingVerifiedReceipt', NULL)
                    """,
                arguments: [
                    origin.deviceID.rawBytes,
                    origin.recordingUUID.uuidString.lowercased(),
                    requestedAtMS,
                ]
            )
        }

        let upgraded = try HarcTransferStore(
            databaseURL: locations.transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        let intent = try #require(try upgraded.cleanupIntent(for: origin))
        #expect(intent.requestedAt == ClientStoreFixtures.baseDate)
        #expect(intent.state == .awaitingVerifiedReceipt)
        #expect(!intent.isEligible)
        #expect(try tableNames(at: locations.transferDatabase).contains(
            "verified_recording_receipts"
        ))

        // A receipt-shaped digest alone still cannot cross the migrated gate.
        #expect(throws: DatabaseError.self) {
            try upgraded.database.queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE cleanup_intents
                        SET state = 'eligible', verified_receipt_sha256 = ?
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                        """,
                    arguments: [
                        ClientStoreFixtures.bytes(0xCC),
                        origin.deviceID.rawBytes,
                        origin.recordingUUID.uuidString.lowercased(),
                    ]
                )
            }
        }
        #expect(try upgraded.cleanupIntent(for: origin)?.isEligible == false)
    }

    @Test("WAL stores retain FULL synchronous durability across reopen")
    func fullSynchronousDurabilityAcrossReopen() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()

        for pass in 0..<2 {
            let transfer = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
            let cache = try HarcLibraryCache(
                rootDirectory: root,
                storageAttributes: attributes
            )

            #expect(try synchronousMode(of: transfer.database) == 2, "transfer pass \(pass)")
            #expect(try synchronousMode(of: cache.database) == 2, "cache pass \(pass)")
        }
    }

    @Test("protected-data unavailability performs no filesystem mutation")
    func unavailableAtOpenIsNonDestructive() throws {
        let root = temporaryClientStoreDirectory()
        let locations = try ClientStoreLocations(rootDirectory: root)
        let attributes = RecordingStorageAttributes(available: false)

        #expect(throws: ClientStoreError.self) {
            try HarcTransferStore(
                databaseURL: locations.transferDatabase,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
        }
        #expect(throws: ClientStoreError.self) {
            try HarcLibraryCache(
                databaseURL: locations.libraryCacheDatabase,
                storageAttributes: attributes
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(attributes.events.isEmpty)
    }

    @Test("protected-data loss after open blocks reconciliation before inspection")
    func unavailableAfterOpenBlocksReconciliation() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        let origin = ClientStoreFixtures.origin()
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        let inspector = StubArtifactInspector(existingURLs: [])
        attributes.setAvailable(false)

        #expect(throws: ClientStoreError.self) {
            try store.reconcileLocalArtifacts(inspector: inspector)
        }
        #expect(inspector.inspectedPaths.isEmpty)

        attributes.setAvailable(true)
        let outbox = try #require(try store.recordingOutbox(for: origin))
        #expect(outbox.finalizedCapture.masterFileState == .present)
        #expect(outbox.stateMachine.state == .localOnly)
    }

    private func tableNames(at url: URL) throws -> Set<String> {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
        }
    }

    private func synchronousMode(of database: ClientStoreDatabase) throws -> Int {
        try database.queue.read { db in
            let mode = try Int.fetchOne(db, sql: "PRAGMA synchronous")
            return try #require(mode)
        }
    }

    private func allColumnNames(at url: URL) throws -> [String] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
            return try tables.flatMap { table in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
            }
        }
    }

    private func schemaSQL(at url: URL) throws -> String {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL"
            ).joined(separator: "\n")
        }
    }
}
