import XCTest
@testable import HarcSummarize

final class SummaryOutputTests: XCTestCase {

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
