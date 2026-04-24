import Foundation

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
