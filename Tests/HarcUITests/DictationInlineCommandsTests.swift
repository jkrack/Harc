import Testing
@testable import HarcUI

/// Spoken editing commands (#100). The safety rule under test throughout:
/// a command fires only when it stands as its own clause — Parakeet emits
/// spoken commands as little sentences ("New line."), while false-positive
/// phrases sit mid-clause and must survive untouched.
struct DictationInlineCommandsTests {

    @Test("new line as its own sentence becomes a line break")
    func newLine() {
        let out = DictationInlineCommands.apply(
            to: "Thanks for the update. New line. See you Thursday."
        )
        #expect(out == "Thanks for the update.\nSee you Thursday.")
    }

    @Test("new paragraph becomes a blank line")
    func newParagraph() {
        let out = DictationInlineCommands.apply(
            to: "First point. New paragraph. Second point."
        )
        #expect(out == "First point.\n\nSecond point.")
    }

    @Test("mid-sentence phrases never trigger")
    func midSentenceSafe() {
        let phrases = [
            "We are launching a new line of products this fall.",
            "I want to delete that file from the archive.",
            "The new paragraph styling looks better.",
        ]
        for p in phrases {
            #expect(DictationInlineCommands.apply(to: p) == p)
        }
    }

    @Test("scratch that drops the previous sentence")
    func scratchSentence() {
        let out = DictationInlineCommands.apply(
            to: "Send the report Monday. Actually Tuesday works better, scratch that. Send it Wednesday."
        )
        #expect(out == "Send the report Monday. Send it Wednesday.")
    }

    @Test("delete that is a synonym")
    func deleteThat() {
        let out = DictationInlineCommands.apply(
            to: "The budget is fine. Delete that. The budget needs work."
        )
        #expect(out == "The budget is fine. The budget needs work.")
    }

    @Test("scratch that cannot reach across a spoken line break")
    func scratchStopsAtBreak() {
        let out = DictationInlineCommands.apply(
            to: "Dear Sarah. New line. wrong start scratch that. Thanks for your note."
        )
        #expect(out == "Dear Sarah.\nThanks for your note.")
    }

    @Test("scratch that erasing everything returns empty")
    func scratchAll() {
        let out = DictationInlineCommands.apply(to: "never mind all of this scratch that.")
        #expect(out.isEmpty)
    }

    @Test("command at the very start just removes itself")
    func commandAtStart() {
        let out = DictationInlineCommands.apply(to: "Scratch that. Let's begin.")
        #expect(out == "Let's begin.")
    }

    @Test("commands at the utterance end need no trailing punctuation")
    func trailingCommand() {
        let out = DictationInlineCommands.apply(to: "Best regards. New line")
        #expect(out == "Best regards.")
    }
}
