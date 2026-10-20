import Foundation
import Testing
import HarcCore

@Suite("Speech overlap provenance")
struct SpeechOverlapProvenanceTests {
    @Test func legacyDiarizationIsUnassessedAndExplicitEmptyIsPreserved() throws {
        let legacy = Data(#"{"segments":[],"speakers":[],"processingMs":0}"#.utf8)
        var result = try JSONDecoder().decode(DiarizeResult.self, from: legacy)
        #expect(result.overlapRanges == nil)
        result.overlapRanges = []
        #expect(try JSONDecoder().decode(DiarizeResult.self,
            from: JSONEncoder().encode(result)).overlapRanges == [])
    }

    @Test func transcribeOverlapRoundTripAndInvalidBounds() throws {
        var result = TranscribeResult(text: "words", words: [], speakers: [], processingMs: 0)
        result.overlapRanges = [try SpeechOverlapRange(startMs: 25, endMs: 100)]
        #expect(try JSONDecoder().decode(TranscribeResult.self,
            from: JSONEncoder().encode(result)) == result)
        for input in [#"{"startMs":-1,"endMs":10}"#, #"{"startMs":10,"endMs":10}"#,
                      #"{"startMs":20,"endMs":10}"#] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SpeechOverlapRange.self, from: Data(input.utf8))
            }
        }
    }
}
