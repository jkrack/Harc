import Foundation

/// Prompt builder for dictation-mode transforms: reformat a dictated
/// transcript per a mode's instruction (clean-up, email, bullet list, …).
/// Pure — mirrors `ConversationPrompt`.
public enum ModeTransformPrompt {
    public static let systemPrompt = """
    You transform dictated text. Follow the instruction exactly. \
    Output only the transformed text — no preamble, no quotes, no explanation.
    """

    /// Dictation clips are short; transforms should stay proportional.
    public static let maxOutputTokens = 700

    public static func build(instruction: String, transcript: String) -> String {
        """
        Instruction:
        \(instruction)

        Dictated text:
        <<<
        \(transcript)
        >>>
        """
    }
}
