import Testing
import Foundation
import HarcCore
@testable import HarcExport

struct SubtitleExporterTests {

    // MARK: - Display words

    @Test("SentencePiece tokens re-join into whole display words")
    func sentencePieceJoin() {
        let words = [
            Word(text: " B", startMs: 0, endMs: 100),
            Word(text: "ig", startMs: 100, endMs: 200),
            Word(text: " deal", startMs: 300, endMs: 500),
        ]
        let display = SubtitleExporter.displayWords(from: words)
        #expect(display.map(\.text) == ["Big", "deal"])
        #expect(display[0].startMs == 0)
        #expect(display[0].endMs == 200)
    }

    @Test("plain word-per-entry timings pass through")
    func plainWords() {
        let words = [
            Word(text: "hello", startMs: 0, endMs: 400),
            Word(text: "there", startMs: 500, endMs: 900),
        ]
        #expect(SubtitleExporter.displayWords(from: words).map(\.text) == ["hello", "there"])
    }

    // MARK: - Cue segmentation

    @Test("a silence gap starts a new cue")
    func gapBreaks() {
        let words = [
            Word(text: "first", startMs: 0, endMs: 400),
            Word(text: "thought", startMs: 500, endMs: 900),
            Word(text: "second", startMs: 3_000, endMs: 3_400),
        ]
        let cues = SubtitleExporter.makeCues(words: words, speakers: [])
        #expect(cues.count == 2)
        #expect(cues[0].text == "first thought")
        #expect(cues[1].text == "second")
        #expect(cues[1].startMs == 3_000)
    }

    @Test("a speaker change starts a new cue")
    func speakerBreaks() {
        let words = [
            Word(text: "mine", startMs: 0, endMs: 400),
            Word(text: "yours", startMs: 500, endMs: 900),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0, endMs: 450),
            SpeakerSegment(speaker: 1, startMs: 450, endMs: 1_000),
        ]
        let cues = SubtitleExporter.makeCues(words: words, speakers: speakers)
        #expect(cues.count == 2)
        #expect(cues[0].speaker == 0)
        #expect(cues[1].speaker == 1)
    }

    @Test("cues never overlap despite the minimum hold")
    func noOverlap() {
        let words = [
            Word(text: "quick", startMs: 0, endMs: 200),
            Word(text: "reply", startMs: 1_100, endMs: 1_300),
        ]
        let cues = SubtitleExporter.makeCues(words: words, speakers: [])
        #expect(cues.count == 2)
        #expect(cues[0].endMs <= cues[1].startMs)
    }

    @Test("long speech splits at the character budget, never mid-word")
    func charBudgetSplits() {
        let words = (0..<40).map {
            Word(text: "onboarding", startMs: $0 * 100, endMs: $0 * 100 + 90)
        }
        let cues = SubtitleExporter.makeCues(words: words, speakers: [])
        #expect(cues.count > 1)
        for cue in cues {
            #expect(cue.text.count <= SubtitleExporter.maxCueChars + 12)
            #expect(!cue.text.contains("onboardingonboarding"))
        }
    }

    // MARK: - Renderers

    @Test("SRT renders indexes, comma timestamps, and speaker prefixes")
    func srtShape() {
        let cues = [
            SubtitleExporter.Cue(startMs: 0, endMs: 1_500, speaker: 0, text: "hello there"),
            SubtitleExporter.Cue(startMs: 61_250, endMs: 62_000, speaker: 1, text: "hi"),
        ]
        let srt = SubtitleExporter.srt(cues: cues, speakerNames: [0: "Sarah"])
        let lines = srt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "1")
        #expect(lines[1] == "00:00:00,000 --> 00:00:01,500")
        #expect(lines[2] == "Sarah: hello there")
        #expect(lines[4] == "2")
        #expect(lines[5] == "00:01:01,250 --> 00:01:02,000")
        #expect(lines[6] == "Speaker 2: hi")
    }

    @Test("VTT renders the header and dot timestamps")
    func vttShape() {
        let cues = [
            SubtitleExporter.Cue(startMs: 3_723_042, endMs: 3_724_000, speaker: nil, text: "an hour in"),
        ]
        let vtt = SubtitleExporter.vtt(cues: cues)
        let lines = vtt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "WEBVTT")
        #expect(lines[2] == "01:02:03.042 --> 01:02:04.000")
        #expect(lines[3] == "an hour in")
    }

    @Test("undiarized cues carry no speaker prefix")
    func noSpeakerPrefix() {
        let cues = [SubtitleExporter.Cue(startMs: 0, endMs: 1_000, speaker: nil, text: "solo")]
        #expect(SubtitleExporter.srt(cues: cues).contains("solo"))
        #expect(!SubtitleExporter.srt(cues: cues).contains(":  solo"))
        #expect(!SubtitleExporter.srt(cues: cues).contains("Speaker"))
    }
}
