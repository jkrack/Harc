import Foundation
import HarcCore
import HarcClient
import Testing

@Suite("Plain transcript overlap attribution")
struct OverlapRenderingTests {
    private func fixture() throws -> SessionTranscript {
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "before mixed after", words: [
                Word(text: "before", startMs: 0, endMs: 100),
                Word(text: "mixed", startMs: 100, endMs: 300),
                Word(text: "after", startMs: 300, endMs: 400)
            ], speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 400)], chunks: [])
        transcript.overlapRanges = [try SpeechOverlapRange(startMs: 250, endMs: 300)]
        return transcript
    }

    @Test func anyWordIntersectionWithOverlapSuppressesPersonName() throws {
        let transcript = try fixture()
        #expect(TranscriptPlainTextRenderer.render(transcript, nameForSpeaker: { _ in "Alice" }) ==
            "Overlapping voices detected. Speaker attribution may be incomplete.\n\nAlice: before\n\nOverlapping voices: mixed\n\nAlice: after")
        #expect(transcript.joinedText == "before mixed after")
    }

    @Test func overlapWithoutTrackedSpeakersOrWordTimingsRemainsVisible() throws {
        var transcript = try fixture()
        transcript.speakers = []
        #expect(TranscriptPlainTextRenderer.render(transcript).contains("Overlapping voices: mixed"))
        transcript.words = []
        #expect(TranscriptPlainTextRenderer.render(transcript) ==
            "Overlapping voices detected. Speaker attribution may be incomplete.\n\nbefore mixed after")
    }

    @Test func legacyAndAssessedEmptyKeepExistingRendering() throws {
        var transcript = try fixture()
        transcript.overlapRanges = nil
        let legacy = TranscriptPlainTextRenderer.render(transcript)
        transcript.overlapRanges = []
        #expect(legacy == "Speaker 1: before mixed after")
        #expect(TranscriptPlainTextRenderer.render(transcript) == legacy)
    }
}
