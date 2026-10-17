import Foundation
import Testing
@testable import HarcSummarize

@Suite("Two-pass summary generation")
struct TwoPassSummaryTests {
    @Test func summariesUseDedicatedGenerationAndKeepFactsSeparateFromTasks() async throws {
        let model = TwoPassModel()
        let service = SummarizerService(loader: { _ in model })
        let result = try await service.summarize(transcript: .init(utterances: [.init(speaker: "Ada", text: "I will send it.")]), modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 512)
        #expect(result.summary == "The project is healthy. Ada will send the plan on Friday.")
        #expect(result.actionItems.first?.actor == "Ada")
        #expect(result.actionItems.first?.due == "Friday")
        #expect(await model.summaryCalls == 2)
        _ = try await service.answer(question: "q", contextMarkdown: "c", modelID: "m", modelDirectory: .temporaryDirectory)
        _ = try await service.transform(text: "t", instruction: "i", modelID: "m", modelDirectory: .temporaryDirectory)
        #expect(await model.ordinaryCalls == 2)
    }

    @Test(arguments: ["", "## Summary\n", "## Summary\nFacts\n## Action Items\n_None identified._"])
    func incompleteFactsCannotPublishFirstPass(response: String) async throws {
        let model = TwoPassModel(facts: response)
        let service = SummarizerService(loader: { _ in model })
        do {
            _ = try await service.summarize(transcript: .init(utterances: [.init(speaker: "Ada", text: "hello")]), modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 512)
            Issue.record("Incomplete factual pass returned a summary")
        } catch is SummarizerError { }
        #expect(await model.summaryCalls == 2)
    }
}
private actor TwoPassModel: ContainerLike {
    var summaryCalls = 0
    var ordinaryCalls = 0
    let facts: String
    init(facts: String = "## Summary\nThe project is healthy. Ada will send the plan on Friday.") { self.facts = facts }
    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int, onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        ordinaryCalls += 1; return "Ordinary answer"
    }
    func generateSummary(promptBody: String, maxTokens: Int, onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        summaryCalls += 1
        return summaryCalls == 1 ? "## Summary\nA plan will be sent.\n## Confirmed Commitments\n- [Ada]: send the plan (Friday)" : facts
    }
}
