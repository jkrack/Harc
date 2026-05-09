import Foundation
import Testing
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
}
