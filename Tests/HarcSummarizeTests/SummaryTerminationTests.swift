import Foundation
import Testing
@testable import HarcSummarize

@Suite("Summary generation termination")
struct SummaryTerminationTests {
    @Test(arguments: [1, 2, 4])
    func outputLimitCannotPublishAnyPass(pass: Int) async throws {
        let model = TerminationModel(stopAt: pass, reason: .outputLimit)
        let service = SummarizerService(loader: { _ in model })
        do {
            _ = try await service.summarize(transcript: transcript(long: pass != 1), modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 128)
            Issue.record("Output-limited response was returned as complete")
        } catch let error as SummarizerError {
            #expect(error.localizedDescription.contains("output limit"))
        }
        #expect(await model.calls == pass)
    }

    @Test(arguments: [GenerationStats.StopReason.cancelled, .outputLimit])
    func laterCompletionCannotEraseAnEarlierFailure(reason: GenerationStats.StopReason) async throws {
        let model = TerminationModel(stopAt: 1, reason: reason, contradictFinal: true)
        let service = SummarizerService(loader: { _ in model })
        do {
            _ = try await service.summarize(transcript: transcript(long: false), modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 128)
            Issue.record("Contradictory completion cleared the failure")
        } catch let error as SummarizerError {
            #expect(error.localizedDescription.contains(reason == .cancelled ? "stopped before completing" : "output limit"))
        }
    }

    @Test func exactTokenCountAndInterimEstimatesDoNotOverrideNormalCompletion() async throws {
        let model = TerminationModel(stopAt: 1, reason: .complete)
        let service = SummarizerService(loader: { _ in model })
        let result = try await service.summarize(transcript: transcript(long: false), modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 128)
        #expect(!result.parseWarning)
        #expect(result.summary == "A complete fact.")
    }

    private func transcript(long: Bool) -> PromptTranscript {
        .init(utterances: (0..<(long ? 3 : 1)).map { _ in
            .init(speaker: "Ada", text: long ? Array(repeating: "context", count: 90).joined(separator: " ") : "A fact.")
        })
    }
}

private actor TerminationModel: ContainerLike {
    var calls = 0
    let stopAt: Int
    let reason: GenerationStats.StopReason
    let contradictFinal: Bool
    init(stopAt: Int, reason: GenerationStats.StopReason, contradictFinal: Bool = false) {
        self.stopAt = stopAt; self.reason = reason; self.contradictFinal = contradictFinal
    }
    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int,
                  onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        calls += 1
        // Approximate interim counts are intentionally misleading.
        onStats?(.init(generatedTokens: maxTokens + 100, tokensPerSecond: 10, isFinal: false, stopReason: .outputLimit))
        onStats?(.init(generatedTokens: maxTokens, tokensPerSecond: 10, isFinal: true, stopReason: calls == stopAt ? reason : .complete))
        if contradictFinal { onStats?(.init(generatedTokens: maxTokens, tokensPerSecond: 10, isFinal: true, stopReason: .complete)) }
        if promptBody.contains("Do not generate an action list") { return "## Summary\nA complete fact." }
        return "## Summary\nA complete fact.\n## Action Items\n_None identified._"
    }
}
