import Foundation

public enum ContextEvidenceExtractor {
    public static func extract(
        from text: String?,
        queryPlan: ContextQueryPlan,
        fallbackSnippet: String,
        maxLength: Int = 1_200
    ) -> String {
        let cleanFallback = cleanSnippet(fallbackSnippet)
        guard let transcript = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty
        else {
            return cleanFallback
        }

        let terms = significantTerms(from: queryPlan)
        guard let matchRange = bestMatch(in: transcript, terms: terms) else {
            return cleanFallback.isEmpty
                ? clipped(transcript, maxLength: maxLength)
                : cleanFallback
        }

        return window(
            around: matchRange,
            in: transcript,
            maxLength: maxLength
        )
    }

    static func significantTerms(from plan: ContextQueryPlan) -> [String] {
        var terms: [String] = []
        for query in plan.retrievalQueries {
            for token in query
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            {
                let term = String(token)
                guard term.count >= 3, !terms.contains(term) else { continue }
                terms.append(term)
            }
        }
        return terms
    }

    private static func bestMatch(in transcript: String, terms: [String]) -> Range<String.Index>? {
        guard !terms.isEmpty else { return nil }

        let lower = transcript.lowercased()
        var best: Range<String.Index>?
        for term in terms {
            guard let range = lower.range(of: term) else { continue }
            if let current = best {
                if range.lowerBound < current.lowerBound {
                    best = range
                }
            } else {
                best = range
            }
        }
        return best
    }

    private static func window(
        around range: Range<String.Index>,
        in transcript: String,
        maxLength: Int
    ) -> String {
        let target = max(120, maxLength)
        let centerOffset = transcript.distance(from: transcript.startIndex, to: range.lowerBound)
        let half = target / 2
        let rawStartOffset = max(0, centerOffset - half)
        let rawEndOffset = min(transcript.count, rawStartOffset + target)

        let start = transcript.index(transcript.startIndex, offsetBy: rawStartOffset)
        let end = transcript.index(transcript.startIndex, offsetBy: rawEndOffset)

        let chunk = String(transcript[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped(chunk, maxLength: target)
    }

    private static func cleanSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipped(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let clipped = String(text.prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped + "..."
    }

}
