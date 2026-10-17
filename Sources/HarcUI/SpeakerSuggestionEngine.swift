import Foundation
import HarcDomain
import HarcStore
import HarcVoiceprint

/// Two-trigger speaker-identity suggestion engine. Reads embeddings from
/// `RecordingStore.speaker_embeddings`, compares via cosine similarity,
/// writes pending suggestions to `pending_suggestions` for matches above
/// each Person's threshold. Idempotent (INSERT OR REPLACE on
/// pending_suggestions prevents duplicates).
public actor SpeakerSuggestionEngine {
    private let store: RecordingStore
    /// Raw string key stored in `embedder_kind` column (e.g. `EmbedderKind.wespeakerV2`).
    private let embedderKind: String
    private let globalDefaultThreshold: Double
    /// Expected vector dimension for the active embedder.
    private let embeddingDim: Int

    public init(
        store: RecordingStore,
        embedderKind: String,
        globalDefaultThreshold: Double = 0.65,
        embeddingDim: Int = 256
    ) {
        self.store = store
        self.embedderKind = embedderKind
        self.globalDefaultThreshold = globalDefaultThreshold
        self.embeddingDim = embeddingDim
    }

    // MARK: - Trigger 1: post-diarization

    /// Trigger 1: a recording just finished diarization. For each newly-
    /// extracted embedding, find the highest-scoring Person and (if above
    /// threshold and the slot isn't linked or dismissed) write a
    /// `pending_suggestions` row.
    public func suggestForRecording(recordingID: Int64) async throws {
        let newEmbeddings = try await store.fetchSpeakerEmbeddings(
            recordingID: recordingID, embedderKind: embedderKind)
        guard !newEmbeddings.isEmpty else { return }

        let people = try await store.fetchPeople()
        guard !people.isEmpty else { return }
        let references = try await referenceSnapshot(for: people)

        let linksForRec = try await store.fetchPersonSpeakerLinks(recordingID: recordingID)
        let linkedSpeakerIndices = Set(linksForRec.map(\.speakerIndex))

        for emb in newEmbeddings {
            // Skip slots already linked to a Person.
            if linkedSpeakerIndices.contains(emb.speakerIndex) { continue }

            guard let newVec = EmbeddingBlob.decode(emb.embedding, expectedDim: embeddingDim) else {
                continue
            }

            guard let (person, bestScore) = bestMatch(
                for: newVec, people: people, references: references, excludingRecording: recordingID) else { continue }

            // Skip if dismissed.
            if try await store.isDismissed(
                personID: person.id, recordingID: recordingID, speakerIndex: emb.speakerIndex) {
                continue
            }

            try await store.insertPendingSuggestion(
                personID: person.id,
                recordingID: recordingID,
                speakerIndex: emb.speakerIndex,
                score: bestScore
            )
        }
    }

    // MARK: - Trigger 2: new Person backfill

    /// Trigger 2: a new Person was just created via rename. Walk all OTHER
    /// recordings' embeddings; if any match the new Person's seed embedding
    /// above threshold and aren't already linked or dismissed, suggest.
    public func suggestForNewPerson(personID: Int64, fromRecording recordingID: Int64, speakerIndex: Int) async throws {
        let people = try await store.fetchPeople()
        guard let person = people.first(where: { $0.id == personID }) else { return }
        let references = try await referenceSnapshot(for: people)
        // A bound snapshot may outlive or replace its mutable embedding row.
        // Trigger from eligible confirmed evidence, not the old slot payload.
        guard references[person.stableID]?.contains(where: { $0.recordingID == recordingID }) == true else { return }

        let allEmbeddings = try await store.fetchAllSpeakerEmbeddings(embedderKind: embedderKind)
        for cand in allEmbeddings {
            // A different slot in the same recording is not independent
            // corroboration; backfill uses other recordings only.
            if cand.recordingID == recordingID { continue }

            // Skip already-linked slots in the candidate's recording.
            let linkedFor = try await store.fetchPersonSpeakerLinks(recordingID: cand.recordingID)
            if linkedFor.contains(where: { $0.speakerIndex == cand.speakerIndex }) { continue }

            if try await store.isDismissed(
                personID: personID, recordingID: cand.recordingID, speakerIndex: cand.speakerIndex) {
                continue
            }

            guard let candVec = EmbeddingBlob.decode(cand.embedding, expectedDim: embeddingDim) else {
                continue
            }
            guard let (person, score) = bestMatch(
                for: candVec, people: people, references: references, excludingRecording: cand.recordingID),
                  person.id == personID else { continue }
            try await store.insertPendingSuggestion(
                personID: personID,
                recordingID: cand.recordingID,
                speakerIndex: cand.speakerIndex,
                score: score
            )
        }
    }

    /// Pool prototypes per person before comparing distinct identities. A
    /// runner-up remains a competitor even below its own acceptance threshold.
    private func referenceSnapshot(for people: [Person]) async throws -> [PersonID: [RecordingStore.SpeakerRecognitionReference]] {
        guard let dimensions = UInt32(exactly: embeddingDim), dimensions > 0,
              dimensions <= QuantizedSpeakerEmbedding.maximumDimensions else { return [:] }
        var result: [PersonID: [RecordingStore.SpeakerRecognitionReference]] = [:]
        for person in people {
            result[person.stableID] = try await store.speakerRecognitionReferences(
                personID: person.id, modelID: embedderKind, dimensions: dimensions)
        }
        return result
    }

    private func bestMatch(
        for query: [Float], people: [Person], references: [PersonID: [RecordingStore.SpeakerRecognitionReference]],
        excludingRecording recordingID: Int64
    ) -> (Person, Double)? {
        var scores: [PersonID: Double] = [:]
        for person in people {
            for reference in references[person.stableID] ?? [] where reference.recordingID != recordingID {
                guard let vector = EmbeddingBlob.decode(reference.embedding, expectedDim: embeddingDim) else { continue }
                let score = cosine(query, vector)
                guard score.isFinite else { continue }
                scores[person.stableID] = max(scores[person.stableID] ?? -1, score)
            }
        }
        guard let winner = SpeakerRecognitionMatcher.unambiguousBestPerson(scores: scores),
              let person = people.first(where: { $0.stableID == winner }),
              let score = scores[winner],
              score >= (person.matchThreshold ?? globalDefaultThreshold) else { return nil }
        return (person, score)
    }

    // MARK: - Math

    private nonisolated static func isEligibleReference(_ row: RecordingStore.SpeakerEmbeddingRow) -> Bool {
        row.totalMs >= Int(SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs) && row.segmentCount > 0
    }

    private nonisolated func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let av = Double(a[i]); let bv = Double(b[i])
            dot += av * bv
            na += av * av
            nb += bv * bv
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
