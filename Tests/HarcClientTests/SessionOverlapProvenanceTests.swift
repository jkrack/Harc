import Foundation
import Testing
import HarcCore
import HarcClient

@Suite("Saved transcript overlap provenance")
struct SessionOverlapProvenanceTests {
    @Test func daemonConversionRetainsTextTimingOverlapAndCoverage() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(3)
        var result = TranscribeResult(text: "mixed", words: [.init(text: "mixed", startMs: 0, endMs: 500)],
            speakers: [.init(speaker: 0, startMs: 0, endMs: 500)], processingMs: 30)
        let cases: [[SpeechOverlapRange]?] = [nil, [], [try SpeechOverlapRange(startMs: 100, endMs: 400)]]
        for overlaps in cases {
            result.overlapRanges = overlaps
            let transcript = SessionTranscript(startedAt: start, endedAt: end, audioPath: "/tmp/recovered.wav",
                result: result, processingCoverage: .complete)
            #expect(transcript.joinedText == result.text)
            #expect(transcript.words == result.words)
            #expect(transcript.speakers == result.speakers)
            #expect(transcript.overlapRanges == overlaps)
            #expect(transcript.processingCoverage == .complete)
            #expect(transcript.startedAt == start && transcript.endedAt == end)
            #expect(transcript.audioPath == "/tmp/recovered.wav")
            #expect(transcript.manualEditAt == nil)
            #expect(try JSONDecoder().decode(SessionTranscript.self,
                from: JSONEncoder().encode(transcript)) == transcript)
        }
    }

    @Test func legacyUnknownAndAssessedEmptyRemainDistinct() throws {
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/fixture.wav", joinedText: "words", words: [], speakers: [], chunks: [])
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript)) as! [String: Any]
        legacy.removeValue(forKey: "overlapRanges")
        #expect(try JSONDecoder().decode(SessionTranscript.self,
            from: JSONSerialization.data(withJSONObject: legacy)).overlapRanges == nil)
        transcript.overlapRanges = []
        #expect(try JSONDecoder().decode(SessionTranscript.self,
            from: JSONEncoder().encode(transcript)).overlapRanges == [])
    }
}
