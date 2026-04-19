import Foundation
import HarcCore

/// Applies a Vocabulary to a raw transcript string. Pure function —
/// no I/O, no state. Safe to call from any thread.
///
/// Semantics:
/// - Case-insensitive, word-boundary-aware (NSRegularExpression `\b`).
/// - User-typed `from` is escaped so metacharacters are literal.
/// - Supports multi-word phrases on either side.
/// - Preserves surface casing of the match: all-lower → to.lowercased,
///   all-upper → to.uppercased, Title-case → Title-case(to), mixed → to verbatim.
/// - Rules applied in entries-array order; each rule runs once per call.
/// - Disabled / empty entries are skipped.
public enum VocabularyReplacer {
    public static let maxEnabledRules = 500

    public static func apply(_ input: String, using vocabulary: Vocabulary) -> String {
        guard !input.isEmpty else { return input }
        var result = input
        var applied = 0
        for entry in vocabulary.entries {
            if applied >= maxEnabledRules { break }
            guard entry.enabled else { continue }
            let from = entry.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = entry.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { continue }
            result = applyOne(result, from: from, to: to)
            applied += 1
        }
        return result
    }

    private static func applyOne(_ input: String, from: String, to: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        // Lookarounds instead of \b so non-word chars (C++, .NET) match at boundaries.
        let pattern = "(?<!\\w)\(escaped)(?!\\w)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            FileHandle.standardError.write(Data(
                "harc-client: vocabulary rule failed to compile: \(from)\n".utf8
            ))
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var out = ""
        var cursor = 0
        for m in matches {
            let matched = ns.substring(with: m.range)
            let pre = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += pre
            out += casePreserved(replacement: to, matching: matched)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func casePreserved(replacement: String, matching match: String) -> String {
        // If the replacement itself encodes a case choice (acronym, multi-word,
        // internal caps like iPhone), respect it verbatim.
        if isIntentionallyCased(replacement) { return replacement }

        let firstWord = match.split(separator: " ").first.map(String.init) ?? match
        // Key casing off letters only — punctuation like `+` in "C++" is case-invariant
        // and should not trigger all-caps morphing.
        let letters = String(firstWord.filter { $0.isLetter })
        guard !letters.isEmpty else { return replacement }

        if letters == letters.lowercased() {
            return replacement.lowercased()
        }
        if letters.count > 1, letters == letters.uppercased() {
            return replacement.uppercased()
        }
        if let first = letters.first, first.isUppercase,
           letters.dropFirst() == letters.dropFirst().lowercased() {
            guard let firstChar = replacement.first else { return replacement }
            return firstChar.uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    private static func isIntentionallyCased(_ s: String) -> Bool {
        if s.contains(" ") { return true }
        let upperCount = s.filter { $0.isUppercase }.count
        if upperCount >= 2 { return true }
        if upperCount == 1, let first = s.first, !first.isUppercase {
            return true
        }
        return false
    }
}
