import Testing
@testable import HarcSummarize

@Suite("ActionItemsMarkdown.render")
struct ActionItemsMarkdownTests {

    @Test("empty array renders as the canonical None-identified sentinel")
    func emptyRendersSentinel() {
        let rendered = ActionItemsMarkdown.render([])
        #expect(rendered == "_None identified._")
    }

    @Test("undone item renders as `- [ ]`, done item as `- [x]`")
    func checkboxState() {
        let items: [ActionItem] = [
            .init(text: "thing", actor: nil, due: nil, done: false),
            .init(text: "other", actor: nil, due: nil, done: true),
        ]
        let rendered = ActionItemsMarkdown.render(items)
        #expect(rendered == "- [ ] thing\n- [x] other")
    }

    @Test("actor + text + due renders as `- [ ] actor: text (due)`")
    func actorTextDue() {
        let items: [ActionItem] = [
            .init(text: "rewrite tiering page", actor: "Jason", due: "Friday", done: false),
        ]
        #expect(
            ActionItemsMarkdown.render(items)
            == "- [ ] Jason: rewrite tiering page (Friday)"
        )
    }

    @Test("actor + text without due omits parentheses")
    func actorTextOnly() {
        let items: [ActionItem] = [
            .init(text: "file the ticket", actor: "Amy", due: nil, done: false),
        ]
        #expect(ActionItemsMarkdown.render(items) == "- [ ] Amy: file the ticket")
    }

    @Test("text + due without actor omits the colon prefix")
    func textDueOnly() {
        let items: [ActionItem] = [
            .init(text: "ship the release", actor: nil, due: "next week", done: true),
        ]
        #expect(ActionItemsMarkdown.render(items) == "- [x] ship the release (next week)")
    }

    @Test("text-only renders as bare checkbox + text")
    func textOnly() {
        let items: [ActionItem] = [
            .init(text: "do the thing", actor: nil, due: nil, done: false),
        ]
        #expect(ActionItemsMarkdown.render(items) == "- [ ] do the thing")
    }

    @Test("render output round-trips through SummaryParser.parse")
    func roundTripThroughParser() {
        let original: [ActionItem] = [
            .init(text: "rewrite pricing page", actor: "Jason", due: "Friday", done: false),
            .init(text: "follow up", actor: "Amy", due: nil, done: true),
            .init(text: "file GDPR ticket", actor: nil, due: nil, done: false),
        ]
        let rendered = ActionItemsMarkdown.render(original)
        // Wrap in a fake summary body so SummaryParser.parse can split.
        let fakeModelOutput = """
        ## Summary
        sum body

        ## Action Items
        \(rendered)
        """
        let parsed = SummaryParser.parse(fakeModelOutput)
        #expect(parsed.actionItems.count == 3)
        #expect(parsed.actionItems[0].actor == "Jason")
        #expect(parsed.actionItems[0].text == "rewrite pricing page")
        #expect(parsed.actionItems[0].due == "Friday")
        #expect(parsed.actionItems[0].done == false)
        #expect(parsed.actionItems[1].actor == "Amy")
        #expect(parsed.actionItems[1].done == true)
        #expect(parsed.actionItems[2].actor == nil)
        #expect(parsed.actionItems[2].text == "file GDPR ticket")
    }
}
