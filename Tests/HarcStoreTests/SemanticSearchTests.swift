import Testing
import Foundation
@testable import HarcStore

@Suite("Semantic + hybrid search")
struct SemanticSearchTests {

    private func makeRecording(_ title: String, transcript: String, at offset: TimeInterval) -> Recording {
        Recording(
            wavPath: "/tmp/harc-test-\(UUID().uuidString.prefix(8)).wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            endedAt: nil,
            title: title,
            transcriptText: transcript
        )
    }

    // MARK: - Chunker

    @Test("chunker splits into overlapping windows that advance")
    func chunkerOverlaps() {
        let words = (1...100).map { "word\($0)" }.joined(separator: " ")
        let chunker = TranscriptChunker(windowWords: 30, overlapWords: 10)
        let chunks = chunker.chunks(of: words)

        #expect(chunks.count > 1)
        #expect(chunks[0].ordinal == 0)
        // Stride is 20, so chunk 1 starts at word 21 and shares 10 with chunk 0.
        let firstWords = chunks[0].text.split(separator: " ")
        let secondWords = chunks[1].text.split(separator: " ")
        #expect(firstWords.count == 30)
        #expect(secondWords.first == "word21")
        #expect(firstWords.suffix(10).first == "word21")
        // Ordinals are dense and increasing — the unique key depends on it.
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
    }

    @Test("chunker interpolates timestamps monotonically across the transcript")
    func chunkerTimestamps() {
        let words = (1...100).map { "word\($0)" }.joined(separator: " ")
        let chunks = TranscriptChunker(windowWords: 30, overlapWords: 10)
            .chunks(of: words, durationMs: 100_000)

        #expect(chunks[0].startMs == 0)
        #expect(chunks.last!.endMs == 100_000)
        for chunk in chunks { #expect(chunk.startMs < chunk.endMs) }
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.startMs < b.startMs)
        }
    }

    @Test("empty or whitespace transcripts produce no chunks")
    func chunkerEmpty() {
        let chunker = TranscriptChunker()
        #expect(chunker.chunks(of: "").isEmpty)
        #expect(chunker.chunks(of: "   \n  ").isEmpty)
    }

    // MARK: - Embedder

    @Test("embeddings are L2-normalized and stable across processes")
    func embedderNormalizedAndStable() {
        let embedder = HashedLexicalEmbedder()
        let vector = embedder.embed("the quarterly revenue forecast")

        #expect(vector.count == 256)
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 0.0001)

        // Same input, same vector — the FNV hash must not be process-seeded, or
        // every stored embedding would be garbage after a relaunch.
        #expect(embedder.embed("the quarterly revenue forecast") == vector)
    }

    @Test("similar passages score above unrelated ones")
    func embedderDiscriminates() {
        let embedder = HashedLexicalEmbedder()
        let query = embedder.embed("migration timeline for the database")
        let related = embedder.embed("we discussed the database migration timeline at length")
        let unrelated = embedder.embed("lunch options near the office on Friday")

        let relatedScore = embedder.similarity(query, related)
        let unrelatedScore = embedder.similarity(query, unrelated)
        #expect(relatedScore > unrelatedScore)
        #expect(relatedScore > 0.2)
    }

    @Test("mismatched vector widths score zero rather than trapping")
    func similarityHandlesMismatch() {
        let embedder = HashedLexicalEmbedder()
        #expect(embedder.similarity([1, 0, 0], [1, 0]) == 0)
        #expect(embedder.similarity([], []) == 0)
    }

    @Test("blob round-trips vectors exactly")
    func blobRoundTrip() {
        let vector: [Float] = [0.5, -0.25, 0, 1, -1]
        #expect(EmbeddingBlob.unpack(EmbeddingBlob.pack(vector)) == vector)
        #expect(EmbeddingBlob.unpack(Data()) == [])
    }

    // MARK: - Store integration

    @Test("indexing writes chunks and marks the recording indexed")
    func indexingWritesChunks() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()
        let text = (1...200).map { "word\($0)" }.joined(separator: " ")
        let saved = try await store.upsert(makeRecording("Standup", transcript: text, at: 0))
        let id = try #require(saved.id)

        let count = try await store.indexTranscript(
            recordingID: id, text: text, durationMs: 60_000, embedder: embedder
        )
        #expect(count > 1)

        let refetched = try await store.fetch(id: id)
        #expect(refetched?.chunksIndexedAt != nil)

        // Re-indexing replaces rather than duplicating — the unique key on
        // (recording_id, ordinal) would otherwise throw.
        let second = try await store.indexTranscript(
            recordingID: id, text: text, durationMs: 60_000, embedder: embedder
        )
        #expect(second == count)
    }

    @Test("semantic search finds the recording whose passage matches")
    func semanticSearchFindsPassage() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()

        let a = try await store.upsert(makeRecording(
            "Infra", transcript: "We agreed to postpone the database migration until the second quarter.", at: 0
        ))
        let b = try await store.upsert(makeRecording(
            "Social", transcript: "Someone suggested tacos for the team lunch on Friday afternoon.", at: 100
        ))
        try await store.indexTranscript(
            recordingID: a.id!, text: a.transcriptText!, embedder: embedder
        )
        try await store.indexTranscript(
            recordingID: b.id!, text: b.transcriptText!, embedder: embedder
        )

        let hits = try await store.semanticSearch(query: "database migration", embedder: embedder)
        #expect(!hits.isEmpty)
        #expect(hits.first?.recordingID == a.id)
    }

    @Test("vectors from a different embedder are never compared")
    func modelIsolation() async throws {
        let store = try await RecordingStore.inMemory()
        let indexed = HashedLexicalEmbedder(dimensions: 256)
        let other = HashedLexicalEmbedder(dimensions: 128)   // different modelID

        let rec = try await store.upsert(makeRecording(
            "Infra", transcript: "the database migration timeline", at: 0
        ))
        try await store.indexTranscript(
            recordingID: rec.id!, text: rec.transcriptText!, embedder: indexed
        )

        #expect(try await !store.semanticSearch(query: "database migration", embedder: indexed).isEmpty)
        // Same words, incomparable space — must return nothing rather than
        // scoring across two unrelated geometries.
        #expect(try await store.semanticSearch(query: "database migration", embedder: other).isEmpty)
    }

    @Test("clearing an index removes chunks and the marker")
    func clearingIndex() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()
        let rec = try await store.upsert(makeRecording(
            "Infra", transcript: "the database migration timeline", at: 0
        ))
        try await store.indexTranscript(
            recordingID: rec.id!, text: rec.transcriptText!, embedder: embedder
        )

        try await store.clearTranscriptIndex(recordingID: rec.id!)
        #expect(try await store.semanticSearch(query: "database", embedder: embedder).isEmpty)
        #expect(try await store.fetch(id: rec.id!)?.chunksIndexedAt == nil)
    }

    @Test("recordingsNeedingIndex lists only unindexed recordings with transcripts")
    func backfillWorkList() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()

        let withText = try await store.upsert(makeRecording("A", transcript: "some spoken words here", at: 0))
        _ = try await store.upsert(makeRecording("B", transcript: "", at: 100))
        let indexedOne = try await store.upsert(makeRecording("C", transcript: "already indexed words", at: 200))
        try await store.indexTranscript(
            recordingID: indexedOne.id!, text: indexedOne.transcriptText!, embedder: embedder
        )

        let pending = try await store.recordingsNeedingIndex()
        let ids = pending.compactMap(\.id)
        #expect(ids.contains(withText.id!))
        #expect(!ids.contains(indexedOne.id!))
        #expect(pending.allSatisfy { !($0.transcriptText ?? "").isEmpty })
    }

    @Test("hybrid search still works when nothing is indexed")
    func hybridFallsBackToKeyword() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()
        _ = try await store.upsert(makeRecording(
            "Infra", transcript: "We postponed the database migration.", at: 0
        ))

        // No indexTranscript call — an unindexed library must search exactly as
        // it did before this feature existed.
        let hits = try await store.hybridSearch(query: "migration", embedder: embedder)
        #expect(!hits.isEmpty)
    }

    @Test("hybrid search ranks a recording found by both routes above one found by either")
    func hybridFusionPrefersAgreement() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()

        let both = try await store.upsert(makeRecording(
            "Both", transcript: "The database migration timeline slipped to the second quarter.", at: 0
        ))
        let semanticOnly = try await store.upsert(makeRecording(
            "Semantic", transcript: "Migration planning and timeline discussion for our datastore.", at: 100
        ))
        for rec in [both, semanticOnly] {
            try await store.indexTranscript(
                recordingID: rec.id!, text: rec.transcriptText!, embedder: embedder
            )
        }

        let hits = try await store.hybridSearch(query: "database migration timeline", embedder: embedder)
        #expect(!hits.isEmpty)
        #expect(hits.first?.recording.id == both.id,
                "the recording matched by both keyword and vector must rank first")
        // Scores are RRF contributions, so they must be positive and ordered.
        #expect(hits.first!.score > 0)
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test("deleted recordings never surface in semantic results")
    func deletedAreExcluded() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()
        let rec = try await store.upsert(makeRecording(
            "Infra", transcript: "the database migration timeline", at: 0
        ))
        try await store.indexTranscript(
            recordingID: rec.id!, text: rec.transcriptText!, embedder: embedder
        )
        #expect(try await !store.semanticSearch(query: "database", embedder: embedder).isEmpty)

        try await store.softDelete(id: rec.id!)
        #expect(try await store.semanticSearch(query: "database", embedder: embedder).isEmpty)
    }
}
