import AppKit
import Testing
@testable import HarcUI

@MainActor
struct TranscriptPlaybackHitTests {
    @Test("Playback hit testing accepts visible text and rejects empty space")
    func textAndWhitespace() throws {
        let view = CmdClickTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.string = "Amy: hello world"
        view.font = .systemFont(ofSize: 14)
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: 6)
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = NSPoint(x: bounds.midX + view.textContainerOrigin.x,
                            y: bounds.midY + view.textContainerOrigin.y)
        #expect(view.playbackCharacterOffset(at: point) == 6)
        #expect(view.playbackCharacterOffset(at: NSPoint(x: 450, y: point.y)) == nil)
        #expect(view.playbackCharacterOffset(at: NSPoint(x: 20, y: 250)) == nil)
    }
}
