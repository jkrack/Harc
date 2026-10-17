import Foundation
import HarcDomain
import HarcProtocolWire

public extension Harc_V1_HostSpeakerClusterOutcomeV1 {
    init(_ value: HostSpeakerProcessingOutcome.Cluster) {
        self.init()
        speakerIndex = value.speakerIndex
        if let evidence = value.evidenceSHA256, let operation = value.decisionOperationID,
           let disposition = value.disposition, let revision = value.recognitionPackRevision {
            state = .hostSpeakerClusterStateEvaluated
            evidenceSha256.value = evidence
            decisionOperationID = Harc_V1_OperationIDV1(operation)
            self.disposition = Harc_V1_SpeakerObservationDispositionV1(disposition)
            recognitionPackRevision = revision.rawValue
        } else {
            state = .hostSpeakerClusterStateMissingEvidence
        }
    }

    func domainValue() throws -> HostSpeakerProcessingOutcome.Cluster {
        guard hasSpeakerIndex else { throw HarcProtobufConversionError.missingField("hostSpeakerCluster.speakerIndex") }
        switch state {
        case .hostSpeakerClusterStateMissingEvidence:
            guard !hasEvidenceSha256, !hasDecisionOperationID, !hasRecognitionPackRevision,
                  disposition == .speakerObservationDispositionUnspecified else {
                throw HarcProtobufConversionError.inconsistentField("hostSpeakerCluster.missingEvidence")
            }
            return try .init(speakerIndex: speakerIndex)
        case .hostSpeakerClusterStateEvaluated:
            guard hasEvidenceSha256, hasDecisionOperationID, hasRecognitionPackRevision else {
                throw HarcProtobufConversionError.missingField("hostSpeakerCluster.evaluation")
            }
            return try .init(speakerIndex: speakerIndex, evidenceSHA256: evidenceSha256.value,
                decisionOperationID: decisionOperationID.domainValue(), disposition: disposition.domainValue(),
                recognitionPackRevision: EntityRevision(recognitionPackRevision))
        default:
            throw HarcProtobufConversionError.inconsistentField("hostSpeakerCluster.state")
        }
    }
}

public extension Harc_V1_HostSpeakerProcessingOutcomeV1 {
    init(_ value: HostSpeakerProcessingOutcome) {
        self.init()
        canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(value.canonicalRecordingID)
        canonicalAudioSha256.value = value.canonicalPCMHash.rawBytes
        producerDeviceID = Harc_V1_DeviceIDV1(value.producerDeviceID)
        processingArtifactSha256.value = value.processingArtifactSHA256
        diarization = value.diarization == .disabled ? .hostSpeakerDiarizationStateDisabled : .hostSpeakerDiarizationStateCompleted
        clusters = value.clusters.map(Harc_V1_HostSpeakerClusterOutcomeV1.init)
    }

    func domainValue() throws -> HostSpeakerProcessingOutcome {
        guard hasCanonicalRecordingID, hasCanonicalAudioSha256, hasProducerDeviceID, hasProcessingArtifactSha256 else {
            throw HarcProtobufConversionError.missingField("hostSpeakerOutcome.binding")
        }
        let mode: HostSpeakerProcessingOutcome.Diarization
        switch diarization {
        case .hostSpeakerDiarizationStateDisabled: mode = .disabled
        case .hostSpeakerDiarizationStateCompleted: mode = .completed
        default: throw HarcProtobufConversionError.inconsistentField("hostSpeakerOutcome.diarization")
        }
        return try .init(canonicalRecordingID: canonicalRecordingID.domainValue(),
            canonicalPCMHash: CanonicalPCMHash(canonicalAudioSha256.value),
            producerDeviceID: producerDeviceID.domainValue(), processingArtifactSHA256: processingArtifactSha256.value,
            diarization: mode, clusters: clusters.map { try $0.domainValue() })
    }
}

public extension Harc_V1_ProcessingStatusV1 {
    /// Call only on the response to an authenticated own-recording status request.
    /// The caller supplies identity from its adoption and durable audio receipt,
    /// never from fields in this response. This does not qualify model accuracy.
    func validatedHostSpeakerOutcome(canonicalID: CanonicalRecordingID,
        originID: OriginRecordingID, canonicalPCMHash: CanonicalPCMHash,
        producerDeviceID: DeviceID) throws -> HostSpeakerProcessingOutcome? {
        guard hasHostSpeakerOutcome else { return nil }
        guard hasCanonicalRecordingID, hasOriginRecordingID, hasCanonicalAudioSha256,
              hasProcessing, hasProjection, !hasSelectedEdgeBundleSha256,
              try canonicalRecordingID.domainValue() == canonicalID,
              try originRecordingID.domainValue() == originID,
              canonicalAudioSha256.value == canonicalPCMHash.rawBytes,
              try processing.domainValue().state == .ready,
              try projection.domainValue().state == .ready else {
            throw HarcProtobufConversionError.inconsistentField("hostSpeakerOutcome.statusBinding")
        }
        let value = try hostSpeakerOutcome.domainValue()
        guard value.canonicalRecordingID == canonicalID,
              value.canonicalPCMHash == canonicalPCMHash, value.producerDeviceID == producerDeviceID else {
            throw HarcProtobufConversionError.inconsistentField("hostSpeakerOutcome.authorityOrAudio")
        }
        return value
    }
}
