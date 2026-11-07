import Testing
import Foundation
import HarcCore
@testable import HarcUI

@Suite("WordIndex")
struct WordIndexTests {
    private func word(_ text: String, _ startMs: Int, _ endMs: Int) -> Word {
        Word(text: text, startMs: startMs, endMs: endMs)
    }

    @Test("locates each word's range in joined text")
    func locatesRanges() {
        let idx = WordIndex(
            words: [word("hello", 0, 500), word("world", 500, 1000)],
            text: "hello world"
        )
        #expect(idx.entries.count == 2)
        #expect(idx.entries[0].range == NSRange(location: 0, length: 5))
        #expect(idx.entries[1].range == NSRange(location: 6, length: 5))
    }

    @Test("wordAt(charOffset:) returns the containing word")
    func byCharOffset() {
        let idx = WordIndex(
            words: [word("hello", 0, 500), word("world", 500, 1000)],
            text: "hello world"
        )
        #expect(idx.wordAt(charOffset: 0)?.word.text == "hello")
        #expect(idx.wordAt(charOffset: 4)?.word.text == "hello")
        #expect(idx.wordAt(charOffset: 5) == nil) // whitespace
        #expect(idx.wordAt(charOffset: 6)?.word.text == "world")
        #expect(idx.wordAt(charOffset: 100) == nil)
    }

    @Test("wordAt(timeMs:) returns the word whose window contains the time")
    func byTimeMs() {
        let idx = WordIndex(
            words: [word("hello", 0, 500), word("world", 500, 1000)],
            text: "hello world"
        )
        #expect(idx.wordAt(timeMs: 0)?.word.text == "hello")
        #expect(idx.wordAt(timeMs: 499)?.word.text == "hello")
        #expect(idx.wordAt(timeMs: 500)?.word.text == "world")
        #expect(idx.wordAt(timeMs: 999)?.word.text == "world")
        #expect(idx.wordAt(timeMs: 1000) == nil) // past end
        #expect(idx.wordAt(timeMs: 2000) == nil)
    }

    @Test("case-insensitive match against joined text")
    func caseInsensitive() {
        let idx = WordIndex(
            words: [word("Hello", 0, 500)],
            text: "hello world"
        )
        #expect(idx.entries.count == 1)
        #expect(idx.entries[0].range == NSRange(location: 0, length: 5))
    }

    @Test("words not present in text are skipped, not errored")
    func missingWordsSkipped() {
        let idx = WordIndex(
            words: [word("hello", 0, 500), word("zzz", 500, 700), word("world", 700, 1000)],
            text: "hello world"
        )
        #expect(idx.entries.count == 2)
        #expect(idx.entries[0].word.text == "hello")
        #expect(idx.entries[1].word.text == "world")
    }

    @Test("empty inputs return empty index")
    func empty() {
        let idx = WordIndex(words: [], text: "anything")
        #expect(idx.entries.isEmpty)
        #expect(idx.wordAt(charOffset: 0) == nil)
        #expect(idx.wordAt(timeMs: 100) == nil)
    }

    @Test("forward-scan cursor means repeated words resolve in order")
    func repeatedWords() {
        let idx = WordIndex(
            words: [word("yes", 0, 200), word("yes", 300, 500)],
            text: "yes and yes"
        )
        #expect(idx.entries.count == 2)
        #expect(idx.entries[0].range == NSRange(location: 0, length: 3))
        #expect(idx.entries[1].range == NSRange(location: 8, length: 3))
    }

    @Test("repeated missing tokens do not hide later matches or change UTF-16 offsets")
    func repeatedMissingTokens() {
        let words = [word("removed", 0, 100), word("HELLO", 100, 200),
                     word("removed", 200, 300), word("café", 300, 400),
                     word("removed", 400, 500), word("hello", 500, 600)]
        let text = "🙂 hello café hello"
        let idx = WordIndex(words: words, text: text)
        #expect(idx.entries.map(\.word) == [words[1], words[3], words[5]])
        #expect(idx.entries.map(\.range) == [
            NSRange(location: 3, length: 5), NSRange(location: 9, length: 4),
            NSRange(location: 14, length: 5)
        ])
    }

    @Test("large edited transcript skips repeated absent words and retains its matching tail")
    func largeEditedTranscript() {
        var words = (0..<15_000).map { word("removed", $0 * 100, $0 * 100 + 100) }
        let tail = word("retained", 1_500_000, 1_500_100)
        words.append(tail)
        let text = String(repeating: "replacement ", count: 15_000) + "retained"
        let idx = WordIndex(words: words, text: text)
        #expect(idx.entries == [WordIndex.Entry(
            word: tail, range: NSRange(location: 180_000, length: 8)
        )])
    }

}
