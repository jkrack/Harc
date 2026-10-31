import Foundation
import Testing
@testable import HarcSummarize

@Suite("Refusal task publication guard")
struct SummaryTaskValidationTests {
    @Test(arguments: ["I will not book a venue", " I\nwill NOT book a venue ",
                      "I won’t book a venue", "Will not book a venue"])
    func explicitRefusalCannotPublish(text: String) throws {
        #expect(throws: SummarizerError.self) {
            try SummaryTaskValidation.validate(.init(summary: "Cancelled", actionItems: [.init(text: text, actor: "Ari")], parseWarning: false))
        }
    }

    @Test(arguments: ["remove obsolete accounts", "email the cancellation notice tonight",
                      "send the plan if legal approves", "I will not only review but also send the plan",
                      "I won't just review the plan", "record that Ari will not book a venue"])
    func legitimateWorkIsNotRejectedByNegationElsewhere(text: String) throws {
        try SummaryTaskValidation.validate(.init(summary: "Work", actionItems: [.init(text: text, actor: "Ada")], parseWarning: false))
    }

    @Test func shortAndLongServicesRejectRefusalBeforeReturningResult() async throws {
        for budget in [512, 128] {
            let model = RefusalModel()
            let service = SummarizerService(loader: { _ in model })
            let transcript = PromptTranscript(utterances: [.init(speaker: "Ari", text: String(repeating: "The event is cancelled. ", count: 40) + "I will not book a venue.")])
            do {
                _ = try await service.summarize(transcript: transcript, modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: budget)
                Issue.record("A refusal was published as a task")
            } catch let error as SummarizerError {
                guard case .generationFailed(let message) = error else { throw error }
                #expect(message.contains("refusal"))
            }
        }
    }
}

private actor RefusalModel: ContainerLike {
    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int,
                  onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        "## Summary\nThe event is cancelled.\n## Action Items\n- [ ] Ari: I will not book a venue"
    }
}
