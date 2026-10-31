import Foundation
import HarcDomain
import HarcProtocolWire
import Testing
@testable import HarcProtocol

@Suite("Bound speaker evidence conversion")
struct SpeakerEvidenceBindingTests {
    private func fixture() throws -> BoundSpeakerEmbeddingObservation {
        let evidence = try SpeakerEvidenceSnapshot(
            canonicalRecordingID: CanonicalRecordingID(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!),
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: 1, count: 32)),
            producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(repeating: 3, count: 32), localClusterID: "cluster-0",
            embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127, 0, 255]), scale: 0.5),
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 2)
        let observation = try SpeakerEmbeddingObservation(operationID: .random(),
            canonicalRecordingID: evidence.canonicalRecordingID, speakerIndex: 0,
            embedding: evidence.embedding, modelID: evidence.modelID,
            speechDurationMs: evidence.speechDurationMs, segmentCount: evidence.segmentCount)
        return try BoundSpeakerEmbeddingObservation(observation: observation, evidence: evidence)
    }

    @Test func boundRequestRequiresNegotiationAndCannotDowngradeToLegacy() throws {
        let value = try fixture()
        let feature = HarcSpeakerObservationRequestV1.boundFeatureID
        #expect(throws: (any Error).self) { try HarcSpeakerObservationRequestV1.boundRequest(value, negotiatedFeatureIDs: []) }
        let request = try HarcSpeakerObservationRequestV1.boundRequest(value, negotiatedFeatureIDs: [feature])
        let decoded = try Harc_V1_SubmitSpeakerObservationRequestV1(serializedBytes: request.serializedData())
        #expect(!decoded.hasObservation && decoded.hasBoundObservation)
        #expect(try HarcSpeakerObservationRequestV1(decoded, negotiatedFeatureIDs: [feature]) == .bound(value))
        #expect(throws: (any Error).self) { try HarcSpeakerObservationRequestV1(decoded, negotiatedFeatureIDs: []) }
        #expect(throws: (any Error).self) {
            try HarcProtobufCompatibilityPolicy.currentV1.validate(decoded.protocol, knownCriticalFieldNumbers: [1,2])
        }
        for mode in 0..<4 {
            var invalid = request
            switch mode {
            case 0: invalid.protocol.requirements.criticalFieldNumbers = []
            case 1: invalid.protocol.requirements.requiredFeatures = []
            case 2: invalid.observation = Harc_V1_SpeakerEmbeddingObservationV1(value.observation)
            default: invalid.boundObservation.clearEvidence()
            }
            #expect(throws: (any Error).self) { try HarcSpeakerObservationRequestV1(invalid, negotiatedFeatureIDs: [feature]) }
        }
        var legacy = Harc_V1_SubmitSpeakerObservationRequestV1()
        legacy.protocol = HarcProtocolVersion.v1.protobufV1()
        legacy.observation = Harc_V1_SpeakerEmbeddingObservationV1(value.observation)
        #expect(try HarcSpeakerObservationRequestV1(legacy, negotiatedFeatureIDs: []) == .legacy(value.observation))
        legacy.protocol = request.protocol
        #expect(throws: (any Error).self) { try HarcSpeakerObservationRequestV1(legacy, negotiatedFeatureIDs: [feature]) }
        var empty = Harc_V1_SubmitSpeakerObservationRequestV1()
        empty.protocol = HarcProtocolVersion.v1.protobufV1()
        #expect(throws: (any Error).self) { try HarcSpeakerObservationRequestV1(empty, negotiatedFeatureIDs: []) }
    }

    @Test func exactEvidenceSurvivesWireAndJSONRoundTrips() throws {
        let value = try fixture()
        let bytes = try Harc_V1_BoundSpeakerEmbeddingObservationV1(value).serializedData()
        let wire = try Harc_V1_BoundSpeakerEmbeddingObservationV1(serializedBytes: bytes)
        #expect(try wire.domainValue() == value)
        #expect(try wire.domainValue().evidence.evidenceSHA256 == value.evidence.evidenceSHA256)
        #expect(try JSONDecoder().decode(BoundSpeakerEmbeddingObservation.self,
            from: JSONEncoder().encode(value)) == value)
    }

    @Test func alteredObservationCannotClaimUnchangedEvidence() throws {
        let value = try fixture()
        let edits: [(inout Harc_V1_SpeakerEmbeddingObservationV1) -> Void] = [
            { $0.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(CanonicalRecordingID.random()) },
            { $0.embedding.signedInt8Values = Data([0, 127, 255]) },
            { $0.embedding.scale = 0.25 },
            { $0.modelID = "another-model" },
            { $0.speechDurationMs += 1 },
            { $0.segmentCount += 1 }
        ]
        for edit in edits {
            var wire = Harc_V1_BoundSpeakerEmbeddingObservationV1(value)
            edit(&wire.observation)
            #expect(throws: (any Error).self) { try wire.domainValue() }
        }
    }

    @Test func missingOrMalformedEvidenceIsNotLegacyFallback() throws {
        let value = try fixture()
        let edits: [(inout Harc_V1_BoundSpeakerEmbeddingObservationV1) -> Void] = [
            { $0.clearObservation() }, { $0.clearEvidence() },
            { $0.evidence.clearCanonicalRecordingID() }, { $0.evidence.clearProducerDeviceID() },
            { $0.evidence.clearEmbedding() }, { $0.evidence.canonicalPcmSha256 = Data([1]) },
            { $0.evidence.processingArtifactSha256 = Data([1]) },
            { $0.evidence.localClusterID = "" }, { $0.evidence.embedding.scale = 0 }
        ]
        for edit in edits {
            var wire = Harc_V1_BoundSpeakerEmbeddingObservationV1(value); edit(&wire)
            #expect(throws: (any Error).self) { try wire.domainValue() }
        }
        // Legacy values still round-trip as legacy values, never as evidence.
        let legacy = Harc_V1_SpeakerEmbeddingObservationV1(value.observation)
        #expect(try legacy.domainValue() == value.observation)
        #expect(throws: (any Error).self) {
            try Harc_V1_BoundSpeakerEmbeddingObservationV1(serializedBytes: legacy.serializedData()).domainValue()
        }
    }

    @Test func reevaluationChangesOperationButNotEvidence() throws {
        let value = try fixture()
        var wire = Harc_V1_BoundSpeakerEmbeddingObservationV1(value)
        wire.observation.operationID = Harc_V1_OperationIDV1(.random())
        wire.observation.sourcePackRevision = 5
        let reevaluated = try wire.domainValue()
        #expect(reevaluated.observation.operationID != value.observation.operationID)
        #expect(reevaluated.evidence.evidenceSHA256 == value.evidence.evidenceSHA256)
    }

    @Test func persistedEnvelopeRevalidatesPayloadBinding() throws {
        let value = try fixture()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        var observation = try #require(json["observation"] as? [String: Any])
        observation["speechDurationMs"] = 7000; json["observation"] = observation
        let bytes = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BoundSpeakerEmbeddingObservation.self, from: bytes)
        }
    }
}
