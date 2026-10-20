import Foundation
import XCTest
import GRDB
@testable import HarcStore

final class SpeakerConfirmationMigrationTests: XCTestCase {
    func test_oldAutomaticAssignmentsAreExcludedButLaterConfirmationsSurvive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harc-confirmation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        let migrator = DatabaseMigrator.harcMigrator()
        try migrator.migrate(queue, upTo: "v19_capture_integrity")
        try queue.write { db in
            let person = UUID().uuidString.lowercased()
            try db.execute(sql: """
                INSERT INTO people (id, display_name, created_at, updated_at, stable_uuid, profile_revision)
                VALUES (1, 'Alice', 100, 100, ?, 1)
                """, arguments: [person])
            for index in 0..<3 {
                let recording = Recording(wavPath: "/tmp/migration-\(index).wav", txtPath: nil,
                    jsonPath: nil, startedAt: Date(), endedAt: Date(), transcriptText: nil)
                try recording.insert(db)
                try db.execute(sql: """
                    INSERT INTO person_speakers(person_id,recording_id,speaker_index,confirmed_at)
                    VALUES(1,?,0,?)
                    """, arguments: [db.lastInsertedRowID, index == 2 ? 101 : 100])
                if index > 0 {
                    try db.execute(sql: """
                        INSERT INTO speaker_embedding_observations(
                          operation_uuid,request_sha256,canonical_recording_uuid,speaker_index,
                          source_device_id,model_id,dimensions,quantized_embedding,quantization_scale,
                          segment_count,speech_duration_ms,disposition,decided_person_uuid,
                          decided_score,received_at,result_json)
                        VALUES(?,zeroblob(32),?,0,zeroblob(32),'test',1,x'01',1,1,1000,'matched',?,0.9,100,x'00')
                        """, arguments: [UUID().uuidString.lowercased(),recording.canonicalID.description,person])
                }
            }
        }
        try migrator.migrate(queue)
        let snapshot = try queue.read { db in
            (
                try Int.fetchAll(db, sql: "SELECT is_user_confirmed FROM person_speakers ORDER BY recording_id"),
                try Int.fetchOne(db, sql: "SELECT pack_revision FROM speaker_identity_metadata"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_observations")
            )
        }
        XCTAssertEqual(snapshot.0, [1, 0, 1])
        // v20 excludes inferred enrollment; v27 invalidates pre-publication packs.
        XCTAssertEqual(snapshot.1, 3)
        XCTAssertEqual(snapshot.2, 2)
        try migrator.migrate(queue)
        let again = try queue.read { try Int.fetchOne($0, sql: "SELECT pack_revision FROM speaker_identity_metadata") }
        XCTAssertEqual(again, 3)
        let reopened = try DatabaseQueue(path: path)
        let flags = try reopened.read { try Int.fetchAll($0,
            sql: "SELECT is_user_confirmed FROM person_speakers ORDER BY recording_id") }
        XCTAssertEqual(flags, [1, 0, 1])
    }
}
