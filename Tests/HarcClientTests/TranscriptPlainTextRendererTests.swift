import Testing
import Foundation
import HarcCore
@testable import HarcClient

@Suite("TranscriptPlainTextRenderer")
struct TranscriptPlainTextRendererTests {
    @Test("no speakers → joinedText as single paragraph")
    func noSpeakers() {
        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/x.wav",
            joinedText: "hello world",
            words: [
                Word(text: "hello", startMs: 0, endMs: 500),
                Word(text: "world", startMs: 500, endMs: 1000),
            ],
            speakers: [],
            chunks: []
        )
        #expect(TranscriptPlainTextRenderer.render(transcript) == "hello world")
    }

    @Test("two speakers → two paragraphs with labels and blank-line separation")
    func twoSpeakers() {
        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/x.wav",
            joinedText: "Hello there friend howdy",
            words: [
                Word(text: "Hello",  startMs: 0,    endMs: 500),
                Word(text: "there",  startMs: 500,  endMs: 1800),
                Word(text: "friend", startMs: 2000, endMs: 2500),
                Word(text: "howdy",  startMs: 2500, endMs: 3800),
            ],
            speakers: [
                SpeakerSegment(speaker: 0, startMs: 0,    endMs: 2000),
                SpeakerSegment(speaker: 1, startMs: 2000, endMs: 4000),
            ],
            chunks: []
        )
        let expected =
            "Speaker 1: Hello there\n\n" +
            "Speaker 2: friend howdy"
        #expect(TranscriptPlainTextRenderer.render(transcript) == expected)
    }

    @Test("sentencepiece-style leading-space tokens concatenate without double spaces")
    func sentencePieceTokens() {
        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/x.wav",
            joinedText: "tee it up",
            words: [
                Word(text: " te", startMs: 400,  endMs: 560),
                Word(text: "e",   startMs: 560,  endMs: 720),
                Word(text: " it", startMs: 800,  endMs: 1040),
                Word(text: " up", startMs: 1040, endMs: 1280),
            ],
            speakers: [
                SpeakerSegment(speaker: 0, startMs: 0, endMs: 2000),
            ],
            chunks: []
        )
        #expect(TranscriptPlainTextRenderer.render(transcript) == "Speaker 1: tee it up")
    }

    @Test("speaker flip and back → three paragraphs in order")
    func flipAndBack() {
        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/x.wav",
            joinedText: "a b c",
            words: [
                Word(text: "a", startMs: 0,    endMs: 500),
                Word(text: "b", startMs: 2200, endMs: 2500),
                Word(text: "c", startMs: 4200, endMs: 4500),
            ],
            speakers: [
                SpeakerSegment(speaker: 0, startMs: 0,    endMs: 2000),
                SpeakerSegment(speaker: 1, startMs: 2000, endMs: 4000),
                SpeakerSegment(speaker: 0, startMs: 4000, endMs: 6000),
            ],
            chunks: []
        )
        let expected =
            "Speaker 1: a\n\n" +
            "Speaker 2: b\n\n" +
            "Speaker 1: c"
        #expect(TranscriptPlainTextRenderer.render(transcript) == expected)
    }

    @Test("leading-edge word before first speaker segment snaps to nearest segment")
    func leadingEdgeSnap() {
        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/x.wav",
            joinedText: "te e it up",
            words: [
                // Midpoint 480ms, before first speaker segment (506ms).
                Word(text: " te", startMs: 400,  endMs: 560),
                Word(text: "e",   startMs: 560,  endMs: 720),
                Word(text: " it", startMs: 800,  endMs: 1040),
                Word(text: " up", startMs: 1040, endMs: 1280),
            ],
            speakers: [
                SpeakerSegment(speaker: 0, startMs: 506, endMs: 1755),
            ],
            chunks: []
        )
        #expect(TranscriptPlainTextRenderer.render(transcript) == "Speaker 1: tee it up")
    }

    @Test("mid-recording gap between speaker segments keeps current speaker")
    func midRecordingGap() {
        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/x.wav",
            joinedText: "a b c",
            words: [
                Word(text: "a", startMs: 0,    endMs: 500),
                // Midpoint 2050ms falls in the 2000–2100ms gap.
                Word(text: "b", startMs: 2000, endMs: 2100),
                Word(text: "c", startMs: 3000, endMs: 3500),
            ],
            speakers: [
                SpeakerSegment(speaker: 0, startMs: 0,    endMs: 2000),
                SpeakerSegment(speaker: 1, startMs: 2500, endMs: 4000),
            ],
            chunks: []
        )
        let expected =
            "Speaker 1: a b\n\n" +
            "Speaker 2: c"
        #expect(TranscriptPlainTextRenderer.render(transcript) == expected)
    }

    @Test("words but no speaker segments → joinedText fallback")
    func wordsNoSpeakers() {
        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: "/tmp/x.wav",
            joinedText: "just text",
            words: [Word(text: "just", startMs: 0, endMs: 500)],
            speakers: [],
            chunks: []
        )
        #expect(TranscriptPlainTextRenderer.render(transcript) == "just text")
    }
}
