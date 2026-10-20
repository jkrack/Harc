import Testing
import Foundation
import HarcCore
@testable import HarcClient

@Suite("TranscriptPlainTextRenderer")
struct TranscriptPlainTextRendererTests {
    @Test func attributedUtterancesRenderWithoutInventingWordsAndRespectManualEdits() throws {
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/test.wav",
            joinedText: "Untimed sentence. Full text survives.", words: [], speakers: [], chunks: [])
        transcript.attributedUtterances = [
            try AttributedTranscriptUtterance(text: "Untimed sentence.", startMs: 0, endMs: 1000,
                speakerAttribution: WordSpeakerAttribution(speakerIndex: 1)),
            try AttributedTranscriptUtterance(text: "Full text survives.", startMs: 1000, endMs: 2000,
                speakerAttribution: WordSpeakerAttribution(speakerIndex: 1), words: [
                    Word(text: "Full", startMs: 1000, endMs: 1200,
                         speakerAttribution: WordSpeakerAttribution(speakerIndex: 2))])]
        #expect(TranscriptPlainTextRenderer.render(transcript) == "Speaker 2: Untimed sentence.\n\nFull text survives.")
        let notice = UntranscribedAudioMarker.text(startMs: 2000, endMs: 2500)
        transcript.joinedText += " " + notice
        #expect(TranscriptPlainTextRenderer.render(transcript).contains(notice))
        transcript.manualEditAt = Date()
        transcript.joinedText = "My corrected wording"
        #expect(TranscriptPlainTextRenderer.render(transcript) == "My corrected wording")
    }

    @Test func explicitWordAttributionSurvivesStorageAndNeverFallsBackWhenUnresolved() throws {
        let explicit = try WordSpeakerAttribution(speakerIndex: 1)
        let words = [Word(text: "Alice", startMs: 0, endMs: 100, speakerAttribution: explicit),
                     Word(text: "unknown", startMs: 100, endMs: 200, speakerAttribution: WordSpeakerAttribution())]
        let decoded = try JSONDecoder().decode([Word].self, from: JSONEncoder().encode(words))
        #expect(decoded == words)
        let legacy = try JSONDecoder().decode(Word.self, from: Data(#"{"text":"old","startMs":0,"endMs":100}"#.utf8))
        #expect(legacy.speakerAttribution == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Word.self,
                from: Data(#"{"text":"bad","startMs":0,"endMs":100,"speakerAttribution":{"speakerIndex":-1}}"#.utf8))
        }
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "Alice unknown", words: words,
            speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 200)], chunks: [])
        #expect(TranscriptPlainTextRenderer.render(transcript) == "Speaker 2: Alice\n\nunknown")
        transcript.speakers = []
        #expect(TranscriptPlainTextRenderer.render(transcript) == "Speaker 2: Alice\n\nunknown")
        let merged = Word.displayWords(from: [
            Word(text: " alre", startMs: 0, endMs: 100, speakerAttribution: explicit),
            Word(text: "ady", startMs: 100, endMs: 200, speakerAttribution: WordSpeakerAttribution())])
        #expect(merged.count == 1)
        #expect(merged[0].text == "already")
        #expect(merged[0].speakerAttribution == WordSpeakerAttribution())
    }

    @Test("speaker and overlap boundaries cannot split a lexical word")
    func completeWordAttribution() throws {
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "already", words: [Word(text: " alre", startMs: 0, endMs: 100),
                Word(text: "ady", startMs: 100, endMs: 300)],
            speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 100),
                SpeakerSegment(speaker: 1, startMs: 100, endMs: 300)], chunks: [])
        #expect(TranscriptPlainTextRenderer.render(transcript) == "Speaker 2: already")
        transcript.overlapRanges = [try SpeechOverlapRange(startMs: 0, endMs: 20)]
        #expect(TranscriptPlainTextRenderer.render(transcript).hasSuffix("Overlapping voices: already"))
    }

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

    @Test("subword tokens merge before midpoint speaker assignment")
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

    @Test("mid-recording gap does not inherit a speaker name")
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
            "Speaker 1: a\n\nb\n\n" +
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

@Suite("Transcript failure marker rendering")
struct TranscriptFailureMarkerRenderingTests {
    @Test func noticesSurviveWithSpeakerLabels() {
        let notices = [0, 1000, 3000].map { UntranscribedAudioMarker.text(startMs: $0, endMs: $0 + 500) }
        let transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/example.wav",
            joinedText: "\(notices[0]) Hello \(notices[1]) Bye \(notices[2])",
            words: [.init(text: " Hello", startMs: 600, endMs: 900), .init(text: " Bye", startMs: 2000, endMs: 2400)],
            speakers: [.init(speaker: 0, startMs: 0, endMs: 3000)], chunks: [])
        let rendered = TranscriptPlainTextRenderer.render(transcript, nameForSpeaker: { _ in "Alex" })
        #expect(rendered == [notices[0], "Alex: Hello", notices[1], "Alex: Bye", notices[2]].joined(separator: "\n\n"))
        var noSpeakers = transcript
        noSpeakers.speakers = []
        #expect(TranscriptPlainTextRenderer.render(noSpeakers) == transcript.joinedText)
    }
}
