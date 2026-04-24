import XCTest
@testable import HarcSummarize

final class SummaryPromptBudgetTests: XCTestCase {

    func test_budgetWords_forGemma4E2B_returnsPositiveWordCount() {
        // Spec §6.2 formula against Gemma 4 E2B's 32k context:
        //   budgetTokens = min(32000, 32000) - 1200 - 1024  = 29776
        //   budgetWords  = 29776 / 1.3                      = 22904
        let budget = SummaryPrompt.budgetWords(contextTokens: 32_000)
        XCTAssertGreaterThan(budget, 20_000,
            "32k context should leave well over 20k words after overhead.")
        XCTAssertLessThan(budget, 25_000,
            "The overhead reservations should cap the budget well under raw tokens/1.3.")
    }

    func test_budgetWords_clamps32kCap() {
        // If a model reports >32k context (e.g. 128k), we still cap at
        // 32k for the prompt budget — beyond that the prompt becomes
        // unwieldy and summarization quality degrades in practice.
        let budget32k = SummaryPrompt.budgetWords(contextTokens: 32_000)
        let budget128k = SummaryPrompt.budgetWords(contextTokens: 128_000)
        XCTAssertEqual(budget32k, budget128k,
            "Models with larger context are still clamped at the 32k prompt cap.")
    }

    func test_budgetWords_forTinyContext_returnsNonNegative() {
        // Pathologically small context (shouldn't happen in prod, but
        // the function shouldn't underflow).
        let budget = SummaryPrompt.budgetWords(contextTokens: 1_000)
        XCTAssertGreaterThanOrEqual(budget, 0,
            "A tiny context window must not underflow the budget.")
    }
}
