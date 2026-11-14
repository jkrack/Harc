import Foundation
import HarcCore

/// Maps each `Word` from a transcript to a character range in the joined
/// text — so char-offset ↔ time-ms lookups are cheap. Built via a single
/// forward scan; words that can't be located in the text are skipped.
public struct WordIndex: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let word: Word
        public let range: NSRange

        public init(word: Word, range: NSRange) {
            self.word = word
            self.range = range
        }
    }

    public let entries: [Entry]

    public init(words: [Word], text: String) {
        let nsText = text as NSString
        var cursor = 0
        var out: [Entry] = []
        out.reserveCapacity(words.count)
        // Edited transcripts can omit many occurrences of the same token.
        // A failed search covers the entire remaining suffix, so advancing
        // the cursor cannot make that exact token appear later. Remember
        // misses instead of rescanning the same suffix for every occurrence.
        var missingTokens: Set<String> = []
        for word in words {
            guard !word.text.isEmpty, !missingTokens.contains(word.text) else { continue }
            guard cursor <= nsText.length else { break }
            let searchRange = NSRange(location: cursor, length: nsText.length - cursor)
            let found = nsText.range(of: word.text, options: .caseInsensitive, range: searchRange)
            if found.location != NSNotFound {
                out.append(Entry(word: word, range: found))
                cursor = found.location + found.length
            } else {
                missingTokens.insert(word.text)
            }
        }
        self.entries = out
    }

    /// Returns the entry whose range contains `charOffset`. Whitespace
    /// between words returns nil.
    public func wordAt(charOffset: Int) -> Entry? {
        entries.first { NSLocationInRange(charOffset, $0.range) }
    }

    /// Resolve speaker labels and spaces within the clicked paragraph without
    /// jumping to a different turn when that paragraph has no timing evidence.
    public func wordForPlayback(atCharOffset offset: Int, text: String) -> Entry? {
        let ns = text as NSString
        guard offset >= 0, offset < ns.length else { return nil }
        if let exact = wordAt(charOffset: offset) { return exact }
        let paragraph = ns.paragraphRange(for: NSRange(location: offset, length: 0))
        let timed = entries.filter { NSLocationInRange($0.range.location, paragraph) }
        guard let first = timed.first else { return nil }
        let prefix = ns.substring(with: NSRange(location: paragraph.location,
                                                length: first.range.location - paragraph.location)) as NSString
        let colon = prefix.range(of: ":")
        if colon.location != NSNotFound, colon.location <= 40,
           offset <= paragraph.location + colon.location {
            return first
        }
        // Do not invent timing for unmatched transcript annotations or text.
        let character = ns.substring(with: NSRange(location: offset, length: 1))
        guard character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
        return timed.first(where: { $0.range.location >= offset }) ?? timed.last
    }

    /// Returns the entry whose word `[startMs, endMs)` contains `timeMs`.
    /// Binary-searches on `startMs` because entries are guaranteed in-order.
    public func wordAt(timeMs: Int) -> Entry? {
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let w = entries[mid].word
            if timeMs < w.startMs {
                hi = mid
            } else if timeMs >= w.endMs {
                lo = mid + 1
            } else {
                return entries[mid]
            }
        }
        return nil
    }
}
