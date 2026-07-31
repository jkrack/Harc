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

        // Generic summarizer lead-ins carry no identity — "The discussion
        // focused on various models of interaction" is a title about the
        // models, not about the discussing. Strip the boilerplate and let
        // the subject stand, unless what's left is too thin to be a title.
        let leadIns = [
            "the discussion focused on", "the discussion centered on",
            "the discussion covered", "the conversation focused on",
            "the conversation covered", "the speakers discussed",
            "the team discussed", "the group discussed",
            "the meeting covered", "this meeting covered",
            "the discussion was about", "the conversation was about",
        ]
        let lowered = text.lowercased()
        for lead in leadIns where lowered.hasPrefix(lead) {
            let stripped = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            if stripped.count >= 12 {
                text = stripped.prefix(1).uppercased() + stripped.dropFirst()
            }
            break
        }

        // First clause, once past a readable minimum — "The team reviewed
        // the drop-off" is a title; "The team" is not.
        let minReadable = 24
        if text.count > 60 {
            // Earliest qualifying boundary wins — matching pattern-by-pattern
            // let a ", and" deep in the sentence beat a ", including" right
            // after the subject, keeping half a sentence of trailing clause.
            let boundaries = [", which", ", and", ", but", ", including", "; ", " — ", ", "]
            let cut = boundaries
                .compactMap { text.range(of: $0)?.lowerBound }
                .filter { text.distance(from: text.startIndex, to: $0) >= minReadable }
                .min()
            if let cut {
                text = String(text[..<cut])
            }
        }

        // Hard cap at a word boundary.
        if text.count > 72 {
            let prefix = String(text.prefix(72))
            text = prefix[..<(prefix.lastIndex(of: " ") ?? prefix.endIndex)].trimmingCharacters(in: .whitespaces)
        }

        // Never end on a dangling function word: the hard cap and clause
        // cuts can land mid-phrase, and "…models of interaction, including
        // the" is not a title anyone wants on a row.
        let danglers: Set<String> = [
            "the", "a", "an", "and", "or", "but", "of", "to", "in", "on",
            "at", "for", "with", "including", "like", "such", "as", "that",
            "which", "their", "its", "his", "her", "was", "were", "is", "are",
            "how", "what", "when", "where", "who", "why",
        ]
        var words = text.split(separator: " ").map(String.init)
        while let last = words.last,
              danglers.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeLast()
        }
        text = words.joined(separator: " ")

        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:—-"))
        return cleaned.count >= 8 ? cleaned : nil
    }
}
