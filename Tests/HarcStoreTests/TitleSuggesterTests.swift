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
}
