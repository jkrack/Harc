import Foundation
import Testing
@testable import HarcCore

@Suite("Attributed transcript utterances")
struct AttributedTranscriptUtteranceTests {
    @Test func retainsUntimedTextAndWordOverridesWithoutInventingTimings() throws {
        let alice = try WordSpeakerAttribution(speakerIndex: 1)
        let utterance = try AttributedTranscriptUtterance(text: "Full utterance without timed words",
            startMs: 100, endMs: 2000, speakerAttribution: alice)
        let decoded = try JSONDecoder().decode(AttributedTranscriptUtterance.self,
            from: JSONEncoder().encode(utterance))
        #expect(decoded == utterance)
        #expect(decoded.wordsWithInheritedAttribution.isEmpty)
        let finer = try AttributedTranscriptUtterance(text: "one two three", startMs: 100, endMs: 2000,
            speakerAttribution: alice, words: [
                Word(text: "one", startMs: 100, endMs: 200),
                Word(text: "two", startMs: 200, endMs: 300, speakerAttribution: WordSpeakerAttribution()),
                Word(text: "three", startMs: 300, endMs: 400,
                    speakerAttribution: try WordSpeakerAttribution(speakerIndex: 2))])
        let resolved = finer.wordsWithInheritedAttribution
        #expect(resolved[0].speakerAttribution == alice)
        #expect(resolved[1].speakerAttribution == WordSpeakerAttribution())
        #expect(resolved[2].speakerAttribution?.speakerIndex == 2)
        #expect(finer.words[0].speakerAttribution == nil)
        let runs = finer.displayRuns(speakers: [], overlapRanges: [try SpeechOverlapRange(startMs: 200, endMs: 300)])
        #expect(runs.map(\.text) == ["one", "two", "three"])
        #expect(runs.map(\.speakerIndex) == [1, nil, 2])
        #expect(runs.map(\.overlaps) == [false, true, false])
    }
    @Test func rejectsOutOfUtteranceWordsAndMalformedStoredRanges() throws {
        #expect(throws: (any Error).self) {
            try AttributedTranscriptUtterance(text: "bad", startMs: 100, endMs: 200,
                words: [Word(text: "outside", startMs: 0, endMs: 150)])
        }
        for json in [#"{"text":"bad","startMs":-1,"endMs":10}"#,
                     #"{"text":"bad","startMs":10,"endMs":10}"#] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(AttributedTranscriptUtterance.self, from: Data(json.utf8))
            }
        }
    }
}
