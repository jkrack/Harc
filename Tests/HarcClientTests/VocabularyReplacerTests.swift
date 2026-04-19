import Testing
import Foundation
@testable import HarcClient
import HarcCore

struct VocabularyReplacerTests {
    private func vocab(_ rules: [(String, String)]) -> Vocabulary {
        Vocabulary(entries: rules.map { VocabularyEntry(from: $0.0, to: $0.1) })
    }

    @Test("whole-word case-insensitive replace")
    func replacesWholeWordCaseInsensitive() {
        let v = vocab([("Arakeet", "Parakeet")])
        #expect(VocabularyReplacer.apply("Arakeet is up", using: v) == "Parakeet is up")
        #expect(VocabularyReplacer.apply("arakeet is up", using: v) == "parakeet is up")
        #expect(VocabularyReplacer.apply("ARAKEET is up", using: v) == "PARAKEET is up")
    }

    @Test("does not match subword")
    func doesNotMatchSubword() {
        let v = vocab([("Sara", "Sarah")])
        #expect(VocabularyReplacer.apply("Saratoga", using: v) == "Saratoga")
        #expect(VocabularyReplacer.apply("Sara went", using: v) == "Sarah went")
    }

    @Test("preserves surrounding punctuation")
    func preservesSurroundingPunctuation() {
        let v = vocab([("Arakeet", "Parakeet")])
        #expect(VocabularyReplacer.apply("Arakeet's tests, Arakeet.", using: v) == "Parakeet's tests, Parakeet.")
    }

    @Test("multi-word phrase matches as unit")
    func multiWordPhrase() {
        let v = vocab([("oh kay are", "OKR")])
        #expect(VocabularyReplacer.apply("the oh kay are process", using: v) == "the OKR process")
    }

    @Test("multi-word phrase with punctuation")
    func multiWordPhraseWithPunctuation() {
        let v = vocab([("oh kay are", "OKR")])
        #expect(VocabularyReplacer.apply("the oh kay are, then", using: v) == "the OKR, then")
    }

    @Test("chained rules apply in order")
    func chainedRulesApplyInOrder() {
        let v = vocab([("sara", "Sarah"), ("Sarah", "Sarah Kim")])
        #expect(VocabularyReplacer.apply("sara went home", using: v) == "Sarah Kim went home")
    }

    @Test("disabled rule is skipped")
    func disabledRuleIsSkipped() {
        var v = vocab([("Arakeet", "Parakeet")])
        v.entries[0].enabled = false
        #expect(VocabularyReplacer.apply("Arakeet", using: v) == "Arakeet")
    }

    @Test("empty vocabulary is identity")
    func emptyVocabularyIsIdentity() {
        #expect(VocabularyReplacer.apply("hello world", using: .empty) == "hello world")
    }

    @Test("empty from/to is skipped, not crashed")
    func emptyFromOrToSkipped() {
        let v = vocab([("", "Parakeet"), ("Arakeet", "")])
        #expect(VocabularyReplacer.apply("Arakeet", using: v) == "Arakeet")
    }

    @Test("idempotent: apply twice == apply once")
    func idempotent() {
        let v = vocab([("Arakeet", "Parakeet")])
        let once = VocabularyReplacer.apply("Arakeet", using: v)
        let twice = VocabularyReplacer.apply(once, using: v)
        #expect(once == twice)
    }

    @Test("regex metacharacters in `from` are literal")
    func regexMetaInFromIsLiteral() {
        let v = vocab([("C++", "Cpp")])
        #expect(VocabularyReplacer.apply("I love C++ code", using: v) == "I love Cpp code")
    }

    @Test("case preservation — lowercase stays lowercase")
    func caseLowerStaysLower() {
        let v = vocab([("arakeet", "Parakeet")])
        #expect(VocabularyReplacer.apply("arakeet is down", using: v) == "parakeet is down")
    }

    @Test("case preservation — title stays title")
    func caseTitleStaysTitle() {
        let v = vocab([("Arakeet", "parakeet")])
        #expect(VocabularyReplacer.apply("Arakeet is down", using: v) == "Parakeet is down")
    }

    @Test("case preservation — all caps stays all caps")
    func caseAllCapsStaysAllCaps() {
        let v = vocab([("arakeet", "parakeet")])
        #expect(VocabularyReplacer.apply("ARAKEET IS DOWN", using: v) == "PARAKEET IS DOWN")
    }

    @Test("unicode word boundaries — diacritics behave")
    func handlesUnicode() {
        let v = vocab([("café", "coffee")])
        #expect(VocabularyReplacer.apply("the café opens", using: v) == "the coffee opens")
    }
}
