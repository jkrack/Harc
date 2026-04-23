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

    func test_parse_noActionItems_returnsEmptyList() {
        let raw = """
        ## Summary
        Quick check-in. No work assigned.

        ## Action Items
        _None identified._
        """
        let result = SummaryParser.parse(raw)

        XCTAssertFalse(result.parseWarning)
        XCTAssertEqual(result.summary, "Quick check-in. No work assigned.")
        XCTAssertTrue(result.actionItems.isEmpty,
            "_None identified._ sentinel must yield zero items.")
    }

    func test_parse_noSummaryHeader_setsParseWarningAndKeepsRaw() {
        let raw = "Sometimes the model just talks. No fences, no structure."
        let result = SummaryParser.parse(raw)

        XCTAssertTrue(result.parseWarning,
            "Missing ## Summary header must raise the warning.")
        XCTAssertEqual(result.summary, raw,
            "Raw text is preserved so the user still sees something.")
        XCTAssertTrue(result.actionItems.isEmpty)
    }

    func test_parse_summaryHeaderButNoActionItemsHeader_setsParseWarning() {
        let raw = """
        ## Summary
        We talked about the roadmap. Then the model trailed off without
        producing the action items section.
        """
        let result = SummaryParser.parse(raw)

        XCTAssertTrue(result.parseWarning,
            "## Summary without ## Action Items is malformed per the template.")
        XCTAssertTrue(result.summary.hasPrefix("We talked about"))
        XCTAssertTrue(result.actionItems.isEmpty)
    }

    func test_parse_actionItemWithoutActor_keepsFullTextAndNilActor() {
        let raw = """
        ## Summary
        Standup.

        ## Action Items
        - [ ] follow up with the design review thread
        """
        let result = SummaryParser.parse(raw)

        XCTAssertEqual(result.actionItems.count, 1)
        let item = result.actionItems[0]
        XCTAssertNil(item.actor,
            "No leading 'Actor:' → actor should be nil.")
        XCTAssertEqual(item.text, "follow up with the design review thread")
        XCTAssertNil(item.due)
    }

    func test_parse_actionItemWithActorAndDue_extractsBoth() {
        let raw = """
        ## Summary
        Planning.

        ## Action Items
        - [ ] Jason: rewrite tiering page (next Friday)
        """
        let result = SummaryParser.parse(raw)

        XCTAssertEqual(result.actionItems.count, 1)
        let item = result.actionItems[0]
        XCTAssertEqual(item.actor, "Jason")
        XCTAssertEqual(item.text, "rewrite tiering page")
        XCTAssertEqual(item.due, "next Friday")
    }

    func test_parse_actionItemWithCommasInPrefix_doesNotMisidentifyActor() {
        // "Tuesday, Friday: ..." — colon in a phrase that isn't an
        // actor. The 3-word + no-comma heuristic should reject this.
        let raw = """
        ## Summary
        Time-boxed.

        ## Action Items
        - [ ] Tuesday, Friday: check in on rollout
        """
        let result = SummaryParser.parse(raw)

        XCTAssertEqual(result.actionItems.count, 1)
        let item = result.actionItems[0]
        XCTAssertNil(item.actor,
            "Comma-bearing prefix is not an actor name.")
        XCTAssertEqual(item.text, "Tuesday, Friday: check in on rollout")
    }
}
