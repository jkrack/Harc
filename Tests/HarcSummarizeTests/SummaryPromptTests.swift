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
}
