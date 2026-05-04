import Foundation
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

        let linksForRec = try await store.fetchPersonSpeakerLinks(recordingID: recordingID)
        let linkedSpeakerIndices = Set(linksForRec.map(\.speakerIndex))

        for emb in newEmbeddings {
            // Skip slots already linked to a Person.
            if linkedSpeakerIndices.contains(emb.speakerIndex) { continue }

            guard let newVec = EmbeddingBlob.decode(emb.embedding, expectedDim: embeddingDim) else {
                continue
            }

            // Find best matching Person.
            var bestPerson: Person?
            var bestScore: Double = 0
            for person in people {
                let personEmbeddings = try await store.fetchEmbeddingsForPerson(
                    person.id, embedderKind: embedderKind)
                for pe in personEmbeddings {
                    guard let v = EmbeddingBlob.decode(pe.embedding, expectedDim: embeddingDim) else {
                        continue
                    }
                    let s = cosine(newVec, v)
                    if s > bestScore {
                        bestScore = s
                        bestPerson = person
                    }
                }
            }
            guard let person = bestPerson else { continue }
            let threshold = person.matchThreshold ?? globalDefaultThreshold
            guard bestScore >= threshold else { continue }

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
        let seedRow = try await store.speakerEmbedding(
            recordingID: recordingID, speakerIndex: speakerIndex)
        guard let seed = seedRow, seed.embedderKind == embedderKind else { return }
        guard let seedVec = EmbeddingBlob.decode(seed.embedding, expectedDim: embeddingDim) else {
            return
        }

        let person = try await store.fetchPeople().first(where: { $0.id == personID })
        let threshold = person?.matchThreshold ?? globalDefaultThreshold

        let allEmbeddings = try await store.fetchAllSpeakerEmbeddings(embedderKind: embedderKind)
        for cand in allEmbeddings {
            // Skip the seed slot itself.
            if cand.recordingID == recordingID && cand.speakerIndex == speakerIndex { continue }

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
            let s = cosine(seedVec, candVec)
            if s >= threshold {
                try await store.insertPendingSuggestion(
                    personID: personID,
                    recordingID: cand.recordingID,
                    speakerIndex: cand.speakerIndex,
                    score: s
                )
            }
        }
    }

    // MARK: - Math

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
