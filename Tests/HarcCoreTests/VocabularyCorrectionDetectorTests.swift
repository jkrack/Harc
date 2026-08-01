import Testing
@testable import HarcCore

/// #101: a transcript edit that fixes a mistranscribed name is a standing
/// correction worth offering to the vocabulary — a prose rewrite is not.
struct VocabularyCorrectionDetectorTests {

    @Test("a fixed name in place is detected")
    func nameFix() {
        let old = "and then Neil said the numbers looked fine"
        let new = "and then Neal said the numbers looked fine"
        let found = VocabularyCorrectionDetector.detect(old: old, new: new)
        #expect(found == [.init(from: "Neil", to: "Neal")])
    }

    @Test("punctuation attached to the token doesn't leak into the pair")
    func punctuationTrimmed() {
        let old = "we should ask Neil, before Friday"
        let new = "we should ask Neal, before Friday"
        let found = VocabularyCorrectionDetector.detect(old: old, new: new)
        #expect(found == [.init(from: "Neil", to: "Neal")])
    }

    @Test("a capitalization-only fix is a valid correction")
    func capitalizationFix() {
        let old = "the harc roadmap needs review"
        let new = "the Harc roadmap needs review"
        let found = VocabularyCorrectionDetector.detect(old: old, new: new)
        #expect(found == [.init(from: "harc", to: "Harc")])
    }

    @Test("a prose rewrite is not a correction")
    func rewriteIgnored() {
        let old = "and then he said the numbers looked fine"
        let new = "and then Sarah said the numbers looked fine"
        // "he" → "Sarah": different spoken word, not a transcription fix.
        #expect(VocabularyCorrectionDetector.detect(old: old, new: new).isEmpty)
    }

    @Test("lowercase word swaps are ignored")
    func lowercaseIgnored() {
        let old = "the numbers looked fine to me"
        let new = "the numbers seemed fine to me"
        #expect(VocabularyCorrectionDetector.detect(old: old, new: new).isEmpty)
    }

    @Test("multiple distinct fixes in one edit are all found")
    func multipleFixes() {
        let old = "Neil and Kubernetees met on Tuesday"
        let new = "Neal and Kubernetes met on Tuesday"
        let found = VocabularyCorrectionDetector.detect(old: old, new: new)
        #expect(found.contains(.init(from: "Neil", to: "Neal")))
        #expect(found.contains(.init(from: "Kubernetees", to: "Kubernetes")))
    }

    @Test("a massive rewrite bails instead of guessing")
    func hugeEditBails() {
        let old = (0..<600).map { "old\($0)" }.joined(separator: " ")
        let new = (0..<600).map { "New\($0)" }.joined(separator: " ")
        #expect(VocabularyCorrectionDetector.detect(old: old, new: new).isEmpty)
    }

    @Test("identical texts produce nothing")
    func identical() {
        let text = "nothing changed here at all"
        #expect(VocabularyCorrectionDetector.detect(old: text, new: text).isEmpty)
    }

    @Test("an insertion without a replacement pairs with nothing")
    func insertionIgnored() {
        let old = "we met on Tuesday"
        let new = "we met with Sarah on Tuesday"
        #expect(VocabularyCorrectionDetector.detect(old: old, new: new).isEmpty)
    }
}
