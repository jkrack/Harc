import Foundation
import NaturalLanguage

/// Derives a short title hint from a transcript by pulling the top
/// named entities (people, organizations, places) via Apple's NLTagger.
/// Runs on-device, no network, no model cost beyond the built-in tagger.
public enum TitleSuggester {
    /// Returns a human-readable hint like "Sarah, Q3 roadmap" or nil if the
    /// transcript has no usable entities. Deterministic for a given input.
    public static func suggest(from transcript: String?) -> String? {
        guard let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let relevantTags: Set<NLTag> = [.personalName, .organizationName, .placeName]

        // Count occurrences of each entity (case-insensitive).
        var counts: [String: Int] = [:]
        var order: [String] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag, relevantTags.contains(tag) else { return true }
            let entity = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard entity.count >= 2 else { return true }
            let key = entity.lowercased()
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
            return true
        }

        guard !counts.isEmpty else { return nil }

        // Rank: by frequency desc, then by first-appearance order (stable).
        let ranked = order.sorted { (a, b) in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }

        // Take top 2, pretty-case them by pulling the first occurrence form from
        // the text so "sarah" becomes "Sarah" not lowercased.
        let top = Array(ranked.prefix(2)).compactMap { key -> String? in
            prettyCase(key, in: text)
        }
        guard !top.isEmpty else { return nil }
        return top.joined(separator: ", ")
    }

    /// Find the first occurrence of `key` in `text` ignoring case and return
    /// the original-case substring. Falls back to `key.capitalized` if not found.
    private static func prettyCase(_ key: String, in text: String) -> String {
        if let range = text.range(of: key, options: [.caseInsensitive]) {
            return String(text[range])
        }
        return key.capitalized
    }
}
