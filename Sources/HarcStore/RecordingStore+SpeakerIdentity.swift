import CryptoKit
import Foundation
import GRDB
import HarcDomain

public extension RecordingStore {
    static let defaultSpeakerMatchThreshold = 0.65

    /// Builds an uncached recognition snapshot for local evaluation and diagnostics.
    /// Network publication must use publishedSpeakerRecognitionPack so validity
    /// dates cannot change under an existing client-visible revision.
    func speakerRecognitionPack(
        modelID: String = "wespeaker_v2",
        dimensions: UInt32 = 256,
        maximumPrototypesPerPerson: Int = 3,
        lifetime: TimeInterval = 7 * 24 * 60 * 60,
        at generatedAt: Date = Date()
    ) async throws -> SpeakerRecognitionPack {
        guard maximumPrototypesPerPerson > 0 else {
            throw StoreError.invalidData("A recognition pack must allow at least one prototype")
        }
        let snapshot = try await db.read { database -> (EntityRevision, [SpeakerIdentityProfile]) in
            try Self.recognitionSnapshot(in: database, modelID: modelID,
                dimensions: dimensions, maximumPrototypesPerPerson: maximumPrototypesPerPerson)
        }
        return try SpeakerRecognitionPack(
            revision: snapshot.0,
            modelID: modelID,
            dimensions: dimensions,
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(lifetime),
            profiles: snapshot.1
        )
    }

    private static func recognitionSnapshot(
        in database: Database, modelID: String, dimensions: UInt32,
        maximumPrototypesPerPerson: Int
    ) throws -> (EntityRevision, [SpeakerIdentityProfile]) {
        let revision = try Self.speakerRecognitionPackRevision(in: database)
        let people = try Self.fetchPeople(db: database).sorted { $0.stableID < $1.stableID }
        let confirmedSnapshots = try Self.confirmedSpeakerEvidence(in: database, modelID: modelID, dimensions: dimensions)
        let profiles = try people.map { person in
            var candidates: [(SpeakerPrototypeID, Data, Int, Int, String)] = []
            for selected in confirmedSnapshots where selected.personID == person.id {
                let evidence = selected.snapshot
                candidates.append((selected.prototypeID, Self.encodeFloat32(evidence.embedding.dequantized),
                    Int(evidence.segmentCount), Int(evidence.speechDurationMs),
                    "bound:\(evidence.evidenceSHA256.base64EncodedString())"))
            }
            let localRows = try Row.fetchAll(database, sql: """
                SELECT e.prototype_uuid, e.embedding, e.segment_count, e.total_ms,
                       e.recording_id AS evidence_recording_id, e.speaker_index
                FROM speaker_embeddings e
                JOIN person_speakers ps
                  ON ps.recording_id = e.recording_id
                 AND ps.speaker_index = e.speaker_index
                WHERE ps.is_user_confirmed = 1 AND NOT EXISTS (
                    SELECT 1 FROM bound_speaker_enrollment_sources b WHERE b.recording_id = ps.recording_id)
                   AND ps.person_id = ? AND e.embedder_kind = ?
                ORDER BY e.total_ms DESC, e.segment_count DESC, e.prototype_uuid ASC
                """, arguments: [person.id, modelID])
            for row in localRows {
                guard let uuid = UUID(uuidString: row["prototype_uuid"] as String) else { continue }
                candidates.append((
                    SpeakerPrototypeID(uuid),
                    row["embedding"],
                    row["segment_count"],
                    row["total_ms"],
                    "\(row["evidence_recording_id"] as Int64):\(row["speaker_index"] as Int64)"
                ))
            }

            // Historical decisions remain immutable provenance. Recognition
            // evidence follows the current assignment so corrections and
            // unlinking take effect in both packs and Host matching.
            let remoteRows = try Row.fetchAll(database, sql: """
                SELECT o.operation_uuid, o.quantized_embedding, o.quantization_scale,
                       o.segment_count, o.speech_duration_ms,
                       r.id AS evidence_recording_id, o.speaker_index
                FROM speaker_embedding_observations o
                JOIN recordings r ON r.canonical_uuid = o.canonical_recording_uuid
                JOIN person_speakers ps
                  ON ps.recording_id = r.id AND ps.speaker_index = o.speaker_index
                WHERE ps.is_user_confirmed = 1 AND NOT EXISTS (
                    SELECT 1 FROM bound_speaker_enrollment_sources b WHERE b.recording_id = ps.recording_id)
                   AND ps.person_id = ? AND o.model_id = ? AND o.dimensions = ?
                ORDER BY o.speech_duration_ms DESC, o.segment_count DESC, o.operation_uuid ASC
                """, arguments: [person.id, modelID, dimensions])
            for row in remoteRows {
                guard let uuid = UUID(uuidString: row["operation_uuid"] as String) else { continue }
                let quantized: Data = row["quantized_embedding"]
                let scale: Double = row["quantization_scale"]
                let floats = Self.dequantizeSpeakerEmbedding(quantized, scale: Float(scale))
                candidates.append((
                    SpeakerPrototypeID(uuid),
                    Self.encodeFloat32(floats),
                    row["segment_count"],
                    row["speech_duration_ms"],
                    "\(row["evidence_recording_id"] as Int64):\(row["speaker_index"] as Int64)"
                ))
            }

            candidates.sort {
                if $0.3 != $1.3 { return $0.3 > $1.3 }
                if $0.2 != $1.2 { return $0.2 > $1.2 }
                return $0.0 < $1.0
            }
            // Local and remote copies, including revision-driven resubmissions,
            // are one source of voice evidence. Reserve the compact pack for
            // distinct recording speakers; invalid vectors consume no slot.
            var seenSources: Set<String> = []
            var prototypes: [SpeakerRecognitionPrototype] = []
            for candidate in candidates {
                guard prototypes.count < maximumPrototypesPerPerson else { break }
                guard candidate.2 > 0,
                      candidate.3 >= Int(SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs),
                      let vector = Self.decodeFloat32(candidate.1, expectedDimensions: Int(dimensions)),
                      vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }),
                      seenSources.insert(candidate.4).inserted else { continue }
                prototypes.append(try SpeakerRecognitionPrototype(
                    id: candidate.0,
                    embedding: Self.quantizeSpeakerEmbedding(vector),
                    speechDurationMs: UInt64(candidate.3),
                    segmentCount: UInt32(candidate.2)
                ))
            }
            prototypes.sort { $0.id < $1.id }
            return try SpeakerIdentityProfile(
                id: person.stableID,
                displayName: person.displayName,
                matchThreshold: person.matchThreshold ?? Self.defaultSpeakerMatchThreshold,
                revision: person.profileRevision,
                prototypes: prototypes
            )
        }
        return (revision, profiles)
    }

    /// One immutable payload per published revision, including its validity dates.
    /// Renewal and profile changes are serialized with the durable publication.
    func publishedSpeakerRecognitionPack(at now: Date = Date()) async throws -> SpeakerRecognitionPack {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw StoreError.invalidData("Recognition-pack publication time is invalid")
        }
        return try await db.write { database in
            let revision = try Self.speakerRecognitionPackRevision(in: database)
            if let data = try Data.fetchOne(database,
                sql: "SELECT pack_payload FROM published_speaker_recognition_pack WHERE singleton = 1") {
                let cached = try JSONDecoder().decode(SpeakerRecognitionPack.self, from: data)
                guard cached.revision <= revision else {
                    throw StoreError.invalidData("Published recognition-pack revision is ahead of the Library")
                }
                if cached.revision == revision {
                    if now < cached.expiresAt { return cached }
                    // A fresh lifetime must never reuse an earlier payload's revision.
                    try Self.bumpSpeakerRecognitionPackRevision(in: database,
                        at: now.timeIntervalSince1970)
                }
            }
            let snapshot = try Self.recognitionSnapshot(in: database, modelID: "wespeaker_v2",
                dimensions: 256, maximumPrototypesPerPerson: 3)
            let pack = try SpeakerRecognitionPack(revision: snapshot.0, modelID: "wespeaker_v2",
                dimensions: 256, generatedAt: now,
                expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60), profiles: snapshot.1)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try database.execute(sql: """
                INSERT INTO published_speaker_recognition_pack(singleton, pack_payload) VALUES (1, ?)
                ON CONFLICT(singleton) DO UPDATE SET pack_payload = excluded.pack_payload
                """, arguments: [try encoder.encode(pack)])
            return pack
        }
    }

    /// Legacy wire observations do not prove which canonical cluster they describe.
    /// Retain them separately from usable enrollment evidence and canonical names.
    func retainUnmappedSpeakerObservation(
        _ observation: SpeakerEmbeddingObservation, from sourceDeviceID: DeviceID,
        at receivedAt: Date = Date()
    ) async throws -> SpeakerObservationDecision {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(observation)
        let hash = Data(SHA256.hash(data: payload))
        return try await db.write { database in
            if let row = try Row.fetchOne(database, sql: """
                SELECT source_device_id, request_sha256, result_json
                FROM unmapped_speaker_observations WHERE operation_uuid = ?
                """, arguments: [observation.operationID.description]) {
                guard row["source_device_id"] as Data == sourceDeviceID.rawBytes,
                      row["request_sha256"] as Data == hash else {
                    throw StoreError.invalidData("Unmapped speaker observation replay changed authority or payload")
                }
                return try JSONDecoder().decode(SpeakerObservationDecision.self, from: row["result_json"])
            }
            guard let recording = try Recording.fetchOne(database,
                sql: "SELECT * FROM recordings WHERE canonical_uuid = ?",
                arguments: [observation.canonicalRecordingID.description]) else { throw StoreError.notFound }
            let decision = try SpeakerObservationDecision(operationID: observation.operationID,
                disposition: .pendingReview, personID: nil, displayName: nil, score: nil,
                recognitionPackRevision: Self.speakerRecognitionPackRevision(in: database),
                recordingRevision: recording.revision)
            try database.execute(sql: """
                INSERT INTO unmapped_speaker_observations(operation_uuid, canonical_recording_uuid,
                    source_device_id, request_sha256, request_json, received_at, result_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [observation.operationID.description, observation.canonicalRecordingID.description,
                    sourceDeviceID.rawBytes, hash, payload, receivedAt.timeIntervalSince1970,
                    try encoder.encode(decision)])
            return decision
        }
    }

    /// Persists a client-computed observation exactly once, evaluates it
    /// against all host-confirmed evidence, and projects a confident Host
    /// decision into the canonical recording label.
    func submitSpeakerObservation(
        _ observation: SpeakerEmbeddingObservation,
        from sourceDeviceID: DeviceID,
        expectedEvidenceSHA256: Data? = nil,
        at receivedAt: Date = Date()
    ) async throws -> SpeakerObservationDecision {
        try await evaluateSpeakerObservation(observation, from: sourceDeviceID,
            expectedEvidenceSHA256: expectedEvidenceSHA256, selectedEdgeEvidence: nil,
            selectedArtifactSource: nil, at: receivedAt)
    }

    /// Local scheduled work must still own its exact queue snapshot inside the
    /// naming transaction, including on replay. Completion CAS alone is too late
    /// to protect displayed names from a superseded worker.
    func submitHostSpeakerReviewObservation(
        _ observation: SpeakerEmbeddingObservation,
        from sourceDeviceID: DeviceID,
        expectedEvidenceSHA256: Data,
        job: HostSpeakerReviewJob,
        expectedPackRevision: EntityRevision,
        at receivedAt: Date = Date()
    ) async throws -> SpeakerObservationDecision {
        try await evaluateSpeakerObservation(observation, from: sourceDeviceID,
            expectedEvidenceSHA256: expectedEvidenceSHA256, selectedEdgeEvidence: nil,
            selectedArtifactSource: nil, reviewJob: job, reviewPackRevision: expectedPackRevision, at: receivedAt)
    }

    /// The Host must first authenticate the processing bundle and validate cluster
    /// membership/duration. This transaction rechecks selection before any replay
    /// or naming mutation; the client's numeric index is never naming authority.
    func submitSelectedEdgeSpeakerObservation(
        _ bound: BoundSpeakerEmbeddingObservation, validatedClusterMap: SpeakerClusterMap,
        selectedArtifactSource: SelectedEdgeArtifactSource? = nil, from sourceDeviceID: DeviceID, at receivedAt: Date = Date()
    ) async throws -> SpeakerObservationDecision {
        try await evaluateSpeakerObservation(bound.observation, from: sourceDeviceID,
            expectedEvidenceSHA256: nil, selectedEdgeEvidence: (bound, validatedClusterMap),
            selectedArtifactSource: selectedArtifactSource, at: receivedAt)
    }

    private func evaluateSpeakerObservation(
        _ originalObservation: SpeakerEmbeddingObservation, from sourceDeviceID: DeviceID,
        expectedEvidenceSHA256: Data?,
        selectedEdgeEvidence: (BoundSpeakerEmbeddingObservation, SpeakerClusterMap)?,
        selectedArtifactSource: SelectedEdgeArtifactSource?,
        reviewJob: HostSpeakerReviewJob? = nil, reviewPackRevision: EntityRevision? = nil, at receivedAt: Date
    ) async throws -> SpeakerObservationDecision {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        // Preserve the complete original request for replay identity, including
        // the client's hint, rather than hashing its canonicalized replacement.
        let requestBytes = try selectedEdgeEvidence.map { try encoder.encode($0.0) }
            ?? encoder.encode(originalObservation)
        let requestHash = Data(SHA256.hash(data: requestBytes))

        let outcome = try await db.write { database -> (SpeakerObservationDecision, Int64?) in
            var observation = originalObservation
            if let reviewJob {
                guard let expectedEvidenceSHA256,
                      try Self.speakerRecognitionPackRevision(in: database) == reviewPackRevision,
                      let row = try Row.fetchOne(database,
                        sql: "SELECT * FROM host_speaker_review_queue WHERE recording_id = ?",
                        arguments: [reviewJob.recordingID]),
                      try Self.decodeHostSpeakerReviewJob(row) == reviewJob,
                      reviewJob.eligibleAt <= receivedAt,
                      reviewJob.expectedOutcome.canonicalRecordingID == observation.canonicalRecordingID,
                      reviewJob.expectedOutcome.clusters.contains(where: {
                          $0.speakerIndex == observation.speakerIndex && $0.evidenceSHA256 == expectedEvidenceSHA256
                      }),
                      let recording = try Recording.fetchOne(database, key: reviewJob.recordingID),
                      recording.deletedAt == nil, recording.processing.state == .ready,
                      recording.projection.state == .ready,
                      let bytes = try Data.fetchOne(database,
                        sql: "SELECT outcome_json FROM host_speaker_processing_outcome WHERE recording_id = ?",
                        arguments: [reviewJob.recordingID]),
                      try decoder.decode(HostSpeakerProcessingOutcome.self, from: bytes) == reviewJob.expectedOutcome else {
                    throw StoreError.invalidData("Host speaker review was superseded or is not eligible")
                }
                try Self.validateHostSpeakerOutcome(in: database, recording: recording, outcome: reviewJob.expectedOutcome)
            }
            if let (bound, validatedMap) = selectedEdgeEvidence {
                guard sourceDeviceID == bound.evidence.producerDeviceID,
                      let recordingID = try Int64.fetchOne(database,
                        sql: "SELECT id FROM recordings WHERE canonical_uuid = ?",
                        arguments: [bound.evidence.canonicalRecordingID.description]),
                      let selectedMap = try Self.selectedSpeakerClusterMap(in: database, recordingID: recordingID),
                      selectedMap == validatedMap else {
                    throw StoreError.invalidData("Speaker evidence no longer belongs to the selected edge artifact")
                }
                if let selectedArtifactSource {
                    guard try Self.selectedEdgeArtifactSource(in: database, recordingID: recordingID) == selectedArtifactSource else {
                        throw StoreError.invalidData("Selected signed processing artifact changed before admission")
                    }
                }
                let index = try selectedMap.canonicalSpeakerIndex(for: bound.evidence)
                observation = try SpeakerEmbeddingObservation(operationID: originalObservation.operationID,
                    canonicalRecordingID: originalObservation.canonicalRecordingID, speakerIndex: index,
                    embedding: originalObservation.embedding, modelID: originalObservation.modelID,
                    speechDurationMs: originalObservation.speechDurationMs,
                    segmentCount: originalObservation.segmentCount,
                    sourcePackRevision: originalObservation.sourcePackRevision,
                    proposedPersonID: originalObservation.proposedPersonID, proposedScore: originalObservation.proposedScore)
            }
            if let expectedEvidenceSHA256 {
                guard let row = try Row.fetchOne(database, sql: """
                    SELECT r.*, e.snapshot_json FROM recordings r
                    JOIN current_speaker_evidence c ON c.recording_id = r.id
                    JOIN speaker_evidence_snapshots e ON e.evidence_sha256 = c.evidence_sha256
                    WHERE r.canonical_uuid = ? AND c.speaker_index = ? AND c.evidence_sha256 = ?
                    """, arguments: [observation.canonicalRecordingID.description,
                        observation.speakerIndex, expectedEvidenceSHA256]),
                      let path = row["json_path"] as String? else {
                    throw StoreError.invalidData("Host speaker generation is no longer current")
                }
                let evidence = try Self.decodeSpeakerEvidence(row["snapshot_json"], expectedDigest: expectedEvidenceSHA256)
                guard evidence.processingArtifactSHA256 == (try Self.speakerArtifactDigest(path: path)),
                      evidence.embedding == observation.embedding, evidence.modelID == observation.modelID,
                      evidence.speechDurationMs == observation.speechDurationMs,
                      evidence.segmentCount == observation.segmentCount else {
                    throw StoreError.invalidData("Host speaker observation differs from its current evidence")
                }
            }
            if let row = try Row.fetchOne(
                database,
                sql: "SELECT request_sha256, source_device_id, result_json FROM speaker_embedding_observations WHERE operation_uuid = ?",
                arguments: [observation.operationID.description]
            ) {
                guard row["request_sha256"] as Data == requestHash,
                      row["source_device_id"] as Data == sourceDeviceID.rawBytes else {
                    throw StoreError.invalidData("Speaker observation operation identity or authority was reused")
                }
                if let (bound, map) = selectedEdgeEvidence {
                    guard let provenance = try Row.fetchOne(database, sql:
                        """
                        SELECT p.*, e.snapshot_json FROM bound_speaker_observation_provenance p
                        JOIN speaker_evidence_snapshots e ON e.evidence_sha256 = p.evidence_sha256
                        JOIN current_speaker_evidence c ON c.recording_id = e.recording_id
                            AND c.evidence_sha256 = e.evidence_sha256
                        WHERE p.operation_uuid = ? AND c.speaker_index = ?
                        """,
                        arguments: [observation.operationID.description, observation.speakerIndex]),
                          provenance["evidence_sha256"] as Data == bound.evidence.evidenceSHA256,
                          provenance["cluster_map_sha256"] as Data == map.mappingSHA256,
                          provenance["request_json"] as Data == requestBytes,
                          try Self.decodeSpeakerEvidence(provenance["snapshot_json"],
                            expectedDigest: bound.evidence.evidenceSHA256) == bound.evidence else {
                        throw StoreError.invalidData("Bound speaker decision provenance is missing or changed")
                    }
                }
                if let expectedEvidenceSHA256 {
                    guard try Data.fetchOne(database,
                        sql: "SELECT evidence_sha256 FROM host_speaker_decision_provenance WHERE operation_uuid = ?",
                        arguments: [observation.operationID.description]) == expectedEvidenceSHA256 else {
                        throw StoreError.invalidData("Host speaker decision provenance is missing or changed")
                    }
                }
                return (try decoder.decode(SpeakerObservationDecision.self, from: row["result_json"]), nil)
            }

            guard var recording = try Recording
                .filter(Recording.Columns.canonicalID == observation.canonicalRecordingID.description)
                .fetchOne(database), recording.deletedAt == nil,
                let recordingID = recording.id else {
                throw StoreError.notFound
            }

            var evidenceSelectionChanged = false
            if let (bound, _) = selectedEdgeEvidence {
                try Self.retainSpeakerEvidence(in: database, evidence: bound.evidence, at: receivedAt)
                evidenceSelectionChanged = try Self.installCurrentEdgeSpeakerEvidence(in: database,
                    recording: recording, speakerIndex: observation.speakerIndex, evidence: bound.evidence, at: receivedAt)
                guard let refreshed = try Recording.fetchOne(database, key: recordingID) else { throw StoreError.notFound }
                recording = refreshed
            }

            let query = Self.dequantizeSpeakerEmbedding(
                observation.embedding.values,
                scale: observation.embedding.scale
            )
            // A recording cannot corroborate its own identity on a new operation.
            // Exact operation replays return above; reevaluation needs external evidence.
            let candidateRows = try Row.fetchAll(database, sql: """
                SELECT p.id AS person_local_id, p.stable_uuid, p.display_name,
                       p.match_threshold, e.embedding AS float_embedding,
                       NULL AS quantized_embedding, NULL AS quantization_scale
                FROM people p
                JOIN person_speakers ps ON ps.person_id = p.id
                JOIN speaker_embeddings e
                  ON e.recording_id = ps.recording_id
                 AND e.speaker_index = ps.speaker_index
                WHERE ps.is_user_confirmed = 1 AND NOT EXISTS (
                        SELECT 1 FROM bound_speaker_enrollment_sources b WHERE b.recording_id = ps.recording_id)
                       AND e.embedder_kind = ? AND e.recording_id != ?
                  AND e.total_ms >= ? AND e.segment_count > 0
                UNION ALL
                SELECT p.id AS person_local_id, p.stable_uuid, p.display_name,
                       p.match_threshold, NULL AS float_embedding,
                       o.quantized_embedding, o.quantization_scale
                FROM people p
                JOIN person_speakers ps ON ps.person_id = p.id
                JOIN recordings r ON r.id = ps.recording_id
                JOIN speaker_embedding_observations o
                  ON o.canonical_recording_uuid = r.canonical_uuid
                 AND o.speaker_index = ps.speaker_index
                WHERE ps.is_user_confirmed = 1 AND NOT EXISTS (
                        SELECT 1 FROM bound_speaker_enrollment_sources b WHERE b.recording_id = ps.recording_id)
                       AND o.model_id = ? AND o.dimensions = ? AND r.id != ?
                  AND o.speech_duration_ms >= ? AND o.segment_count > 0
                """, arguments: [observation.modelID, recordingID,
                    SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs,
                    observation.modelID, observation.embedding.dimensions, recordingID,
                    SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs])

            var candidates: [PersonID: (localID: Int64, stableID: PersonID, name: String, threshold: Double, score: Double)] = [:]
            for row in candidateRows {
                let candidate: [Float]?
                if let raw: Data = row["float_embedding"] {
                    candidate = Self.decodeFloat32(raw, expectedDimensions: query.count)
                } else if let quantized: Data = row["quantized_embedding"],
                          let scale: Double = row["quantization_scale"] {
                    candidate = Self.dequantizeSpeakerEmbedding(quantized, scale: Float(scale))
                } else {
                    candidate = nil
                }
                guard let candidate,
                      let uuid = UUID(uuidString: row["stable_uuid"] as String) else { continue }
                let score = Self.cosineSimilarity(query, candidate)
                let personID = PersonID(uuid)
                if score.isFinite && score > (candidates[personID]?.score ?? -1) {
                    candidates[personID] = (
                        row["person_local_id"],
                        PersonID(uuid),
                        row["display_name"],
                        row["match_threshold"] ?? Self.defaultSpeakerMatchThreshold,
                        score
                    )
                }
            }

            let confirmedSnapshots = try Self.confirmedSpeakerEvidence(in: database,
                modelID: observation.modelID, dimensions: observation.embedding.dimensions,
                excludingRecordingID: recordingID)
            let peopleByID = Dictionary(uniqueKeysWithValues: try Self.fetchPeople(db: database).map { ($0.id, $0) })
            for selected in confirmedSnapshots {
                guard let person = peopleByID[selected.personID] else { continue }
                let score = Self.cosineSimilarity(query, selected.snapshot.embedding.dequantized)
                if score.isFinite && score > (candidates[person.stableID]?.score ?? -1) {
                    candidates[person.stableID] = (person.id, person.stableID, person.displayName,
                        person.matchThreshold ?? Self.defaultSpeakerMatchThreshold, score)
                }
            }

            let winner = SpeakerRecognitionMatcher.unambiguousBestPerson(
                scores: candidates.mapValues(\.score)
            )
            let best = winner.flatMap { candidates[$0] }
            var match = best.flatMap { $0.score >= $0.threshold ? $0 : nil }
            let existingLink = try Row.fetchOne(database, sql: """
                SELECT person_id, is_user_confirmed FROM person_speakers
                WHERE recording_id = ? AND speaker_index = ?
                """, arguments: [recordingID, observation.speakerIndex])
            let conflictsWithConfirmation = match.map { candidate in
                existingLink?["is_user_confirmed"] as Int? == 1 &&
                    existingLink?["person_id"] as Int64? != candidate.localID
            } ?? false
            let rejectedPersonID = match?.localID
            let wasDismissed = try rejectedPersonID.map { personID in
                try Bool.fetchOne(database, sql: """
                    SELECT EXISTS(SELECT 1 FROM dismissed_suggestions
                        WHERE person_id = ? AND recording_id = ? AND speaker_index = ?)
                    """, arguments: [personID, recordingID, observation.speakerIndex]) == true
            } ?? false
            if conflictsWithConfirmation || wasDismissed { match = nil }
            var recordingWasChanged = evidenceSelectionChanged
            if let match {
                let existingPerson = try Int64.fetchOne(
                    database,
                    sql: "SELECT person_id FROM person_speakers WHERE recording_id = ? AND speaker_index = ?",
                    arguments: [recordingID, observation.speakerIndex]
                )
                try database.execute(sql: """
                    INSERT INTO person_speakers
                        (person_id, recording_id, speaker_index, confirmed_at, is_user_confirmed)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(recording_id, speaker_index) DO UPDATE SET
                        person_id = excluded.person_id,
                        confirmed_at = CASE WHEN person_speakers.is_user_confirmed = 1
                            THEN person_speakers.confirmed_at ELSE excluded.confirmed_at END
                    """, arguments: [match.localID, recordingID, observation.speakerIndex, receivedAt.timeIntervalSince1970])

                if existingLink?["is_user_confirmed"] as Int? != 1 {
                    // Reuse the existing inspector review surface. A displayed
                    // automatic name is not human-confirmed enrollment evidence.
                    try database.execute(
                        sql: "DELETE FROM pending_suggestions WHERE recording_id = ? AND speaker_index = ?",
                        arguments: [recordingID, observation.speakerIndex]
                    )
                    try database.execute(sql: """
                        INSERT INTO pending_suggestions
                            (person_id, recording_id, speaker_index, score, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [match.localID, recordingID, observation.speakerIndex,
                                          match.score, receivedAt.timeIntervalSince1970])
                }

                guard let speakerIndex = Int(exactly: observation.speakerIndex) else {
                    throw StoreError.invalidData("Speaker observation index is out of range")
                }
                var names = recording.speakerNames
                if names[speakerIndex] != match.name || existingPerson != match.localID {
                    names[speakerIndex] = match.name
                    let encoded = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
                    let json = String(data: try JSONEncoder().encode(encoded), encoding: .utf8)
                    try database.execute(
                        sql: "UPDATE recordings SET speaker_names = ?, updated_at = ? WHERE id = ?",
                        arguments: [json, receivedAt, recordingID]
                    )
                    _ = try Self.bumpRevisionAndAppendLibraryChange(
                        in: database,
                        recordingID: recordingID,
                        changedAt: receivedAt
                    )
                    recordingWasChanged = true
                }
            } else if existingLink?["is_user_confirmed"] as Int? == 0 {
                // A fresh nonmatch supersedes an automatic assignment. Keep
                // immutable observation history, but do not display its old name
                // or offer its stale review as the current recognition result.
                let previousName = try String.fetchOne(database, sql:
                    "SELECT display_name FROM people WHERE id = ?",
                    arguments: [existingLink?["person_id"] as Int64?])
                try database.execute(sql:
                    "DELETE FROM person_speakers WHERE recording_id = ? AND speaker_index = ? AND is_user_confirmed = 0",
                    arguments: [recordingID, observation.speakerIndex])
                try database.execute(sql:
                    "DELETE FROM pending_suggestions WHERE recording_id = ? AND speaker_index = ?",
                    arguments: [recordingID, observation.speakerIndex])
                var names = recording.speakerNames
                // A separately edited label is not automatic recognition output.
                if let index = Int(exactly: observation.speakerIndex),
                   let previousName, names[index] == previousName {
                    names.removeValue(forKey: index)
                    let encoded = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
                    let json = String(data: try JSONEncoder().encode(encoded), encoding: .utf8)
                    try database.execute(sql:
                        "UPDATE recordings SET speaker_names = ?, updated_at = ? WHERE id = ?",
                        arguments: [json, receivedAt, recordingID])
                }
                _ = try Self.bumpRevisionAndAppendLibraryChange(
                    in: database, recordingID: recordingID, changedAt: receivedAt)
                recordingWasChanged = true
            }

            let packRevision: EntityRevision
            // Only confirmed evidence can change the recognition pack. A new
            // automatic name must not trigger a pack revision and retry cascade.
            // A Host review reuses an already-selected immutable snapshot. It
            // adds no enrollment evidence, even when that voice is confirmed.
            // Bumping here would invalidate later clusters and exact retries.
            if reviewJob == nil, let match, existingLink?["is_user_confirmed"] as Int? == 1 {
                packRevision = try Self.bumpSpeakerProfiles(
                    in: database,
                    personIDs: [match.localID],
                    at: receivedAt.timeIntervalSince1970
                )
            } else {
                packRevision = try Self.speakerRecognitionPackRevision(in: database)
            }
            guard let currentRecordingRevision = try Int64.fetchOne(
                database,
                sql: "SELECT revision FROM recordings WHERE id = ?",
                arguments: [recordingID]
            ) else { throw StoreError.notFound }

            let disposition: SpeakerObservationDisposition = match != nil
                ? .matched
                : (wasDismissed ? .noMatch : (conflictsWithConfirmation || observation.proposedPersonID != nil ? .pendingReview : .noMatch))
            let decision = try SpeakerObservationDecision(
                operationID: observation.operationID,
                disposition: disposition,
                personID: match?.stableID,
                displayName: match?.name,
                score: match?.score,
                recognitionPackRevision: packRevision,
                recordingRevision: try EntityRevision(signedValue: currentRecordingRevision)
            )
            let resultJSON = try encoder.encode(decision)
            try database.execute(sql: """
                INSERT INTO speaker_embedding_observations (
                    operation_uuid, request_sha256, canonical_recording_uuid,
                    speaker_index, source_device_id, model_id, dimensions,
                    quantized_embedding, quantization_scale, segment_count,
                    speech_duration_ms, source_pack_revision,
                    proposed_person_uuid, proposed_score, disposition,
                    decided_person_uuid, decided_score, received_at, result_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    observation.operationID.description,
                    requestHash,
                    observation.canonicalRecordingID.description,
                    observation.speakerIndex,
                    sourceDeviceID.rawBytes,
                    observation.modelID,
                    observation.embedding.dimensions,
                    observation.embedding.values,
                    observation.embedding.scale,
                    observation.segmentCount,
                    observation.speechDurationMs,
                    observation.sourcePackRevision?.rawValue,
                    observation.proposedPersonID?.description,
                    observation.proposedScore,
                    disposition.rawValue,
                    match?.stableID.description,
                    match?.score,
                    receivedAt.timeIntervalSince1970,
                    resultJSON,
                ])
            if let expectedEvidenceSHA256 {
                try database.execute(sql: "INSERT INTO host_speaker_decision_provenance VALUES (?, ?)",
                    arguments: [observation.operationID.description, expectedEvidenceSHA256])
            }
            if let (bound, map) = selectedEdgeEvidence {
                try database.execute(sql: """
                    INSERT INTO bound_speaker_observation_provenance
                        (operation_uuid, evidence_sha256, cluster_map_sha256, request_json)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [observation.operationID.description, bound.evidence.evidenceSHA256,
                        map.mappingSHA256, requestBytes])
            }
            return (decision, recordingWasChanged ? recordingID : nil)
        }
        if let recordingID = outcome.1 {
            await reprojectOKF(id: recordingID)
        }
        return outcome.0
    }

    static func quantizeSpeakerEmbedding(_ vector: [Float]) throws -> QuantizedSpeakerEmbedding {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
            throw StoreError.invalidData("Speaker embedding contains invalid values")
        }
        let maximum = vector.reduce(Float.zero) { max($0, abs($1)) }
        let scale = max(maximum / 127, Float.leastNonzeroMagnitude)
        let values = Data(vector.map { value in
            let quantized = Int8(clamping: Int((value / scale).rounded()))
            return UInt8(bitPattern: quantized)
        })
        return try QuantizedSpeakerEmbedding(
            dimensions: UInt32(vector.count),
            values: values,
            scale: scale
        )
    }

    static func bumpSpeakerProfiles(
        in database: Database,
        personIDs: Set<Int64>,
        at unixTime: Double
    ) throws -> EntityRevision {
        for personID in personIDs {
            try database.execute(
                sql: "UPDATE people SET profile_revision = profile_revision + 1, updated_at = ? WHERE id = ?",
                arguments: [unixTime, personID]
            )
        }
        return try bumpSpeakerRecognitionPackRevision(in: database, at: unixTime)
    }

    @discardableResult
    static func bumpSpeakerRecognitionPackRevision(
        in database: Database,
        at unixTime: Double
    ) throws -> EntityRevision {
        try database.execute(sql: """
            UPDATE speaker_identity_metadata
            SET pack_revision = pack_revision + 1, updated_at = ?
            WHERE singleton = 1 AND pack_revision < 9223372036854775807
            """, arguments: [unixTime])
        guard database.changesCount == 1 else {
            throw StoreError.revisionOverflow
        }
        return try speakerRecognitionPackRevision(in: database)
    }

    static func speakerRecognitionPackRevision(in database: Database) throws -> EntityRevision {
        guard let value = try Int64.fetchOne(
            database,
            sql: "SELECT pack_revision FROM speaker_identity_metadata WHERE singleton = 1"
        ) else { throw StoreError.invalidData("Speaker identity metadata is missing") }
        return try EntityRevision(signedValue: value)
    }

    private static func decodeFloat32(_ data: Data, expectedDimensions: Int) -> [Float]? {
        guard data.count == expectedDimensions * 4 else { return nil }
        var result: [Float] = []
        result.reserveCapacity(expectedDimensions)
        for offset in stride(from: 0, to: data.count, by: 4) {
            let bits = UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
            let value = Float(bitPattern: bits)
            guard value.isFinite else { return nil }
            result.append(value)
        }
        return result
    }

    static func encodeFloat32(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func dequantizeSpeakerEmbedding(_ data: Data, scale: Float) -> [Float] {
        data.map { Float(Int8(bitPattern: $0)) * scale }
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return -1 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }
}
