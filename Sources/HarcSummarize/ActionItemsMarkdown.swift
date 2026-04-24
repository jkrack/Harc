import Foundation

/// Serialize `[ActionItem]` to the exact markdown shape `SummaryParser.parse`
/// consumes. Enables round-trip persistence — the UI re-parses markdown on
/// read and re-renders it here when the user toggles `done`.
public enum ActionItemsMarkdown {

    /// Render items as one line each, or the canonical empty sentinel.
    public static func render(_ items: [ActionItem]) -> String {
        if items.isEmpty { return "_None identified._" }
        return items.map(renderLine(_:)).joined(separator: "\n")
    }

    private static func renderLine(_ item: ActionItem) -> String {
        let box = item.done ? "- [x]" : "- [ ]"
        let body: String
        switch (item.actor, item.due) {
        case (let actor?, let due?):
            body = "\(actor): \(item.text) (\(due))"
        case (let actor?, nil):
            body = "\(actor): \(item.text)"
        case (nil, let due?):
            body = "\(item.text) (\(due))"
        case (nil, nil):
            body = item.text
        }
        return "\(box) \(body)"
    }
}
