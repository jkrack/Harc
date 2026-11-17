import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Abstraction over the mlx-swift-lm `ModelContainer` used by
/// `SummarizerService`. Production code uses `MLXModelContainer` (see
/// below) which wraps `MLXLMCommon.ModelContainer`. Unit tests pass a
/// stub implementation so we can cover state-machine behaviour without
/// compiling a Metal library or loading multi-GB weights.
public protocol ContainerLike: Sendable {
    /// Render the prompt through the model's chat template, generate
    /// up to `maxTokens` tokens, and return the aggregated string.
    /// `systemPrompt` is optional — when non-nil it's rendered as a
    /// `{role: "system"}` message ahead of the user turn.
    /// `onStats` (optional) receives interim throughput snapshots during
    /// generation and one final snapshot with authoritative numbers.
    func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int,
        onStats: (@Sendable (GenerationStats) -> Void)?
    ) async throws -> String
    /// Fail-closed evidence capability; implementations must prepare once and
    /// enforce the full templated token budget before starting generation.
    func generateEvidence(promptBody: String, budget: EvidenceGenerationBudget) async throws -> String
    /// Separate trusted policy from selected-source data. Unsupported by default;
    /// implementations must not concatenate roles or silently fall back.
    func generateEvidence(systemPrompt: String, sourceJSON: String,
                          budget: EvidenceGenerationBudget) async throws -> String

    func generateSummary(promptBody: String, maxTokens: Int,
                         onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String

}

public extension ContainerLike {
    func generateEvidence(systemPrompt: String, sourceJSON: String,
                          budget: EvidenceGenerationBudget) async throws -> String {
        throw EvidenceGenerationError.unsupported
    }

    func generateEvidence(promptBody: String, budget: EvidenceGenerationBudget) async throws -> String {
        throw EvidenceGenerationError.unsupported
    }

    func generateSummary(promptBody: String, maxTokens: Int,
                         onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        try await generate(promptBody: promptBody, systemPrompt: nil, maxTokens: maxTokens, onStats: onStats)
    }

    /// Convenience for call sites that don't observe throughput.
    func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String {
        try await generate(
            promptBody: promptBody,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            onStats: nil
        )
    }
}

/// Production `ContainerLike` backed by `MLXLMCommon.ModelContainer`.
/// Thin wrapper: builds `UserInput` from the prompt body (+ optional
/// system message), prepares, generates, and aggregates `Generation`
/// chunks into one string.
public struct MLXModelContainer: ContainerLike {
    private let container: ModelContainer
    private let evidenceObserver: (@Sendable (Int, Int, String) -> Void)?

    public init(container: ModelContainer) {
        self.container = container
        self.evidenceObserver = nil
    }

    // Internal diagnostic observer: numeric completion metadata only, no text.
    init(container: ModelContainer, evidenceObserver: @escaping @Sendable (Int, Int, String) -> Void) {
        self.container = container
        self.evidenceObserver = evidenceObserver
    }

    public func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int,
        onStats: (@Sendable (GenerationStats) -> Void)?
    ) async throws -> String {
        try await generateConfigured(promptBody: promptBody, systemPrompt: systemPrompt,
            maxTokens: maxTokens, onStats: onStats, temperature: 0.6)
    }

    public func generateSummary(promptBody: String, maxTokens: Int,
                                onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        try await generateConfigured(promptBody: promptBody, systemPrompt: nil,
            maxTokens: maxTokens, onStats: onStats, temperature: 0)
    }

    public func generateEvidence(promptBody: String, budget: EvidenceGenerationBudget) async throws -> String {
        try await generateEvidenceMessages(EvidenceRoleMessages.legacy(promptBody), budget: budget)
    }

    public func generateEvidence(systemPrompt: String, sourceJSON: String,
                                 budget: EvidenceGenerationBudget) async throws -> String {
        try await generateEvidenceMessages(EvidenceRoleMessages.separated(systemPrompt: systemPrompt,
            sourceJSON: sourceJSON), budget: budget)
    }

    private func generateEvidenceMessages(_ messages: [[String: String]],
                                          budget: EvidenceGenerationBudget) async throws -> String {
        try Task.checkCancellation()
        // BOTH roles and the template are prepared ONCE and counted together.
        let input = UserInput(messages: messages.map { $0.mapValues { $0 as any Sendable } },
                              additionalContext: ["enable_thinking": false])
        let prepared = try await container.prepare(input: input)
        let promptTokenCount = prepared.text.tokens.size
        try budget.validate(promptTokens: promptTokenCount)
        try Task.checkCancellation()
        var parameters = GenerateParameters()
        parameters.maxTokens = budget.outputReserve
        parameters.temperature = 0
        // Generate the SAME prepared input whose actual templated tokens were counted.
        let configuredParameters = parameters
        let (stream, producer) = try await container.perform(nonSendable: prepared) { context, input in
            let iterator = try TokenIterator(input: input, model: context.model, parameters: configuredParameters)
            return MLXLMCommon.generateTask(promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
        }
        return try await withEvidenceProducerCleanup(producer) {
            var result = EvidenceGenerationCollector()
            for await event in stream {
                try Task.checkCancellation()
                switch event {
                case .chunk(let fragment): try result.append(fragment)
                case .info(let info):
                    evidenceObserver?(promptTokenCount, info.generationTokenCount, String(describing: info.stopReason))
                    switch info.stopReason {
                    case .stop: try result.complete(normally: true)
                    case .length, .cancelled: throw EvidenceGenerationError.invalidCompletion
                    }
                case .toolCall: throw EvidenceGenerationError.invalidCompletion
                }
            }
            try Task.checkCancellation()
            return try result.finish()
        }
    }

    private func generateConfigured(promptBody: String, systemPrompt: String?, maxTokens: Int,
                                    onStats: (@Sendable (GenerationStats) -> Void)?, temperature: Float) async throws -> String {
        // mlx-swift-lm 3.x takes raw message dicts here, not a
        // Chat.Message array. Each dict has "role" + "content".
        var messages: [[String: any Sendable]] = []
        if let systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": promptBody])

        // Current-gen small models (Gemma 4, Qwen 3.5) are reasoning-tuned:
        // their chat templates default to emitting a chain-of-thought channel
        // before the answer. That burns most of the output-token budget on
        // scratch work the parser then chokes on (observed: truncation
        // mid-thought, E2B repetition loops). `enable_thinking` is the
        // conventional template variable to suppress it; templates that
        // don't know the variable ignore it.
        let userInput = UserInput(
            messages: messages,
            additionalContext: ["enable_thinking": false]
        )
        let lmInput = try await container.prepare(input: userInput)

        var params = GenerateParameters()
        params.maxTokens = maxTokens
        params.temperature = temperature

        let stream = try await container.generate(input: lmInput, parameters: params)

        // Interim rate from streamed chunks (one chunk ≈ one token),
        // throttled to every `interimEvery` chunks; the `.info` event at
        // stream end carries the authoritative numbers.
        let started = Date()
        let interimEvery = 10
        var chunkCount = 0

        var result = ""
        var completionObserved = false
        for await generation in stream {
            switch generation {
            case .chunk(let fragment):
                result += fragment
                chunkCount += 1
                if let onStats, chunkCount % interimEvery == 0 {
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 0.5 {
                        onStats(GenerationStats(
                            generatedTokens: chunkCount,
                            tokensPerSecond: Double(chunkCount) / elapsed,
                            isFinal: false
                        ))
                    }
                }
            case .info(let info):
                completionObserved = true
                let stopReason: GenerationStats.StopReason = switch info.stopReason {
                case .stop: .complete
                case .length: .outputLimit
                case .cancelled: .cancelled
                }
                onStats?(GenerationStats(
                    generatedTokens: info.generationTokenCount,
                    tokensPerSecond: info.tokensPerSecond,
                    isFinal: true,
                    stopReason: stopReason
                ))
            case .toolCall:
                break   // not a tool-use model
            }
        }
        try Task.checkCancellation()
        guard completionObserved else {
            throw SummarizerError.generationFailed("The model stream ended without completion metadata.")
        }
        return result
    }
}

extension SummarizerService {

    /// Default production loader. Resolves a directory URL to an
    /// `MLXModelContainer` via `LLMModelFactory.shared.loadContainer`
    /// using the HuggingFace tokenizer macro for tokenization. Inject
    /// this at `SummarizerService.init(loader:)` in production code.
    ///
    /// The `#huggingFaceTokenizerLoader()` macro expands at compile
    /// time to a TokenizerLoader that reads the model directory's
    /// `tokenizer.json` + `tokenizer_config.json`.
    public static let defaultLoader: Loader = { @Sendable directory in
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        return MLXModelContainer(container: container)
    }
}
