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
        #expect(markdown.contains("## Relevant Evidence"))
        #expect(markdown.contains("## Summaries"))
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
