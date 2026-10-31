import CryptoKit
import Foundation
import HarcDomain

public extension RecordingStore {
    /// Executes one persisted review without re-running transcription or inference.
    /// Failures leave the queued job intact for the caller's persisted backoff.
    func performHostSpeakerReview(_ job: HostSpeakerReviewJob, at now: Date = Date()) async throws -> Bool {
        guard now.timeIntervalSince1970.isFinite, job.eligibleAt <= now else {
            throw StoreError.invalidData("Host speaker review is not eligible")
        }
        try Task.checkCancellation()
        guard let recording = try await fetch(id: job.recordingID),
              let source = recording.originID?.deviceID,
              try await hostSpeakerProcessingOutcome(recordingID: job.recordingID) == job.expectedOutcome else {
            return false
        }
        let revision = try await publishedSpeakerRecognitionPack(at: now).revision
        var clusters: [HostSpeakerProcessingOutcome.Cluster] = []
        for cluster in job.expectedOutcome.clusters {
            try Task.checkCancellation()
            guard let digest = cluster.evidenceSHA256 else {
                clusters.append(cluster) // Missing voice evidence remains missing.
                continue
            }
            guard let evidence = try await retainedSpeakerEvidence(sha256: digest) else {
                throw StoreError.invalidData("Host review voice evidence is missing")
            }
            let operation = Self.hostSpeakerReviewOperation(jobID: job.id,
                evidenceSHA256: digest, packRevision: revision)
            let observation = try SpeakerEmbeddingObservation(operationID: operation,
                canonicalRecordingID: job.expectedOutcome.canonicalRecordingID,
                speakerIndex: cluster.speakerIndex, embedding: evidence.embedding,
                modelID: evidence.modelID, speechDurationMs: evidence.speechDurationMs,
                segmentCount: evidence.segmentCount)
            let decision = try await submitHostSpeakerReviewObservation(observation, from: source,
                expectedEvidenceSHA256: digest, job: job, expectedPackRevision: revision, at: now)
            clusters.append(try .init(speakerIndex: cluster.speakerIndex, evidenceSHA256: digest,
                decisionOperationID: decision.operationID, disposition: decision.disposition,
                recognitionPackRevision: decision.recognitionPackRevision))
        }
        try Task.checkCancellation()
        let old = job.expectedOutcome
        let replacement = try HostSpeakerProcessingOutcome(canonicalRecordingID: old.canonicalRecordingID,
            canonicalPCMHash: old.canonicalPCMHash, producerDeviceID: old.producerDeviceID,
            processingArtifactSHA256: old.processingArtifactSHA256, diarization: old.diarization, clusters: clusters)
        return try await replaceHostSpeakerProcessingOutcome(recordingID: job.recordingID,
            expected: old, replacement: replacement, reviewJob: job, now: now)
    }
}

extension RecordingStore {
    static func hostSpeakerReviewOperation(jobID: UUID, evidenceSHA256: Data,
        packRevision: EntityRevision) -> OperationID {
        var material = Data("harc-host-speaker-review-v1".utf8)
        material.append(Data(jobID.uuidString.lowercased().utf8))
        material.append(evidenceSHA256)
        var revision = packRevision.rawValue.bigEndian
        withUnsafeBytes(of: &revision) { material.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: material).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return OperationID(UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])))
    }
}
