import Foundation

/// A generation-bound account of Host speaker work, not proof that a name is correct.
/// Absence means unknown; older transcripts must not acquire a fabricated receipt.
public struct HostSpeakerProcessingOutcome: Codable, Equatable, Sendable {
    public enum Diarization: String, Codable, Sendable { case disabled, completed }
    public struct Cluster: Codable, Equatable, Sendable {
        public let speakerIndex: UInt32
        public let evidenceSHA256: Data?
        public let decisionOperationID: OperationID?
        public let disposition: SpeakerObservationDisposition?
        public let recognitionPackRevision: EntityRevision?

        /// Both absent means the cluster has no usable voice evidence.
        public init(speakerIndex: UInt32, evidenceSHA256: Data? = nil,
                    decisionOperationID: OperationID? = nil, disposition: SpeakerObservationDisposition? = nil,
                    recognitionPackRevision: EntityRevision? = nil) throws {
            guard (evidenceSHA256 == nil) == (decisionOperationID == nil),
                  (decisionOperationID == nil) == (disposition == nil),
                  (decisionOperationID == nil) == (recognitionPackRevision == nil),
                  evidenceSHA256 == nil || evidenceSHA256?.count == 32 else {
                throw DomainValidationError.invalidState(reason: "A completed speaker evaluation requires evidence and a decision")
            }
            self.speakerIndex = speakerIndex
            self.evidenceSHA256 = evidenceSHA256
            self.decisionOperationID = decisionOperationID
            self.disposition = disposition
            self.recognitionPackRevision = recognitionPackRevision
        }
        private enum CodingKeys: String, CodingKey { case speakerIndex, evidenceSHA256, decisionOperationID, disposition, recognitionPackRevision }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(speakerIndex: c.decode(UInt32.self, forKey: .speakerIndex),
                evidenceSHA256: c.decodeIfPresent(Data.self, forKey: .evidenceSHA256),
                decisionOperationID: c.decodeIfPresent(OperationID.self, forKey: .decisionOperationID),
                disposition: c.decodeIfPresent(SpeakerObservationDisposition.self, forKey: .disposition),
                recognitionPackRevision: c.decodeIfPresent(EntityRevision.self, forKey: .recognitionPackRevision))
        }
    }
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalPCMHash: CanonicalPCMHash
    public let producerDeviceID: DeviceID
    public let processingArtifactSHA256: Data
    public let diarization: Diarization
    public let clusters: [Cluster]

    public init(canonicalRecordingID: CanonicalRecordingID, canonicalPCMHash: CanonicalPCMHash,
                producerDeviceID: DeviceID, processingArtifactSHA256: Data,
                diarization: Diarization, clusters: [Cluster]) throws {
        guard processingArtifactSHA256.count == 32,
              Set(clusters.map(\.speakerIndex)).count == clusters.count,
              diarization != .disabled || clusters.isEmpty else {
            throw DomainValidationError.invalidState(reason: "Invalid Host speaker outcome generation or cluster inventory")
        }
        let operations = clusters.compactMap(\.decisionOperationID)
        guard Set(operations).count == operations.count else {
            throw DomainValidationError.invalidState(reason: "A speaker decision cannot complete two clusters")
        }
        self.canonicalRecordingID = canonicalRecordingID
        self.canonicalPCMHash = canonicalPCMHash
        self.producerDeviceID = producerDeviceID
        self.processingArtifactSHA256 = processingArtifactSHA256
        self.diarization = diarization
        self.clusters = clusters.sorted { $0.speakerIndex < $1.speakerIndex }
    }
    private enum CodingKeys: String, CodingKey {
        case canonicalRecordingID, canonicalPCMHash, producerDeviceID, processingArtifactSHA256, diarization, clusters
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(canonicalRecordingID: c.decode(CanonicalRecordingID.self, forKey: .canonicalRecordingID),
            canonicalPCMHash: c.decode(CanonicalPCMHash.self, forKey: .canonicalPCMHash),
            producerDeviceID: c.decode(DeviceID.self, forKey: .producerDeviceID),
            processingArtifactSHA256: c.decode(Data.self, forKey: .processingArtifactSHA256),
            diarization: c.decode(Diarization.self, forKey: .diarization),
            clusters: c.decode([Cluster].self, forKey: .clusters))
    }
}
