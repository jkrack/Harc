import Foundation
import HarcCore
import HarcSummarize
import Testing

@Suite("Summary overlap attribution")
struct OverlapPromptTests {
    @Test func overlapIsNotAttributedToTheKnownPerson() throws {
        let result = PromptTranscriptAdapter.make(joinedText: "before mixed after", words: [
            Word(text: "before", startMs: 0, endMs: 100),
            Word(text: "mixed", startMs: 100, endMs: 300),
            Word(text: "after", startMs: 300, endMs: 400)
        ], speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 400)],
            speakerNameOverrides: [0: "Alice"], overlapRanges: [try SpeechOverlapRange(startMs: 250, endMs: 300)])
        #expect(result.utterances == [
            .init(speaker: nil, text: "Overlapping voices detected. Speaker attribution may be incomplete."),
            .init(speaker: "Alice", text: "before"), .init(speaker: "Overlapping voices", text: "mixed"),
            .init(speaker: "Alice", text: "after")
        ])
    }

    @Test func sessionWarningSurvivesWithoutWordTimings() throws {
        var part = SessionPromptAssembler.Part(joinedText: "preserved text", words: [], speakers: [],
            speakerNames: [:], startedAt: Date())
        part.overlapRanges = [try SpeechOverlapRange(startMs: 0, endMs: 100)]
        let result = SessionPromptAssembler.make(parts: [part])
        #expect(result.utterances.map(\.text) == [
            "Overlapping voices detected. Speaker attribution may be incomplete.", "preserved text"
        ])
        #expect(result.utterances.allSatisfy { $0.speaker == nil })
    }
}
