import Testing
import AppKit
import HarcUI

@Suite("SelectionContextReader")
@MainActor
struct SelectionContextReaderTests {
    /// Fully stubbed environment; individual tests override pieces.
    private func stubEnvironment(
        trusted: Bool = true,
        selectedText: String? = nil,
        frontmostApp: (name: String?, bundleID: String?)? = (name: "TestApp", bundleID: "com.example.test"),
        clipboard: String? = nil
    ) -> SelectionContextReader.Environment {
        SelectionContextReader.Environment(
            isAXTrusted: { trusted },
            focusedSelectedText: { selectedText },
            frontmostApp: { frontmostApp },
            clipboardString: { clipboard }
        )
    }

    // MARK: - Selected text via stubbed AX

    @Test("captures selected text when trusted and an element has a selection")
    func selectedTextCaptured() {
        let env = stubEnvironment(selectedText: "hello selection", clipboard: "clip")
        let ctx = SelectionContextReader.capture(selectedText: true, clipboard: true, environment: env)
        #expect(ctx.selectedText == "hello selection")
        #expect(ctx.clipboardText == "clip")
        #expect(ctx.frontmostAppName == "TestApp")
        #expect(ctx.frontmostBundleID == "com.example.test")
    }

    @Test("untrusted process yields nil selected text without invoking the AX read")
    func untrustedYieldsNilSelection() {
        var axReadInvoked = false
        let env = SelectionContextReader.Environment(
            isAXTrusted: { false },
            focusedSelectedText: {
                axReadInvoked = true
                return "should never be read"
            },
            frontmostApp: { (name: "TestApp", bundleID: "com.example.test") },
            clipboardString: { nil }
        )
        let ctx = SelectionContextReader.capture(selectedText: true, clipboard: false, environment: env)
        #expect(ctx.selectedText == nil)
        #expect(!axReadInvoked)
        // App info still captured — it needs no permission.
        #expect(ctx.frontmostBundleID == "com.example.test")
    }

    @Test("no focused element / unsupported attribute (AX read returns nil) yields nil")
    func axFailureYieldsNil() {
        let env = stubEnvironment(selectedText: nil)
        let ctx = SelectionContextReader.capture(selectedText: true, clipboard: false, environment: env)
        #expect(ctx.selectedText == nil)
    }

    @Test("empty or whitespace-only AX selection is normalized to nil")
    func emptySelectionNormalized() {
        let env = stubEnvironment(selectedText: "  \n ")
        let ctx = SelectionContextReader.capture(selectedText: true, clipboard: false, environment: env)
        #expect(ctx.selectedText == nil)
    }

    // MARK: - Flags gate the reads

    @Test("flags off → selection and clipboard nil even when sources have content")
    func flagsOffLeaveFieldsNil() {
        var selectionRead = false
        var clipboardRead = false
        let env = SelectionContextReader.Environment(
            isAXTrusted: { true },
            focusedSelectedText: {
                selectionRead = true
                return "selection"
            },
            frontmostApp: { (name: "TestApp", bundleID: "com.example.test") },
            clipboardString: {
                clipboardRead = true
                return "clipboard"
            }
        )
        let ctx = SelectionContextReader.capture(selectedText: false, clipboard: false, environment: env)
        #expect(ctx.selectedText == nil)
        #expect(ctx.clipboardText == nil)
        #expect(!selectionRead)
        #expect(!clipboardRead)
        // Frontmost app is still recorded.
        #expect(ctx.frontmostAppName == "TestApp")
    }

    // MARK: - Clipboard read path (real NSPasteboard, private name)

    @Test("clipboard read uses NSPasteboard string(forType:) semantics")
    func clipboardReadPath() {
        // A uniquely named pasteboard so the user's general clipboard is
        // never touched. The environment closure exercises the same
        // string(forType:) call the live environment makes.
        let name = NSPasteboard.Name("harc-tests-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("from the test pasteboard", forType: .string)

        let env = SelectionContextReader.Environment(
            isAXTrusted: { false },
            focusedSelectedText: { nil },
            frontmostApp: { nil },
            clipboardString: { pasteboard.string(forType: .string) }
        )
        let ctx = SelectionContextReader.capture(selectedText: false, clipboard: true, environment: env)
        #expect(ctx.clipboardText == "from the test pasteboard")
    }

    @Test("empty clipboard yields nil")
    func emptyClipboardYieldsNil() {
        let env = stubEnvironment(clipboard: nil)
        let ctx = SelectionContextReader.capture(selectedText: false, clipboard: true, environment: env)
        #expect(ctx.clipboardText == nil)
    }

    // MARK: - Frontmost app

    @Test("no frontmost application leaves app fields nil")
    func noFrontmostApp() {
        let env = stubEnvironment(frontmostApp: nil)
        let ctx = SelectionContextReader.capture(selectedText: false, clipboard: false, environment: env)
        #expect(ctx.frontmostAppName == nil)
        #expect(ctx.frontmostBundleID == nil)
        #expect(ctx.isEmpty)
    }

    // MARK: - End-to-end into promptBlock

    @Test("captured context renders a prompt block")
    func captureRendersPromptBlock() throws {
        let env = stubEnvironment(selectedText: "quarterly numbers", clipboard: "meeting notes")
        let ctx = SelectionContextReader.capture(selectedText: true, clipboard: true, environment: env)
        let block = try #require(ctx.promptBlock)
        #expect(block.contains("quarterly numbers"))
        #expect(block.contains("meeting notes"))
        #expect(block.contains("TestApp"))
    }
}
