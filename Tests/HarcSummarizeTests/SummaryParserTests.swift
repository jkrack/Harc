import XCTest
@testable import HarcSummarize

final class SummaryParserTests: XCTestCase {

    func test_parse_happyPath_extractsSummaryAndThreeActionItems() {
        let raw = """
        ## Summary
        The team reviewed the Q3 roadmap. Amy raised pricing as a blocker.
        Jason agreed to rewrite the tiering page by Friday.

        ## Action Items
        - [ ] Jason: rewrite tiering page (Friday)
        - [ ] Amy: schedule follow-up on pricing
        - [x] Sam: file GDPR ticket
        """
        let result = SummaryParser.parse(raw)

        XCTAssertFalse(result.parseWarning,
            "Well-formed input must not raise the parse warning.")
        XCTAssertTrue(result.summary.hasPrefix("The team reviewed"),
            "Summary should start at the first prose line after ## Summary.")
        XCTAssertFalse(result.summary.contains("## Action Items"),
            "Summary must not bleed into the action-items section.")
        XCTAssertEqual(result.actionItems.count, 3,
            "Three action-item lines should produce three items.")

        XCTAssertEqual(result.actionItems[0].actor, "Jason")
        XCTAssertEqual(result.actionItems[0].text, "rewrite tiering page")
        XCTAssertEqual(result.actionItems[0].due, "Friday")
        XCTAssertFalse(result.actionItems[0].done)

        XCTAssertEqual(result.actionItems[1].actor, "Amy")
        XCTAssertEqual(result.actionItems[1].text, "schedule follow-up on pricing")
        XCTAssertNil(result.actionItems[1].due)
        XCTAssertFalse(result.actionItems[1].done,
            "Unchecked - [ ] item must have done = false.")

        XCTAssertEqual(result.actionItems[2].actor, "Sam")
        XCTAssertTrue(result.actionItems[2].done,
            "- [x] should produce a done item.")
    }
}
