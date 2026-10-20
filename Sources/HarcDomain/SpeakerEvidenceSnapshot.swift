import CryptoKit
import Foundation

/// Immutable voice evidence for one cluster in one exact processing artifact.
/// This value identifies evidence; it does not authenticate the producer, prove
/// cluster membership, or confer human-confirmed enrollment authority.
public struct SpeakerEvidenceSnapshot: Codable, Equatable, Hashable, Sendable {
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalPCMHash: CanonicalPCMHash
    public let producerDeviceID: DeviceID
    public let processingArtifactSHA256: Data
    public let localClusterID: String
    public let embedding: QuantizedSpeakerEmbedding
    public let modelID: String
    public let speechDurationMs: UInt64
    public let segmentCount: UInt32

    public init(
        canonicalRecordingID: CanonicalRecordingID,
        canonicalPCMHash: CanonicalPCMHash,
        producerDeviceID: DeviceID,
        processingArtifactSHA256: Data,
        localClusterID: String,
        embedding: QuantizedSpeakerEmbedding,
        modelID: String,
        speechDurationMs: UInt64,
        segmentCount: UInt32
    ) throws {
        guard processingArtifactSHA256.count == 32 else {
            throw DomainValidationError.invalidDigestLength(
                field: "SpeakerEvidenceSnapshot.processingArtifactSHA256",
                expected: 32, actual: processingArtifactSHA256.count)
        }
        // Canonical text avoids distinct byte identities for Unicode-equivalent
        // Swift strings. Reject noncanonical input instead of silently rebinding it.
        for (field, value) in [("localClusterID", localClusterID), ("modelID", modelID)] {
            guard !value.isEmpty, value.utf8.count <= 128,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  Array(value.utf8) == Array(value.precomposedStringWithCanonicalMapping.utf8),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw DomainValidationError.invalidCode(field: "SpeakerEvidenceSnapshot.\(field)")
            }
        }
        // Revalidate values even when a caller obtained an embedding through
        // synthesized Codable, which does not invoke its validating initializer.
        let validatedEmbedding = try QuantizedSpeakerEmbedding(
            dimensions: embedding.dimensions, values: embedding.values, scale: embedding.scale)
        guard speechDurationMs > 0, segmentCount > 0,
              validatedEmbedding.values.contains(where: { $0 != 0 }) else {
            throw DomainValidationError.invalidState(reason: "Speaker evidence requires nonzero voice and speech")
        }
        self.canonicalRecordingID = canonicalRecordingID
        self.canonicalPCMHash = canonicalPCMHash
        self.producerDeviceID = producerDeviceID
        self.processingArtifactSHA256 = processingArtifactSHA256
        self.localClusterID = localClusterID
        self.embedding = validatedEmbedding
        self.modelID = modelID
        self.speechDurationMs = speechDurationMs
        self.segmentCount = segmentCount
    }

    /// Stable identity independent of JSON formatting, evaluation operation IDs,
    /// recognition-pack revisions, arrival order, or a person's current name.
    public var evidenceSHA256: Data {
        var bytes = Data("harc-speaker-evidence-v1\0".utf8)
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
        }
        append(Data(canonicalRecordingID.description.utf8))
        append(canonicalPCMHash.rawBytes)
        append(producerDeviceID.rawBytes)
        append(processingArtifactSHA256)
        append(Data(localClusterID.utf8))
        append(Data(modelID.utf8))
        appendInteger(embedding.dimensions)
        appendInteger(embedding.scale.bitPattern)
        append(embedding.values)
        appendInteger(speechDurationMs)
        appendInteger(segmentCount)
        return Data(SHA256.hash(data: bytes))
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalRecordingID, canonicalPCMHash, producerDeviceID
        case processingArtifactSHA256, localClusterID, embedding, modelID
        case speechDurationMs, segmentCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            canonicalRecordingID: c.decode(CanonicalRecordingID.self, forKey: .canonicalRecordingID),
            canonicalPCMHash: c.decode(CanonicalPCMHash.self, forKey: .canonicalPCMHash),
            producerDeviceID: c.decode(DeviceID.self, forKey: .producerDeviceID),
            processingArtifactSHA256: c.decode(Data.self, forKey: .processingArtifactSHA256),
            localClusterID: c.decode(String.self, forKey: .localClusterID),
            embedding: c.decode(QuantizedSpeakerEmbedding.self, forKey: .embedding),
            modelID: c.decode(String.self, forKey: .modelID),
            speechDurationMs: c.decode(UInt64.self, forKey: .speechDurationMs),
            segmentCount: c.decode(UInt32.self, forKey: .segmentCount))
    }
}

/// An evaluation request tied to exact evidence. The numeric speaker index is
/// still a projection hint; only a validated artifact mapping can authorize it.
public struct BoundSpeakerEmbeddingObservation: Codable, Equatable, Hashable, Sendable {
    public let observation: SpeakerEmbeddingObservation
    public let evidence: SpeakerEvidenceSnapshot

    public init(observation: SpeakerEmbeddingObservation, evidence: SpeakerEvidenceSnapshot) throws {
        // Re-run observation validation for persisted input as well as fresh calls.
        let validated = try SpeakerEmbeddingObservation(
            operationID: observation.operationID, canonicalRecordingID: observation.canonicalRecordingID,
            speakerIndex: observation.speakerIndex, embedding: evidence.embedding,
            modelID: observation.modelID, speechDurationMs: observation.speechDurationMs,
            segmentCount: observation.segmentCount, sourcePackRevision: observation.sourcePackRevision,
            proposedPersonID: observation.proposedPersonID, proposedScore: observation.proposedScore)
        guard observation.canonicalRecordingID == evidence.canonicalRecordingID,
              observation.embedding == evidence.embedding,
              observation.modelID == evidence.modelID,
              observation.speechDurationMs == evidence.speechDurationMs,
              observation.segmentCount == evidence.segmentCount else {
            throw DomainValidationError.invalidState(reason: "Speaker observation does not describe its bound evidence")
        }
        self.observation = validated
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey { case observation, evidence }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(observation: c.decode(SpeakerEmbeddingObservation.self, forKey: .observation),
                      evidence: c.decode(SpeakerEvidenceSnapshot.self, forKey: .evidence))
    }
}
