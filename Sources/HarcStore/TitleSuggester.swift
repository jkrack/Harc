import Foundation
import NaturalLanguage

/// Derives a short title hint from a transcript by pulling the top
/// named entities (people, organizations, places) via Apple's NLTagger.
/// Runs on-device, no network, no model cost beyond the built-in tagger.
public enum TitleSuggester {
    /// All distinct named entities in the transcript, ordered by frequency desc
    /// then first-appearance. Pretty-cased from the first occurrence form.
    public static func extractEntities(from transcript: String?) -> [String] {
        guard let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let relevantTags: Set<NLTag> = [.personalName, .organizationName, .placeName]

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

        guard !counts.isEmpty else { return [] }

        let ranked = order.sorted { (a, b) in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }

        return ranked.compactMap { prettyCase($0, in: text) }
    }

    /// Returns a human-readable hint like "Sarah, Q3 roadmap" or nil if the
    /// transcript has no usable entities. Deterministic for a given input.
    public static func suggest(from transcript: String?) -> String? {
        let entities = extractEntities(from: transcript)
        guard !entities.isEmpty else { return nil }
        return Array(entities.prefix(2)).joined(separator: ", ")
    }

    /// Find the first occurrence of `key` in `text` ignoring case and return
    /// the original-case substring. Falls back to `key.capitalized` if not found.
    private static func prettyCase(_ key: String, in text: String) -> String {
        if let range = text.range(of: key, options: [.caseInsensitive]) {
            return String(text[range])
        }
        return key.capitalized
    }

    /// A title from the first clause of a generated summary.
    ///
    /// The summarizer already writes a sentence that names what the meeting
    /// was about — "The team reviewed the weekly onboarding drop-off, which…"
    /// — and that first clause beats any entity list as a row identity. This
    /// runs at summary-save time; recordings that never summarize keep the
    /// entity-based suggestion as their fallback.
    ///
    /// Deliberately dumb: first sentence, cut at the first clause boundary
    /// once past a readable minimum, hard cap at a word boundary. No model,
    /// deterministic, and safe to re-run (same summary, same title).
    public static func fromSummary(_ summaryMarkdown: String?) -> String? {
        guard var text = summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        // Strip leading markdown furniture — headings, list markers, bold.
        while let first = text.first, "#-*> ".contains(first) {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "**", with: "")

        // First sentence.
        if let end = text.firstIndex(where: { ".!?\n".contains($0) }) {
            text = String(text[..<end])
        }

        // First clause, once past a readable minimum — "The team reviewed
        // the drop-off" is a title; "The team" is not.
        let minReadable = 24
        if text.count > 60 {
            for boundary in [", which", ", and", ", but", "; ", " — ", ", "] {
                if let r = text.range(of: boundary), text.distance(from: text.startIndex, to: r.lowerBound) >= minReadable {
                    text = String(text[..<r.lowerBound])
                    break
                }
            }
        }

        // Hard cap at a word boundary.
        if text.count > 72 {
            let prefix = String(text.prefix(72))
            text = prefix[..<(prefix.lastIndex(of: " ") ?? prefix.endIndex)].trimmingCharacters(in: .whitespaces)
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count >= 8 ? cleaned : nil
    }
}
