import Foundation

/// A compact, normalized voice vector. Each byte is the bit pattern of an
/// `Int8`; multiplying it by `scale` reconstructs the approximate Float value.
public struct QuantizedSpeakerEmbedding: Codable, Equatable, Hashable, Sendable {
    public static let maximumDimensions: UInt32 = 4_096

    public let dimensions: UInt32
    public let values: Data
    public let scale: Float

    public init(dimensions: UInt32, values: Data, scale: Float) throws {
        guard dimensions > 0, dimensions <= Self.maximumDimensions else {
            throw DomainValidationError.invalidState(reason: "Speaker embedding dimensions are out of range")
        }
        guard values.count == Int(dimensions) else {
            throw DomainValidationError.invalidDigestLength(
                field: "QuantizedSpeakerEmbedding.values",
                expected: Int(dimensions),
                actual: values.count
            )
        }
        guard scale.isFinite, scale > 0 else {
            throw DomainValidationError.invalidState(reason: "Speaker embedding scale must be finite and positive")
        }
        self.dimensions = dimensions
        self.values = values
        self.scale = scale
    }

    public static func quantizing(_ vector: [Float]) throws -> Self {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite),
              vector.count <= Int(maximumDimensions) else {
            throw DomainValidationError.invalidState(
                reason: "Speaker embedding contains invalid values"
            )
        }
        let maximum = vector.reduce(Float.zero) { max($0, abs($1)) }
        let scale = max(maximum / 127, Float.leastNonzeroMagnitude)
        return try Self(
            dimensions: UInt32(vector.count),
            values: Data(vector.map {
                UInt8(bitPattern: Int8(clamping: Int(($0 / scale).rounded())))
            }),
            scale: scale
        )
    }

    public var dequantized: [Float] {
        values.map { Float(Int8(bitPattern: $0)) * scale }
    }
}

public struct ProvisionalSpeakerMatch: Equatable, Hashable, Sendable {
    public let personID: PersonID
    public let displayName: String
    public let score: Double
    public let profileRevision: EntityRevision
    public let packRevision: EntityRevision
}

/// Pure client-side matcher for immediate provisional labels. The Host always
/// re-evaluates the observation against its authoritative evidence.
public enum SpeakerRecognitionMatcher {
    public static func bestMatch(
        embedding: QuantizedSpeakerEmbedding,
        modelID: String,
        pack: SpeakerRecognitionPack,
        at now: Date = Date()
    ) -> ProvisionalSpeakerMatch? {
        guard pack.modelID == modelID,
              pack.dimensions == embedding.dimensions,
              now < pack.expiresAt else { return nil }
        let query = embedding.dequantized
        var best: (SpeakerIdentityProfile, Double)?
        for profile in pack.profiles {
            for prototype in profile.prototypes {
                let score = cosineSimilarity(query, prototype.embedding.dequantized)
                if best == nil || score > best!.1 { best = (profile, score) }
            }
        }
        guard let best, best.1 >= best.0.matchThreshold else { return nil }
        return ProvisionalSpeakerMatch(
            personID: best.0.id,
            displayName: best.0.displayName,
            score: best.1,
            profileRevision: best.0.revision,
            packRevision: pack.revision
        )
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

public struct SpeakerRecognitionPrototype: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: SpeakerPrototypeID
    public let embedding: QuantizedSpeakerEmbedding
    public let speechDurationMs: UInt64
    public let segmentCount: UInt32

    public init(
        id: SpeakerPrototypeID,
        embedding: QuantizedSpeakerEmbedding,
        speechDurationMs: UInt64,
        segmentCount: UInt32
    ) throws {
        guard speechDurationMs > 0, segmentCount > 0 else {
            throw DomainValidationError.invalidState(reason: "A speaker prototype requires observed speech")
        }
        self.id = id
        self.embedding = embedding
        self.speechDurationMs = speechDurationMs
        self.segmentCount = segmentCount
    }
}

/// One durable host-owned speaker identity and the small set of representative
/// prototypes clients may use for low-latency provisional matching.
public struct SpeakerIdentityProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: PersonID
    public let displayName: String
    public let matchThreshold: Double
    public let revision: EntityRevision
    public let prototypes: [SpeakerRecognitionPrototype]

    public init(
        id: PersonID,
        displayName: String,
        matchThreshold: Double,
        revision: EntityRevision,
        prototypes: [SpeakerRecognitionPrototype]
    ) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainValidationError.emptyField(field: "SpeakerIdentityProfile.displayName")
        }
        guard trimmed.count <= 256 else {
            throw DomainValidationError.fieldTooLong(
                field: "SpeakerIdentityProfile.displayName",
                maximum: 256,
                actual: trimmed.count
            )
        }
        guard matchThreshold.isFinite, (0 ... 1).contains(matchThreshold) else {
            throw DomainValidationError.invalidState(reason: "Speaker match threshold must be between zero and one")
        }
        guard prototypes.map(\.id) == prototypes.map(\.id).sorted() else {
            throw DomainValidationError.invalidOrdering(field: "SpeakerIdentityProfile.prototypes")
        }
        guard Set(prototypes.map(\.id)).count == prototypes.count else {
            throw DomainValidationError.duplicateIdentifier(field: "SpeakerIdentityProfile.prototypes")
        }
        self.id = id
        self.displayName = trimmed
        self.matchThreshold = matchThreshold
        self.revision = revision
        self.prototypes = prototypes
    }
}

/// An authenticated, versioned snapshot downloaded asynchronously over the
/// pinned Host session by paired clients.
/// It contains compact prototypes, not the Host's raw embedding history.
public struct SpeakerRecognitionPack: Codable, Equatable, Hashable, Sendable {
    public let revision: EntityRevision
    public let modelID: String
    public let dimensions: UInt32
    public let generatedAt: Date
    public let expiresAt: Date
    public let profiles: [SpeakerIdentityProfile]

    public init(
        revision: EntityRevision,
        modelID: String,
        dimensions: UInt32,
        generatedAt: Date,
        expiresAt: Date,
        profiles: [SpeakerIdentityProfile]
    ) throws {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else {
            throw DomainValidationError.emptyField(field: "SpeakerRecognitionPack.modelID")
        }
        guard trimmedModelID.count <= 128 else {
            throw DomainValidationError.fieldTooLong(
                field: "SpeakerRecognitionPack.modelID",
                maximum: 128,
                actual: trimmedModelID.count
            )
        }
        guard dimensions > 0, dimensions <= QuantizedSpeakerEmbedding.maximumDimensions else {
            throw DomainValidationError.invalidState(reason: "Recognition-pack dimensions are out of range")
        }
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > generatedAt else {
            throw DomainValidationError.invalidDate(field: "SpeakerRecognitionPack.expiry")
        }
        guard profiles.map(\.id) == profiles.map(\.id).sorted() else {
            throw DomainValidationError.invalidOrdering(field: "SpeakerRecognitionPack.profiles")
        }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw DomainValidationError.duplicateIdentifier(field: "SpeakerRecognitionPack.profiles")
        }
        guard profiles.flatMap(\.prototypes).allSatisfy({ $0.embedding.dimensions == dimensions }) else {
            throw DomainValidationError.invalidState(reason: "Recognition-pack prototype dimensions disagree")
        }
        self.revision = revision
        self.modelID = trimmedModelID
        self.dimensions = dimensions
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.profiles = profiles
    }
}

public struct SpeakerEmbeddingObservation: Codable, Equatable, Hashable, Sendable {
    public let operationID: OperationID
    public let canonicalRecordingID: CanonicalRecordingID
    public let speakerIndex: UInt32
    public let embedding: QuantizedSpeakerEmbedding
    public let modelID: String
    public let speechDurationMs: UInt64
    public let segmentCount: UInt32
    public let sourcePackRevision: EntityRevision?
    public let proposedPersonID: PersonID?
    public let proposedScore: Double?

    public init(
        operationID: OperationID,
        canonicalRecordingID: CanonicalRecordingID,
        speakerIndex: UInt32,
        embedding: QuantizedSpeakerEmbedding,
        modelID: String,
        speechDurationMs: UInt64,
        segmentCount: UInt32,
        sourcePackRevision: EntityRevision? = nil,
        proposedPersonID: PersonID? = nil,
        proposedScore: Double? = nil
    ) throws {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty, trimmedModelID.count <= 128 else {
            throw DomainValidationError.invalidCode(field: "SpeakerEmbeddingObservation.modelID")
        }
        guard speechDurationMs > 0, segmentCount > 0 else {
            throw DomainValidationError.invalidState(reason: "A speaker observation requires observed speech")
        }
        guard (proposedPersonID == nil) == (proposedScore == nil) else {
            throw DomainValidationError.invalidState(reason: "A provisional speaker proposal requires both identity and score")
        }
        if let proposedScore {
            guard proposedScore.isFinite, (-1 ... 1).contains(proposedScore) else {
                throw DomainValidationError.invalidState(reason: "Speaker proposal score must be between minus one and one")
            }
        }
        self.operationID = operationID
        self.canonicalRecordingID = canonicalRecordingID
        self.speakerIndex = speakerIndex
        self.embedding = embedding
        self.modelID = trimmedModelID
        self.speechDurationMs = speechDurationMs
        self.segmentCount = segmentCount
        self.sourcePackRevision = sourcePackRevision
        self.proposedPersonID = proposedPersonID
        self.proposedScore = proposedScore
    }
}

public enum SpeakerObservationDisposition: String, Codable, Equatable, Hashable, Sendable {
    case matched
    case noMatch
    case pendingReview
}

public struct SpeakerObservationDecision: Codable, Equatable, Hashable, Sendable {
    public let operationID: OperationID
    public let disposition: SpeakerObservationDisposition
    public let personID: PersonID?
    public let displayName: String?
    public let score: Double?
    public let recognitionPackRevision: EntityRevision
    public let recordingRevision: EntityRevision

    public init(
        operationID: OperationID,
        disposition: SpeakerObservationDisposition,
        personID: PersonID?,
        displayName: String?,
        score: Double?,
        recognitionPackRevision: EntityRevision,
        recordingRevision: EntityRevision
    ) throws {
        let hasMatch = personID != nil && displayName != nil && score != nil
        guard (disposition == .matched) == hasMatch else {
            throw DomainValidationError.invalidState(reason: "Only a matched observation may carry a resolved identity")
        }
        if let score {
            guard score.isFinite, (-1 ... 1).contains(score) else {
                throw DomainValidationError.invalidState(reason: "Speaker decision score must be between minus one and one")
            }
        }
        self.operationID = operationID
        self.disposition = disposition
        self.personID = personID
        self.displayName = displayName
        self.score = score
        self.recognitionPackRevision = recognitionPackRevision
        self.recordingRevision = recordingRevision
    }
}
