import Foundation

extension SummaryPrompt {

    /// Prompt-overhead reservation in tokens — the template body plus
    /// chat-template wrapping that Gemma adds at tokenization time.
    /// Conservative; measured empirically on the Gemma 4 E2B chat
    /// template. Bump this if the template ever grows meaningfully.
    static let promptOverheadTokens = 1_200

    /// Reserved generation budget. Fixed at 1024 per spec §6.3 — a
    /// 6-sentence summary + 10 action items fits comfortably.
    static let maxOutputTokens = 1_024

    /// Hard ceiling on how much of the model's context we'll actually
    /// use for the prompt body. Beyond 32k the summary quality tends
    /// to degrade regardless of how much context the model supports.
    static let maxPromptTokens = 32_000

    /// Approximate tokens-per-word for English. Conservative — real
    /// English averages ~1.3–1.5, so using 1.3 leans toward slightly
    /// over-reserving budget.
    static let tokensPerEnglishWord: Double = 1.3

    /// Translate the model's reported context window into an English
    /// word budget for `SummaryPrompt.build`. Implements spec §6.2.
    public static func budgetWords(contextTokens: Int) -> Int {
        let cappedContext = min(contextTokens, maxPromptTokens)
        let budgetTokens = cappedContext - promptOverheadTokens - maxOutputTokens
        guard budgetTokens > 0 else { return 0 }
        let budgetWords = Double(budgetTokens) / tokensPerEnglishWord
        return Int(budgetWords.rounded(.down))
    }
}
