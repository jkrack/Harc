import Foundation
import GRDB
import HarcDomain

public extension RecordingStore {
    /// Returns only a current, ready projection's checked artifact-scoped map.
    /// RPC admission must resolve this again in its mutation transaction.
    func selectedSpeakerClusterMap(recordingID: Int64) async throws -> SpeakerClusterMap? {
        try await db.read { database in
            try Self.selectedSpeakerClusterMap(in: database, recordingID: recordingID)
        }
    }

    internal static func selectedSpeakerClusterMap(in database: Database, recordingID: Int64) throws -> SpeakerClusterMap? {
        guard let recording = try Recording.fetchOne(database, key: recordingID),
              recording.deletedAt == nil, recording.processing.state == .ready,
              recording.projection.state == .ready,
              let row = try Row.fetchOne(database,
                sql: "SELECT * FROM selected_speaker_cluster_map WHERE recording_id = ?",
                arguments: [recordingID]) else { return nil }
        let map = try JSONDecoder().decode(SpeakerClusterMap.self, from: row["map_json"])
        guard map.mappingSHA256 == row["map_sha256"] as Data,
              map.canonicalRecordingID == recording.canonicalID,
              map.canonicalPCMHash == recording.canonicalPCMHash,
              map.producerDeviceID == recording.originID?.deviceID,
              let path = recording.jsonPath,
              try Self.speakerArtifactDigest(path: path) == row["projection_sha256"] as Data else {
            throw StoreError.invalidData("Selected speaker cluster map or projection binding changed")
        }
        return map
    }
}

internal extension RecordingStore {
    /// Install one authenticated edge voice without disturbing other speakers.
    /// The caller owns the same transaction as selection checks and the decision.
    static func installCurrentEdgeSpeakerEvidence(in database: Database, recording: Recording,
        speakerIndex: UInt32, evidence: SpeakerEvidenceSnapshot, at date: Date) throws -> Bool {
        guard let id = recording.id, let index = Int(exactly: speakerIndex) else { throw StoreError.notFound }
        let previous = try Data.fetchOne(database, sql:
            "SELECT evidence_sha256 FROM current_speaker_evidence WHERE recording_id = ? AND speaker_index = ?",
            arguments: [id, speakerIndex])
        guard previous != evidence.evidenceSHA256 else { return false }
        let links = try Row.fetchAll(database, sql: """
            SELECT ps.person_id, ps.confirmed_at, ps.is_user_confirmed, p.stable_uuid, p.display_name
            FROM person_speakers ps JOIN people p ON p.id = ps.person_id
            WHERE ps.recording_id = ? AND ps.speaker_index = ?
            """, arguments: [id, speakerIndex])
        if !links.isEmpty || recording.speakerNames[index] != nil {
            let names = recording.speakerNames[index].map { [String(index): $0] } ?? [:]
            let history: [String: Any] = ["names": names, "links": links.map { row -> [String: Any] in
                ["speakerIndex": index, "personID": row["person_id"] as Int64,
                 "personUUID": row["stable_uuid"] as String, "personName": row["display_name"] as String,
                 "confirmedAt": row["confirmed_at"] as Double, "userConfirmed": row["is_user_confirmed"] as Int]
            }]
            try database.execute(sql: """
                INSERT INTO speaker_assignment_history(recording_id, recording_revision, artifact_sha256, assignments_json, archived_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, try recording.revision.signedInt64Value(),
                    try recording.jsonPath.map { try speakerArtifactDigest(path: $0) },
                    try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys]), date.timeIntervalSince1970])
        }
        for table in ["person_speakers", "pending_suggestions", "dismissed_suggestions", "speaker_embeddings"] {
            try database.execute(sql: "DELETE FROM \(table) WHERE recording_id = ? AND speaker_index = ?",
                arguments: [id, speakerIndex])
        }
        var names = recording.speakerNames
        names.removeValue(forKey: index)
        let json = try JSONSerialization.data(withJSONObject:
            Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }), options: [.sortedKeys])
        try database.execute(sql: "UPDATE recordings SET speaker_names = ? WHERE id = ?",
            arguments: [String(data: json, encoding: .utf8), id])
        try database.execute(sql: """
            INSERT INTO current_speaker_evidence(recording_id, speaker_index, evidence_sha256) VALUES (?, ?, ?)
            ON CONFLICT(recording_id, speaker_index) DO UPDATE SET evidence_sha256 = excluded.evidence_sha256
            """, arguments: [id, speakerIndex, evidence.evidenceSHA256])
        _ = try Self.bumpSpeakerProfiles(in: database, personIDs: Set(links.map { $0["person_id"] as Int64 }),
            at: date.timeIntervalSince1970)
        _ = try Self.bumpRevisionAndAppendLibraryChange(in: database, recordingID: id, changedAt: date)
        return true
    }
}
