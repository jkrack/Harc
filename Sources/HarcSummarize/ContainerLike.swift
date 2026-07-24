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
    func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String
}

/// Production `ContainerLike` backed by `MLXLMCommon.ModelContainer`.
/// Thin wrapper: builds `UserInput` from the prompt body (+ optional
/// system message), prepares, generates, and aggregates `Generation`
/// chunks into one string.
public struct MLXModelContainer: ContainerLike {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String {
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

        let stream = try await container.generate(input: lmInput, parameters: params)

        var result = ""
        for await generation in stream {
            switch generation {
            case .chunk(let fragment):
                result += fragment
            case .info:
                break   // final stats; not used by the parser
            case .toolCall:
                break   // not a tool-use model
            }
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
