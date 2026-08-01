import Testing
import Foundation
import HarcCore
@testable import HarcClient

/// Overlap-stitching (#102): adjacent chunks share ~2s of audio so the
/// boundary word arrives whole in both; the assembler must keep exactly one
/// copy — the predecessor's, which had a full chunk of left context.
struct TranscriptStitchingTests {

    private func chunk(
        _ text: String,
        startMs: Int,
        endMs: Int,
        words: [Word] = []
    ) -> ChunkResult {
        ChunkResult(startMs: startMs, endMs: endMs, text: text,
                    words: words, speakers: [], processingMs: 1)
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
        // Words inside the shared 2s are dropped with the text.
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
