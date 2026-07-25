import Testing
import Foundation
@testable import HarcUI
@testable import HarcStore

@Suite("LibraryMaintenanceStore")
@MainActor
struct LibraryMaintenanceStoreTests {

    struct StubTranscriber: ArchiveTranscriber {
        let modelID: String
        var output: String = "reprocessed"
        func retranscribe(wavPath: String) async throws -> String { output }
    }

    /// Creates a real (empty) file at the wav path: the reprocessor correctly
    /// skips recordings whose audio is gone, so a fixture without a file on
    /// disk would exercise the missing-audio path instead of the one under test.
    private func makeRecording(_ title: String, at offset: TimeInterval) -> Recording {
        let path = "/tmp/harc-maint-\(UUID().uuidString.prefix(8)).wav"
        FileManager.default.createFile(atPath: path, contents: Data([0x00]))
        return Recording(
            wavPath: path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060 + offset),
            title: title,
            transcriptText: "a transcript with several words in it"
        )
    }

    @Test("backlogs reflect what actually needs work")
    func backlogsReflectWork() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(makeRecording("A", at: 0))
        _ = try await store.upsert(makeRecording("B", at: 100))

        let maintenance = LibraryMaintenanceStore(
            store: store,
            transcriberProvider: { StubTranscriber(modelID: "engine-v2") }
        )
        await maintenance.refreshBacklogs()

        #expect(maintenance.reprocessBacklog == 2)
        #expect(maintenance.indexBacklog == 2)
    }

    @Test("indexing clears the index backlog and makes recordings searchable")
    func indexingWorks() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(makeRecording("Meeting", at: 0))

        let maintenance = LibraryMaintenanceStore(
            store: store,
            transcriberProvider: { StubTranscriber(modelID: "engine-v2") }
        )
        await maintenance.refreshBacklogs()
        maintenance.startIndexing()

        try await waitUntil { maintenance.job == .idle && maintenance.indexBacklog == 0 }
        #expect(maintenance.indexBacklog == 0)
        #expect(maintenance.lastOutcome?.contains("indexed") == true)

        let hits = try await store.semanticSearch(
            query: "transcript words",
            embedder: maintenance.searchEmbedder
        )
        #expect(!hits.isEmpty)
    }

    @Test("reprocessing replaces transcripts and empties the backlog")
    func reprocessingWorks() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(makeRecording("Old", at: 0))

        let maintenance = LibraryMaintenanceStore(
            store: store,
            transcriberProvider: { StubTranscriber(modelID: "engine-v2", output: "brand new text") }
        )
        await maintenance.refreshBacklogs()
        #expect(maintenance.reprocessBacklog == 1)

        maintenance.startReprocess()
        try await waitUntil { maintenance.job == .idle && maintenance.reprocessBacklog == 0 }

        #expect(try await store.fetch(id: rec.id!)?.transcriptText == "brand new text")
        #expect(maintenance.lastOutcome?.contains("re-transcribed") == true)
    }

    @Test("a second job is refused while one is running")
    func jobsAreMutuallyExclusive() async throws {
        let store = try await RecordingStore.inMemory()
        for i in 0..<20 { _ = try await store.upsert(makeRecording("R\(i)", at: Double(i))) }

        let maintenance = LibraryMaintenanceStore(
            store: store,
            transcriberProvider: { StubTranscriber(modelID: "engine-v2") }
        )
        await maintenance.refreshBacklogs()

        maintenance.startIndexing()
        // Reprocess must not start on top of an in-flight index build; both
        // write transcript rows and would race.
        maintenance.startReprocess()
        if case .reprocessing = maintenance.job {
            Issue.record("reprocess started while indexing was running")
        }
        maintenance.cancel()
    }

    @Test("no store means every operation is an inert no-op")
    func nilStoreIsInert() async {
        let maintenance = LibraryMaintenanceStore(
            store: nil,
            transcriberProvider: { StubTranscriber(modelID: "engine-v2") }
        )
        await maintenance.refreshBacklogs()
        maintenance.startIndexing()
        maintenance.startReprocess()
        maintenance.indexNewRecording(id: 1, text: "words", durationMs: 1000)

        #expect(maintenance.job == .idle)
        #expect(maintenance.reprocessBacklog == 0)
        #expect(maintenance.indexBacklog == 0)
    }

    @Test("a newly captured recording is indexed without a manual pass")
    func newRecordingIsIndexed() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(makeRecording("Fresh", at: 0))

        let maintenance = LibraryMaintenanceStore(
            store: store,
            transcriberProvider: { StubTranscriber(modelID: "engine-v2") }
        )
        maintenance.indexNewRecording(
            id: rec.id!,
            text: "the quarterly planning discussion happened here",
            durationMs: 60_000
        )

        try await waitUntil {
            let hits = try await store.semanticSearch(
                query: "quarterly planning",
                embedder: maintenance.searchEmbedder
            )
            return !hits.isEmpty
        }
    }

    /// Poll a condition to a deadline. The work runs in detached tasks, so
    /// there's no handle to await — but a fixed sleep is exactly the flake this
    /// codebase already got bitten by.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("condition not met within \(timeout)s")
    }
}
