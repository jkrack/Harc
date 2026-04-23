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

    func test_build_soloDictation_omitsSpeakerLabel() {
        let transcript = PromptTranscript(utterances: [
            .init(speaker: nil, text: "Note to self: pick up groceries."),
        ])
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 1_000)

        XCTAssertTrue(prompt.contains("Note to self: pick up groceries."),
            "Solo utterance must appear verbatim.")
        // No leading-colon artifact — that would mean a missing speaker
        // label rendered as ": Note…" or "nil: Note…".
        XCTAssertFalse(prompt.contains(": Note to self"),
            "Solo line must not be prefixed with a label separator.")
        XCTAssertFalse(prompt.contains("nil:"),
            "nil speaker must never leak into the prompt.")
    }

    func test_build_overBudget_headTruncatesWithPrefix() {
        // 100 utterances, each "S0: w1" / "S1: w2" / ... — 2 words per
        // line for the wordCount counter.
        let utterances = (1...100).map { i in
            PromptTranscript.Utterance(speaker: "S\(i % 2)", text: "w\(i)")
        }
        let transcript = PromptTranscript(utterances: utterances)
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 20)

        XCTAssertTrue(prompt.contains("[Earlier in the meeting…]"),
            "Truncated transcripts must announce the cut so the model knows.")
        XCTAssertTrue(prompt.contains("w100"),
            "The tail (most recent utterances) must be retained.")
        XCTAssertFalse(prompt.contains("w1\n"),
            "Early utterances must be dropped (w1 followed by newline).")
        XCTAssertFalse(prompt.contains("w50\n"),
            "Mid-meeting utterances should also be dropped at this budget.")
    }

    func test_build_underBudget_doesNotPrependPrefix() {
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "Short meeting."),
        ])
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 1_000)
        XCTAssertFalse(prompt.contains("[Earlier in the meeting…]"),
            "Under-budget transcripts must not announce a (false) cut.")
    }
}
