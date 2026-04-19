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
        for word in words {
            guard !word.text.isEmpty else { continue }
            guard cursor <= nsText.length else { break }
            let searchRange = NSRange(location: cursor, length: nsText.length - cursor)
            let found = nsText.range(of: word.text, options: .caseInsensitive, range: searchRange)
            if found.location != NSNotFound {
                out.append(Entry(word: word, range: found))
                cursor = found.location + found.length
            }
        }
        self.entries = out
    }

    /// Returns the entry whose range contains `charOffset`. Whitespace
    /// between words returns nil.
    public func wordAt(charOffset: Int) -> Entry? {
        entries.first { NSLocationInRange(charOffset, $0.range) }
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
