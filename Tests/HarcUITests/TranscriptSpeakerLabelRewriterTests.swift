import Testing
@testable import HarcUI

struct TranscriptSpeakerLabelRewriterTests {
    @Test("resolved Person names replace generated speaker heads")
    func replacesGeneratedHeads() {
        let input = "Speaker 1: Hello\n\nSpeaker 2: Hi"
        let output = TranscriptSpeakerLabelRewriter.rewrite(
            input,
            turnSpeakerIndices: [0, 1],
            previousLabels: [:],
            resolvedLabels: [0: "Frank Thomas", 1: "Amy"]
        )
        #expect(output == "Frank Thomas: Hello\n\nAmy: Hi")
    }

    @Test("multiple diarization clusters can resolve to one Person")
    func mergesDisplayIdentityWithoutMergingTurns() {
        let input = "Speaker 1: First\n\nSpeaker 3: Later\n\nSpeaker 1: Last"
        let output = TranscriptSpeakerLabelRewriter.rewrite(
            input,
            turnSpeakerIndices: [0, 2, 0],
            previousLabels: [:],
            resolvedLabels: [0: "James", 2: "James"]
        )
        #expect(output == "James: First\n\nJames: Later\n\nJames: Last")
    }

    @Test("a later rename uses ordered turns even when old names collide")
    func handlesDuplicatePreviousLabels() {
        let input = "James: First\n\nJames: Other voice\n\nJames: Last"
        let output = TranscriptSpeakerLabelRewriter.rewrite(
            input,
            turnSpeakerIndices: [0, 2, 0],
            previousLabels: [0: "James", 2: "James"],
            resolvedLabels: [0: "James", 2: "Frank"]
        )
        #expect(output == "James: First\n\nFrank: Other voice\n\nJames: Last")
    }

    @Test("manual non-speaker lines are preserved in tolerant fallback")
    func preservesManualLines() {
        let input = "Speaker 1: Hello\nNote: keep this\nSpeaker 2: Hi"
        let output = TranscriptSpeakerLabelRewriter.rewrite(
            input,
            turnSpeakerIndices: [0, 1, 0],
            previousLabels: [:],
            resolvedLabels: [0: "Frank", 1: "Amy"]
        )
        #expect(output == "Frank: Hello\nNote: keep this\nAmy: Hi")
    }
}
