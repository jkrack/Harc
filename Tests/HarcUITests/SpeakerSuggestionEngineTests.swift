import Testing
import Foundation
import CryptoKit
import HarcDomain
import GRDB
@testable import HarcStore
@testable import HarcUI
@testable import HarcVoiceprint

@Suite("SpeakerSuggestionEngine")
@MainActor
struct SpeakerSuggestionEngineTests {
    @Test("published standalone targets use current bound evidence and preserve unchanged reviews")
    func boundTargetSuggestions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RecordingStore.inMemory()
        let person = try await store.createPerson(displayName: "Alice")
        let reference = try await Self.seedRecording(in: store, wav: root.appendingPathComponent("reference.wav").path)
        try await store.upsertSpeakerEmbeddings(recordingID: reference, rows: [
            .init(recordingID: reference, speakerIndex: 0, embedding: EmbeddingBlob.encode([Float(1), 0]),
                segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)])
        try await store.linkSpeaker(personID: person, recordingID: reference, speakerIndex: 0)
        let target = try await store.upsert(Recording(wavPath: root.appendingPathComponent("target.wav").path, startedAt: Date()))
        let id = try #require(target.id)
        let hash = try CanonicalPCMHash(Data(repeating: 1, count: 32))
        let data = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"synthetic"}"#.utf8)
        let snapshot = try SpeakerEvidenceSnapshot(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: hash, producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(SHA256.hash(data: data)), localClusterID: "local-speaker-0",
            embedding: .quantizing([Float(1), 0]), modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        try await store.publishLocalSpeakerGeneration(recordingID: id, expectedRevision: target.revision,
            expectedArtifactSHA256: nil, canonicalPCMHash: hash, canonicalFrames: 160000,
            structuredTranscriptData: data, snapshots: [snapshot])
        // A mutable slot must not replace the bound query's identity.
        try await store.upsertSpeakerEmbeddings(recordingID: id, rows: [
            .init(recordingID: id, speakerIndex: 0, embedding: EmbeddingBlob.encode([Float(0), 1]),
                segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)])
        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2, embeddingDim: 2)
        try await engine.suggestForRecording(recordingID: id)
        let suggestion = try #require(try await store.fetchPendingSuggestionsForRecording(id).first)
        #expect(suggestion.personID == person)
        let review = try #require(try await store.hostSpeakerReview(for: suggestion))
        try await engine.suggestForRecording(recordingID: id)
        #expect(try await store.fetchPendingSuggestionsForRecording(id) == [suggestion])
        #expect(try await store.hostSpeakerReview(for: suggestion) == review)
        let healthy = try await Self.seedRecording(in: store, wav: root.appendingPathComponent("healthy.wav").path)
        try await store.upsertSpeakerEmbeddings(recordingID: healthy, rows: [
            .init(recordingID: healthy, speakerIndex: 0, embedding: EmbeddingBlob.encode([Float(1), 0]),
                segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)])
        try await engine.suggestForRecording(recordingID: healthy)
        #expect(try await store.fetchPendingSuggestionsForRecording(healthy).count == 1)
        let saved = try #require(try await store.fetch(id: id))
        let sidecar = URL(fileURLWithPath: try #require(saved.jsonPath))
        try Data("changed synthetic artifact".utf8).write(to: sidecar)
        try await store.unlinkSpeaker(recordingID: reference, speakerIndex: 0)
        try await engine.suggestForNewPerson(personID: person, fromRecording: reference, speakerIndex: 0)
        #expect(try await store.fetchPendingSuggestionsForRecording(healthy).isEmpty)
        #expect(try await store.fetchPendingSuggestionsForRecording(id) == [suggestion])
        try data.write(to: sidecar)
        try await engine.suggestForRecording(recordingID: id)
        #expect(try await store.fetchPendingSuggestionsForRecording(id).isEmpty)
    }

    @Test("reevaluation clears ambiguity, replaces winners, and clears missing references")
    func reconcileChangedEvidence() async throws {
        for backfill in [false, true] {
            let store = try await RecordingStore.inMemory()
            let alice = try await store.createPerson(displayName: "Alice")
            let bob = try await store.createPerson(displayName: "Bob")
            let a = try await Self.seedRecording(in: store, wav: "/tmp/reconcile-a.wav")
            let b = try await Self.seedRecording(in: store, wav: "/tmp/reconcile-b.wav")
            let q = try await Self.seedRecording(in: store, wav: "/tmp/reconcile-query.wav")
            func embed(_ id: Int64, _ vector: [Float]) async throws {
                try await store.upsertSpeakerEmbeddings(recordingID: id, rows: [
                    .init(recordingID: id, speakerIndex: 0, embedding: EmbeddingBlob.encode(vector),
                        segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)])
            }
            try await embed(a, [1, 0]); try await embed(b, [0, 1]); try await embed(q, [1, 0])
            try await store.linkSpeaker(personID: alice, recordingID: a, speakerIndex: 0)
            try await store.linkSpeaker(personID: bob, recordingID: b, speakerIndex: 0)
            let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2, embeddingDim: 2)
            func refresh() async throws {
                if backfill { try await engine.suggestForNewPerson(personID: bob, fromRecording: b, speakerIndex: 0) }
                else { try await engine.suggestForRecording(recordingID: q) }
            }
            try await engine.suggestForRecording(recordingID: q)
            #expect(try await store.fetchPendingSuggestionsForRecording(q).map(\.personID) == [alice])
            try await embed(b, [1, 0]); try await refresh()
            #expect(try await store.fetchPendingSuggestionsForRecording(q).isEmpty)
            try await embed(a, [0, 1]); try await refresh()
            #expect(try await store.fetchPendingSuggestionsForRecording(q).map(\.personID) == [bob])
            try await store.linkSpeaker(personID: alice, recordingID: b, speakerIndex: 0); try await refresh()
            #expect(try await store.fetchPendingSuggestionsForRecording(q).map(\.personID) == [alice])
            try await store.unlinkSpeaker(recordingID: b, speakerIndex: 0); try await refresh()
            #expect(try await store.fetchPendingSuggestionsForRecording(q).isEmpty)
            try await store.linkSpeaker(personID: bob, recordingID: b, speakerIndex: 0); try await refresh()
            try await store.upsertSpeakerEmbeddings(recordingID: q, rows: []); try await refresh()
            #expect(try await store.fetchPendingSuggestionsForRecording(q).isEmpty)
        }
    }

    @Test("reconciliation preserves confirmations, dismissals and bound review rows")
    func reconcileProtectedReviews() async throws {
        let store = try await RecordingStore.inMemory()
        let person = try await store.createPerson(displayName: "Alice")
        let source = try await Self.seedRecording(in: store, wav: "/tmp/protected-source.wav")
        let query = try await Self.seedRecording(in: store, wav: "/tmp/protected-query.wav")
        for id in [source, query] {
            try await store.upsertSpeakerEmbeddings(recordingID: id, rows: [
                .init(recordingID: id, speakerIndex: 0, embedding: EmbeddingBlob.encode([Float(1), 0]),
                    segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)])
        }
        try await store.linkSpeaker(personID: person, recordingID: source, speakerIndex: 0)
        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2, embeddingDim: 2)
        try await engine.suggestForRecording(recordingID: query)
        // Either transaction ordering must preserve the user's confirmation.
        async let refresh: Void = engine.suggestForRecording(recordingID: query)
        async let confirm: Void = store.confirmSuggestion(personID: person, recordingID: query, speakerIndex: 0)
        _ = try await (refresh, confirm)
        #expect(try await store.fetchPersonSpeakerLinks(recordingID: query).first?.isUserConfirmed == true)
        #expect(try await store.fetchPendingSuggestionsForRecording(query).isEmpty)
        try await store.unlinkSpeaker(recordingID: query, speakerIndex: 0)
        async let dismissRefresh: Void = engine.suggestForRecording(recordingID: query)
        async let dismiss: Void = store.dismissSuggestion(personID: person, recordingID: query, speakerIndex: 0)
        _ = try await (dismissRefresh, dismiss)
        try await engine.suggestForRecording(recordingID: query)
        #expect(try await store.fetchPendingSuggestionsForRecording(query).isEmpty)
        // A bound review must not be treated as a standalone legacy suggestion.
        let queue = await store.uncoordinatedDB
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO bound_speaker_enrollment_sources (recording_id) VALUES (?)", arguments: [query])
        }
        try await store.insertPendingSuggestion(personID: person, recordingID: query, speakerIndex: 0, score: 0.9)
        try await engine.suggestForRecording(recordingID: query)
        #expect(try await store.fetchPendingSuggestionsForRecording(query).count == 1)
    }

    @Test("both triggers recognize selected snapshots without a mutable source embedding")
    func selectedSnapshotReferences() async throws {
        for backfill in [false, true] {
            let store = try await RecordingStore.inMemory()
            let queue = await store.uncoordinatedDB
            let reference = try await queue.write { db in
                let r = Recording(wavPath: "/tmp/bound-suggestion-reference.wav", startedAt: Date(),
                    canonicalPCMHash: try CanonicalPCMHash(Data(repeating: 1, count: 32)), canonicalPCMFrames: 160000)
                try r.insert(db)
                return try #require(try Recording.fetchOne(db, key: db.lastInsertedRowID))
            }
            let person = try await store.createPerson(displayName: "Selected")
            var vector = [Float](repeating: 0, count: 256); vector[0] = 1
            let snapshot = try SpeakerEvidenceSnapshot(canonicalRecordingID: reference.canonicalID,
                canonicalPCMHash: #require(reference.canonicalPCMHash), producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
                processingArtifactSHA256: Data(repeating: 3, count: 32), localClusterID: "cluster-a",
                embedding: .quantizing(vector), modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
            _ = try await store.retainSpeakerEvidence(snapshot)
            _ = try await store.confirmSpeakerEvidence(sha256: snapshot.evidenceSHA256, personID: person)
            let query = try await store.upsert(Recording(wavPath: "/tmp/bound-suggestion-query.wav", startedAt: Date()))
            let queryID = try #require(query.id)
            try await store.upsertSpeakerEmbeddings(recordingID: queryID, rows: [
                .init(recordingID: queryID, speakerIndex: 0, embedding: EmbeddingBlob.encode(vector),
                    segmentCount: 1, totalMs: 1000, embedderKind: "wespeaker_v2")])
            let engine = SpeakerSuggestionEngine(store: store, embedderKind: "wespeaker_v2")
            if backfill {
                try await engine.suggestForNewPerson(personID: person, fromRecording: #require(reference.id), speakerIndex: 0)
            } else {
                try await engine.suggestForRecording(recordingID: queryID)
            }
            let suggestions = try await store.fetchPendingSuggestionsForRecording(queryID)
            #expect(suggestions.count == 1)
            #expect(suggestions.first?.personID == person)
        }
    }

    @Test("both triggers pool a person's references and abstain on competing identities")
    func competingIdentities() async throws {
        for backfill in [false, true] {
            for competitor: Float in [1, 0.98, 0.8] {
                let store = try await RecordingStore.inMemory()
                let alice = try await store.createPerson(displayName: "Alice")
                // A runner-up below its own threshold must still cause ambiguity.
                let bob = try await store.createPerson(displayName: "Bob", matchThreshold: 1.0)
                var source: Int64 = 0
                for (index, person) in [alice, bob, alice].enumerated() {
                    let recording = try await Self.seedRecording(in: store, wav: "/tmp/competition-\(index).wav")
                    if index == 0 { source = recording }
                    let vector: [Float] = person == alice ? [1, 0] : [competitor, sqrt(1 - competitor * competitor)]
                    try await store.upsertSpeakerEmbeddings(recordingID: recording, rows: [
                        .init(recordingID: recording, speakerIndex: 0, embedding: EmbeddingBlob.encode(vector),
                              segmentCount: 1, totalMs: 6_000, embedderKind: EmbedderKind.wespeakerV2)])
                    try await store.linkSpeaker(personID: person, recordingID: recording, speakerIndex: 0)
                }
                let query = try await Self.seedRecording(in: store, wav: "/tmp/competition-query.wav")
                try await store.upsertSpeakerEmbeddings(recordingID: query, rows: [
                    .init(recordingID: query, speakerIndex: 0, embedding: EmbeddingBlob.encode([1, 0]),
                          segmentCount: 1, totalMs: 1_000, embedderKind: EmbedderKind.wespeakerV2)])
                let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2, embeddingDim: 2)
                if backfill {
                    try await engine.suggestForNewPerson(personID: alice, fromRecording: source, speakerIndex: 0)
                } else {
                    try await engine.suggestForRecording(recordingID: query)
                }
                let suggestions = try await store.fetchPendingSuggestionsForRecording(query)
                #expect(suggestions.map(\.personID) == (competitor == 0.8 ? [alice] : []))
            }
        }
    }

    @Test("both suggestion triggers require eligible reference speech but allow short queries")
    func referenceDurationBoundary() async throws {
        for backfill in [false, true] {
            for duration in [4_999, 5_000] {
                let store = try await RecordingStore.inMemory()
                let reference = try await Self.seedRecording(in: store, wav: "/tmp/floor-reference.wav")
                let query = try await Self.seedRecording(in: store, wav: "/tmp/floor-query.wav")
                let person = try await store.createPerson(displayName: "Alice")
                let blob = EmbeddingBlob.encode([Float](repeating: 0.0625, count: 256))
                try await store.upsertSpeakerEmbeddings(recordingID: reference, rows: [
                    .init(recordingID: reference, speakerIndex: 0, embedding: blob,
                          segmentCount: 1, totalMs: duration, embedderKind: EmbedderKind.wespeakerV2)])
                try await store.upsertSpeakerEmbeddings(recordingID: query, rows: [
                    .init(recordingID: query, speakerIndex: 0, embedding: blob,
                          segmentCount: 1, totalMs: 1_000, embedderKind: EmbedderKind.wespeakerV2)])
                try await store.linkSpeaker(personID: person, recordingID: reference, speakerIndex: 0)
                let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
                if backfill {
                    try await engine.suggestForNewPerson(personID: person, fromRecording: reference, speakerIndex: 0)
                } else {
                    try await engine.suggestForRecording(recordingID: query)
                }
                let suggestions = try await store.fetchPendingSuggestionsForRecording(query)
                #expect(suggestions.count == (duration == 5_000 ? 1 : 0))
                let links = try await store.fetchPersonSpeakerLinks(recordingID: reference)
                #expect(links.first?.personID == person)
                #expect(links.first?.isUserConfirmed == true)
            }
        }
    }

    @Test("neither trigger treats another slot in the same recording as independent voice evidence")
    func excludesSameRecording() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await Self.seedRecording(in: store, wav: "/tmp/same-recording.wav")
        let person = try await store.createPerson(displayName: "Alice")
        let blob = EmbeddingBlob.encode([Float](repeating: 0.0625, count: 256))
        try await store.upsertSpeakerEmbeddings(recordingID: recording, rows: [0, 1].map {
            .init(recordingID: recording, speakerIndex: $0, embedding: blob,
                  segmentCount: 1, totalMs: 6_000, embedderKind: EmbedderKind.wespeakerV2)
        })
        try await store.linkSpeaker(personID: person, recordingID: recording, speakerIndex: 0)
        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recording)
        #expect(try await store.fetchPendingSuggestionsForRecording(recording).isEmpty)
        try await engine.suggestForNewPerson(personID: person, fromRecording: recording, speakerIndex: 0)
        #expect(try await store.fetchPendingSuggestionsForRecording(recording).isEmpty)
    }


    /// Insert a minimal Recording and return its auto-assigned row ID.
    @discardableResult
    static func seedRecording(in store: RecordingStore, wav: String) async throws -> Int64 {
        let saved = try await store.upsert(Recording(
            wavPath: wav,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        return saved.id!
    }

    @Test("suggestForRecording inserts pending row when embedding matches a Person above threshold")
    func suggestsAboveThreshold() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)

        // Identical embeddings under both recordings → cosine 1.0.
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            RecordingStore.SpeakerEmbeddingRow(
                recordingID: recA, speakerIndex: 0,
                embedding: blob, segmentCount: 4, totalMs: 6000,
                embedderKind: EmbedderKind.wespeakerV2
            )
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            RecordingStore.SpeakerEmbeddingRow(
                recordingID: recB, speakerIndex: 0,
                embedding: blob, segmentCount: 3, totalMs: 4500,
                embedderKind: EmbedderKind.wespeakerV2
            )
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)

        let suggestions = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].personID == sarah)
        #expect(suggestions[0].score >= 0.99)
    }

    @Test("suggestForRecording skips slots already linked")
    func skipsLinkedSlots() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.linkSpeaker(personID: david, recordingID: recB, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        #expect(try await store.fetchPendingSuggestionsForRecording(recB).isEmpty)
    }

    @Test("suggestForRecording skips dismissed (person, recording, speaker) triples")
    func skipsDismissed() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.dismissSuggestion(personID: sarah, recordingID: recB, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        #expect(try await store.fetchPendingSuggestionsForRecording(recB).isEmpty)
    }

    @Test("suggestForNewPerson backfills suggestions across older recordings")
    func newPersonBackfill() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 1, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForNewPerson(personID: sarah, fromRecording: recA, speakerIndex: 0)

        let s = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(s.count == 1)
        #expect(s[0].personID == sarah)
        #expect(s[0].speakerIndex == 1)
    }

    @Test("idempotent — calling suggestForRecording twice doesn't duplicate")
    func idempotent() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await Self.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await Self.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: 0.1...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 6000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        try await engine.suggestForRecording(recordingID: recB)

        let s = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(s.count == 1)
    }
}
