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
}
