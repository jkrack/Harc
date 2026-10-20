import XCTest
@testable import HarcSummarize

final class SummaryOutputTests: XCTestCase {
    func test_inputCoverageAndFormatNoticesBothSurviveStorage() {
        let result = SummaryParseResult(summary: "raw response", actionItems: [], parseWarning: true, omittedUtteranceCount: 2)
        XCTAssertTrue(result.markdownForStorage.contains("Partial summary:"))
        XCTAssertTrue(result.markdownForStorage.contains("Review needed:"))
        XCTAssertTrue(result.markdownForStorage.hasSuffix("raw response"))
    }

    func test_storageText_keepsCleanSummaryUnchanged() {
        let result = SummaryParser.parse("## Summary\nA clean summary.\n## Action Items\n_None identified._")
        XCTAssertEqual(result.markdownForStorage, "A clean summary.")
    }

    func test_storageText_preservesMalformedResponseWithReviewNotice() {
        let raw = "## Summary\nPlanning.\n## Action Items\nJason will send the plan."
        let result = SummaryParser.parse(raw)
        XCTAssertTrue(result.markdownForStorage.hasPrefix("Review needed:"))
        XCTAssertTrue(result.markdownForStorage.hasSuffix(raw))
        XCTAssertEqual(result.summary, raw)
        XCTAssertTrue(result.actionItems.isEmpty)
    }

    func test_actionItem_codableRoundTrip() throws {
        let original = ActionItem(
            text: "rewrite tiering page",
            actor: "Jason",
            due: "Friday",
            done: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActionItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_summaryParseResult_holdsSummaryItemsAndWarning() {
        let result = SummaryParseResult(
            summary: "The team reviewed the roadmap.",
            actionItems: [
                ActionItem(text: "follow up on pricing", actor: "Amy", due: nil, done: false)
            ],
            parseWarning: false
        )
        XCTAssertEqual(result.summary, "The team reviewed the roadmap.")
        XCTAssertEqual(result.actionItems.count, 1)
        XCTAssertEqual(result.actionItems[0].actor, "Amy")
        XCTAssertFalse(result.parseWarning)
    }

    func test_summaryOutput_codableRoundTrip() throws {
        let original = SummaryOutput(
            summary: "Three sentences here.",
            actionItems: [
                ActionItem(text: "ship it", actor: nil, due: nil, done: false)
            ],
            model: "gemma-4-e2b-it-4bit",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            elapsedMs: 24_500,
            sourceWordCount: 8_200,
            parseWarning: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SummaryOutput.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
