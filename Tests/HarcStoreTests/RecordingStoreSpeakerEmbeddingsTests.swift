import XCTest
@testable import HarcStore

final class RecordingStoreSpeakerEmbeddingsTests: XCTestCase {

    func test_upsertAndFetch_roundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")

        let vec = Data([UInt8](repeating: 0xAB, count: 768))
        let row = RecordingStore.SpeakerEmbeddingRow(
            recordingID: recID, speakerIndex: 0,
            embedding: vec, segmentCount: 4, totalMs: 6000
        )
        try await store.upsertSpeakerEmbeddings(recordingID: recID, rows: [row])

        let fetched = try await store.speakerEmbedding(recordingID: recID, speakerIndex: 0)
        XCTAssertEqual(fetched?.embedding, vec)
        XCTAssertEqual(fetched?.segmentCount, 4)
        XCTAssertEqual(fetched?.totalMs, 6000)
    }

    func test_upsert_overwritesPriorRows() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/b.wav")

        let first = RecordingStore.SpeakerEmbeddingRow(
            recordingID: recID, speakerIndex: 0,
            embedding: Data(repeating: 0x01, count: 768),
            segmentCount: 1, totalMs: 1000
        )
        try await store.upsertSpeakerEmbeddings(recordingID: recID, rows: [first])

        let second = RecordingStore.SpeakerEmbeddingRow(
            recordingID: recID, speakerIndex: 0,
            embedding: Data(repeating: 0x02, count: 768),
            segmentCount: 9, totalMs: 9000
        )
        try await store.upsertSpeakerEmbeddings(recordingID: recID, rows: [second])

        let fetched = try await store.speakerEmbedding(recordingID: recID, speakerIndex: 0)
        XCTAssertEqual(fetched?.segmentCount, 9)
        XCTAssertEqual(fetched?.totalMs, 9000)
        XCTAssertEqual(fetched?.embedding.first, 0x02)
    }

    func test_allSpeakerEmbeddings_excludesTargetRecording() async throws {
        let store = try await RecordingStore.inMemory()
        let a = try await seedRecording(in: store, wav: "/tmp/c.wav")
        let b = try await seedRecording(in: store, wav: "/tmp/d.wav")

        try await store.upsertSpeakerEmbeddings(recordingID: a, rows: [
            .init(recordingID: a, speakerIndex: 0, embedding: Data(repeating: 0x11, count: 768),
                  segmentCount: 1, totalMs: 2000)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: b, rows: [
            .init(recordingID: b, speakerIndex: 0, embedding: Data(repeating: 0x22, count: 768),
                  segmentCount: 1, totalMs: 2000),
            .init(recordingID: b, speakerIndex: 1, embedding: Data(repeating: 0x33, count: 768),
                  segmentCount: 1, totalMs: 2000),
        ])

        let rows = try await store.allSpeakerEmbeddings(excludingRecording: a)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.recordingID == b })
    }

    func test_fetch_missingReturnsNil() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/e.wav")
        let missing = try await store.speakerEmbedding(recordingID: recID, speakerIndex: 99)
        XCTAssertNil(missing)
    }

    // MARK: - helpers

    private func seedRecording(in store: RecordingStore, wav: String) async throws -> Int64 {
        let rec = Recording(
            wavPath: wav,
            txtPath: nil,
            jsonPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            transcriptText: nil
        )
        let saved = try await store.upsert(rec)
        return saved.id!
    }
}
