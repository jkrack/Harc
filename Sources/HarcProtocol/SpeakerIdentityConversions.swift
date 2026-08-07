import Foundation
import HarcDomain
import HarcProtocolWire

public extension Harc_V1_QuantizedSpeakerEmbeddingV1 {
    init(_ value: QuantizedSpeakerEmbedding) {
        self.init()
        dimensions = value.dimensions
        signedInt8Values = value.values
        scale = value.scale
    }

    func domainValue() throws -> QuantizedSpeakerEmbedding {
        try QuantizedSpeakerEmbedding(
            dimensions: dimensions,
            values: signedInt8Values,
            scale: scale
        )
    }
}

public extension Harc_V1_SpeakerRecognitionPrototypeV1 {
    init(_ value: SpeakerRecognitionPrototype) {
        self.init()
        prototypeID = Harc_V1_SpeakerPrototypeIDV1(value.id)
        embedding = Harc_V1_QuantizedSpeakerEmbeddingV1(value.embedding)
        speechDurationMs = value.speechDurationMs
        segmentCount = value.segmentCount
    }

    func domainValue() throws -> SpeakerRecognitionPrototype {
        guard hasPrototypeID else {
            throw HarcProtobufConversionError.missingField("speakerPrototype.prototypeID")
        }
        guard hasEmbedding else {
            throw HarcProtobufConversionError.missingField("speakerPrototype.embedding")
        }
        return try SpeakerRecognitionPrototype(
            id: prototypeID.domainValue(),
            embedding: embedding.domainValue(),
            speechDurationMs: speechDurationMs,
            segmentCount: segmentCount
        )
    }
}

public extension Harc_V1_SpeakerIdentityProfileV1 {
    init(_ value: SpeakerIdentityProfile) {
        self.init()
        personID = Harc_V1_PersonIDV1(value.id)
        displayName = value.displayName
        matchThreshold = value.matchThreshold
        revision = value.revision.rawValue
        prototypes = value.prototypes.map(Harc_V1_SpeakerRecognitionPrototypeV1.init)
    }

    func domainValue() throws -> SpeakerIdentityProfile {
        guard hasPersonID else {
            throw HarcProtobufConversionError.missingField("speakerIdentityProfile.personID")
        }
        return try SpeakerIdentityProfile(
            id: personID.domainValue(),
            displayName: displayName,
            matchThreshold: matchThreshold,
            revision: EntityRevision(revision),
            prototypes: prototypes.map { try $0.domainValue() }
        )
    }
}

public extension Harc_V1_SpeakerRecognitionPackV1 {
    init(_ value: SpeakerRecognitionPack) throws {
        self.init()
        revision = value.revision.rawValue
        modelID = value.modelID
        dimensions = value.dimensions
        generatedAtUnixMs = try speakerWireMilliseconds(value.generatedAt)
        expiresAtUnixMs = try speakerWireMilliseconds(value.expiresAt)
        profiles = value.profiles.map(Harc_V1_SpeakerIdentityProfileV1.init)
    }

    func domainValue() throws -> SpeakerRecognitionPack {
        try SpeakerRecognitionPack(
            revision: EntityRevision(revision),
            modelID: modelID,
            dimensions: dimensions,
            generatedAt: try speakerWireDate(generatedAtUnixMs),
            expiresAt: try speakerWireDate(expiresAtUnixMs),
            profiles: profiles.map { try $0.domainValue() }
        )
    }
}

public extension Harc_V1_SpeakerEmbeddingObservationV1 {
    init(_ value: SpeakerEmbeddingObservation) {
        self.init()
        operationID = Harc_V1_OperationIDV1(value.operationID)
        canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(value.canonicalRecordingID)
        speakerIndex = value.speakerIndex
        embedding = Harc_V1_QuantizedSpeakerEmbeddingV1(value.embedding)
        modelID = value.modelID
        speechDurationMs = value.speechDurationMs
        segmentCount = value.segmentCount
        if let revision = value.sourcePackRevision { sourcePackRevision = revision.rawValue }
        if let personID = value.proposedPersonID { proposedPersonID = Harc_V1_PersonIDV1(personID) }
        if let score = value.proposedScore { proposedScore = score }
    }

    func domainValue() throws -> SpeakerEmbeddingObservation {
        guard hasOperationID else {
            throw HarcProtobufConversionError.missingField("speakerObservation.operationID")
        }
        guard hasCanonicalRecordingID else {
            throw HarcProtobufConversionError.missingField("speakerObservation.canonicalRecordingID")
        }
        guard hasEmbedding else {
            throw HarcProtobufConversionError.missingField("speakerObservation.embedding")
        }
        guard hasProposedPersonID == hasProposedScore else {
            throw HarcProtobufConversionError.invalidValue(field: "speakerObservation.proposal")
        }
        return try SpeakerEmbeddingObservation(
            operationID: operationID.domainValue(),
            canonicalRecordingID: canonicalRecordingID.domainValue(),
            speakerIndex: speakerIndex,
            embedding: embedding.domainValue(),
            modelID: modelID,
            speechDurationMs: speechDurationMs,
            segmentCount: segmentCount,
            sourcePackRevision: hasSourcePackRevision ? try EntityRevision(sourcePackRevision) : nil,
            proposedPersonID: hasProposedPersonID ? try proposedPersonID.domainValue() : nil,
            proposedScore: hasProposedScore ? proposedScore : nil
        )
    }
}

public extension Harc_V1_SpeakerObservationDispositionV1 {
    init(_ value: SpeakerObservationDisposition) {
        switch value {
        case .matched: self = .speakerObservationDispositionMatched
        case .noMatch: self = .speakerObservationDispositionNoMatch
        case .pendingReview: self = .speakerObservationDispositionPendingReview
        }
    }

    func domainValue() throws -> SpeakerObservationDisposition {
        switch self {
        case .speakerObservationDispositionMatched: return .matched
        case .speakerObservationDispositionNoMatch: return .noMatch
        case .speakerObservationDispositionPendingReview: return .pendingReview
        case .speakerObservationDispositionUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "speakerObservationDecision.disposition",
                rawValue: rawValue
            )
        case .UNRECOGNIZED(let rawValue):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "speakerObservationDecision.disposition",
                rawValue: rawValue
            )
        }
    }
}

public extension Harc_V1_SpeakerObservationDecisionV1 {
    init(_ value: SpeakerObservationDecision) {
        self.init()
        operationID = Harc_V1_OperationIDV1(value.operationID)
        disposition = Harc_V1_SpeakerObservationDispositionV1(value.disposition)
        if let personID = value.personID { self.personID = Harc_V1_PersonIDV1(personID) }
        if let displayName = value.displayName { self.displayName = displayName }
        if let score = value.score { self.score = score }
        recognitionPackRevision = value.recognitionPackRevision.rawValue
        recordingRevision = value.recordingRevision.rawValue
    }

    func domainValue() throws -> SpeakerObservationDecision {
        guard hasOperationID else {
            throw HarcProtobufConversionError.missingField("speakerObservationDecision.operationID")
        }
        guard hasPersonID == hasDisplayName, hasDisplayName == hasScore else {
            throw HarcProtobufConversionError.invalidValue(field: "speakerObservationDecision.identity")
        }
        return try SpeakerObservationDecision(
            operationID: operationID.domainValue(),
            disposition: disposition.domainValue(),
            personID: hasPersonID ? try personID.domainValue() : nil,
            displayName: hasDisplayName ? displayName : nil,
            score: hasScore ? score : nil,
            recognitionPackRevision: EntityRevision(recognitionPackRevision),
            recordingRevision: EntityRevision(recordingRevision)
        )
    }
}

private func speakerWireMilliseconds(_ date: Date) throws -> UInt64 {
    let milliseconds = date.timeIntervalSince1970 * 1_000
    guard milliseconds.isFinite,
          milliseconds >= 0,
          milliseconds <= Double(UInt64.max) else {
        throw HarcProtobufConversionError.invalidValue(field: "speakerIdentity.date")
    }
    return UInt64(milliseconds.rounded(.towardZero))
}

private func speakerWireDate(_ milliseconds: UInt64) throws -> Date {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw HarcProtobufConversionError.invalidValue(field: "speakerIdentity.date")
    }
    return date
}
