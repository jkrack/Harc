import Testing
import Foundation
import HarcCore
@testable import HarcSummarize

@Suite("PromptTranscriptAdapter")
struct PromptTranscriptAdapterTests {

    @Test func utteranceAttributionAndManualTextReachSummaryInput() throws {
        let utterances = [try AttributedTranscriptUtterance(text: "Untimed sentence", startMs: 0, endMs: 1000,
            speakerAttribution: WordSpeakerAttribution(speakerIndex: 1))]
        let result = PromptTranscriptAdapter.make(joinedText: "Untimed sentence", words: [], speakers: [],
            speakerNameOverrides: [1: "Alice"], overlapRanges: nil, attributedUtterances: utterances)
        #expect(result.utterances.count == 1)
        #expect(result.utterances[0].speaker == "Alice")
        #expect(result.utterances[0].text == "Untimed sentence")
        let edited = PromptTranscriptAdapter.make(joinedText: "My correction", words: [], speakers: [],
            speakerNameOverrides: [1: "Alice"], overlapRanges: nil,
            attributedUtterances: utterances, manualEditAt: Date())
        #expect(edited.utterances[0].text == "My correction")
        #expect(edited.utterances[0].speaker == nil)
    }

    @Test func explicitAndUnresolvedWordsOverrideTimingAttribution() throws {
        let words = [Word(text: "named", startMs: 0, endMs: 100,
                          speakerAttribution: try WordSpeakerAttribution(speakerIndex: 1)),
                     Word(text: "unknown", startMs: 100, endMs: 200, speakerAttribution: WordSpeakerAttribution())]
        for segments in [[], [SpeakerSegment(speaker: 0, startMs: 0, endMs: 200)]] {
            let result = PromptTranscriptAdapter.make(joinedText: "named unknown", words: words,
                speakers: segments, speakerNameOverrides: [0: "Wrong", 1: "Alice"])
            #expect(result.utterances.count == 2)
            #expect(result.utterances[0].speaker == "Alice")
            #expect(result.utterances[1].speaker == nil)
            #expect(result.utterances[1].text == "unknown")
        }
    }

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

    @Test("word in a between-segment gap stays unnamed")
    func gapHandling() {
        // Three segments with a gap between seg[0] (0-500) and seg[1] (1000-1500).
        // The middle word has no speaker evidence and must not inherit a name.
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
        #expect(t.utterances.count == 3)
        #expect(t.utterances[0].speaker == "Speaker 1")
        #expect(t.utterances[0].text == "alpha")
        #expect(t.utterances[1].speaker == nil)
        #expect(t.utterances[1].text == "beta")
        #expect(t.utterances[2].speaker == "Speaker 2")
        #expect(t.utterances[2].text == "gamma")
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

@Suite("Summary transcript failure notices")
struct SummaryTranscriptFailureNoticeTests {
    @Test func noticesArePreservedWithoutSpeakerAttribution() {
        let notice = UntranscribedAudioMarker.text(startMs: 1000, endMs: 2000)
        let result = PromptTranscriptAdapter.make(joinedText: "Hello \(notice) Bye",
            words: [.init(text: "Hello", startMs: 0, endMs: 500), .init(text: "Bye", startMs: 2000, endMs: 2500)],
            speakers: [.init(speaker: 0, startMs: 0, endMs: 3000)], speakerNameOverrides: [0: "Alex"])
        #expect(result.utterances.map(\.text) == ["Hello", notice, "Bye"])
        #expect(result.utterances.map(\.speaker) == ["Alex", nil, "Alex"])
    }
}
