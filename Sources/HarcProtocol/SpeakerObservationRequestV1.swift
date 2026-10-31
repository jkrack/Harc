import Foundation
import HarcDomain
import HarcProtocolWire

public enum HarcSpeakerObservationRequestV1: Sendable, Equatable {
    public static let boundFeatureID = "harc.speaker-evidence.v1"
    case legacy(SpeakerEmbeddingObservation)
    case bound(BoundSpeakerEmbeddingObservation)

    public init(_ wire: Harc_V1_SubmitSpeakerObservationRequestV1,
        negotiatedFeatureIDs: Set<String>, compatibility: HarcProtobufCompatibilityPolicy = .currentV1) throws {
        guard wire.hasProtocol else { throw HarcProtobufConversionError.missingField("speakerRequest.protocol") }
        _ = try compatibility.validate(wire.protocol, knownCriticalFieldNumbers: [1, 2, 3])
        guard wire.hasObservation != wire.hasBoundObservation else {
            throw HarcProtobufConversionError.inconsistentField("speakerRequest.exactlyOneObservation")
        }
        if wire.hasBoundObservation {
            guard wire.protocol.requirements.criticalFieldNumbers.contains(3),
                  wire.protocol.requirements.requiredFeatures.contains(Self.boundFeatureID),
                  negotiatedFeatureIDs.contains(Self.boundFeatureID) else {
                throw HarcProtobufConversionError.inconsistentField("speakerRequest.boundNegotiation")
            }
            self = .bound(try wire.boundObservation.domainValue())
        } else {
            guard !wire.protocol.requirements.requiredFeatures.contains(Self.boundFeatureID),
                  !wire.protocol.requirements.criticalFieldNumbers.contains(3) else {
                throw HarcProtobufConversionError.inconsistentField("speakerRequest.boundEvidenceMissing")
            }
            self = .legacy(try wire.observation.domainValue())
        }
    }

    public static func boundRequest(_ value: BoundSpeakerEmbeddingObservation,
        negotiatedFeatureIDs: Set<String>, protocolVersion: HarcProtocolVersion = .v1) throws -> Harc_V1_SubmitSpeakerObservationRequestV1 {
        guard negotiatedFeatureIDs.contains(boundFeatureID) else {
            throw HarcProtobufConversionError.inconsistentField("speakerRequest.boundNegotiation")
        }
        var request = Harc_V1_SubmitSpeakerObservationRequestV1()
        request.protocol = protocolVersion.protobufV1()
        request.protocol.requirements.criticalFieldNumbers = [3]
        request.protocol.requirements.requiredFeatures = [boundFeatureID]
        request.boundObservation = Harc_V1_BoundSpeakerEmbeddingObservationV1(value)
        return request
    }
}
