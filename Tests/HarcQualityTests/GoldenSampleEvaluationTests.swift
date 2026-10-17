import Foundation
import Testing
import XCTest
import HarcCore
import HarcSTT
import HarcSummarize
import CryptoKit
import FluidAudio

@Suite("Golden sample quality evaluation")
struct GoldenSampleEvaluationTests {
    @Test("unparsed action text cannot pass through otherwise complete output")
    func malformedActionTextFailsQualityGate() {
        var candidate = GoldenSample.customerRenewalCompleteCandidate
        candidate.summaryMarkdown += "\nAnother action line without the required checkbox."
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: GoldenSample.customerRenewal)
        #expect(result.summaryParseWarning)
        #expect(!result.passed)
        #expect(result.missingActionItems.isEmpty)
    }

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
        #expect(result.claimReviewConcerns.isEmpty)
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
        #expect(result.claimReviewConcerns.contains { $0.claimID == "discount approved" })
        #expect(result.missingSummaryFacts.contains("legal-review"))
        #expect(result.missingActionItems.contains("Jason: send renewal plan"))
        #expect(result.missingNoteFacts.contains("Friday deadline"))
    }

    @Test("a request does not establish a follow-up owner", arguments: ["Amy", "Michelle", "Someone"])
    func unsupportedFollowUpOwnerFails(actor: String) {
        var candidate = GoldenSample.customerRenewalCompleteCandidate
        candidate.summaryMarkdown += "\n- [ ] \(actor): capture the customer renewal follow-up note for Michelle"
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: GoldenSample.customerRenewal)
        #expect(!result.passed)
        #expect(result.missingActionItems.isEmpty)
        #expect(result.unexpectedActionItems.count == 1)
    }

    @Test("correct task ownership cannot hide an omitted current status")
    func missingStatusFailsDespiteCorrectAction() {
        var candidate = GoldenSample.customerRenewalCompleteCandidate
        // Reproduces the omission in the 2026-09-06 local Gemma candidate:
        // the open risk survives, but the positive status disappears.
        candidate.summaryMarkdown = candidate.summaryMarkdown.replacingOccurrences(
            of: "The customer renewal is healthy, but pricing risk is still open.",
            with: "Pricing risk is still open for the customer renewal."
        )
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: GoldenSample.customerRenewal)
        #expect(result.missingActionItems.isEmpty)
        #expect(result.unexpectedActionItems.isEmpty)
        #expect(!result.summaryParseWarning)
        #expect(result.missingSummaryFacts == ["healthy-renewal"])
        #expect(!result.passed)
    }

    @Test("a discount prohibition is not a new commitment by its speaker")
    func prohibitionDoesNotBecomeAssignedAction() {
        var candidate = GoldenSample.customerRenewalCompleteCandidate
        candidate.summaryMarkdown += "\n- [ ] Priya: do not approve the discount until legal finishes review"
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: GoldenSample.customerRenewal)
        #expect(!result.passed)
        #expect(result.unexpectedActionItems.count == 1)
    }

    @Test("an explicit deadline can be represented in the structured due field")
    func structuredDeadlineIsPreserved() {
        var candidate = GoldenSample.customerRenewalCompleteCandidate
        candidate.summaryMarkdown = candidate.summaryMarkdown.replacingOccurrences(
            of: "Jason: send the renewal plan by Friday", with: "Jason: send the renewal plan (due Friday)"
        )
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: GoldenSample.customerRenewal)
        #expect(result.passed)
    }

    @Test("recorded local model output fails unsupported-commitment checks")
    func recordedSummaryDoesNotQualifyInventedOwners() {
        var candidate = GoldenSample.customerRenewalCompleteCandidate
        // Replay of the retained 2026-09-05 Qwen synthetic-fixture output.
        // This is a scorer regression, not a new model invocation.
        candidate.summaryMarkdown = """
        ## Summary
        The meeting addressed the status of a healthy customer renewal while noting that pricing risks remain unresolved. Jason committed to delivering a renewal plan by Friday, which will include a new tiering page. Priya emphasized that no discounts should be approved until legal completes its review. Additionally, Amy tasked with documenting a follow-up note for Michelle and tagging it as a customer renewal.

        ## Action Items
        - [ ] Jason: Send the renewal plan by Friday (includes the new tiering page).
        - [ ] Priya: Do not approve the discount until legal finishes the review.
        - [ ] Amy: Capture the follow-up note for Michelle and tag it customer renewal.
        """
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: GoldenSample.customerRenewal)
        #expect(!result.passed)
        #expect(result.unexpectedActionItems.count == 2)
        #expect(result.unexpectedActionItems.contains { $0.hasPrefix("Amy:") })
        #expect(result.unexpectedActionItems.contains { $0.hasPrefix("Priya:") })
    }

    @Test("conditional and negated approval mentions require review without asserting a contradiction", arguments: [
        "Legal must complete their review before any discount is approved.",
        "The discount is not approved.",
        "The discount is approved."
    ])
    func approvalMentionsRetainEvidenceForReview(statement: String) {
        var candidate = GoldenSample.customerRenewalCompleteCandidate
        candidate.summaryMarkdown = candidate.summaryMarkdown.replacingOccurrences(
            of: "## Action Items", with: statement + "\n\n## Action Items"
        )
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: GoldenSample.customerRenewal)
        #expect(!result.passed)
        #expect(result.missingActionItems.isEmpty)
        #expect(result.unexpectedActionItems.isEmpty)
        let concern = result.claimReviewConcerns.first { $0.claimID == "discount approved" }
        #expect(concern?.summaryText.contains(statement) == true)
        #expect(result.report.contains("not established contradictions"))
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

/// Test-only capture of synthetic evaluation output. No production transcript
/// logging or changes to generation parameters are introduced by this wrapper.
private actor RawSummaryCapture {
    private var output: [String] = []

    func record(_ value: String) { output.append(value) }

    func take() -> String? {
        defer { output = [] }
        return output.isEmpty ? nil : output.enumerated().map { "PASS \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
    }
}

private struct CapturingSummaryContainer: ContainerLike {
    let base: any ContainerLike
    let capture: RawSummaryCapture

    func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int,
        onStats: (@Sendable (GenerationStats) -> Void)?
    ) async throws -> String {
        let raw = try await base.generate(
            promptBody: promptBody, systemPrompt: systemPrompt,
            maxTokens: maxTokens, onStats: onStats
        )
        await capture.record(raw)
        return raw
    }

    func generateSummary(
        promptBody: String,
        maxTokens: Int,
        onStats: (@Sendable (GenerationStats) -> Void)?
    ) async throws -> String {
        let raw = try await base.generateSummary(
            promptBody: promptBody, maxTokens: maxTokens, onStats: onStats
        )
        await capture.record(raw)
        return raw
    }
}

final class RealModelGoldenSampleTests: XCTestCase {
    func test_inspectVADBoundaries_forLocalFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["HARC_VAD_PROBE_AUDIO"] else {
            throw XCTSkip("Set HARC_VAD_PROBE_AUDIO for the boundary diagnostic.")
        }
        let audio = URL(fileURLWithPath: path)
        let samples = try AudioConverter().resampleAudioFile(audio)
        let manager = try await VadManager()
        struct Boundary: Encodable { let start: Double; let end: Double }
        struct Probe: Encodable {
            let id: String
            let padding: Double
            let maxSpeech: Double
            let originalSamples: Int
            let compactSamples: Int
            let boundaries: [Boundary]
        }
        var probes: [Probe] = []
        for (id, padding, maximum) in [("default", 0.1, 14.0), ("padding-300ms", 0.3, 14.0), ("long-segment", 0.3, 60.0)] {
            var config = VadSegmentationConfig.default
            config.speechPadding = padding
            config.maxSpeechDuration = maximum
            let segments = try await manager.segmentSpeech(samples, config: config)
            let compact = VoicedStitcher.stitch(samples: samples, segments: segments)
            XCTAssertFalse(segments.isEmpty)
            let output = audio.deletingLastPathComponent().appendingPathComponent("vad-\(id).f32")
            try compact.compactSamples.withUnsafeBytes { try Data($0).write(to: output, options: .atomic) }
            probes.append(Probe(id: id, padding: padding, maxSpeech: maximum,
                originalSamples: samples.count, compactSamples: compact.compactSamples.count,
                boundaries: segments.map { Boundary(start: $0.startTime, end: $0.endTime) }))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(probes).write(to: audio.deletingLastPathComponent().appendingPathComponent("vad-boundaries.json"), options: .atomic)
    }

    func test_localCorpus_reportsPerCaseAccuracyTimingAndCompleteness() async throws {
        guard let path = ProcessInfo.processInfo.environment["HARC_STT_CORPUS"] else {
            throw XCTSkip("Set HARC_STT_CORPUS to an explicit local corpus manifest.")
        }
        struct Entry: Decodable {
            let id: String
            let audio: String
            let reference: String
            let maximumWER: Double
            let vad: Bool
            let durationSeconds: Double
            let sha256: String
        }
        struct Corpus: Decodable { let classification: String; let cases: [Entry] }
        struct Measurement: Encodable {
            let id: String
            let engine: String
            let reference: String
            let result: TranscribeResult
            let wordErrorRate: Double
            let maximumWER: Double
            let seconds: Double
            let realtimeFactor: Double
            let durationSeconds: Double
            let vadRequested: Bool
        }
        let manifest = URL(fileURLWithPath: path)
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: manifest))
        XCTAssertFalse(corpus.cases.isEmpty)
        XCTAssertEqual(Set(corpus.cases.map(\.id)).count, corpus.cases.count)
        for entry in corpus.cases {
            guard entry.maximumWER.isFinite, (0...1).contains(entry.maximumWER),
                  entry.durationSeconds.isFinite, entry.durationSeconds > 0,
                  !entry.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                XCTFail("Invalid corpus entry: \(entry.id)")
                return
            }
            let audio = try Data(contentsOf: URL(fileURLWithPath: entry.audio))
            let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, entry.sha256, "Fixture changed: \(entry.id)")
            guard digest == entry.sha256 else { return }
        }
        let engineName = ProcessInfo.processInfo.environment["HARC_STT_CORPUS_ENGINE"] ?? "v2"
        let engine = try XCTUnwrap(Transcriber.ASREngine(rawValue: engineName),
            "Unknown corpus engine: \(engineName)")
        let transcriber = Transcriber(engine: engine)
        let loadStart = Date()
        try await transcriber.loadModels()
        print("CORPUS engine=\(engineName); modelLoadSeconds=\(Date().timeIntervalSince(loadStart)); classification=\(corpus.classification)")
        var measurements: [Measurement] = []
        for entry in corpus.cases {
            let start = Date()
            let result = try await transcriber.transcribe(audioPath: entry.audio, vad: entry.vad)
            let elapsed = Date().timeIntervalSince(start)
            let wer = GoldenSampleEvaluator.wordErrorRate(candidate: result.text, reference: entry.reference)
            measurements.append(Measurement(id: entry.id, engine: engineName, reference: entry.reference, result: result,
                wordErrorRate: wer, maximumWER: entry.maximumWER, seconds: elapsed,
                realtimeFactor: elapsed / entry.durationSeconds, durationSeconds: entry.durationSeconds,
                vadRequested: entry.vad))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(measurements).write(to: manifest.deletingLastPathComponent().appendingPathComponent("results.json"), options: .atomic)
            print("CORPUS \(entry.id): WER=\(wer) limit=\(entry.maximumWER) seconds=\(elapsed) RTF=\(elapsed / entry.durationSeconds) text=\(result.text)")
            XCTAssertLessThanOrEqual(wer, entry.maximumWER, entry.id)
            XCTAssertFalse(result.words.isEmpty, "Missing timings: \(entry.id)")
            XCTAssertTrue(result.words.allSatisfy { $0.startMs >= 0 && $0.endMs >= $0.startMs && Double($0.endMs) <= entry.durationSeconds * 1000 + 1000 }, "Invalid/out-of-range timings: \(entry.id)")
            let suffix = entry.reference.lowercased().split { !$0.isLetter && !$0.isNumber }.suffix(4)
            let actual = result.text.lowercased().split { !$0.isLetter && !$0.isNumber }.suffix(4)
            XCTAssertEqual(Array(actual), Array(suffix), "Missing or incorrect final phrase: \(entry.id)")
        }
    }

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARC_INTEGRATION_TESTS"] == "1",
            "Set HARC_INTEGRATION_TESTS=1 to run real STT/summarizer golden quality gates."
        )
    }

    func test_realSummarizerOutput_passesCustomerRenewalGoldenSample() async throws {
        let modelID = ProcessInfo.processInfo.environment["HARC_SUMMARY_MODEL_ID"] ?? "gemma-4-e2b-it-4bit"
        let modelDir = try summarizerModelDirectory(modelID: modelID)
        let capture = RawSummaryCapture()
        let service = SummarizerService(loader: { directory in
            CapturingSummaryContainer(base: try await SummarizerService.defaultLoader(directory), capture: capture)
        })
        let reference = GoldenSample.customerRenewal
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Amy", text: "The customer renewal is healthy, but pricing risk is still open."),
            .init(speaker: "Jason", text: "I will send the renewal plan by Friday and include the new tiering page."),
            .init(speaker: "Priya", text: "Do not approve the discount until legal finishes review."),
            .init(speaker: "Amy", text: "Capture the follow up note for Michelle and tag it customer renewal."),
        ])

        let generated = try await service.summarize(
            transcript: transcript,
            modelID: modelID,
            modelDirectory: modelDir,
            budgetWords: SummaryPrompt.budgetWords(contextTokens: 32_000)
        )
        let captured = await capture.take()
        let rawResponses = try XCTUnwrap(captured, "The real model responses were not captured")
        print("Raw model passes:\n\(rawResponses)")
        // Score the service result delivered to the app, retaining every raw
        // pass above. The final facts-only pass is not the complete result.
        let actions = generated.actionItems.map { item in
            "- [ ] \(item.actor ?? "Unassigned"): \(item.text)" + (item.due.map { " (due: \($0))" } ?? "")
        }.joined(separator: "\n")
        let summaryMarkdown = "## Summary\n\(generated.summary)\n## Action Items\n" +
            (actions.isEmpty ? "- None identified." : actions)
        XCTAssertFalse(generated.parseWarning, "Malformed model response: \(rawResponses)")
        let candidate = GoldenSampleCandidate(
            transcript: reference.referenceTranscript,
            speakerTurns: reference.expectedSpeakerTurns.map {
                CandidateSpeakerTurn(speakerName: $0.speakerName, text: $0.requiredPhrase)
            },
            summaryMarkdown: summaryMarkdown,
            noteMarkdown: summaryMarkdown
        )
        let result = GoldenSampleEvaluator.evaluate(candidate: candidate, against: reference)
        print("Real summary diagnostic: model=\(modelID), directory=\(modelDir.path)\n\(result.report)\nGenerated:\n\(summaryMarkdown)")

        XCTAssertTrue(
            result.passed,
            "Real summarizer output failed golden quality gates.\n\(result.report)\nGenerated:\n\(summaryMarkdown)"
        )
    }

    /// Synthetic contrast cases isolate action attribution. Passing these is
    /// not a general summary-quality or real-recording qualification.
    func test_realSummarizerActionAttribution_contrastSet() async throws {
        let modelID = ProcessInfo.processInfo.environment["HARC_SUMMARY_MODEL_ID"] ?? "gemma-4-e2b-it-4bit"
        let modelDir = try summarizerModelDirectory(modelID: modelID)
        let capture = RawSummaryCapture()
        let service = SummarizerService(loader: { directory in
            CapturingSummaryContainer(base: try await SummarizerService.defaultLoader(directory), capture: capture)
        })
        let cases: [(id: String, utterances: [PromptTranscript.Utterance], actors: [String])] = [
            ("unaccepted-request", [
                .init(speaker: "Lina", text: "Marcus, please send the inventory report on Friday."),
                .init(speaker: "Marcus", text: "I need to check my workload before I can answer.")
            ], []),
            ("accepted-request", [
                .init(speaker: "Lina", text: "Marcus, please send the inventory report on Friday."),
                .init(speaker: "Marcus", text: "Yes, I will send the inventory report on Friday.")
            ], ["Marcus"]),
            ("conditional-possibility", [
                .init(speaker: "Nia", text: "If legal approves the proposal, I could prepare a launch plan. I am not committing to that work yet."),
                .init(speaker: "Owen", text: "Ownership of the work is still undecided.")
            ], []),
            ("declined-task", [
                .init(speaker: "Theo", text: "I cannot take on the audit this week."),
                .init(speaker: "Uma", text: "No one has volunteered for the audit. It remains unassigned.")
            ], []),
            ("changed-owner", [
                .init(speaker: "Hana", text: "I was going to send the invoice, but I will not be doing it after all."),
                .init(speaker: "Jules", text: "I will send the invoice on Monday instead.")
            ], ["Jules"]),
            ("cancelled-quoted-commitment", [
                .init(speaker: "Bea", text: "Ari said yesterday, I will book the venue. That event has now been cancelled and the booking is no longer needed."),
                .init(speaker: "Ari", text: "Correct. I will not book a venue.")
            ], []),
            ("accepted-short-reply", [
                .init(speaker: "Rosa", text: "Eli, could you update the rota by Tuesday?"),
                .init(speaker: "Eli", text: "Yes, I'll do that by Tuesday.")
            ], ["Eli"]),
            ("completed-work", [
                .init(speaker: "Marta", text: "I sent the signed contract yesterday. The task is complete."),
                .init(speaker: "Neil", text: "Thanks. Nothing else is needed.")
            ], []),
            ("mixed-future", [
                .init(speaker: "Ravi", text: "I'll update the deployment checklist tomorrow. I will not deploy the service; that is still unassigned.")
            ], ["Ravi"]),
            ("two-owners", [
                .init(speaker: "Noor", text: "I will review the invoice on Thursday."),
                .init(speaker: "Felix", text: "I will send the receipt after Noor reviews the invoice.")
            ], ["Noor", "Felix"]),
            ("conditional-commitment", [
                .init(speaker: "Dara", text: "If finance approves the budget, I will order the replacement equipment.")
            ], ["Dara"]),
            ("revoked-same-speaker", [
                .init(speaker: "Tess", text: "I will organize the workshop."),
                .init(speaker: "Tess", text: "Correction: I cannot organize it. The workshop is cancelled; no preparation is needed.")
            ], []),
            ("fictional-quote", [
                .init(speaker: "Omar", text: "Our training example reads: I will reset the server. That is fictional dialogue, not a task for anyone here.")
            ], []),
            ("request-no-response", [
                .init(speaker: "Leah", text: "Please send the slides to the team by Monday.")
            ], []),
            ("fresh-individual-refusal", [
                .init(speaker: "Alex", text: "I will not restart the database. Morgan will decide who handles that."),
                .init(speaker: "Morgan", text: "I have not chosen anyone yet.")
            ], []),
            ("fresh-distinct-reasons", [
                .init(speaker: "Parker", text: "I cannot attend the inspection."),
                .init(speaker: "Rowan", text: "The replacement inspector is still undecided.")
            ], []),
            ("fresh-no-receipt", [
                .init(speaker: "Sky", text: "I mailed the permit yesterday."),
                .init(speaker: "Lee", text: "Thanks. I will check the mailbox tomorrow.")
            ], ["Lee"]),
            ("fresh-withdraw-and-replace", [
                .init(speaker: "Jordan", text: "I promised to reserve the restaurant, but that dinner is cancelled. I will not reserve it. I will email the cancellation notice tonight.")
            ], ["Jordan"]),
            ("fresh-quoted-source", [
                .init(speaker: "Cameron", text: "Yesterday Reese said the grant was approved. I have not verified that report."),
                .init(speaker: "Reese", text: "I will check the grant portal on Monday.")
            ], ["Reese"]),
            ("fresh-valid-negative-work", [
                .init(speaker: "Drew", text: "I will remove the obsolete accounts on Friday, but I will not delete the audit records.")
            ], ["Drew"]),
            ("fresh-explicit-cause", [
                .init(speaker: "Quinn", text: "I cannot send the package today because the road is closed. I will send it tomorrow if the road reopens.")
            ], ["Quinn"]),
            ("fresh-completed-then-request", [
                .init(speaker: "Avery", text: "I completed the access review on Tuesday. Bailey, please file the report."),
                .init(speaker: "Bailey", text: "I have not agreed to that yet.")
            ], [])
        ]
        // Actor/count checks alone can pass while the task or its condition
        // changes. These lexical checks protect specific obligations in this
        // synthetic set; they do not establish general factual correctness.
        let requiredActionTerms: [String: [String: [String]]] = [
            "accepted-request": ["marcus": ["inventory", "report", "friday"]],
            "changed-owner": ["jules": ["invoice", "monday"]],
            "accepted-short-reply": ["eli": ["rota", "tuesday"]],
            "mixed-future": ["ravi": ["checklist", "tomorrow"]],
            "two-owners": ["noor": ["invoice", "thursday"], "felix": ["receipt", "after", "noor"]],
            "conditional-commitment": ["dara": ["equipment", "finance", "approv"]],
            "fresh-no-receipt": ["lee": ["mailbox", "tomorrow"]],
            "fresh-withdraw-and-replace": ["jordan": ["cancellation", "notice", "tonight"]],
            "fresh-quoted-source": ["reese": ["grant", "portal", "monday"]],
            "fresh-valid-negative-work": ["drew": ["obsolete", "accounts", "friday"]],
            "fresh-explicit-cause": ["quinn": ["package", "tomorrow", "road", "reopen"]],
        ]
        for sample in cases {
            let output = try await service.summarize(
                transcript: PromptTranscript(utterances: sample.utterances),
                modelID: modelID, modelDirectory: modelDir,
                budgetWords: SummaryPrompt.budgetWords(contextTokens: 32_000)
            )
            let actual = output.actionItems.map { ($0.actor ?? "Unassigned").lowercased() }.sorted()
            let expected = sample.actors.map { $0.lowercased() }.sorted()
            let captured = await capture.take()
            let raw = try XCTUnwrap(captured, "Missing raw response: \(sample.id)")
            print("ATTRIBUTION \(sample.id) model=\(modelID) expected=\(expected) actual=\(actual) parseWarning=\(output.parseWarning)\nRAW RESPONSE:\n\(raw)")
            XCTAssertFalse(output.parseWarning, "Malformed model response: \(sample.id)\n\(raw)")
            XCTAssertEqual(actual, expected, "Action ownership mismatch: \(sample.id)")
            for (actor, terms) in requiredActionTerms[sample.id] ?? [:] {
                let task = output.actionItems
                    .filter { $0.actor?.lowercased() == actor }
                    .map { ($0.text + " " + ($0.due ?? "")).lowercased() }
                    .joined(separator: " ")
                for term in terms {
                    XCTAssertTrue(task.contains(term),
                                  "Missing task/condition evidence '\(term)' for \(actor): \(sample.id)\n\(raw)")
                }
            }
        }
        await service.unload(reason: "quality-evaluation-complete")
    }

    func test_realSTTOutput_isScoredAgainstShortSpeechReference() async throws {
        let fixture = try shortSpeechFixtureURL()
        // Full eight-word fixture reference, also recorded in docs/dictation-plan.md.
        // This short diagnostic allows at most one word error. It does not stand
        // in for the diverse, long-form production evaluation corpus.
        let reference = ProcessInfo.processInfo.environment["HARC_STT_GOLDEN_REFERENCE"]
            ?? "Hello. This is a test recording for HARC."
        let thresholdText = ProcessInfo.processInfo.environment["HARC_STT_MAX_WER"] ?? "0.125"
        let maximumWER = try XCTUnwrap(Double(thresholdText), "Invalid HARC_STT_MAX_WER")
        XCTAssertTrue(maximumWER.isFinite && maximumWER >= 0 && maximumWER <= 1)
        XCTAssertFalse(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let transcriber = Transcriber()
        try await transcriber.loadModels()
        let result = try await transcriber.transcribe(audioPath: fixture.path, vad: false)
        let wer = GoldenSampleEvaluator.wordErrorRate(candidate: result.text, reference: reference)
        print("Real STT diagnostic: reference=\(reference), candidate=\(result.text), wer=\(wer), maximumWER=\(maximumWER), timingEntries=\(result.words.count)")

        XCTAssertLessThanOrEqual(
            wer,
            maximumWER,
            "Real STT output exceeded WER threshold. reference=\(reference), candidate=\(result.text), wer=\(wer)"
        )
        XCTAssertFalse(result.words.isEmpty, "Real STT output should include word timings.")
    }

    private func summarizerModelDirectory(modelID: String) throws -> URL {
        guard modelID.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$", options: .regularExpression) != nil else {
            throw NSError(domain: "HarcQualityTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid local model identifier"])
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let modelDir = appSupport
            .appendingPathComponent("Harc", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)

        // Once explicitly enabled, an incomplete installation must fail the
        // quality gate rather than turn into a successful skipped run.
        let files = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        guard files.contains(where: { $0.lastPathComponent == "config.json" }),
              files.contains(where: { $0.lastPathComponent == "tokenizer.json" }),
              files.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw NSError(domain: "HarcQualityTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Incomplete local model: \(modelDir.path)"])
        }
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

// This evaluator detects token co-occurrence, not semantic entailment. Retain
// the actual text so a reviewer can distinguish assertions from conditions or
// negations. Every unresolved concern blocks automatic qualification.
private struct ClaimReviewConcern {
    var claimID: String
    var summaryText: String

    var report: String { "Review \(claimID): \(summaryText)" }
}

private struct GoldenSampleResult {
    var summaryParseWarning: Bool
    var wordErrorRate: Double
    var missingSpeakerTurns: [String]
    var missingSummaryFacts: [String]
    var claimReviewConcerns: [ClaimReviewConcern]
    var missingActionItems: [String]
    var unexpectedActionItems: [String]
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
            && claimReviewConcerns.isEmpty
            && unexpectedActionItems.isEmpty
            && !summaryParseWarning
    }

    var report: String {
        """
        WER: \(wordErrorRate)
        Summary parse warning: \(summaryParseWarning)
        Missing speaker turns: \(missingSpeakerTurns)
        Missing summary facts: \(missingSummaryFacts)
        Claims requiring manual review (lexical matches, not established contradictions): \(claimReviewConcerns.map(\.report))
        Missing action items: \(missingActionItems)
        Unexpected action items: \(unexpectedActionItems)
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
        let claimReviewConcerns = reference.forbiddenClaims
            .filter { containsAllTerms($0.terms, in: parsedSummary.summary) }
            .map { ClaimReviewConcern(claimID: $0.id, summaryText: parsedSummary.summary) }
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
            summaryParseWarning: parsedSummary.parseWarning,
            wordErrorRate: wordErrorRate(
                candidate: candidate.transcript,
                reference: reference.referenceTranscript
            ),
            missingSpeakerTurns: missingSpeakerTurns,
            missingSummaryFacts: missingSummaryFacts,
            claimReviewConcerns: claimReviewConcerns,
            missingActionItems: missingActionItems,
            unexpectedActionItems: parsedSummary.actionItems.filter { actual in
                !reference.requiredActionItems.contains { matchesAction(actual, expected: $0) }
            }.map { "\($0.actor ?? "Unassigned"): \($0.text)" },
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
                    matchesAction(actual, expected: expected)
                }
            }
            .map(\.id)
    }

    private static func matchesAction(_ actual: ActionItem, expected: RequiredActionItem) -> Bool {
        actual.actor?.localizedCaseInsensitiveCompare(expected.actor) == .orderedSame
            && containsAllTerms(expected.requiredTerms, in: actual.text + " " + (actual.due ?? ""))
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
