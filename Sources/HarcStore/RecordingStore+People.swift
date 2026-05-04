import Foundation
import GRDB

public extension RecordingStore {

    // MARK: - Group A: createPerson + fetchPeople

    func createPerson(displayName: String, matchThreshold: Double? = nil) async throws -> Int64 {
        try await db.write { database in
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                    INSERT INTO people (display_name, match_threshold, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [displayName, matchThreshold, now, now]
            )
            return database.lastInsertedRowID
        }
    }

    func fetchPeople() async throws -> [Person] {
        try await db.read { database in
            try Self.fetchPeople(db: database)
        }
    }

    static func fetchPeople(db database: Database) throws -> [Person] {
        let rows = try Row.fetchAll(database, sql: """
            SELECT id, display_name, match_threshold, created_at, updated_at
            FROM people
            ORDER BY display_name COLLATE NOCASE
            """)
        return rows.map { row in
            Person(
                id: row["id"],
                displayName: row["display_name"],
                matchThreshold: row["match_threshold"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    // MARK: - Group B: renamePerson + deletePerson

    func renamePerson(id: Int64, to newName: String) async throws {
        try await db.write { database in
            try database.execute(
                sql: "UPDATE people SET display_name = ?, updated_at = ? WHERE id = ?",
                arguments: [newName, Date().timeIntervalSince1970, id]
            )
        }
    }

    func deletePerson(id: Int64) async throws {
        try await db.write { database in
            try database.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Group C: linkSpeaker + unlinkSpeaker + fetchPersonSpeakerLinks

    func linkSpeaker(personID: Int64, recordingID: Int64, speakerIndex: Int) async throws {
        try await db.write { database in
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO person_speakers
                        (person_id, recording_id, speaker_index, confirmed_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [personID, recordingID, speakerIndex, Date().timeIntervalSince1970]
            )
        }
    }

    func unlinkSpeaker(recordingID: Int64, speakerIndex: Int) async throws {
        try await db.write { database in
            try database.execute(
                sql: """
                    DELETE FROM person_speakers
                    WHERE recording_id = ? AND speaker_index = ?
                    """,
                arguments: [recordingID, speakerIndex]
            )
        }
    }

    func fetchPersonSpeakerLinks(recordingID: Int64) async throws -> [PersonSpeakerLink] {
        try await db.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT person_id, recording_id, speaker_index, confirmed_at
                FROM person_speakers
                WHERE recording_id = ?
                """, arguments: [recordingID])
            return rows.map { row in
                PersonSpeakerLink(
                    personID: row["person_id"],
                    recordingID: row["recording_id"],
                    speakerIndex: row["speaker_index"],
                    confirmedAt: Date(timeIntervalSince1970: row["confirmed_at"])
                )
            }
        }
    }
}
