import Testing
import Foundation
@testable import HarcStore

@Suite("TitleSuggester")
struct TitleSuggesterTests {
    @Test("nil/empty transcripts return nil")
    func emptyInputs() {
        #expect(TitleSuggester.suggest(from: nil) == nil)
        #expect(TitleSuggester.suggest(from: "") == nil)
        #expect(TitleSuggester.suggest(from: "   \n  ") == nil)
    }

    @Test("picks a person name from simple transcript")
    func extractsPersonName() {
        let text = "So Sarah led the discussion about the Q3 roadmap and timelines."
        let result = TitleSuggester.suggest(from: text)
        #expect(result?.contains("Sarah") == true)
    }

    @Test("picks organization names")
    func extractsOrganization() {
        let text = "We met with folks from Acme Corp yesterday to talk about the contract."
        let result = TitleSuggester.suggest(from: text)
        #expect(result != nil)
        #expect(result?.lowercased().contains("acme") == true)
    }

    @Test("returns nil when no entities are present")
    func noEntities() {
        let text = "uh yeah so i was thinking about lunch and then tomorrow"
        let result = TitleSuggester.suggest(from: text)
        #expect(result == nil)
    }

    @Test("pretty-cases the first occurrence form")
    func preservesOriginalCase() {
        let text = "Sarah shared the plan. Then sarah followed up."
        let result = TitleSuggester.suggest(from: text)
        // Must use the first-occurrence capitalisation.
        #expect(result?.contains("Sarah") == true)
    }

    @Test("extractEntities returns ordered list of all entities")
    func extractEntitiesReturnsAll() {
        let text = "Sarah met with Acme Corp and also spoke with John about Q3."
        let entities = TitleSuggester.extractEntities(from: text)
        #expect(entities.count >= 2)
        #expect(entities.contains { $0.lowercased().contains("sarah") })
        #expect(entities.contains { $0.lowercased().contains("acme") })
    }

    @Test("extractEntities returns empty for no-entity transcript")
    func extractEntitiesEmpty() {
        #expect(TitleSuggester.extractEntities(from: nil) == [])
        #expect(TitleSuggester.extractEntities(from: "") == [])
        #expect(TitleSuggester.extractEntities(from: "uh yeah so about lunch") == [])
    }

    @Test("suggest still delegates to top-2 of extractEntities")
    func suggestUsesTopTwo() {
        let text = "Sarah and John met Sarah and Acme Corp. Acme Acme."
        let suggestion = TitleSuggester.suggest(from: text)
        let entities = TitleSuggester.extractEntities(from: text)
        let expected = Array(entities.prefix(2)).joined(separator: ", ")
        #expect(suggestion == expected)
    }

    // MARK: - Summary-derived titles

    /// The row identity the audit asked for: the summary's first clause.
    @Test("summary first clause becomes the title")
    func summaryFirstClause() {
        let summary = "The team reviewed the weekly onboarding drop-off, which remains at 40% and is primarily caused by users misinterpreting the missing microphone prompt."
        #expect(TitleSuggester.fromSummary(summary) == "The team reviewed the weekly onboarding drop-off")
    }

    @Test("short first sentence is taken whole")
    func shortSentenceWhole() {
        #expect(TitleSuggester.fromSummary("Pricing review for the Acme renewal. More detail follows.")
                == "Pricing review for the Acme renewal")
    }

    @Test("markdown furniture is stripped")
    func markdownStripped() {
        #expect(TitleSuggester.fromSummary("## **Budget planning kickoff for Q3.** More.")
                == "Budget planning kickoff for Q3")
    }

    @Test("empty and trivial summaries produce no title")
    func trivialSummariesRejected() {
        #expect(TitleSuggester.fromSummary(nil) == nil)
        #expect(TitleSuggester.fromSummary("   ") == nil)
        #expect(TitleSuggester.fromSummary("Okay.") == nil)
    }

    @Test("very long clause caps at a word boundary")
    func longClauseCaps() {
        let long = String(repeating: "onboarding ", count: 30)
        let title = TitleSuggester.fromSummary(long)
        #expect(title != nil)
        #expect((title?.count ?? 0) <= 72)
        #expect(title?.hasSuffix(" ") == false)
    }
}
