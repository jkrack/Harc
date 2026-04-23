import Foundation

/// Builds the Gemma-bound prompt string. Pure — given the same
/// transcript + budget, returns the same string. No model state,
/// no I/O. The MLX caller (Stage 2) wraps the chat-template shell
/// around this body via the tokenizer, not via this code.
public enum SummaryPrompt {

    /// The user-turn body sent to Gemma. `{TRANSCRIPT}` is replaced
    /// at build time with the rendered utterance lines.
    public static let template: String = """
    You analyze meeting transcripts and produce a short, factual summary plus
    action items.

    Output EXACTLY this format:

    ## Summary
    <3–6 sentences, plain prose, no bullets, no headings inside>

    ## Action Items
    - [ ] <actor>: <task> (<due if mentioned>)
    - [ ] <actor>: <task>

    If no action items are in the transcript, write:
    ## Action Items
    _None identified._

    Rules:
    - Never invent facts. If something isn't said, don't add it.
    - Use speaker names where present in the transcript; fall back to "the team" or "someone".
    - Action items are the MINIMUM — only include items someone actually committed to.

    Transcript:
    <<<
    {TRANSCRIPT}
    >>>
    """

    /// Build the full prompt. If the rendered body exceeds `budgetWords`,
    /// drop whole utterances from the front and prepend
    /// `[Earlier in the meeting…]` so the model knows context is missing.
    public static func build(transcript: PromptTranscript, budgetWords: Int) -> String {
        let body = renderBody(transcript: transcript, budgetWords: budgetWords)
        return template.replacingOccurrences(of: "{TRANSCRIPT}", with: body)
    }

    // MARK: - Internals (visible for tests via @testable)

    static func renderBody(transcript: PromptTranscript, budgetWords: Int) -> String {
        let lines = transcript.utterances.map(line(for:))
        let totalWords = lines.map(wordCount(of:)).reduce(0, +)
        if totalWords <= budgetWords {
            return lines.joined(separator: "\n")
        }
        // Walk from the tail forward, keeping whole utterances until we
        // hit the budget. Preserves speaker boundaries.
        var keptReversed: [String] = []
        var keptWords = 0
        for line in lines.reversed() {
            let w = wordCount(of: line)
            if keptWords + w > budgetWords { break }
            keptReversed.append(line)
            keptWords += w
        }
        let tail = keptReversed.reversed().joined(separator: "\n")
        return "[Earlier in the meeting…]\n" + tail
    }

    static func line(for utt: PromptTranscript.Utterance) -> String {
        if let speaker = utt.speaker, !speaker.isEmpty {
            return "\(speaker): \(utt.text)"
        }
        return utt.text
    }

    static func wordCount(of s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
