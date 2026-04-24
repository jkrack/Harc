import Testing
import HarcCore
@testable import HarcSummarize

@Suite("PromptTranscriptAdapter")
struct PromptTranscriptAdapterTests {

    @Test("no speakers or words → single utterance carrying joinedText, speaker nil")
    func undiarized() {
        let t = PromptTranscriptAdapter.make(
            joinedText: "Hello there, this is a solo dictation.",
            words: [],
            speakers: [],
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].speaker == nil)
        #expect(t.utterances[0].text == "Hello there, this is a solo dictation.")
    }

    @Test("empty joinedText and no segments → empty utterances")
    func emptyTranscript() {
        let t = PromptTranscriptAdapter.make(
            joinedText: "",
            words: [],
            speakers: [],
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.isEmpty)
    }

    @Test("two diarized speakers → two utterances with default Speaker N labels")
    func twoSpeakersDefaultLabels() {
        let words = [
            Word(text: "Hello",    startMs: 0,    endMs: 500),
            Word(text: "everyone", startMs: 500,  endMs: 1000),
            Word(text: "Hi",       startMs: 1000, endMs: 1300),
            Word(text: "there",    startMs: 1300, endMs: 1600),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0,    endMs: 1000),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 1600),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "Hello everyone Hi there",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0].speaker == "Speaker 1")
        #expect(t.utterances[0].text == "Hello everyone")
        #expect(t.utterances[1].speaker == "Speaker 2")
        #expect(t.utterances[1].text == "Hi there")
    }

    @Test("speakerNameOverrides replaces the default Speaker N label")
    func overriddenLabels() {
        let words = [
            Word(text: "Roadmap",  startMs: 0,   endMs: 500),
            Word(text: "first",    startMs: 500, endMs: 1000),
            Word(text: "Pricing",  startMs: 1000, endMs: 1500),
            Word(text: "concern",  startMs: 1500, endMs: 2000),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0,    endMs: 1000),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 2000),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "Roadmap first Pricing concern",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [0: "Jason", 1: "Amy"]
        )
        #expect(t.utterances[0].speaker == "Jason")
        #expect(t.utterances[1].speaker == "Amy")
    }

    @Test("word whose midpoint falls in a between-segment gap stays with the current speaker")
    func gapHandling() {
        // Three segments with a gap between seg[0] (0-500) and seg[1] (1000-1500).
        // The middle word (550-650, midpoint 600) falls in the gap and should stay
        // on speaker 0 rather than starting a bogus un-labeled run.
        let words = [
            Word(text: "alpha", startMs: 0,    endMs: 500),
            Word(text: "beta",  startMs: 550,  endMs: 650),
            Word(text: "gamma", startMs: 1000, endMs: 1500),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0,    endMs: 500),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 1500),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "alpha beta gamma",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0].speaker == "Speaker 1")
        #expect(t.utterances[0].text == "alpha beta")
        #expect(t.utterances[1].speaker == "Speaker 2")
        #expect(t.utterances[1].text == "gamma")
    }

    @Test("partial speakerNameOverrides — missing keys fall back to default Speaker N")
    func partialOverrides() {
        let words = [
            Word(text: "first",  startMs: 0,    endMs: 500),
            Word(text: "second", startMs: 1000, endMs: 1500),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0,    endMs: 500),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 1500),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "first second",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [0: "Jason"]   // speaker 1 has no override
        )
        #expect(t.utterances[0].speaker == "Jason")
        #expect(t.utterances[1].speaker == "Speaker 2")
    }

    @Test("sentencepiece-style words (leading space) concatenate without extra spaces")
    func sentencePieceStyle() {
        // Tokens arrive with leading spaces; concatenation is verbatim.
        let words = [
            Word(text: "Hello",    startMs: 0,   endMs: 500),
            Word(text: " every",   startMs: 500, endMs: 700),
            Word(text: "one",      startMs: 700, endMs: 1000),
        ]
        let speakers = [
            SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000),
        ]
        let t = PromptTranscriptAdapter.make(
            joinedText: "Hello everyone",
            words: words,
            speakers: speakers,
            speakerNameOverrides: [:]
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].text == "Hello everyone")
    }
}
