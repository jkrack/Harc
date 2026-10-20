import Foundation
import CryptoKit
import GRDB
import HarcDomain
import HarcCore

public extension RecordingStore {
    /// Identity-loss detection must include superseded local generations.
    func hasLocalSpeakerEvidence() async throws -> Bool {
        try await db.read { database in
            try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM speaker_evidence_snapshots
                    WHERE json_extract(CAST(snapshot_json AS TEXT), '$.localClusterID') LIKE 'local-speaker-%')
                """) == true
        }
    }

    /// Publishes a generation prepared by the trusted local pipeline. The caller
    /// supplies canonical audio inspected from its protected master and exact
    /// snapshots derived from these transcript bytes, never peer-claimed data.
    func publishLocalSpeakerGeneration(recordingID: Int64, expectedRevision: EntityRevision,
        expectedArtifactSHA256: Data?, canonicalPCMHash: CanonicalPCMHash, canonicalFrames: UInt64,
        structuredTranscriptData: Data, snapshots: [SpeakerEvidenceSnapshot],
        transcriptText: String? = nil, transcriptionModelID: String? = nil) async throws {
        guard canonicalFrames > 0, let frames = Int64(exactly: canonicalFrames),
              !structuredTranscriptData.isEmpty else { throw StoreError.invalidData("Invalid local generation") }
        guard (transcriptText == nil) == (transcriptionModelID == nil) else {
            throw StoreError.invalidData("Transcript text and model provenance must publish together")
        }
        let document = try JSONDecoder().decode(LocalSpeakerPublicationDocument.self, from: structuredTranscriptData)
        if let transcriptText, document.joinedText != transcriptText {
            throw StoreError.invalidData("The published text differs from its structured transcript")
        }
        if let transcriptionModelID, transcriptionModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StoreError.invalidData("Missing transcription model provenance")
        }
        var durations: [Int: UInt64] = [:]
        var ends: [Int: Int] = [:]
        for turn in document.speakers.sorted(by: { $0.startMs < $1.startMs }) {
            guard turn.speaker >= 0, turn.startMs >= 0, turn.endMs > turn.startMs,
                  UInt64(turn.endMs) <= canonicalFrames / 16,
                  (ends[turn.speaker] ?? 0) <= turn.startMs else {
                throw StoreError.invalidData("Invalid local speaker publication timeline")
            }
            let total = (durations[turn.speaker] ?? 0).addingReportingOverflow(UInt64(turn.endMs - turn.startMs))
            guard !total.overflow else { throw StoreError.invalidData("Speaker duration overflow") }
            durations[turn.speaker] = total.partialValue
            ends[turn.speaker] = turn.endMs
        }
        let speechDurations = durations
        guard Set(snapshots.map(\.producerDeviceID)).count <= 1 else {
            throw StoreError.invalidData("A local speaker generation must have one producer")
        }
        let artifact = Data(SHA256.hash(data: structuredTranscriptData))
        try await db.write { database in
            guard let existing = try Recording.fetchOne(database, key: recordingID), existing.deletedAt == nil,
                  existing.revision == expectedRevision else {
                throw StoreError.invalidData("The recording changed while identifying speakers")
            }
            let previousArtifact = try existing.jsonPath.map { try Self.speakerArtifactDigest(path: $0) }
            guard previousArtifact == expectedArtifactSHA256,
                  existing.canonicalPCMHash == nil || existing.canonicalPCMHash == canonicalPCMHash,
                  existing.canonicalPCMFrames == nil || existing.canonicalPCMFrames == canonicalFrames else {
                throw StoreError.canonicalArtifactIdentityMismatch
            }
            var indices = Set<Int>()
            var retained: [(Int, SpeakerEvidenceSnapshot, Data)] = []
            for snapshot in snapshots {
                guard snapshot.canonicalRecordingID == existing.canonicalID,
                      snapshot.canonicalPCMHash == canonicalPCMHash,
                      snapshot.processingArtifactSHA256 == artifact,
                      snapshot.localClusterID.hasPrefix("local-speaker-"),
                      let index = Int(snapshot.localClusterID.dropFirst("local-speaker-".count)), index >= 0,
                      snapshot.localClusterID == "local-speaker-\(index)", indices.insert(index).inserted,
                      let available = speechDurations[index], snapshot.speechDurationMs <= available else {
                    throw StoreError.invalidData("Local speaker evidence does not match its publication")
                }
                let bytes = try JSONEncoder().encode(snapshot)
                _ = try Self.decodeSpeakerEvidence(bytes, expectedDigest: snapshot.evidenceSHA256)
                retained.append((index, snapshot, bytes))
            }
            let now = Date()
            let links = try Row.fetchAll(database, sql: """
                SELECT ps.speaker_index, ps.person_id, ps.confirmed_at, ps.is_user_confirmed,
                    p.stable_uuid, p.display_name
                FROM person_speakers ps JOIN people p ON p.id = ps.person_id WHERE ps.recording_id = ?
                """, arguments: [recordingID])
            let oldMap = try Row.fetchAll(database, sql:
                "SELECT speaker_index, evidence_sha256 FROM current_speaker_evidence WHERE recording_id = ?",
                arguments: [recordingID])
            let unchanged = oldMap.count == retained.count && retained.allSatisfy { index, snapshot, _ in
                oldMap.contains { $0["speaker_index"] as Int == index && $0["evidence_sha256"] as Data == snapshot.evidenceSHA256 }
            }
            let replaced = previousArtifact != artifact || !unchanged
            if replaced && (!links.isEmpty || !existing.speakerNames.isEmpty) {
                let history: [String: Any] = [
                    "names": Dictionary(uniqueKeysWithValues: existing.speakerNames.map { (String($0.key), $0.value) }),
                    "links": links.map { row -> [String: Any] in
                        ["speakerIndex": row["speaker_index"] as Int, "personID": row["person_id"] as Int64,
                         "personUUID": row["stable_uuid"] as String, "personName": row["display_name"] as String,
                         "confirmedAt": row["confirmed_at"] as Double, "userConfirmed": row["is_user_confirmed"] as Int]
                    }]
                try database.execute(sql: """
                    INSERT INTO speaker_assignment_history(recording_id, recording_revision, artifact_sha256, assignments_json, archived_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [recordingID, try existing.revision.signedInt64Value(), previousArtifact,
                        try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys]), now.timeIntervalSince1970])
                try database.execute(sql: "DELETE FROM person_speakers WHERE recording_id = ?", arguments: [recordingID])
            }
            if replaced {
                try database.execute(sql: "DELETE FROM pending_suggestions WHERE recording_id = ?", arguments: [recordingID])
                try database.execute(sql: "DELETE FROM dismissed_suggestions WHERE recording_id = ?", arguments: [recordingID])
            }
            let path = try Self.publishStructuredTranscript(structuredTranscriptData, recording: existing, prefix: "local-transcript")
            try database.execute(sql: """
                UPDATE recordings SET json_path = ?, canonical_pcm_sha256 = ?, canonical_pcm_frames = ?,
                    speaker_names = CASE WHEN ? THEN NULL ELSE speaker_names END,
                    processing_state = 'ready', processing_failure_detail = NULL,
                    projection_state = 'ready', projection_failure_detail = NULL, projection_version = 1, updated_at = ?
                WHERE id = ?
                """, arguments: [path, canonicalPCMHash.rawBytes, frames, replaced, now, recordingID])
            if let transcriptText, let transcriptionModelID {
                try database.execute(sql: """
                    UPDATE recordings SET transcript_text = ?, stt_model_id = ?, transcribed_at = ?, chunks_indexed_at = NULL
                    WHERE id = ?
                    """, arguments: [transcriptText, transcriptionModelID, Int64(now.timeIntervalSince1970 * 1000), recordingID])
                try database.execute(sql: "DELETE FROM transcript_chunks WHERE recording_id = ?", arguments: [recordingID])
            }
            try database.execute(sql: "DELETE FROM current_speaker_evidence WHERE recording_id = ?", arguments: [recordingID])
            try database.execute(sql: "DELETE FROM speaker_embeddings WHERE recording_id = ?", arguments: [recordingID])
            for (index, snapshot, bytes) in retained {
                guard let duration = Int64(exactly: snapshot.speechDurationMs) else {
                    throw StoreError.invalidData("Speaker duration exceeds storage bounds")
                }
                try database.execute(sql: """
                    INSERT INTO speaker_embeddings(prototype_uuid, recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [SpeakerPrototypeID.random().description, recordingID, index,
                        Self.encodeFloat32(snapshot.embedding.dequantized), Int64(snapshot.segmentCount), duration, snapshot.modelID])
                try database.execute(sql: """
                    INSERT OR IGNORE INTO speaker_evidence_snapshots(evidence_sha256, recording_id, snapshot_json, retained_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [snapshot.evidenceSHA256, recordingID, bytes, now.timeIntervalSince1970])
                guard let row = try Row.fetchOne(database, sql: "SELECT recording_id, snapshot_json FROM speaker_evidence_snapshots WHERE evidence_sha256 = ?",
                    arguments: [snapshot.evidenceSHA256]), row["recording_id"] as Int64 == recordingID,
                    try Self.decodeSpeakerEvidence(row["snapshot_json"], expectedDigest: snapshot.evidenceSHA256) == snapshot else {
                    throw StoreError.invalidData("Retained local evidence conflicts with publication")
                }
                try database.execute(sql: "INSERT INTO current_speaker_evidence VALUES (?, ?, ?)",
                    arguments: [recordingID, index, snapshot.evidenceSHA256])
            }
            try database.execute(sql: "INSERT OR IGNORE INTO bound_speaker_enrollment_sources VALUES (?)", arguments: [recordingID])
            _ = try Self.bumpSpeakerProfiles(in: database, personIDs: Set(links.map { $0["person_id"] as Int64 }), at: now.timeIntervalSince1970)
            _ = try Self.bumpRevisionAndAppendLibraryChange(in: database, recordingID: recordingID, changedAt: now)
        }
        await reprojectOKF(id: recordingID)
    }
}

private struct LocalSpeakerPublicationDocument: Decodable {
    let joinedText: String
    let speakers: [SpeakerSegment]
}
