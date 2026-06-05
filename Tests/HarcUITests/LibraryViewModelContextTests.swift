import Foundation
import Testing
import HarcContext
import HarcStore
@testable import HarcUI

@Suite("LibraryViewModel context")
@MainActor
struct LibraryViewModelContextTests {
    @Test("renders context markdown for a library query")
    func rendersContextMarkdown() async throws {
        let store = try await RecordingStore.inMemory()
        let saved = try await store.upsert(Recording(
            wavPath: "/tmp/pricing.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Pricing Review",
            transcriptText: "Amy said pricing pressure affects enterprise margins."
        ))
        try await store.updateSummary(
            id: saved.id!,
            markdown: "Pricing pressure was the main risk.",
            actionItemsMarkdown: "- [ ] Amy: update margin model",
            modelID: "test-model",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceWordCount: 7
        )

        let vm = LibraryViewModel(store: store)
        let markdown = try await vm.contextMarkdown(for: "pricing pressure")

        #expect(markdown.contains("# Context: pricing pressure"))
        #expect(markdown.contains("## Supporting Evidence"))
        #expect(markdown.contains("## Supporting Summaries"))
        #expect(markdown.contains("## Action Items"))
        #expect(markdown.contains("Pricing Review"))
    }

    @Test("library search uses semantic results before text fallback")
    func librarySearchUsesSemanticResults() async throws {
        let store = try await RecordingStore.inMemory()
        let semanticRecording = try await store.upsert(Recording(
            wavPath: "/tmp/semantic-renewal.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Enterprise Renewal",
            transcriptText: "Amy discussed the enterprise renewal path."
        ))
        try await KnowledgeIndexer(store: store, embedder: RenewalEmbedder())
            .index(recordingID: semanticRecording.id!)

        let vm = LibraryViewModel(
            store: store,
            semanticSearch: SemanticSearchService(store: store, embedder: RenewalEmbedder())
        )
        vm.start()
        defer { vm.stop() }

        vm.searchText = "pricing"
        try await Task.sleep(nanoseconds: 350_000_000)

        #expect(vm.hits.first?.recording.wavPath == "/tmp/semantic-renewal.wav")
        #expect(vm.hits.first?.snippet.contains("enterprise renewal") == true)
    }

    @Test("library storage total tracks observed recordings")
    func libraryStorageTotalTracksObservedRecordings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.wav")
        let secondURL = directory.appendingPathComponent("second.wav")
        try Data(repeating: 1, count: 3).write(to: firstURL)
        try Data(repeating: 2, count: 7).write(to: secondURL)

        let store = try await RecordingStore.inMemory()
        let vm = LibraryViewModel(store: store)
        vm.start()
        defer { vm.stop() }

        let first = try await store.upsert(Recording(
            wavPath: firstURL.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "First"
        ))
        _ = try await store.upsert(Recording(
            wavPath: secondURL.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            title: "Second"
        ))

        #expect(await waitForLibraryState { vm.totalBytes == 10 })

        try await store.softDelete(id: first.id!)

        #expect(await waitForLibraryState { vm.totalBytes == 7 })
    }
}

private func waitForLibraryState(
    timeout: TimeInterval = 1,
    condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

private struct RenewalEmbedder: LocalTextEmbedder {
    let modelID = "renewal-test-embedder"

    func embed(texts: [String]) async throws -> [Data] {
        texts.map { text in
            let lowercased = text.lowercased()
            if lowercased.contains("pricing") || lowercased.contains("renewal") {
                return EmbeddingVectorCodec.encode([1, 0, 0, 0])
            }
            return EmbeddingVectorCodec.encode([0, 1, 0, 0])
        }
    }
}
