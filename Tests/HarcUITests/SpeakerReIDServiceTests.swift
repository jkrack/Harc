import Foundation
import Testing

@testable import HarcStore
@testable import HarcUI
@testable import HarcVoiceprint

// MARK: - Mock Resolver for Testing

private actor MockSpeakerNameResolver: SpeakerNameResolver {
    private let names: [Int64: [Int: String]]

    init(names: [Int64: [Int: String]] = [:]) {
        self.names = names
    }

    func name(recordingID: Int64, speakerIndex: Int) async -> String? {
        return names[recordingID]?[speakerIndex]
    }
}

// MARK: - Tests

@Suite("SpeakerReIDService")
struct SpeakerReIDServiceTests {
    // MARK: - Threshold Tests

    @Test("default threshold is 0.65 (WeSpeaker-tuned)")
    func defaultThresholdIs065() async throws {
        let store = try await RecordingStore.inMemory()
        let resolver = MockSpeakerNameResolver()
        let service = SpeakerReIDService(
            store: store,
            nameResolver: resolver
        )
        let threshold = await service.threshold
        #expect(threshold == 0.65)
    }

    @Test("default threshold can be overridden in init")
    func thresholdCanBeOverridden() async throws {
        let store = try await RecordingStore.inMemory()
        let resolver = MockSpeakerNameResolver()
        let service = SpeakerReIDService(
            store: store,
            nameResolver: resolver,
            threshold: 0.7
        )
        let threshold = await service.threshold
        #expect(threshold == 0.7)
    }

    // MARK: - EmbedderKind Filter Tests

    @Test("suggestMatches filters by embedderKind wespeaker_v2")
    func suggestMatchesFiltersEmbedderKind() async throws {
        let store = try await RecordingStore.inMemory()

        // Create three recordings.
        let recA = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: Date()))
        let recB = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: Date()))
        let recC = try await store.upsert(Recording(wavPath: "/tmp/c.wav", startedAt: Date()))

        guard let recAId = recA.id, let recBId = recB.id, let recCId = recC.id else {
            Issue.record("Could not retrieve recording IDs")
            return
        }

        // Create a normalized test vector (same across all embeddings for simplicity).
        var v = [Float](repeating: 0, count: 256)
        v[0] = 1.0  // normalized
        let blob = EmbeddingBlob.encode(v)

        // Insert embeddings with different embedder kinds:
        // recA: ecapa_v1 (old kind, should be filtered out)
        try await store.upsertSpeakerEmbeddings(
            recordingID: recAId,
            rows: [RecordingStore.SpeakerEmbeddingRow(
                recordingID: recAId,
                speakerIndex: 0,
                embedding: blob,
                segmentCount: 1,
                totalMs: 6000,
                embedderKind: "ecapa_v1"
            )]
        )

        // recB: wespeaker_v2 (correct kind, should match)
        try await store.upsertSpeakerEmbeddings(
            recordingID: recBId,
            rows: [RecordingStore.SpeakerEmbeddingRow(
                recordingID: recBId,
                speakerIndex: 0,
                embedding: blob,
                segmentCount: 1,
                totalMs: 6000,
                embedderKind: EmbedderKind.wespeakerV2
            )]
        )

        // Create a resolver.
        let resolver = MockSpeakerNameResolver()

        // Create the service with default threshold (0.65).
        let service = SpeakerReIDService(store: store, nameResolver: resolver)

        // Query suggestions for recC using the test vector.
        let suggestions = try await service.suggestions(
            for: v,
            excludingRecording: recCId
        )

        // Should find exactly one match (recB with wespeaker_v2).
        #expect(suggestions.count == 1, "expected 1 suggestion group; got \(suggestions.count)")

        // The suggestion should contain exactly one match from recB.
        #expect(suggestions[0].matches.count == 1, "expected 1 match; got \(suggestions[0].matches.count)")
        #expect(suggestions[0].matches[0].recordingID == recBId, "expected match from recB")
        #expect(suggestions[0].matches[0].speakerIndex == 0)

        // Similarity should be 1.0 (identical vectors).
        #expect(suggestions[0].matches[0].similarity == 1.0)
    }

    @Test("suggestMatches ignores stale embedder kinds")
    func ignoresStalEmbedderKinds() async throws {
        let store = try await RecordingStore.inMemory()

        let recA = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: Date()))
        let recB = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: Date()))

        guard let recAId = recA.id, let recBId = recB.id else {
            Issue.record("Could not retrieve recording IDs")
            return
        }

        var v = [Float](repeating: 0, count: 256)
        v[0] = 1.0
        let blob = EmbeddingBlob.encode(v)

        // Insert multiple embeddings for recA with different stale kinds.
        try await store.upsertSpeakerEmbeddings(
            recordingID: recAId,
            rows: [
                RecordingStore.SpeakerEmbeddingRow(
                    recordingID: recAId,
                    speakerIndex: 0,
                    embedding: blob,
                    segmentCount: 1,
                    totalMs: 6000,
                    embedderKind: "stub_v1"
                ),
                RecordingStore.SpeakerEmbeddingRow(
                    recordingID: recAId,
                    speakerIndex: 1,
                    embedding: blob,
                    segmentCount: 1,
                    totalMs: 6000,
                    embedderKind: "ecapa_v1"
                ),
            ]
        )

        let resolver = MockSpeakerNameResolver()
        let service = SpeakerReIDService(store: store, nameResolver: resolver)

        let suggestions = try await service.suggestions(
            for: v,
            excludingRecording: recBId
        )

        // Should find zero matches because recA has no wespeaker_v2 embeddings.
        #expect(suggestions.isEmpty, "expected no suggestions for stale kinds; got \(suggestions.count)")
    }

    @Test("threshold filtering works alongside embedderKind filter")
    func thresholdAndKindFiltersTogether() async throws {
        let store = try await RecordingStore.inMemory()

        let recA = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: Date()))
        let recB = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: Date()))

        guard let recAId = recA.id, let recBId = recB.id else {
            Issue.record("Could not retrieve recording IDs")
            return
        }

        // Query vector (normalized).
        var query = [Float](repeating: 0, count: 256)
        query[0] = 1.0

        // Target vector (slightly perturbed, similarity ~0.9).
        var target = [Float](repeating: 0, count: 256)
        target[0] = 0.9
        target[1] = Float(sqrt(0.19))  // normalize

        let targetBlob = EmbeddingBlob.encode(target)

        // Insert embeddings with correct kind but below threshold.
        try await store.upsertSpeakerEmbeddings(
            recordingID: recAId,
            rows: [RecordingStore.SpeakerEmbeddingRow(
                recordingID: recAId,
                speakerIndex: 0,
                embedding: targetBlob,
                segmentCount: 1,
                totalMs: 6000,
                embedderKind: EmbedderKind.wespeakerV2
            )]
        )

        let resolver = MockSpeakerNameResolver()
        let service = SpeakerReIDService(store: store, nameResolver: resolver, threshold: 0.95)

        let suggestions = try await service.suggestions(
            for: query,
            excludingRecording: recBId
        )

        // Should find zero matches because cosine similarity is ~0.9, below threshold 0.95.
        #expect(suggestions.isEmpty, "expected no suggestions below threshold; got \(suggestions.count)")
    }

    @Test("minTotalMs filter still applies with embedderKind")
    func minTotalMsFilterAppliesWithEmbedderKind() async throws {
        let store = try await RecordingStore.inMemory()

        let recA = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: Date()))
        let recB = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: Date()))

        guard let recAId = recA.id, let recBId = recB.id else {
            Issue.record("Could not retrieve recording IDs")
            return
        }

        var v = [Float](repeating: 0, count: 256)
        v[0] = 1.0
        let blob = EmbeddingBlob.encode(v)

        // Insert embedding with correct kind but too short duration (< 5000 ms default).
        try await store.upsertSpeakerEmbeddings(
            recordingID: recAId,
            rows: [RecordingStore.SpeakerEmbeddingRow(
                recordingID: recAId,
                speakerIndex: 0,
                embedding: blob,
                segmentCount: 1,
                totalMs: 3000,  // Below default 5000ms threshold
                embedderKind: EmbedderKind.wespeakerV2
            )]
        )

        let resolver = MockSpeakerNameResolver()
        let service = SpeakerReIDService(store: store, nameResolver: resolver)

        let suggestions = try await service.suggestions(
            for: v,
            excludingRecording: recBId
        )

        // Should find zero matches because totalMs < minTotalMs.
        #expect(suggestions.isEmpty, "expected no suggestions for short audio; got \(suggestions.count)")
    }

    @Test("suggests top-k matches grouped by name")
    func suggestionsGroupedByName() async throws {
        let store = try await RecordingStore.inMemory()

        let recA = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: Date()))
        let recB = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: Date()))
        let recC = try await store.upsert(Recording(wavPath: "/tmp/c.wav", startedAt: Date()))

        guard let recAId = recA.id, let recBId = recB.id, let recCId = recC.id else {
            Issue.record("Could not retrieve recording IDs")
            return
        }

        // Set speaker names for recA and recB.
        try await store.updateSpeakerNames(id: recAId, names: [0: "Alice"])
        try await store.updateSpeakerNames(id: recBId, names: [0: "Alice"])

        var v = [Float](repeating: 0, count: 256)
        v[0] = 1.0
        let blob = EmbeddingBlob.encode(v)

        // Insert embeddings for Alice speakers in both recA and recB.
        try await store.upsertSpeakerEmbeddings(
            recordingID: recAId,
            rows: [RecordingStore.SpeakerEmbeddingRow(
                recordingID: recAId,
                speakerIndex: 0,
                embedding: blob,
                segmentCount: 1,
                totalMs: 6000,
                embedderKind: EmbedderKind.wespeakerV2
            )]
        )

        try await store.upsertSpeakerEmbeddings(
            recordingID: recBId,
            rows: [RecordingStore.SpeakerEmbeddingRow(
                recordingID: recBId,
                speakerIndex: 0,
                embedding: blob,
                segmentCount: 1,
                totalMs: 6000,
                embedderKind: EmbedderKind.wespeakerV2
            )]
        )

        let resolver = StoreSpeakerNameResolver(store: store)
        let service = SpeakerReIDService(store: store, nameResolver: resolver)

        let suggestions = try await service.suggestions(
            for: v,
            excludingRecording: recCId
        )

        // Should find exactly one suggestion group named "Alice".
        #expect(suggestions.count == 1, "expected 1 suggestion group; got \(suggestions.count)")
        #expect(suggestions[0].name == "Alice")

        // The group should contain two matches (from recA and recB).
        #expect(suggestions[0].matches.count == 2, "expected 2 matches in Alice group; got \(suggestions[0].matches.count)")
    }
}
