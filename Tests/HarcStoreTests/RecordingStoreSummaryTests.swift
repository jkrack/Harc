import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("RecordingStore summary persistence")
struct RecordingStoreSummaryTests {

    private func seed(_ store: RecordingStore, wav: String) async throws -> Int64 {
        let rec = Recording(
            wavPath: wav,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptText: "body"
        )
        let saved = try await store.upsert(rec)
        return saved.id!
    }

    @Test("v7_summary migration adds the five columns without dropping existing data")
    func v7AddsColumnsAndPreservesData() throws {
        let dbq = try DatabaseQueue()

        // Stand up migrations up through v6 only, seed a row, then run v7.
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO recordings
                  (wav_path, started_at, transcript_text, pinned, created_at, updated_at)
                VALUES (?, ?, ?, 0, ?, ?)
                """, arguments: ["/tmp/seed.wav", Date(), "seed body", Date(), Date()])
        }

        try dbq.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(recordings)")
                .map { ($0["name"] as String?) ?? "" }
            #expect(cols.contains("summary_markdown"))
            #expect(cols.contains("action_items_markdown"))
            #expect(cols.contains("summary_model_id"))
            #expect(cols.contains("summary_generated_at"))
            #expect(cols.contains("summary_source_word_count"))

            // Seed row still there and queryable.
            let transcript = try String.fetchOne(
                db,
                sql: "SELECT transcript_text FROM recordings WHERE wav_path = ?",
                arguments: ["/tmp/seed.wav"]
            )
            #expect(transcript == "seed body")
        }
    }

    @Test("updateSummary writes all five columns and clearSummary nulls them")
    func updateAndClearSummaryRoundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await seed(store, wav: "/tmp/s.wav")

        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.updateSummary(
            id: id,
            markdown: "summary body",
            actionItemsMarkdown: "- [ ] someone: do the thing",
            modelID: "gemma-4-e2b-it-4bit",
            generatedAt: generatedAt,
            sourceWordCount: 1234
        )

        let saved = try await store.fetch(id: id)
        #expect(saved?.summaryMarkdown == "summary body")
        #expect(saved?.actionItemsMarkdown == "- [ ] someone: do the thing")
        #expect(saved?.summaryModelID == "gemma-4-e2b-it-4bit")
        #expect(saved?.summarySourceWordCount == 1234)
        // Date round-trips via Unix ms — expect equality to millisecond precision.
        #expect(
            Int(saved!.summaryGeneratedAt!.timeIntervalSince1970 * 1000)
            == Int(generatedAt.timeIntervalSince1970 * 1000)
        )

        try await store.clearSummary(id: id)
        let cleared = try await store.fetch(id: id)
        #expect(cleared?.summaryMarkdown == nil)
        #expect(cleared?.actionItemsMarkdown == nil)
        #expect(cleared?.summaryModelID == nil)
        #expect(cleared?.summaryGeneratedAt == nil)
        #expect(cleared?.summarySourceWordCount == nil)
    }

    @Test("updateSummary throws notFound on an unknown id")
    func updateSummaryNotFound() async throws {
        let store = try await RecordingStore.inMemory()
        await #expect(throws: StoreError.self) {
            try await store.updateSummary(
                id: 999_999,
                markdown: "x",
                actionItemsMarkdown: "y",
                modelID: "z",
                generatedAt: Date(),
                sourceWordCount: 0
            )
        }
    }

    @Test("clearSummary throws notFound on an unknown id")
    func clearSummaryNotFound() async throws {
        let store = try await RecordingStore.inMemory()
        await #expect(throws: StoreError.self) {
            try await store.clearSummary(id: 999_999)
        }
    }
}
