import Foundation
import CryptoKit
import HarcCore
import GRDB
import HarcDomain

public extension RecordingStore {
    /// Moves Host processing into the transcribing state only while no
    /// compatible edge artifact has already won the recording.
    func beginHostProcessingIfNotReady(id: Int64) async throws -> Bool {
        let descriptor = try ProcessingDescriptor(state: .transcribing)
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(database, key: id) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            guard existing.processing != descriptor else { return true }
            let now = Date()
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET processing_state = ?, processing_failure_detail = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    descriptor.state.rawValue,
                    encodeStoredFailure(descriptor.failure),
                    now,
                    id,
                ]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: id,
                changedAt: now
            )
            return true
        }
    }

    /// Atomically installs a completed Host transcript only if an accepted
    /// edge artifact has not already made the recording ready.
    func stageHostProcessedTranscriptIfNotReady(
        recordingID: Int64,
        text: String,
        modelID: String,
        now: Date = Date()
    ) async throws -> Bool {
        try await stageHostProcessedTranscriptIfNotReady(recordingID: recordingID, text: text,
            modelID: modelID, structuredTranscriptData: nil, now: now)
    }

    func stageHostProcessedTranscriptIfNotReady(
        recordingID: Int64, text: String, modelID: String,
        structuredTranscriptData: Data?, now: Date = Date()
    ) async throws -> Bool {
        let stamp = try Self.transcriptionStamp(now)
        let processing = try ProcessingDescriptor(state: .projecting)
        let projection = try ProjectionDescriptor(state: .projecting)
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(
                database,
                key: recordingID
            ) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            // Publish immutable, content-addressed structured data before the
            // database can point to it. An edge winner returns above without
            // creating or replacing any Host sidecar.
            let jsonPath = try Self.publishStructuredTranscript(structuredTranscriptData, recording: existing)
            try Self.invalidateReplacedSpeakerAssignments(in: database, recording: existing,
                structuredTranscriptData: structuredTranscriptData, text: text, now: now)
            // Keep the prior evidence for publication comparison when the exact
            // artifact is retried. The projecting state prevents review, and the
            // artifact-change trigger removes bindings when the path changes.
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET transcript_text = ?, stt_model_id = ?, json_path = COALESCE(?, json_path),
                        transcribed_at = ?, chunks_indexed_at = NULL,
                        processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    text,
                    modelID,
                    jsonPath,
                    stamp,
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    now,
                    recordingID,
                ]
            )
            try database.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            return true
        }
    }

    /// Retire the previous generation before recognizing names for its replacement.
    /// Review remains unavailable while the transcript is still projecting.
    func stageHostSpeakerEvidenceIfNotReady(
        recordingID: Int64, expectedArtifactSHA256: Data, speakerEvidence: [Int: Data]
    ) async throws -> Bool {
        try await db.write { database in
            guard let recording = try Recording.fetchOne(database, key: recordingID) else { throw StoreError.notFound }
            guard recording.processing.state != .ready else { return false }
            guard recording.processing.state == .projecting,
                  let path = recording.jsonPath, expectedArtifactSHA256.count == 32,
                  try Self.speakerArtifactDigest(path: path) == expectedArtifactSHA256 else {
                throw StoreError.invalidData("Host speaker generation no longer matches the staged transcript")
            }
            try Self.installCurrentHostSpeakerEvidence(in: database, recording: recording, evidence: speakerEvidence)
            return true
        }
    }

    /// Publishes the current Host-derived projection and both ready states in
    /// one writer transaction. If edge processing became ready first, this
    /// method leaves its transcript and projection untouched.
    func publishHostProcessedProjectionIfNotReady(
        recordingID: Int64,
        speakerEvidence: [Int: Data] = [:],
        speakerOutcome: HostSpeakerProcessingOutcome? = nil,
        structuredTranscriptData: Data? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        let projection = ProjectionDescriptor.readyV1
        let processing = ProcessingDescriptor.ready
        let storedVersion = try Self.storedProjectionVersion(projection)
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(
                database,
                key: recordingID
            ) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            try Self.installCurrentHostSpeakerEvidence(in: database, recording: existing, evidence: speakerEvidence)
            if let speakerOutcome {
                guard let structuredTranscriptData else {
                    throw StoreError.invalidData("Host speaker completion requires the exact transcript")
                }
                try Self.validateHostSpeakerOutcome(in: database, recording: existing,
                    outcome: speakerOutcome, transcript: structuredTranscriptData)
            }
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    storedVersion,
                    now,
                    recordingID,
                ]
            )
            // A legacy caller cannot preserve a receipt for a newly published generation.
            try database.execute(sql: "DELETE FROM host_speaker_processing_outcome WHERE recording_id = ?",
                arguments: [recordingID])
            if let speakerOutcome {
                try database.execute(sql: "INSERT INTO host_speaker_processing_outcome VALUES (?, ?)",
                    arguments: [recordingID, try JSONEncoder().encode(speakerOutcome)])
            }
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            guard let refreshed = try Recording.fetchOne(
                database,
                key: recordingID
            ), OKFProjection.write(recording: refreshed) != nil else {
                throw StoreError.writeFailed(
                    "The Host processing projection could not be published."
                )
            }
            return true
        }
    }

    /// Installs a compatible edge transcript, ready states, revision, and OKF
    /// projection as one serialized canonical-library effect.
    func applyAcceptedEdgeTranscript(
        recordingID: Int64,
        text: String,
        modelID: String,
        now: Date = Date()
    ) async throws {
        try await applyAcceptedEdgeTranscript(recordingID: recordingID, text: text, modelID: modelID,
            structuredTranscriptData: nil, now: now)
    }

    func applyAcceptedEdgeTranscript(
        recordingID: Int64, text: String, modelID: String,
        structuredTranscriptData: Data?, clusterMap: SpeakerClusterMap? = nil,
        artifactSource: SelectedEdgeArtifactSource? = nil, now: Date = Date()
    ) async throws {
        let stamp = try Self.transcriptionStamp(now)
        let projection = ProjectionDescriptor.readyV1
        let processing = ProcessingDescriptor.ready
        let storedVersion = try Self.storedProjectionVersion(projection)
        try await db.write { database in
            guard let existing = try Recording.fetchOne(database, key: recordingID) else {
                throw StoreError.notFound
            }
            if let clusterMap {
                guard clusterMap.canonicalRecordingID == existing.canonicalID,
                      clusterMap.canonicalPCMHash == existing.canonicalPCMHash,
                      clusterMap.producerDeviceID == existing.originID?.deviceID,
                      let data = structuredTranscriptData,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["speakerClusterMapSHA256"] as? String == clusterMap.mappingSHA256.base64EncodedString() else {
                    throw StoreError.invalidData("Selected cluster map does not bind this recording and projection")
                }
            }
            if let artifactSource {
                guard artifactSource.bundleSHA256 == clusterMap?.processingArtifactSHA256 else {
                    throw StoreError.invalidData("Selected artifact source requires its matching cluster map")
                }
                try artifactSource.verifyFiles()
            }
            let jsonPath = try Self.publishStructuredTranscript(structuredTranscriptData, recording: existing)
            try Self.invalidateReplacedSpeakerAssignments(in: database, recording: existing,
                structuredTranscriptData: structuredTranscriptData, text: text, now: now)
            try database.execute(sql: "DELETE FROM current_speaker_evidence WHERE recording_id = ?", arguments: [recordingID])
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET transcript_text = ?, stt_model_id = ?, json_path = ?,
                        transcribed_at = ?, chunks_indexed_at = NULL,
                        processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    text,
                    modelID,
                    jsonPath,
                    stamp,
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    storedVersion,
                    now,
                    recordingID,
                ]
            )
            try database.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            try database.execute(sql: "DELETE FROM selected_speaker_cluster_map WHERE recording_id = ?", arguments: [recordingID])
            if let clusterMap, let data = structuredTranscriptData {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try database.execute(sql: """
                    INSERT INTO selected_speaker_cluster_map(recording_id, map_json, map_sha256, projection_sha256)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [recordingID, try encoder.encode(clusterMap), clusterMap.mappingSHA256,
                        Data(SHA256.hash(data: data))])
            }
            if let artifactSource {
                try database.execute(sql: """
                    INSERT INTO selected_edge_artifact_source(recording_id, signed_metadata_path, bundle_path,
                        signed_metadata_sha256, bundle_sha256) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [recordingID, artifactSource.signedMetadataURL.path, artifactSource.bundleURL.path,
                        artifactSource.signedMetadataSHA256, artifactSource.bundleSHA256])
            }
            guard let refreshed = try Recording.fetchOne(
                database,
                key: recordingID
            ), OKFProjection.write(recording: refreshed) != nil else {
                throw StoreError.writeFailed(
                    "The accepted edge projection could not be published."
                )
            }
        }
    }

    /// Numeric cluster IDs are scoped to one processing artifact. Preserve the
    /// prior assignment as history, never as an identity for a replacement cluster.
    static func invalidateReplacedSpeakerAssignments(in database: Database, recording: Recording,
        structuredTranscriptData: Data?, text: String, now: Date, force: Bool = false,
        clearMutableEmbeddings: Bool = true) throws {
        guard let id = recording.id else { throw StoreError.notFound }
        let priorData = try recording.jsonPath.flatMap { path -> Data? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let unchanged = structuredTranscriptData != nil
            ? priorData == structuredTranscriptData
            : priorData == nil && recording.transcriptText == text
        guard force || !unchanged else { return }
        let links = try Row.fetchAll(database, sql: """
            SELECT ps.speaker_index, ps.person_id, ps.confirmed_at, ps.is_user_confirmed,
                p.stable_uuid, p.display_name
            FROM person_speakers ps JOIN people p ON p.id = ps.person_id WHERE ps.recording_id = ?
            """, arguments: [id])
        if !links.isEmpty || !recording.speakerNames.isEmpty {
            let history: [String: Any] = [
                "names": Dictionary(uniqueKeysWithValues: recording.speakerNames.map { (String($0.key), $0.value) }),
                "links": links.map { row -> [String: Any] in
                    ["speakerIndex": row["speaker_index"] as Int, "personID": row["person_id"] as Int64,
                     "personUUID": row["stable_uuid"] as String, "personName": row["display_name"] as String,
                     "confirmedAt": row["confirmed_at"] as Double, "userConfirmed": row["is_user_confirmed"] as Int]
                }]
            let digest = priorData.map { Data(SHA256.hash(data: $0)) }
            try database.execute(sql: """
                INSERT INTO speaker_assignment_history(recording_id, recording_revision, artifact_sha256, assignments_json, archived_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, try recording.revision.signedInt64Value(), digest,
                    try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys]), now.timeIntervalSince1970])
        }
        try database.execute(sql: "DELETE FROM person_speakers WHERE recording_id = ?", arguments: [id])
        try database.execute(sql: "DELETE FROM pending_suggestions WHERE recording_id = ?", arguments: [id])
        try database.execute(sql: "DELETE FROM dismissed_suggestions WHERE recording_id = ?", arguments: [id])
        if clearMutableEmbeddings {
            try database.execute(sql: "DELETE FROM speaker_embeddings WHERE recording_id = ?", arguments: [id])
        }
        try database.execute(sql: "UPDATE recordings SET speaker_names = NULL WHERE id = ?", arguments: [id])
        _ = try Self.bumpSpeakerProfiles(in: database, personIDs: Set(links.map { $0["person_id"] as Int64 }),
            at: now.timeIntervalSince1970)
    }

    static func publishStructuredTranscript(_ data: Data?, recording: Recording, prefix: String = "host-transcript") throws -> String? {
        guard let data else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = URL(fileURLWithPath: recording.wavPath).deletingLastPathComponent()
            .appendingPathComponent(".harc-derived", isDirectory: true)
        try DurableFileIO.createDirectory(at: directory)
        let url = directory.appendingPathComponent("\(prefix)-\(digest).json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else {
                throw StoreError.writeFailed("The structured transcript path is occupied.")
            }
            try DurableFileIO.synchronizeFileAndParent(at: url)
        } else {
            try DurableFileIO.writeAtomically(data, to: url)
        }
        return url.path
    }

    /// Records a recoverable Host processing failure without regressing an
    /// edge artifact that became ready while Host work was in flight.
    func markHostProcessingFailureIfNotReady(
        recordingID: Int64,
        failure: ProcessingFailure,
        now: Date = Date()
    ) async throws -> Bool {
        let processing = try ProcessingDescriptor(
            state: .failedRecoverable,
            failure: failure
        )
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(
                database,
                key: recordingID
            ) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            let projection: ProjectionDescriptor
            if existing.projection.state == .projecting {
                projection = try ProjectionDescriptor(
                    state: .failedRecoverable,
                    failure: failure
                )
            } else {
                projection = existing.projection
            }
            let storedVersion = try Self.storedProjectionVersion(projection)
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    storedVersion,
                    now,
                    recordingID,
                ]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            return true
        }
    }
}

private extension RecordingStore {
    static func transcriptionStamp(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max) else {
            throw StoreError.invalidData("Transcription time is out of range")
        }
        return Int64(milliseconds.rounded(.down))
    }

    static func storedProjectionVersion(
        _ descriptor: ProjectionDescriptor
    ) throws -> Int64? {
        guard let version = descriptor.version else { return nil }
        guard let value = Int64(exactly: version.rawValue) else {
            throw StoreError.invalidData(
                "Projection version exceeds SQLite range"
            )
        }
        return value
    }
}
