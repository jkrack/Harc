import Foundation
import HarcStore

struct NotePersonMention: Equatable {
    let name: String
    let isExplicit: Bool
}

enum NotePersonMentionAction: Equatable {
    case link(personID: Int64)
    case create(name: String)
    case unresolvedBare(name: String)
}

enum NotePersonMentionResolver {
    static func actions(for body: String, people: [Person]) -> [NotePersonMentionAction] {
        extractMentions(from: body).compactMap { mention in
            let key = normalize(mention.name)
            if let existing = bestPersonMatch(for: key, in: people) {
                return .link(personID: existing.id)
            }
            return mention.isExplicit
                ? .create(name: mention.name)
                : .unresolvedBare(name: mention.name)
        }
    }

    static func extractMentions(from body: String) -> [NotePersonMention] {
        let pattern = #"@person\[([^\]\n]+)\]|@\[([^\]\n]+)\]|@([\p{L}][\p{L}\p{N}'._-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen: Set<String> = []

        return regex.matches(in: body, range: range).compactMap { match in
            let typedPersonRange = match.range(at: 1)
            let bracketedRange = match.range(at: 2)
            let bareRange = match.range(at: 3)
            let isExplicit = typedPersonRange.location != NSNotFound || bracketedRange.location != NSNotFound
            let selectedRange = if typedPersonRange.location != NSNotFound {
                typedPersonRange
            } else if bracketedRange.location != NSNotFound {
                bracketedRange
            } else {
                bareRange
            }
            guard let swiftRange = Range(selectedRange, in: body) else { return nil }

            let name = String(body[swiftRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(name)
            guard !name.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return NotePersonMention(name: name, isExplicit: isExplicit)
        }
    }

    private static func bestPersonMatch(for normalizedMention: String, in people: [Person]) -> Person? {
        let tokenExact = people.filter { person in
            let normalizedName = normalize(person.displayName)
            return normalizedName != normalizedMention &&
                normalizedName.split(separator: " ").contains(Substring(normalizedMention))
        }
        if tokenExact.count == 1 { return tokenExact[0] }

        let exact = people.filter {
            normalize($0.displayName) == normalizedMention
        }
        if exact.count == 1 { return exact[0] }

        let prefix = people.filter { person in
            normalize(person.displayName)
                .split(separator: " ")
                .contains { $0.hasPrefix(normalizedMention) }
        }
        if prefix.count == 1 { return prefix[0] }

        return nil
    }

    private static func normalize(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
