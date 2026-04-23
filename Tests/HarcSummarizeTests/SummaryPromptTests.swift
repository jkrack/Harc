import XCTest
@testable import HarcSummarize

final class SummaryPromptTests: XCTestCase {

    func test_build_multiSpeaker_producesLabeledLinesAndTemplate() {
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "Welcome everyone."),
            .init(speaker: "Amy", text: "Hi all."),
        ])
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 1_000)

        XCTAssertTrue(prompt.contains("Jason: Welcome everyone."),
            "Speaker-labeled line should appear verbatim.")
        XCTAssertTrue(prompt.contains("Amy: Hi all."),
            "Second speaker line should appear verbatim.")
        XCTAssertTrue(prompt.contains("## Summary"),
            "Template's ## Summary section header must be in the prompt.")
        XCTAssertTrue(prompt.contains("## Action Items"),
            "Template's ## Action Items section header must be in the prompt.")
        XCTAssertFalse(prompt.contains("{TRANSCRIPT}"),
            "Placeholder must be replaced.")
    }

    func test_build_lastUtteranceExceedsBudget_keepsItAnyway() {
        // The last utterance alone is much longer than the budget.
        // Without the degenerate-case guard, the body would be
        // literally "[Earlier in the meeting…]" with nothing after,
        // sending Gemma an empty transcript. Verify we keep the last
        // utterance regardless.
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "early small line"),
            .init(speaker: "Amy",
                  text: "this final utterance has many many words far beyond the budget cap"),
        ])
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 5)

        XCTAssertTrue(prompt.contains("[Earlier in the meeting…]"),
            "Truncation prefix must still appear.")
        XCTAssertTrue(prompt.contains("Amy: this final utterance has many many words"),
            "The last utterance must be retained even when over budget.")
        XCTAssertFalse(prompt.contains("early small line"),
            "Earlier utterance was dropped; only the last one survives.")
    }
}
