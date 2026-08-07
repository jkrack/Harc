import CryptoKit
import Foundation
import GRDB
import HarcDomain

public extension RecordingStore {
    static let defaultSpeakerMatchThreshold = 0.65

    /// Builds the compact recognition state clients cache for provisional,
    /// low-latency matching. Raw historical vectors never leave this method.
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
            let revision = try Self.speakerRecognitionPackRevision(in: database)
            let people = try Self.fetchPeople(db: database).sorted { $0.stableID < $1.stableID }
            let profiles = try people.map { person in
                var candidates: [(SpeakerPrototypeID, Data, Int, Int)] = []
                let localRows = try Row.fetchAll(database, sql: """
                    SELECT e.prototype_uuid, e.embedding, e.segment_count, e.total_ms
                    FROM speaker_embeddings e
                    JOIN person_speakers ps
                      ON ps.recording_id = e.recording_id
                     AND ps.speaker_index = e.speaker_index
                    WHERE ps.person_id = ? AND e.embedder_kind = ?
                    ORDER BY e.total_ms DESC, e.segment_count DESC, e.prototype_uuid ASC
                    """, arguments: [person.id, modelID])
                for row in localRows {
                    guard let uuid = UUID(uuidString: row["prototype_uuid"] as String) else { continue }
                    candidates.append((
                        SpeakerPrototypeID(uuid),
                        row["embedding"],
                        row["segment_count"],
                        row["total_ms"]
                    ))
                }

                let remoteRows = try Row.fetchAll(database, sql: """
                    SELECT operation_uuid, quantized_embedding, quantization_scale,
                           segment_count, speech_duration_ms
                    FROM speaker_embedding_observations
                    WHERE decided_person_uuid = ? AND model_id = ? AND dimensions = ?
                    ORDER BY speech_duration_ms DESC, segment_count DESC, operation_uuid ASC
                    """, arguments: [person.stableID.description, modelID, dimensions])
                for row in remoteRows {
                    guard let uuid = UUID(uuidString: row["operation_uuid"] as String) else { continue }
                    let quantized: Data = row["quantized_embedding"]
                    let scale: Double = row["quantization_scale"]
                    let floats = Self.dequantizeSpeakerEmbedding(quantized, scale: Float(scale))
                    candidates.append((
                        SpeakerPrototypeID(uuid),
                        Self.encodeFloat32(floats),
                        row["segment_count"],
                        row["speech_duration_ms"]
                    ))
                }

                candidates.sort {
                    if $0.3 != $1.3 { return $0.3 > $1.3 }
                    if $0.2 != $1.2 { return $0.2 > $1.2 }
                    return $0.0 < $1.0
                }
                let prototypes = try candidates.prefix(maximumPrototypesPerPerson).compactMap {
                    candidate -> SpeakerRecognitionPrototype? in
                    guard let vector = Self.decodeFloat32(candidate.1, expectedDimensions: Int(dimensions)) else {
                        return nil
                    }
                    return try SpeakerRecognitionPrototype(
                        id: candidate.0,
                        embedding: Self.quantizeSpeakerEmbedding(vector),
                        speechDurationMs: UInt64(candidate.3),
                        segmentCount: UInt32(candidate.2)
                    )
                }.sorted { $0.id < $1.id }
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
        return try SpeakerRecognitionPack(
            revision: snapshot.0,
            modelID: modelID,
            dimensions: dimensions,
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(lifetime),
            profiles: snapshot.1
        )
    }

    /// Persists a client-computed observation exactly once, evaluates it
    /// against all host-confirmed evidence, and projects a confident Host
    /// decision into the canonical recording label.
    func submitSpeakerObservation(
        _ observation: SpeakerEmbeddingObservation,
        from sourceDeviceID: DeviceID,
        at receivedAt: Date = Date()
    ) async throws -> SpeakerObservationDecision {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let requestBytes = try encoder.encode(observation)
        let requestHash = Data(SHA256.hash(data: requestBytes))

        let outcome = try await db.write { database -> (SpeakerObservationDecision, Int64?) in
            if let row = try Row.fetchOne(
                database,
                sql: "SELECT request_sha256, result_json FROM speaker_embedding_observations WHERE operation_uuid = ?",
                arguments: [observation.operationID.description]
            ) {
                guard row["request_sha256"] as Data == requestHash else {
                    throw StoreError.invalidData("Speaker observation operation identity was reused")
                }
                return (try decoder.decode(SpeakerObservationDecision.self, from: row["result_json"]), nil)
            }

            guard let recording = try Recording
                .filter(Recording.Columns.canonicalID == observation.canonicalRecordingID.description)
                .fetchOne(database), recording.deletedAt == nil,
                let recordingID = recording.id else {
                throw StoreError.notFound
            }

            let query = Self.dequantizeSpeakerEmbedding(
                observation.embedding.values,
                scale: observation.embedding.scale
            )
            let candidateRows = try Row.fetchAll(database, sql: """
                SELECT p.id AS person_local_id, p.stable_uuid, p.display_name,
                       p.match_threshold, e.embedding AS float_embedding,
                       NULL AS quantized_embedding, NULL AS quantization_scale
                FROM people p
                JOIN person_speakers ps ON ps.person_id = p.id
                JOIN speaker_embeddings e
                  ON e.recording_id = ps.recording_id
                 AND e.speaker_index = ps.speaker_index
                WHERE e.embedder_kind = ?
                UNION ALL
                SELECT p.id AS person_local_id, p.stable_uuid, p.display_name,
                       p.match_threshold, NULL AS float_embedding,
                       o.quantized_embedding, o.quantization_scale
                FROM people p
                JOIN speaker_embedding_observations o
                  ON o.decided_person_uuid = p.stable_uuid
                WHERE o.model_id = ? AND o.dimensions = ?
                """, arguments: [observation.modelID, observation.modelID, observation.embedding.dimensions])

            var best: (localID: Int64, stableID: PersonID, name: String, threshold: Double, score: Double)?
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
                if best == nil || score > best!.score {
                    best = (
                        row["person_local_id"],
                        PersonID(uuid),
                        row["display_name"],
                        row["match_threshold"] ?? Self.defaultSpeakerMatchThreshold,
                        score
                    )
                }
            }

            let match = best.flatMap { $0.score >= $0.threshold ? $0 : nil }
            var recordingWasChanged = false
            if let match {
                let existingPerson = try Int64.fetchOne(
                    database,
                    sql: "SELECT person_id FROM person_speakers WHERE recording_id = ? AND speaker_index = ?",
                    arguments: [recordingID, observation.speakerIndex]
                )
                try database.execute(sql: """
                    INSERT OR REPLACE INTO person_speakers
                        (person_id, recording_id, speaker_index, confirmed_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [match.localID, recordingID, observation.speakerIndex, receivedAt.timeIntervalSince1970])

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
            }

            let packRevision: EntityRevision
            if let match {
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
                : (observation.proposedPersonID == nil ? .noMatch : .pendingReview)
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

    private static func encodeFloat32(_ vector: [Float]) -> Data {
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
