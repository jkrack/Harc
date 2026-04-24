import XCTest
@testable import HarcSummarize
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Pre-Stage-2 spike: confirm mlx-swift-lm 3.31.3 loads the Harc-downloaded
/// Gemma 4 E2B directory and can generate against it end-to-end.
///
/// Gated behind `HARC_INTEGRATION_TESTS=1` because it requires:
/// - the real ~3.6 GB model on disk at
///   `~/Library/Application Support/Harc/Models/gemma-4-e2b-it-4bit/`
/// - ~30–60 s of wall-clock to load + generate
///
/// Run with:
///   HARC_INTEGRATION_TESTS=1 swift test --filter MLXLoadVerifyTests
final class MLXLoadVerifyTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARC_INTEGRATION_TESTS"] == "1",
            "Set HARC_INTEGRATION_TESTS=1 to run the MLX load verification."
        )
    }

    func test_loadGemma4E2B_fromLocalDirectory_generatesNonEmptyOutput() async throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
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
            fm.fileExists(atPath: modelDir.path),
            "Gemma 4 E2B not installed at \(modelDir.path). Download it via Harc Settings → Models first."
        )

        // The entire point of this test: load via the factory from a local
        // directory, no network fallback, no HuggingFace download.
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: #huggingFaceTokenizerLoader()
        )

        // Build a trivially-small chat prompt. If the tokenizer + chat
        // template are wired correctly the container should accept it.
        // mlx-swift-lm 3.x takes raw message dicts here, not Chat.Message.
        let userInput = UserInput(
            messages: [
                ["role": "user", "content": "Say hello."]
            ]
        )
        let lmInput = try await container.prepare(input: userInput)

        var params = GenerateParameters()
        params.maxTokens = 50

        let stream = try await container.generate(input: lmInput, parameters: params)

        var text = ""
        var sawInfo = false
        for await generation in stream {
            switch generation {
            case .chunk(let fragment):
                text += fragment
            case .info:
                sawInfo = true
            case .toolCall:
                break
            }
        }

        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Generation produced no text."
        )
        XCTAssertTrue(sawInfo, "Stream should yield a final .info payload.")
        print("MLX load-verify output (\(text.count) chars): \(text)")
    }

    func test_summarizerService_endToEnd_producesParsedSummary() async throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
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
            fm.fileExists(atPath: modelDir.path),
            "Gemma 4 E2B not installed at \(modelDir.path). Download it via Harc Settings → Models first."
        )

        let service = SummarizerService(loader: SummarizerService.defaultLoader)
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "Let's lock rollout for Friday."),
            .init(speaker: "Amy", text: "I'll send the comms email on Thursday."),
        ])

        let result = try await service.summarize(
            transcript: transcript,
            modelID: "gemma-4-e2b-it-4bit",
            modelDirectory: modelDir,
            budgetWords: SummaryPrompt.budgetWords(contextTokens: 32_000)
        )

        XCTAssertFalse(
            result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Summary must be non-empty."
        )
        // We can't pin specific action items (the model's output varies
        // across runs), but we can insist on SOMETHING structured —
        // either a non-empty list or an explicit "_None identified._"
        // that the parser turned into an empty array. Both are fine.
        XCTAssertFalse(result.parseWarning,
            "Well-installed model + correct prompt should not raise parseWarning; raw=\(result.summary)")
        print("SummarizerService.summarize result — summary (\(result.summary.count) chars), \(result.actionItems.count) action items")
    }
}
