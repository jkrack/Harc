import Foundation

/// Turns Gemma's raw model output into a `SummaryParseResult`. Lenient
/// — the spec template asks for a specific shape but the model can
/// drift; the parser handles "extra prose between fences", "no Action
/// Items header at all", and "completely off-script output" by surfacing
/// `parseWarning = true` rather than erroring.
public enum SummaryParser {

    public static func parse(_ raw: String) -> SummaryParseResult {
        // 1. Split on the FIRST `## Summary` header. If absent, the whole
        //    response is treated as the summary text + parseWarning.
        guard let summaryHeader = raw.range(of: "## Summary") else {
            let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return SummaryParseResult(summary: fallback, actionItems: [], parseWarning: true)
        }

        let afterSummary = raw[summaryHeader.upperBound...]

        // 2. Split on the NEXT `## Action Items`. If absent, everything
        //    after `## Summary` is the summary; no items; warning.
        guard let actionsHeader = ["## Action Items", "## Confirmed Commitments"].compactMap({ afterSummary.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            let summary = afterSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            return SummaryParseResult(summary: String(summary), actionItems: [], parseWarning: true)
        }

        let summaryText = afterSummary[..<actionsHeader.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actionsBody = afterSummary[actionsHeader.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let items = parseActionItems(actionsBody)
        let lines = actionsBody.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let explicitNone = actionsBody.lowercased() == noneIdentifiedMarker
        // A successful header split does not mean the action body was understood.
        // Preserve the response when any line would otherwise disappear, including
        // mixed valid/invalid lists and truncated empty sections. Do not infer tasks
        // from prose or silently turn malformed output into "no items".
        let complete = !summaryText.isEmpty && (explicitNone || (!lines.isEmpty && lines.count == items.count))
        return SummaryParseResult(
            summary: complete ? String(summaryText) : raw.trimmingCharacters(in: .whitespacesAndNewlines),
            actionItems: items,
            parseWarning: !complete
        )
    }

    // MARK: - Internals

    private static let noneIdentifiedMarker = "_none identified._"

    public static func parseActionItems(_ body: String) -> [ActionItem] {
        // The "no items" sentinel is case-insensitive; whitespace around
        // it is tolerated.
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == noneIdentifiedMarker {
            return []
        }

        var items: [ActionItem] = []
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Match "- [ ]" or "- [x]" / "- [X]". Anything else is ignored
            // (stray prose between lines, extra fences, etc.).
            // Explicit bracketed-owner form emitted by the commitment prompt.
            if line.hasPrefix("- ["), let end = line.range(of: "]: ") {
                let owner = String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                let task = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !owner.isEmpty, !owner.contains("["), !owner.contains("]"), !task.isEmpty {
                    let parsed = parseActionItemBody("Owner: " + task, done: false)
                    guard !parsed.text.isEmpty else { continue }
                    items.append(ActionItem(text: parsed.text, actor: owner, due: parsed.due, done: false))
                }
                continue
            }
            let unchecked = "- [ ]"
            let checkedLower = "- [x]"
            let checkedUpper = "- [X]"
            let isUnchecked = line.hasPrefix(unchecked)
            let isChecked = line.hasPrefix(checkedLower) || line.hasPrefix(checkedUpper)
            guard isUnchecked || isChecked else { continue }

            let prefix = isChecked
                ? (line.hasPrefix(checkedLower) ? checkedLower : checkedUpper)
                : unchecked
            let bodyText = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            let item = parseActionItemBody(bodyText, done: isChecked)
            guard !item.text.isEmpty else { continue }
            items.append(item)
        }
        return items
    }

    /// Parses an action-item body into structured `ActionItem` fields.
    ///
    /// Heuristics:
    /// - Trailing `(...)` becomes `due`. Empty parens `()` parse to `nil`.
    /// - Leading `<word>:` (≤3 words, no commas) becomes `actor`.
    ///
    /// Known limitation: short non-name prefixes like `Note:`, `TODO:`,
    /// or `Reminder:` will be captured as `actor` even though they
    /// aren't speaker names. Gemma's prompt template explicitly
    /// discourages such meta-prefixes, so this is acceptable for v1; if
    /// real-model output shows the pattern in Stage 2, add a denylist
    /// here.
    static func parseActionItemBody(_ text: String, done: Bool) -> ActionItem {
        var remaining = text
        var due: String? = nil
        var actor: String? = nil

        // Trailing "(...)" → due. Empty parens "()" are normalised to
        // `nil` rather than the empty string, so downstream `if let`
        // checks behave consistently with "no parens at all".
        if remaining.hasSuffix(")"),
           let openParen = remaining.lastIndex(of: "(") {
            let dueRange = remaining.index(after: openParen)..<remaining.index(before: remaining.endIndex)
            let extracted = String(remaining[dueRange]).trimmingCharacters(in: .whitespaces)
            due = extracted.isEmpty ? nil : extracted
            remaining = String(remaining[..<openParen]).trimmingCharacters(in: .whitespaces)
        }

        // Leading "<actor>:" → actor. Heuristic: actor is short and has
        // no commas — guards against parsing "Tuesday, Friday: …" as
        // an actor.
        if let colon = remaining.firstIndex(of: ":") {
            let candidate = String(remaining[..<colon]).trimmingCharacters(in: .whitespaces)
            let words = candidate.split(whereSeparator: { $0.isWhitespace })
            if !candidate.isEmpty, words.count <= 3, !candidate.contains(",") {
                actor = candidate
                remaining = String(remaining[remaining.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return ActionItem(text: remaining, actor: actor, due: due, done: done)
    }
}
