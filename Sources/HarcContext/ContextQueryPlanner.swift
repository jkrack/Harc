import Foundation

public struct ContextQueryPlan: Sendable, Codable, Equatable {
    public var original: String
    public var retrievalQueries: [String]

    public init(original: String, retrievalQueries: [String]) {
        self.original = original
        self.retrievalQueries = retrievalQueries
    }
}

public enum ContextQueryPlanner {
    public static func plan(for rawQuery: String) -> ContextQueryPlan {
        let original = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return ContextQueryPlan(original: "", retrievalQueries: [])
        }

        let tokens = tokenize(original)
        let important = tokens.filter { !stopwords.contains($0) }

        var candidates: [String] = []
        append(important.joined(separator: " "), to: &candidates)

        if important.count > 2 {
            append(important.prefix(2).joined(separator: " "), to: &candidates)
        }

        if important.count > 3 {
            append(important.suffix(2).joined(separator: " "), to: &candidates)
        }

        for token in important.prefix(4) {
            append(token, to: &candidates)
        }

        append(original, to: &candidates)

        return ContextQueryPlan(original: original, retrievalQueries: candidates)
    }

    private static func append(_ query: String, to candidates: inout [String]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    private static func tokenize(_ query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .map { token in
                if token.hasSuffix("'s") {
                    return String(token.dropLast(2))
                }
                return token
            }
            .filter { !$0.isEmpty }
    }

    private static let stopwords: Set<String> = [
        "a", "about", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at",
        "be", "before", "between", "but", "by", "can", "could", "did", "do", "does", "for",
        "from", "give", "had", "has", "have", "he", "her", "hers", "him", "his", "how", "i",
        "in", "into", "is", "it", "last", "latest", "me", "meeting", "month", "my", "next",
        "of", "on", "or", "our", "please", "prep", "said", "say", "she", "show", "summarize",
        "summary", "tell", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "to", "up", "us", "was", "we", "week", "were", "what", "when", "where",
        "which", "who", "why", "with", "would", "you"
    ]
}
