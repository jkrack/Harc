import Foundation
import HarcDomain
import HarcProtocolWire

/// Evidence bound to an authenticated, currently selected edge artifact and a
/// Host-resolved canonical recording. This proves provenance and cluster membership,
/// not the accuracy of the producing device's model or a human confirmation.
public struct HarcValidatedSpeakerEvidenceV1: Sendable {
    public let value: BoundSpeakerEmbeddingObservation
    public let clusterMap: SpeakerClusterMap
    public let canonicalSpeakerIndex: UInt32

    public init(
        _ value: BoundSpeakerEmbeddingObservation,
        submission: HarcValidatedProcessingSubmissionV1,
        canonicalRecordingID: CanonicalRecordingID,
        originRecordingID: OriginRecordingID,
        canonicalPCMHash: CanonicalPCMHash,
        currentArtifactSHA256: Data
    ) throws {
        try self.init(value, metadata: submission.metadata.message, bundle: submission.bundle,
            map: submission.speakerClusterMap(canonicalRecordingID: canonicalRecordingID),
            canonicalRecordingID: canonicalRecordingID, originRecordingID: originRecordingID,
            canonicalPCMHash: canonicalPCMHash, currentArtifactSHA256: currentArtifactSHA256)
    }

    public init(_ value: BoundSpeakerEmbeddingObservation,
        retainedArtifact: HarcValidatedRetainedProcessingArtifactV1,
        canonicalRecordingID: CanonicalRecordingID, originRecordingID: OriginRecordingID,
        canonicalPCMHash: CanonicalPCMHash, currentArtifactSHA256: Data) throws {
        try self.init(value, metadata: retainedArtifact.metadata.message, bundle: retainedArtifact.bundle,
            map: retainedArtifact.speakerClusterMap(canonicalRecordingID: canonicalRecordingID),
            canonicalRecordingID: canonicalRecordingID, originRecordingID: originRecordingID,
            canonicalPCMHash: canonicalPCMHash, currentArtifactSHA256: currentArtifactSHA256)
    }

    private init(_ value: BoundSpeakerEmbeddingObservation, metadata: Harc_V1_ProcessingArtifactV1,
        bundle: HarcProcessingBundleV1, map: SpeakerClusterMap,
        canonicalRecordingID: CanonicalRecordingID, originRecordingID: OriginRecordingID,
        canonicalPCMHash: CanonicalPCMHash, currentArtifactSHA256: Data) throws {
        let evidence = value.evidence
        guard evidence.canonicalRecordingID == canonicalRecordingID,
              try metadata.originRecordingID.domainValue() == originRecordingID,
              evidence.canonicalPCMHash == canonicalPCMHash,
              metadata.canonicalAudioSha256.value == canonicalPCMHash.rawBytes else {
            throw HarcProtobufConversionError.inconsistentField("speakerEvidence.canonicalBinding")
        }
        guard try metadata.producingDeviceID.domainValue() == evidence.producerDeviceID else {
            throw HarcProtobufConversionError.inconsistentField("speakerEvidence.producer")
        }
        guard currentArtifactSHA256.count == 32,
              currentArtifactSHA256 == bundle.exactSHA256,
              evidence.processingArtifactSHA256 == bundle.exactSHA256 else {
            throw HarcProtobufConversionError.inconsistentField("speakerEvidence.currentArtifact")
        }
        var clusterFrames: UInt64 = 0
        var found = false
        for entry in bundle.entries {
            guard case .diarization(_, let diarization) = entry else { continue }
            for turn in diarization.turns where turn.localClusterID == evidence.localClusterID {
                found = true
                let sum = clusterFrames.addingReportingOverflow(turn.endFrameExclusive - turn.startFrame)
                guard !sum.overflow else {
                    throw HarcProtobufConversionError.invalidValue(field: "speakerEvidence.clusterDuration")
                }
                clusterFrames = sum.partialValue
            }
        }
        // V1 canonical audio is 16,000 frames/second. Integer division avoids
        // overflow and does not grant evidence for a fractional extra millisecond.
        guard found, evidence.speechDurationMs <= clusterFrames / 16 else {
            throw HarcProtobufConversionError.inconsistentField("speakerEvidence.clusterMembershipOrDuration")
        }
        self.canonicalSpeakerIndex = try map.canonicalSpeakerIndex(for: evidence)
        self.clusterMap = map
        self.value = value
    }
}

public extension HarcValidatedProcessingSubmissionV1 {
    /// Derives the complete namespace from the authenticated exact bundle. A caller
    /// supplies only the Host-resolved recording ID, never its own cluster list.
    /// Selection of this artifact as current remains a separate Store transaction.
    func speakerClusterMap(canonicalRecordingID: CanonicalRecordingID) throws -> SpeakerClusterMap {
        try processingSpeakerClusterMap(metadata: metadata.message, bundle: bundle, canonicalRecordingID: canonicalRecordingID)
    }
}

public extension HarcValidatedRetainedProcessingArtifactV1 {
    func speakerClusterMap(canonicalRecordingID: CanonicalRecordingID) throws -> SpeakerClusterMap {
        try processingSpeakerClusterMap(metadata: metadata.message, bundle: bundle, canonicalRecordingID: canonicalRecordingID)
    }
}

private func processingSpeakerClusterMap(metadata: Harc_V1_ProcessingArtifactV1,
    bundle: HarcProcessingBundleV1, canonicalRecordingID: CanonicalRecordingID) throws -> SpeakerClusterMap {
        var clusters: Set<String> = []
        for entry in bundle.entries {
            switch entry {
            case .diarization(_, let value):
                for turn in value.turns { clusters.insert(turn.localClusterID) }
            case .transcript(_, let value):
                for utterance in value.utterances {
                    if utterance.hasLocalSpeakerID { clusters.insert(utterance.localSpeakerID) }
                    for word in utterance.words where word.hasLocalSpeakerID {
                        clusters.insert(word.localSpeakerID)
                    }
                }
            default: break
            }
        }
        return try SpeakerClusterMap(canonicalRecordingID: canonicalRecordingID,
            canonicalPCMHash: CanonicalPCMHash(metadata.canonicalAudioSha256.value),
            producerDeviceID: metadata.producingDeviceID.domainValue(),
            processingArtifactSHA256: bundle.exactSHA256, localClusterIDs: Array(clusters))
}
