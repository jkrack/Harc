import Testing
import AppKit
@testable import HarcUI

/// The speaker channel may color ONLY the "Name:" heads. NSTextView's typing
/// attributes inherit from the insertion point, and a programmatic
/// `textView.string =` restyles the whole document with them — so unless
/// applySpeakerChannel resets bodies on every pass, one reload with the caret
/// at a colored head paints every body in that speaker's color (the
/// all-green-transcript bug).
@MainActor
struct TranscriptSpeakerChannelTests {

    private func makeTextView(_ text: String) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.string = text
        return tv
    }

    @Test("bodies return to label color even when pre-painted")
    func bodiesResetToLabelColor() throws {
        let text = "Speaker 1: hello there\nSpeaker 2: general kenobi"
        let tv = makeTextView(text)
        let storage = try #require(tv.textStorage)

        // Simulate the corrupted state: everything painted in a head color,
        // as a typing-attributes-styled reload used to leave it.
        storage.addAttribute(
            .foregroundColor,
            value: NSColor.systemGreen,
            range: NSRange(location: 0, length: (text as NSString).length)
        )

        TranscriptDetailEditor.applySpeakerChannel(to: tv)

        // A body character (inside "hello") is plain label color again…
        let bodyColor = storage.attribute(
            .foregroundColor, at: 15, effectiveRange: nil
        ) as? NSColor
        #expect(bodyColor == NSColor.labelColor)

        // …while the head keeps its speaker color.
        let headColor = storage.attribute(
            .foregroundColor, at: 0, effectiveRange: nil
        ) as? NSColor
        #expect(headColor == TranscriptDetailEditor.speakerColor(for: "Speaker 1"))
        #expect(headColor != NSColor.labelColor)
    }

    @Test("typing attributes are pinned to plain after applying the channel")
    func typingAttributesStayPlain() {
        let tv = makeTextView("Speaker 1: hello there")
        tv.setSelectedRange(NSRange(location: 0, length: 0))  // caret on the colored head
        TranscriptDetailEditor.applySpeakerChannel(to: tv)

        let typingColor = tv.typingAttributes[.foregroundColor] as? NSColor
        #expect(typingColor == NSColor.labelColor)
    }
}
