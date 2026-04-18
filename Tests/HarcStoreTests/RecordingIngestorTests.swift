import Testing
import Foundation
@testable import HarcStore

@Suite("RecordingIngestor")
struct RecordingIngestorTests {
    private func tempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/private/tmp/harc-ing-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func fakeRecording(
        base: URL, year: String, day: String, time: String,
        txt: String? = "hello world"
    ) throws -> URL {
        let dir = base.appendingPathComponent(year).appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("\(time).wav")
        try Data([0]).write(to: wav)
        if let txt {
            try txt.write(to: dir.appendingPathComponent("\(time).txt"), atomically: true, encoding: .utf8)
        }
        return wav
    }

    @Test("ingestAll inserts all WAVs not yet in the store")
    func ingestInsertsMissing() async throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00")
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "11-30-15")

        let store = try await RecordingStore.inMemory()
        let ingestor = RecordingIngestor(baseDirectory: base, store: store)
        let inserted = try await ingestor.ingestAll()
        #expect(inserted == 2)

        let all = try await store.fetchAll()
        #expect(all.count == 2)
    }

    @Test("ingestAll skips WAVs already in the store")
    func skipsExisting() async throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let wav = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00")

        let store = try await RecordingStore.inMemory()
        let ingestor = RecordingIngestor(baseDirectory: base, store: store)
        _ = try await ingestor.ingestAll()
        let secondRun = try await ingestor.ingestAll()
        #expect(secondRun == 0)

        let all = try await store.fetchAll()
        #expect(all.count == 1)
        #expect(all[0].wavPath == wav.path)
    }

    @Test("ingested rows pick up transcript text from the .txt sibling")
    func ingestCapturesTranscript() async throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try fakeRecording(
            base: base, year: "2026", day: "2026-04-17", time: "10-00-00",
            txt: "discussing the Q3 roadmap"
        )

        let store = try await RecordingStore.inMemory()
        let ingestor = RecordingIngestor(baseDirectory: base, store: store)
        _ = try await ingestor.ingestAll()
        let all = try await store.fetchAll()
        #expect(all[0].transcriptText?.contains("Q3 roadmap") == true)
    }
}
