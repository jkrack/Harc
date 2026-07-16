import Testing
import Foundation
import HarcUI

@Suite("DictationContext")
struct DictationContextTests {
    // MARK: - promptBlock rendering

    @Test("all fields render in order: app, selection, clipboard")
    func allFieldsRender() throws {
        let context = DictationContext(
            selectedText: "pick me",
            clipboardText: "copied earlier",
            frontmostAppName: "Safari",
            frontmostBundleID: "com.apple.Safari"
        )
        let block = try #require(context.promptBlock)

        #expect(block.hasPrefix("## Context"))
        #expect(block.contains("Active app: Safari (com.apple.Safari)"))
        #expect(block.contains("Selected text:\n\"\"\"\npick me\n\"\"\""))
        #expect(block.contains("Clipboard:\n\"\"\"\ncopied earlier\n\"\"\""))

        let appIndex = try #require(block.range(of: "Active app:")).lowerBound
        let selIndex = try #require(block.range(of: "Selected text:")).lowerBound
        let clipIndex = try #require(block.range(of: "Clipboard:")).lowerBound
        #expect(appIndex < selIndex)
        #expect(selIndex < clipIndex)
    }

    @Test("empty fields are omitted")
    func someFieldsRender() throws {
        let context = DictationContext(
            selectedText: nil,
            clipboardText: "just the clipboard",
            frontmostAppName: "Notes",
            frontmostBundleID: nil
        )
        let block = try #require(context.promptBlock)

        #expect(block.contains("Active app: Notes"))
        #expect(!block.contains("("))
        #expect(!block.contains("Selected text:"))
        #expect(block.contains("Clipboard:"))
    }

    @Test("bundle ID alone still renders an app line")
    func bundleIDOnlyAppLine() throws {
        let context = DictationContext(frontmostBundleID: "com.apple.dt.Xcode")
        let block = try #require(context.promptBlock)
        #expect(block.contains("Active app: com.apple.dt.Xcode"))
    }

    @Test("no fields → nil promptBlock and isEmpty")
    func noFields() {
        #expect(DictationContext.empty.promptBlock == nil)
        #expect(DictationContext.empty.isEmpty)
    }

    @Test("whitespace-only fields count as empty")
    func whitespaceOnlyIsEmpty() {
        let context = DictationContext(
            selectedText: "   \n  ",
            clipboardText: "\t",
            frontmostAppName: " ",
            frontmostBundleID: ""
        )
        #expect(context.isEmpty)
        #expect(context.promptBlock == nil)
    }

    // MARK: - Truncation

    @Test("long fields are capped with a truncation marker")
    func truncation() throws {
        let long = String(repeating: "x", count: DictationContext.fieldCharacterCap + 500)
        let context = DictationContext(selectedText: long)
        let block = try #require(context.promptBlock)

        #expect(block.contains("(truncated to \(DictationContext.fieldCharacterCap) characters)"))
        // The rendered body carries exactly the cap, not the full text.
        #expect(!block.contains(String(repeating: "x", count: DictationContext.fieldCharacterCap + 1)))
        #expect(block.contains(String(repeating: "x", count: DictationContext.fieldCharacterCap)))
    }

    @Test("fields at or below the cap carry no truncation marker")
    func noTruncationMarkerWhenShort() throws {
        let exact = String(repeating: "y", count: DictationContext.fieldCharacterCap)
        let context = DictationContext(clipboardText: exact)
        let block = try #require(context.promptBlock)
        #expect(!block.contains("truncated"))
        #expect(block.contains(exact))
    }

    @Test("each field is truncated independently")
    func independentTruncation() throws {
        let cap = DictationContext.fieldCharacterCap
        let context = DictationContext(
            selectedText: String(repeating: "a", count: cap + 1),
            clipboardText: "short"
        )
        let block = try #require(context.promptBlock)
        let markers = block.components(separatedBy: "(truncated to").count - 1
        #expect(markers == 1)
        #expect(block.contains("short"))
    }
}
