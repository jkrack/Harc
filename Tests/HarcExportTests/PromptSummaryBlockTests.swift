import Testing
import Foundation
import HarcStore
@testable import HarcExport

@Suite("PromptSummaryBlock")
struct PromptSummaryBlockTests {
    @Test("make returns nil when any of the four required columns is nil")
    func makeNilWhenAnyFieldMissing() {
        let base = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(),
            summaryMarkdown: nil,
            actionItemsMarkdown: "- [ ] task",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: Date(),
            summarySourceWordCount: 100
        )
        #expect(PromptSummaryBlock.make(from: base) == nil)

        var r2 = base; r2.summaryMarkdown = "s"; r2.actionItemsMarkdown = nil
        #expect(PromptSummaryBlock.make(from: r2) == nil)

        var r3 = base; r3.summaryMarkdown = "s"; r3.summaryModelID = nil
        #expect(PromptSummaryBlock.make(from: r3) == nil)

        var r4 = base; r4.summaryMarkdown = "s"; r4.summaryGeneratedAt = nil
        #expect(PromptSummaryBlock.make(from: r4) == nil)
    }

    @Test("make returns populated block when all four required columns are present")
    func makePopulated() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(),
            summaryMarkdown: "The team agreed…",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 100
        )
        let block = PromptSummaryBlock.make(from: rec)
        #expect(block?.summaryMarkdown == "The team agreed…")
        #expect(block?.actionItemsMarkdown == "- [ ] Jason: ship it")
        #expect(block?.modelID == "gemma-4-e2b-it-4bit")
        #expect(block?.generatedAt == date)
    }

    @Test("Equatable identity")
    func equatable() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let a = PromptSummaryBlock(summaryMarkdown: "s", actionItemsMarkdown: "a", modelID: "m", generatedAt: date)
        let b = PromptSummaryBlock(summaryMarkdown: "s", actionItemsMarkdown: "a", modelID: "m", generatedAt: date)
        #expect(a == b)
    }
}
