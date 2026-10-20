import Foundation

/// Builds the Gemma-bound prompt string. Pure — given the same
/// transcript + budget, returns the same string. No model state,
/// no I/O. The MLX caller (Stage 2) wraps the chat-template shell
/// around this body via the tokenizer, not via this code.
public enum SummaryPrompt {

    /// The user-turn body sent to Gemma. `{TRANSCRIPT}` is replaced
    /// at build time with the rendered utterance lines.
    public static let template: String = """
    Summarize only facts from the transcript below. Requests must remain requests, refusals must remain refusals, and possibilities must remain uncertain. Do not add facts or assume work was accepted.

    Write exactly two Markdown sections, each heading once:
    ## Summary
    A concise factual paragraph covering each substantive topic, risk, restriction, request, and agreed follow-up in the transcript. Describe requests as requests and preserve restrictions and conditions; do not omit them just because they are not commitments.
    ## Confirmed Commitments
    One line per agreed future task, including conditional promises with their condition using exactly: - [ ] <actual owner from transcript>: <task> (<deadline or condition, if stated>)
    If nobody accepted a task, write exactly _None identified._ beneath Confirmed Commitments.

    Include an action only when the owner agrees to do it. An explicit "If X happens, I will do Y" is an agreed conditional task: include Y with its condition X. The condition does not need to be true yet. "I will send the report" is a commitment by that speaker. "Send the report" and "Do not approve the discount" are instructions, not commitments. "Please send it" followed by "I need to check first" is not accepted. "I will not", "I could", cancelled tasks and quoted old promises are not current commitments. When someone else takes over, include only the new owner's accepted task. Exclude work already completed. Never list unassigned tasks or requests that nobody accepted, even under "Unassigned". Include all explicit commitments to remaining work; never omit one because other speakers only made requests. Preserve any condition on an accepted commitment; do not turn conditional work into an unconditional promise.

    Examples of action eligibility (these are examples, NOT transcript facts):
    - "I finished the migration last night." => _None identified._ The work is already done.
    - "Please review the design." with no acceptance => _None identified._ A request alone is not a commitment.
    - "I'll review the design tomorrow." => - [ ] Speaker: review the design (tomorrow)
    - "Could you review the design?" then "Yes, I will." => only the second speaker owns the review.

    Transcript:
    <<<
    {TRANSCRIPT}
    >>>
    """

    static let factsTemplate: String = """
    Summarize only the facts in the transcript. Write one concise paragraph under exactly one heading: ## Summary.
    Cover every substantive current status, risk, restriction, request, and agreed follow-up. Preserve both sides of a contrast: a positive status and an unresolved risk can both be true. Keep requests as requests, refusals as refusals, and possibilities uncertain. Preserve conditions, deadlines, cancellations, and changes of ownership. Do not invent facts or treat a request as accepted. Keep every stated date, quantity and condition attached to its original event, including completed work. Copy relative time phrases exactly rather than changing their reference point. Do not generate an action list.

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
        renderWithCoverage(transcript: transcript, budgetWords: budgetWords).body
    }

    static func renderWithCoverage(transcript: PromptTranscript, budgetWords: Int) -> (body: String, omittedUtterances: Int) {
        let lines = transcript.utterances.map(line(for:))
        let totalWords = lines.map(wordCount(of:)).reduce(0, +)
        if totalWords <= budgetWords {
            return (lines.joined(separator: "\n"), 0)
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
        // Degenerate case: even the last utterance alone exceeds the
        // budget. Keep it anyway — better to give the model SOMETHING
        // than to ask it to summarize an empty transcript.
        if keptReversed.isEmpty, let last = lines.last {
            keptReversed.append(last)
        }
        let tail = keptReversed.reversed().joined(separator: "\n")
        return ("[Earlier in the meeting…]\n" + tail, lines.count - keptReversed.count)
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
