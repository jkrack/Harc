import Foundation

/// A narrow publication check for explicit refusals incorrectly emitted as
/// tasks. This does not establish that other generated actions are supported.
enum SummaryTaskValidation {
    static func validate(_ result: SummaryParseResult) throws {
        guard !result.actionItems.contains(where: { isExplicitRefusal($0.text) }) else {
            throw SummarizerError.generationFailed(
                "The model listed a refusal as an action item. No summary was saved. Retry the summary or review the transcript."
            )
        }
    }

    static func isExplicitRefusal(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for prefix in ["i will not ", "i won't ", "will not ", "won't "] {
            guard normalized.hasPrefix(prefix) else { continue }
            let remainder = normalized.dropFirst(prefix.count)
            // "not only ..." / "won't just ..." describe additional work,
            // not a refusal. Do not reject them based on the opening alone.
            return !remainder.hasPrefix("only ") && !remainder.hasPrefix("just ")
        }
        return false
    }
}
