import Foundation
import Testing
import XCTest
import HarcCore
import HarcSTT
import HarcSummarize

@Suite("Golden sample quality evaluation")
struct GoldenSampleEvaluationTests {
    @Test("complete customer call output passes accuracy and completeness thresholds")
    func completeOutputPassesGoldenSampleThresholds() {
        let result = GoldenSampleEvaluator.evaluate(
            candidate: GoldenSample.customerRenewalCompleteCandidate,
            against: GoldenSample.customerRenewal
        )

        #expect(result.passed)
        #expect(result.wordErrorRate <= 0.12)
        #expect(result.summaryFactCoverage == 1)
        #expect(result.actionItemCoverage == 1)
        #expect(result.speakerTurnCoverage == 1)
        #expect(result.noteFactCoverage == 1)
        #expect(result.forbiddenClaimsFound.isEmpty)
    }

    @Test("incomplete customer call output fails for missing facts, actions, and hallucinations")
    func incompleteOutputFailsGoldenSampleThresholds() {
        let result = GoldenSampleEvaluator.evaluate(
            candidate: GoldenSample.customerRenewalIncompleteCandidate,
            against: GoldenSample.customerRenewal
        )

        #expect(!result.passed, "Incomplete output should not pass quality gates.")
        #expect(result.wordErrorRate > GoldenSampleEvaluator.Thresholds.default.maximumWordErrorRate)
        #expect(result.summaryFactCoverage < 1)
        #expect(result.actionItemCoverage < 1)
        #expect(result.noteFactCoverage < 1)
        #expect(result.forbiddenClaimsFound.contains("discount approved"))
        #expect(result.missingSummaryFacts.contains("legal-review"))
        #expect(result.missingActionItems.contains("Jason: send renewal plan"))
        #expect(result.missingNoteFacts.contains("Friday deadline"))
    }

    @Test("word error rate scores substitutions deletions and insertions")
    func wordErrorRateScoresTranscriptAccuracy() {
        let reference = "amy needs legal review before discount approval"
        let candidate = "amy needs finance approval before discount"

        let wer = GoldenSampleEvaluator.wordErrorRate(candidate: candidate, reference: reference)

        #expect(wer > 0)
        #expect(wer == 3.0 / 7.0)
    }
}

final class RealModelGoldenSampleTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARC_INTEGRATION_TESTS"] == "1",
            "Set HARC_INTEGRATION_TESTS=1 to run real STT/summarizer golden quality gates."
        )
    }

    func test_realSummarizerOutput_passesCustomerRenewalGoldenSample() async throws {
        let modelDir = try summarizerModelDirectory()
        let service = SummarizerService(loader: SummarizerService.defaultLoader)
        let reference = GoldenSample.customerRenewal
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Amy", text: "The customer renewal is healthy, but pricing risk is still open."),
            .init(speaker: "Jason", text: "I will send the renewal plan by Friday and include the new tiering page."),
            .init(speaker: "Priya", text: "Do not approve the discount until legal finishes review."),
            .init(speaker: "Amy", text: "Capture the follow up note for Michelle and tag it customer renewal."),
        ])

        let generated = try await service.summarize(
            transcript: transcript,
            modelID: "gemma-4-e2b-it-4bit",
            modelDirectory: modelDir,
            budgetWords: SummaryPrompt.budgetWords(contextTokens: 32_000)
        )
        let summaryMarkdown = renderSummaryMarkdown(generated)
        let candidate = GoldenSampleCandidate(
            transcript: reference.referenceTranscript,
            speakerTurns: reference.expectedSpeakerTurns.map {
                CandidateSpeakerTurn(speakerName: $0.speakerName, text: $0.requiredPhrase)
            },
            summaryMarkdown: summaryMarkdown,
            noteMarkdown: summaryMarkdown
        )
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: reference)

        XCTAssertTrue(
            result.passed,
            "Real summarizer output failed golden quality gates.\n\(result.report)\nGenerated:\n\(summaryMarkdown)"
        )
    }

    func test_realSTTOutput_isScoredAgainstShortSpeechReference() async throws {
        let fixture = try shortSpeechFixtureURL()
        let reference = ProcessInfo.processInfo.environment["HARC_STT_GOLDEN_REFERENCE"] ?? "this is a test"
        let maximumWER = Double(ProcessInfo.processInfo.environment["HARC_STT_MAX_WER"] ?? "0.75") ?? 0.75

        let transcriber = Transcriber()
        try await transcriber.loadModels()
        let result = try await transcriber.transcribe(audioPath: fixture.path, vad: false)
        let wer = GoldenSampleEvaluator.wordErrorRate(candidate: result.text, reference: reference)

        XCTAssertLessThanOrEqual(
            wer,
            maximumWER,
            "Real STT output exceeded WER threshold. reference=\(reference), candidate=\(result.text), wer=\(wer)"
        )
        XCTAssertFalse(result.words.isEmpty, "Real STT output should include word timings.")
    }

    private func summarizerModelDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let modelDir = appSupport
            .appendingPathComponent("Harc", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("gemma-4-e2b-it-4bit", isDirectory: true)

        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelDir.path),
            "Gemma 4 E2B is not installed at \(modelDir.path). Download it in Harc Settings > Models first."
        )
        return modelDir
    }

    private func shortSpeechFixtureURL() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/HarcSTTTests/Fixtures/short-speech.wav"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("HarcSTTTests/Fixtures/short-speech.wav"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("short-speech.wav fixture not found.")
        }
        return url
    }

    private func renderSummaryMarkdown(_ output: SummaryParseResult) -> String {
        let actions: String
        if output.actionItems.isEmpty {
            actions = "_None identified._"
        } else {
            actions = output.actionItems.map { item in
                let actor = item.actor.map { "\($0): " } ?? ""
                let due = item.due.map { " (\($0))" } ?? ""
                return "- [\(item.done ? "x" : " ")] \(actor)\(item.text)\(due)"
            }
            .joined(separator: "\n")
        }
        return """
        ## Summary
        \(output.summary)

        ## Action Items
        \(actions)
        """
    }
}

private enum GoldenSample {
    static let customerRenewal = GoldenSampleReference(
        id: "customer-renewal-call",
        referenceTranscript: """
        Amy: The customer renewal is healthy, but pricing risk is still open.
        Jason: I will send the renewal plan by Friday and include the new tiering page.
        Priya: Do not approve the discount until legal finishes review.
        Amy: Capture the follow up note for Michelle and tag it customer renewal.
        """,
        expectedSpeakerTurns: [
            .init(speakerName: "Amy", requiredPhrase: "pricing risk is still open"),
            .init(speakerName: "Jason", requiredPhrase: "send the renewal plan by Friday"),
            .init(speakerName: "Priya", requiredPhrase: "legal finishes review"),
        ],
        requiredSummaryFacts: [
            .init(id: "healthy-renewal", requiredTerms: ["renewal", "healthy"]),
            .init(id: "pricing-risk", requiredTerms: ["pricing", "risk", "open"]),
            .init(id: "friday-plan", requiredTerms: ["renewal", "plan", "Friday"]),
            .init(id: "legal-review", requiredTerms: ["legal", "review", "discount"]),
            .init(id: "note-for-michelle", requiredTerms: ["Michelle", "customer", "renewal"]),
        ],
        forbiddenClaims: [
            .init(id: "discount approved", terms: ["discount", "approved"]),
            .init(id: "pricing resolved", terms: ["pricing", "resolved"]),
        ],
        requiredActionItems: [
            .init(id: "Jason: send renewal plan", actor: "Jason", requiredTerms: ["send", "renewal", "plan", "Friday"]),
            .init(id: "Amy: capture Michelle note", actor: "Amy", requiredTerms: ["Michelle", "customer", "renewal"]),
        ],
        requiredNoteFacts: [
            .init(id: "Friday deadline", requiredTerms: ["Friday", "renewal", "plan"]),
            .init(id: "legal discount hold", requiredTerms: ["legal", "discount"]),
            .init(id: "Michelle follow up", requiredTerms: ["Michelle", "customer", "renewal"]),
        ]
    )

    static let customerRenewalCompleteCandidate = GoldenSampleCandidate(
        transcript: """
        Amy: The customer renewal is healthy but pricing risk is still open.
        Jason: I will send the renewal plan by Friday and include the new tiering page.
        Priya: Do not approve the discount until legal finishes review.
        Amy: Capture the follow-up note for Michelle and tag it customer renewal.
        """,
        speakerTurns: [
            .init(speakerName: "Amy", text: "The customer renewal is healthy but pricing risk is still open."),
            .init(speakerName: "Jason", text: "I will send the renewal plan by Friday and include the new tiering page."),
            .init(speakerName: "Priya", text: "Do not approve the discount until legal finishes review."),
            .init(speakerName: "Amy", text: "Capture the follow-up note for Michelle and tag it customer renewal."),
        ],
        summaryMarkdown: """
        ## Summary
        The customer renewal is healthy, but pricing risk is still open. Jason owns sending the renewal plan by Friday with the new tiering page. Priya said the discount must wait for legal review. Amy also asked to capture a customer renewal follow-up note for Michelle.

        ## Action Items
        - [ ] Jason: send the renewal plan by Friday
        - [ ] Amy: capture the customer renewal follow-up note for Michelle
        """,
        noteMarkdown: """
        # Customer Renewal

        Pricing risk remains open even though the renewal is healthy.
        Jason owes the renewal plan by Friday.
        Hold discount approval until legal review is finished.
        Follow up with Michelle and tag the note customer renewal.
        """
    )

    static let customerRenewalIncompleteCandidate = GoldenSampleCandidate(
        transcript: """
        Amy: The customer renewal is okay.
        Jason: I will send a plan soon.
        Priya: The discount is approved.
        """,
        speakerTurns: [
            .init(speakerName: "Amy", text: "The customer renewal is okay."),
            .init(speakerName: "Jason", text: "I will send a plan soon."),
            .init(speakerName: "Priya", text: "The discount is approved."),
        ],
        summaryMarkdown: """
        ## Summary
        The renewal looks okay and the discount approved.

        ## Action Items
        - [ ] Jason: send a plan
        """,
        noteMarkdown: """
        # Renewal

        Renewal looks okay. Jason has a plan.
        """
    )
}

private struct GoldenSampleReference {
    var id: String
    var referenceTranscript: String
    var expectedSpeakerTurns: [ExpectedSpeakerTurn]
    var requiredSummaryFacts: [RequiredFact]
    var forbiddenClaims: [ForbiddenClaim]
    var requiredActionItems: [RequiredActionItem]
    var requiredNoteFacts: [RequiredFact]
}

private struct GoldenSampleCandidate {
    var transcript: String
    var speakerTurns: [CandidateSpeakerTurn]
    var summaryMarkdown: String
    var noteMarkdown: String
}

private struct ExpectedSpeakerTurn {
    var speakerName: String
    var requiredPhrase: String
}

private struct CandidateSpeakerTurn {
    var speakerName: String
    var text: String
}

private struct RequiredFact {
    var id: String
    var requiredTerms: [String]
}

private struct ForbiddenClaim {
    var id: String
    var terms: [String]
}

private struct RequiredActionItem {
    var id: String
    var actor: String
    var requiredTerms: [String]
}

private struct GoldenSampleResult {
    var wordErrorRate: Double
    var missingSpeakerTurns: [String]
    var missingSummaryFacts: [String]
    var forbiddenClaimsFound: [String]
    var missingActionItems: [String]
    var missingNoteFacts: [String]

    var summaryFactCoverage: Double
    var actionItemCoverage: Double
    var speakerTurnCoverage: Double
    var noteFactCoverage: Double

    var passed: Bool {
        wordErrorRate <= GoldenSampleEvaluator.Thresholds.default.maximumWordErrorRate
            && summaryFactCoverage >= GoldenSampleEvaluator.Thresholds.default.minimumSummaryFactCoverage
            && actionItemCoverage >= GoldenSampleEvaluator.Thresholds.default.minimumActionItemCoverage
            && speakerTurnCoverage >= GoldenSampleEvaluator.Thresholds.default.minimumSpeakerTurnCoverage
            && noteFactCoverage >= GoldenSampleEvaluator.Thresholds.default.minimumNoteFactCoverage
            && forbiddenClaimsFound.isEmpty
    }

    var report: String {
        """
        WER: \(wordErrorRate)
        Missing speaker turns: \(missingSpeakerTurns)
        Missing summary facts: \(missingSummaryFacts)
        Forbidden claims: \(forbiddenClaimsFound)
        Missing action items: \(missingActionItems)
        Missing note facts: \(missingNoteFacts)
        """
    }
}

private enum GoldenSampleEvaluator {
    struct Thresholds {
        static let `default` = Thresholds(
            maximumWordErrorRate: 0.12,
            minimumSummaryFactCoverage: 1,
            minimumActionItemCoverage: 1,
            minimumSpeakerTurnCoverage: 1,
            minimumNoteFactCoverage: 1
        )

        var maximumWordErrorRate: Double
        var minimumSummaryFactCoverage: Double
        var minimumActionItemCoverage: Double
        var minimumSpeakerTurnCoverage: Double
        var minimumNoteFactCoverage: Double
    }

    static func evaluate(
        candidate: GoldenSampleCandidate,
        against reference: GoldenSampleReference
    ) -> GoldenSampleResult {
        let parsedSummary = SummaryParser.parse(candidate.summaryMarkdown)
        let missingSummaryFacts = missingFacts(
            reference.requiredSummaryFacts,
            in: parsedSummary.summary
        )
        let forbiddenClaimsFound = reference.forbiddenClaims
            .filter { containsAllTerms($0.terms, in: parsedSummary.summary) }
            .map(\.id)
        let missingActionItems = missingActions(
            reference.requiredActionItems,
            in: parsedSummary.actionItems
        )
        let missingSpeakerTurns = missingSpeakerTurns(
            reference.expectedSpeakerTurns,
            in: candidate.speakerTurns
        )
        let missingNoteFacts = missingFacts(
            reference.requiredNoteFacts,
            in: candidate.noteMarkdown
        )

        return GoldenSampleResult(
            wordErrorRate: wordErrorRate(
                candidate: candidate.transcript,
                reference: reference.referenceTranscript
            ),
            missingSpeakerTurns: missingSpeakerTurns,
            missingSummaryFacts: missingSummaryFacts,
            forbiddenClaimsFound: forbiddenClaimsFound,
            missingActionItems: missingActionItems,
            missingNoteFacts: missingNoteFacts,
            summaryFactCoverage: coverage(total: reference.requiredSummaryFacts.count, missing: missingSummaryFacts.count),
            actionItemCoverage: coverage(total: reference.requiredActionItems.count, missing: missingActionItems.count),
            speakerTurnCoverage: coverage(total: reference.expectedSpeakerTurns.count, missing: missingSpeakerTurns.count),
            noteFactCoverage: coverage(total: reference.requiredNoteFacts.count, missing: missingNoteFacts.count)
        )
    }

    static func wordErrorRate(candidate: String, reference: String) -> Double {
        let candidateTokens = tokens(candidate)
        let referenceTokens = tokens(reference)
        guard !referenceTokens.isEmpty else { return candidateTokens.isEmpty ? 0 : 1 }

        var previous = Array(0...candidateTokens.count)
        for (referenceIndex, referenceToken) in referenceTokens.enumerated() {
            var current = [referenceIndex + 1] + Array(repeating: 0, count: candidateTokens.count)
            for (candidateIndex, candidateToken) in candidateTokens.enumerated() {
                if referenceToken == candidateToken {
                    current[candidateIndex + 1] = previous[candidateIndex]
                } else {
                    current[candidateIndex + 1] = min(
                        previous[candidateIndex + 1] + 1,
                        current[candidateIndex] + 1,
                        previous[candidateIndex] + 1
                    )
                }
            }
            previous = current
        }

        return Double(previous[candidateTokens.count]) / Double(referenceTokens.count)
    }

    private static func missingFacts(_ facts: [RequiredFact], in text: String) -> [String] {
        facts
            .filter { !containsAllTerms($0.requiredTerms, in: text) }
            .map(\.id)
    }

    private static func missingActions(
        _ required: [RequiredActionItem],
        in actionItems: [ActionItem]
    ) -> [String] {
        required
            .filter { expected in
                !actionItems.contains { actual in
                    actual.actor?.localizedCaseInsensitiveCompare(expected.actor) == .orderedSame
                        && containsAllTerms(expected.requiredTerms, in: actual.text)
                }
            }
            .map(\.id)
    }

    private static func missingSpeakerTurns(
        _ expected: [ExpectedSpeakerTurn],
        in turns: [CandidateSpeakerTurn]
    ) -> [String] {
        expected
            .filter { expectedTurn in
                !turns.contains { actual in
                    actual.speakerName.localizedCaseInsensitiveCompare(expectedTurn.speakerName) == .orderedSame
                        && containsAllTerms(tokens(expectedTurn.requiredPhrase), in: actual.text)
                }
            }
            .map { "\($0.speakerName): \($0.requiredPhrase)" }
    }

    private static func containsAllTerms(_ terms: [String], in text: String) -> Bool {
        let haystack = Set(tokens(text))
        return terms.allSatisfy { term in
            tokens(term).allSatisfy { haystack.contains($0) }
        }
    }

    private static func coverage(total: Int, missing: Int) -> Double {
        guard total > 0 else { return 1 }
        return Double(total - missing) / Double(total)
    }

    private static func tokens(_ text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
