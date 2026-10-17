import Foundation
import Testing
@testable import HarcSummarize

@Suite("Full transcript summary coverage")
struct LongSummaryTests {
    @Test func oversizedUtteranceRetainsEveryWordWithinBudget() throws {
        let words = (0..<450).map { "word\($0)" }
        let sections = try LongSummary.sections(.init(utterances: [.init(speaker: "Ada", text: words.joined(separator: " "))]), budget: 128)
        #expect(sections.count > 1)
        #expect(sections.allSatisfy { SummaryPrompt.wordCount(of: $0) <= 128 })
        let restored = sections.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "Ada:" } }
        #expect(restored == words)
    }

    @Test func laterCancellationReachesReconciliationWithEarlierCommitment() async throws {
        let probe = SectionProbe()
        let service = SummarizerService(loader: { _ in probe })
        let result = try await service.summarize(transcript: input, modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 128)
        let prompts = await probe.prompts
        #expect(prompts.count == 4)
        #expect(prompts[0].contains("opening"))
        #expect(prompts[1].contains("middle"))
        #expect(prompts[2].contains("closing"))
        #expect(prompts[3].contains("Ada will book the room"))
        #expect(prompts[3].contains("The meeting was cancelled"))
        #expect(result.omittedUtteranceCount == 0)
        #expect(result.actionItems.isEmpty)
        #expect(result.summary.contains("cancelled"))
    }

    @Test(arguments: [false, true])
    func intermediateFailureDoesNotPublishSuccessfulSections(malformed: Bool) async throws {
        let probe = SectionProbe(failSecond: true, malformed: malformed)
        let service = SummarizerService(loader: { _ in probe })
        do {
            _ = try await service.summarize(transcript: input, modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 128)
            Issue.record("Partial work returned as a summary")
        } catch { }
        #expect(await probe.prompts.count == 2)
    }

    @Test(arguments: [false, true])
    func failedFinalReconciliationDoesNotReturnIntermediateNotes(malformed: Bool) async throws {
        let probe = SectionProbe(failFourth: true, malformed: malformed)
        let service = SummarizerService(loader: { _ in probe })
        do {
            _ = try await service.summarize(transcript: input, modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 128)
            Issue.record("Intermediate notes returned after failed reconciliation")
        } catch { }
        #expect(await probe.prompts.count == 4)
    }

    @Test(arguments: [false, true])
    func interruptionDuringSecondSectionCannotPublish(unload: Bool) async throws {
        let probe = SectionProbe(holdSecond: true)
        let service = SummarizerService(loader: { _ in probe })
        let transcript = input
        let task = Task {
            try await service.summarize(transcript: transcript, modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 128)
        }
        await probe.waitForSecond()
        if unload { await service.unload() } else { task.cancel() }
        await probe.releaseSecond()
        do { _ = try await task.value; Issue.record("Interrupted partial summary returned") }
        catch is CancellationError { }
        #expect(await probe.prompts.count == 2)
    }

    @Test func unmergeableNotesFailInsteadOfLoopingOrDroppingContent() async throws {
        do {
            _ = try await LongSummary.run(transcript: input, budget: 128) { _ in
                "## Summary\n" + Array(repeating: "fact", count: 90).joined(separator: " ") + "\n## Action Items\n_None identified._"
            }
            Issue.record("Unmergeable notes unexpectedly succeeded")
        } catch { }
    }

    private var input: PromptTranscript {
        .init(utterances: ["opening", "middle", "closing"].map { marker in
            .init(speaker: "Ada", text: marker + " " + Array(repeating: "context", count: 90).joined(separator: " "))
        })
    }
}

private actor SectionProbe: ContainerLike {
    var prompts: [String] = []
    let failFourth: Bool
    let failSecond: Bool
    let malformed: Bool
    let holdSecond: Bool
    private var reachedSecond: CheckedContinuation<Void, Never>?
    private var secondRelease: CheckedContinuation<Void, Never>?
    func waitForSecond() async {
        if prompts.count >= 2 { return }
        await withCheckedContinuation { reachedSecond = $0 }
    }
    func releaseSecond() { secondRelease?.resume(); secondRelease = nil }
    init(failSecond: Bool = false, failFourth: Bool = false, malformed: Bool = false, holdSecond: Bool = false) {
        self.failFourth = failFourth
        self.holdSecond = holdSecond
        self.failSecond = failSecond; self.malformed = malformed
    }
    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int,
                  onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        prompts.append(promptBody)
        if prompts.count == 2 {
            reachedSecond?.resume(); reachedSecond = nil
            if holdSecond { await withCheckedContinuation { secondRelease = $0 } }
        }
        if (failSecond && prompts.count == 2) || (failFourth && prompts.count == 4) {
            if malformed { return "## Summary\nIncomplete" }
            throw SummarizerError.generationFailed("Injected section failure")
        }
        if prompts.count == 1 { return "## Summary\nAda will book the room.\n## Action Items\n- [ ] Ada: book the room" }
        if prompts.count == 2 { return "## Summary\nBudget is unchanged.\n## Action Items\n_None identified._" }
        return "## Summary\nThe meeting was cancelled; no booking is needed.\n## Action Items\n_None identified._"
    }
}
