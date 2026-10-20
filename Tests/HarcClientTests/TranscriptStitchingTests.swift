import Testing
import Foundation
import HarcCore
@testable import HarcClient

/// Overlap-stitching (#102): adjacent chunks share ~2s of audio so the
/// boundary word arrives whole in both; the assembler must keep exactly one
/// copy — the predecessor's, which had a full chunk of left context.
struct TranscriptStitchingTests {

    @Test func stitchingAndRebasingPreserveExplicitWordAttribution() throws {
        let attribution = try WordSpeakerAttribution(speakerIndex: 4)
        let first = chunk("hello again today", startMs: 0, endMs: 2000)
        let second = chunk("again today new", startMs: 1000, endMs: 3000, words: [
            Word(text: "again", startMs: 0, endMs: 100),
            Word(text: "today", startMs: 100, endMs: 200),
            Word(text: "new", startMs: 200, endMs: 400, speakerAttribution: attribution)])
        let stitched = TranscriptAssembler.stitchAdjacent([first, second])
        #expect(stitched[1].words.count == 1)
        #expect(stitched[1].text == "new")
        #expect(stitched[1].words.last?.speakerAttribution == attribution)
        let assembler = TranscriptAssembler()
        assembler.add(first); assembler.add(second)
        let result = assembler.finalize(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/test.wav")
        #expect(result.words.last?.speakerAttribution == attribution)
        #expect(result.words.last?.startMs == 1200)
    }

    private func chunk(
        _ text: String,
        startMs: Int,
        endMs: Int,
        words: [Word] = []
    ) -> ChunkResult {
        ChunkResult(startMs: startMs, endMs: endMs, text: text,
                    words: words, speakers: [], processingMs: 1)
    }

    @Test("stitching removes matched words rather than all speech in the time overlap")
    func preservesNewSpeechInsideOverlap() {
        let a = chunk("we can start now", startMs: 0, endMs: 62000)
        let b = chunk("start now already", startMs: 60000, endMs: 122000, words: [
            Word(text: " start", startMs: 0, endMs: 200),
            Word(text: " now", startMs: 200, endMs: 400),
            Word(text: " alre", startMs: 400, endMs: 600),
            Word(text: "ady", startMs: 600, endMs: 900)])
        let result = TranscriptAssembler.stitchAdjacent([a,b])[1]
        #expect(result.text == "already")
        #expect(result.words == [Word(text: " already", startMs: 400, endMs: 900)])
    }

    @Test("unaligned timed prefix keeps the successor intact")
    func unalignedPrefix() {
        let a = chunk("we can start now", startMs: 0, endMs: 62000)
        let b = chunk("start now please", startMs: 60000, endMs: 122000,
            words: [Word(text: "different", startMs: 0, endMs: 500)])
        let result = TranscriptAssembler.stitchAdjacent([a,b])[1]
        #expect(result.text == b.text)
        #expect(result.words == b.words)
    }

    // MARK: - overlapPrefixLength (pure)

    @Test("an exact duplicated run is found and measured")
    func exactRun() {
        let n = TranscriptAssembler.overlapPrefixLength(
            previousTail: "and that is why we return to the board",
            nextHead: "return to the board for the next quarter"
        )
        #expect(n == 4)
    }

    @Test("normalization bridges case and punctuation differences")
    func normalizedMatch() {
        let n = TranscriptAssembler.overlapPrefixLength(
            previousTail: "we should ask Sarah, right?",
            nextHead: "ask sarah right and then move on"
        )
        #expect(n == 3)
    }

    @Test("a single common word is not enough to stitch")
    func singleWordRefused() {
        let n = TranscriptAssembler.overlapPrefixLength(
            previousTail: "we talked about the budget",
            nextHead: "the meeting then moved on"
        )
        #expect(n == nil)
    }

    @Test("unrelated texts do not stitch")
    func unrelatedRefused() {
        let n = TranscriptAssembler.overlapPrefixLength(
            previousTail: "completely different closing words here",
            nextHead: "some other opening entirely new thoughts"
        )
        #expect(n == nil)
    }

    // MARK: - stitchAdjacent

    @Test("the duplicated boundary text appears exactly once")
    func boundaryDeduped() {
        let a = chunk("the plan needs a full review before launch",
                      startMs: 0, endMs: 62_000)
        let b = chunk(
            "review before launch and the timeline holds",
            startMs: 60_000, endMs: 122_000,
            words: [
                Word(text: "review", startMs: 100, endMs: 500),
                Word(text: "before", startMs: 600, endMs: 900),
                Word(text: "launch", startMs: 1_000, endMs: 1_500),
                Word(text: "and", startMs: 2_400, endMs: 2_600),
                Word(text: "the", startMs: 2_700, endMs: 2_800),
            ]
        )
        let stitched = TranscriptAssembler.stitchAdjacent([a, b])
        #expect(stitched.count == 2)
        #expect(stitched[1].text == "and the timeline holds")
        // The three matched words are removed from both representations.
        #expect(stitched[1].words.map(\.text) == ["and", "the"])
    }

    @Test("no confident match falls back to the hard join, nothing lost")
    func fallbackKeepsEverything() {
        let a = chunk("first chunk ends quietly", startMs: 0, endMs: 62_000)
        let b = chunk("second chunk starts fresh", startMs: 60_000, endMs: 122_000,
                      words: [Word(text: "second", startMs: 100, endMs: 400)])
        let stitched = TranscriptAssembler.stitchAdjacent([a, b])
        #expect(stitched[1].text == "second chunk starts fresh")
        #expect(stitched[1].words.count == 1)
    }

    @Test("non-overlapping chunks pass through untouched")
    func hardCutsUntouched() {
        let a = chunk("first minute", startMs: 0, endMs: 60_000)
        let b = chunk("second minute", startMs: 60_000, endMs: 120_000)
        let stitched = TranscriptAssembler.stitchAdjacent([a, b])
        #expect(stitched[0].text == "first minute")
        #expect(stitched[1].text == "second minute")
    }

    @Test("assembler output uses stitched text end to end")
    func assemblerIntegration() {
        let assembler = TranscriptAssembler()
        assembler.add(chunk("we agreed on the migration path", startMs: 0, endMs: 62_000))
        assembler.add(chunk("the migration path is staged rollout",
                            startMs: 60_000, endMs: 122_000))
        #expect(assembler.currentJoinedText
                == "we agreed on the migration path is staged rollout")
        let transcript = assembler.finalize(
            startedAt: Date(), endedAt: Date(), audioPath: "/tmp/x.wav"
        )
        #expect(transcript.joinedText
                == "we agreed on the migration path is staged rollout")
    }
}
