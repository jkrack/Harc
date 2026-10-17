import CryptoKit
import Foundation
import GRDB
import HarcDomain

public extension RecordingStore {
    /// Publishes recognition-only review results for an unchanged Host artifact.
    /// Decisions must already be durable. False means a newer generation or
    /// review won; callers must reload instead of overwriting that winner.
    func replaceHostSpeakerProcessingOutcome(
        recordingID: Int64,
        expected: HostSpeakerProcessingOutcome,
        replacement: HostSpeakerProcessingOutcome,
        reviewJob: HostSpeakerReviewJob? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        try await db.write { database in
            if let reviewJob {
                guard reviewJob.recordingID == recordingID, reviewJob.expectedOutcome == expected,
                      let row = try Row.fetchOne(database,
                        sql: "SELECT * FROM host_speaker_review_queue WHERE recording_id = ?",
                        arguments: [recordingID]),
                      try Self.decodeHostSpeakerReviewJob(row) == reviewJob else { return false }
            }
            guard let recording = try Recording.fetchOne(database, key: recordingID),
                  recording.deletedAt == nil, recording.processing.state == .ready,
                  recording.projection.state == .ready,
                  let bytes = try Data.fetchOne(database,
                    sql: "SELECT outcome_json FROM host_speaker_processing_outcome WHERE recording_id = ?",
                    arguments: [recordingID]),
                  try JSONDecoder().decode(HostSpeakerProcessingOutcome.self, from: bytes) == expected else {
                return false
            }
            guard replacement.canonicalRecordingID == expected.canonicalRecordingID,
                  replacement.canonicalPCMHash == expected.canonicalPCMHash,
                  replacement.producerDeviceID == expected.producerDeviceID,
                  replacement.processingArtifactSHA256 == expected.processingArtifactSHA256,
                  replacement.diarization == expected.diarization,
                  replacement.clusters.map(\.speakerIndex) == expected.clusters.map(\.speakerIndex),
                  replacement.clusters.map(\.evidenceSHA256) == expected.clusters.map(\.evidenceSHA256) else {
                throw StoreError.invalidData("Speaker review cannot replace its transcript or voice evidence")
            }
            try Self.validateHostSpeakerOutcome(in: database, recording: recording, outcome: expected)
            try Self.validateHostSpeakerOutcome(in: database, recording: recording, outcome: replacement)
            // An exact retry is harmless, but must still revalidate retained bytes.
            guard replacement != expected else { return true }
            let revision = try Self.speakerRecognitionPackRevision(in: database)
            guard replacement.clusters.allSatisfy({ cluster in
                cluster.evidenceSHA256 == nil || cluster.recognitionPackRevision == revision
            }) else {
                throw StoreError.invalidData("Speaker review was evaluated against an outdated recognition pack")
            }
            try database.execute(sql:
                "UPDATE host_speaker_processing_outcome SET outcome_json = ? WHERE recording_id = ?",
                arguments: [try JSONEncoder().encode(replacement), recordingID])
            try Self.bumpRevisionAndAppendLibraryChange(in: database, recordingID: recordingID, changedAt: now)
            return true
        }
    }

    /// Local provenance only. Transport must separately authenticate the Host and
    /// bind this outcome to the adopted Library. A decision is not an accuracy claim.
    func hostSpeakerProcessingOutcome(recordingID: Int64) async throws -> HostSpeakerProcessingOutcome? {
        try await db.read { database in
            guard let recording = try Recording.fetchOne(database, key: recordingID),
                  recording.deletedAt == nil, recording.processing.state == .ready,
                  recording.projection.state == .ready,
                  let bytes = try Data.fetchOne(database,
                    sql: "SELECT outcome_json FROM host_speaker_processing_outcome WHERE recording_id = ?",
                    arguments: [recordingID]) else { return nil }
            let outcome = try JSONDecoder().decode(HostSpeakerProcessingOutcome.self, from: bytes)
            try Self.validateHostSpeakerOutcome(in: database, recording: recording, outcome: outcome)
            return outcome
        }
    }

    internal static func validateHostSpeakerOutcome(in database: Database, recording: Recording,
        outcome: HostSpeakerProcessingOutcome, transcript: Data? = nil) throws {
        guard let recordingID = recording.id, let path = recording.jsonPath,
              outcome.canonicalRecordingID == recording.canonicalID,
              outcome.canonicalPCMHash == recording.canonicalPCMHash,
              try speakerArtifactDigest(path: path) == outcome.processingArtifactSHA256,
              try selectedSpeakerClusterMap(in: database, recordingID: recordingID) == nil else {
            throw StoreError.invalidData("Host speaker outcome does not describe the selected Host generation")
        }
        // Revalidate inventory on reads too: a retained digest does not prove
        // that the persisted outcome still accounts for every transcript voice.
        // Hash the same bytes we decode, including when loading them from disk.
        let transcript = try transcript ?? Data(contentsOf: URL(fileURLWithPath: path))
        struct Inventory: Decodable {
            struct Speaker: Decodable { let speaker: UInt32 }
            let speakers: [Speaker]
        }
        let indices = Set(try JSONDecoder().decode(Inventory.self, from: transcript).speakers.map(\.speaker))
        guard Data(SHA256.hash(data: transcript)) == outcome.processingArtifactSHA256,
              indices == Set(outcome.clusters.map(\.speakerIndex)) else {
            throw StoreError.invalidData("Host speaker outcome must account for every transcript cluster")
        }
        let current = try Row.fetchAll(database,
            sql: "SELECT speaker_index, evidence_sha256 FROM current_speaker_evidence WHERE recording_id = ?",
            arguments: [recordingID])
        let expected = outcome.clusters.filter { $0.evidenceSHA256 != nil }
        guard current.count == expected.count else {
            throw StoreError.invalidData("Host speaker outcome has incomplete evidence coverage")
        }
        for cluster in expected {
            guard let digest = cluster.evidenceSHA256, let operationID = cluster.decisionOperationID,
                  current.contains(where: { ($0["speaker_index"] as Int64) == Int64(cluster.speakerIndex)
                    && ($0["evidence_sha256"] as Data) == digest }),
                  try Data.fetchOne(database,
                    sql: "SELECT evidence_sha256 FROM host_speaker_decision_provenance WHERE operation_uuid = ?",
                    arguments: [operationID.description]) == digest,
                  let snapshotBytes = try Data.fetchOne(database,
                    sql: "SELECT snapshot_json FROM speaker_evidence_snapshots WHERE evidence_sha256 = ?",
                    arguments: [digest]),
                  let decision = try Row.fetchOne(database,
                    sql: "SELECT * FROM speaker_embedding_observations WHERE operation_uuid = ?",
                    arguments: [operationID.description]) else {
                throw StoreError.invalidData("Host speaker outcome references missing evidence or an unfinished decision")
            }
            let evidence = try decodeSpeakerEvidence(snapshotBytes, expectedDigest: digest)
            let storedDecision = try JSONDecoder().decode(SpeakerObservationDecision.self, from: decision["result_json"])
            guard storedDecision.operationID == operationID,
                  storedDecision.disposition == cluster.disposition,
                  storedDecision.recognitionPackRevision == cluster.recognitionPackRevision,
                  evidence.producerDeviceID == outcome.producerDeviceID,
                  evidence.processingArtifactSHA256 == outcome.processingArtifactSHA256,
                  evidence.localClusterID == "host-speaker-\(cluster.speakerIndex)",
                  evidence.canonicalRecordingID == outcome.canonicalRecordingID,
                  evidence.canonicalPCMHash == outcome.canonicalPCMHash,
                  decision["canonical_recording_uuid"] as String == outcome.canonicalRecordingID.description,
                  decision["speaker_index"] as Int64 == Int64(cluster.speakerIndex),
                  decision["source_device_id"] as Data == recording.originID?.deviceID.rawBytes,
                  decision["model_id"] as String == evidence.modelID,
                  decision["dimensions"] as Int64 == Int64(evidence.embedding.dimensions),
                  decision["quantized_embedding"] as Data == evidence.embedding.values,
                  decision["quantization_scale"] as Double == Double(evidence.embedding.scale),
                  decision["speech_duration_ms"] as Int64 == Int64(exactly: evidence.speechDurationMs),
                  decision["segment_count"] as Int64 == Int64(evidence.segmentCount) else {
                throw StoreError.invalidData("Host speaker decision does not match its claimed voice evidence")
            }
        }
    }
}
