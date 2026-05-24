import Foundation
import Testing
@testable import HarcUI

struct NoteEditorMarkdownCapabilityTests {
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("full Markdown capability fixture covers expected note syntax")
    func fullMarkdownCapabilityFixtureCoversExpectedSyntax() throws {
        let fixture = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/HarcUI/Resources/NoteEditor/Fixtures/full-markdown-capability.md"
            ),
            encoding: .utf8
        )

        let expectations: [(String, String)] = [
            ("h1", #"(?m)^# Meeting Notes$"#),
            ("h2", #"(?m)^## Decisions$"#),
            ("h3", #"(?m)^### Checklist$"#),
            ("paragraph", #"This paragraph checks"#),
            ("bold", #"\*\*bold\*\*"#),
            ("italic", #"(?<!\*)\*italic\*(?!\*)"#),
            ("bold italic", #"\*\*\*bold italic\*\*\*"#),
            ("inline code", #"`inline code`"#),
            ("strikethrough", #"~~strikethrough~~"#),
            ("wikilink", #"\[\[Michelle\]\]"#),
            ("bare person mention", #"@amy"#),
            ("bracketed person mention", #"@\[Amy Williams\]"#),
            ("typed person mention", #"@person\[Amy Williams\]"#),
            ("typed project mention", #"@project\[Q3 Launch\]"#),
            ("symbol gauntlet", #"Symbol gauntlet: ~ ! @ # \$ % \^ & \* \( \) _ \+ - = \{ \} \[ \] \| \\ : ; " ' < > , \. \? /"#),
            ("escaped literals", #"\\\*literal asterisk\\\* \\\[literal brackets\\\] \\\`literal tick\\\`"#),
            ("unordered list", #"(?m)^- Ship the local editor bundle\.$"#),
            ("checked task", #"(?m)^- \[x\] Record audio locally$"#),
            ("unchecked task", #"(?m)^- \[ \] Link a note to a recording$"#),
            ("blockquote", #"(?m)^> Speaker 1:"#),
            ("ordered list", #"(?m)^1\. First ordered item$"#),
            ("code fence", #"(?s)```swift.*sourceOfTruth.*```"#),
            ("table", #"(?m)^\| Field \| Expected \|$"#),
            ("table divider", #"(?m)^\| --- \| --- \|$"#),
            ("thematic break", #"(?m)^---$"#),
            ("harc context fence", #"(?s)```harc-context.*recording: recording:42.*timecode: 00:03:42.*speaker: Michelle.*```"#),
            ("external link", #"\[Harc repo\]\(https://github\.com/jkrack/Harc\)"#),
        ]

        for (name, pattern) in expectations {
            #expect(
                fixture.range(of: pattern, options: .regularExpression) != nil,
                "Missing Markdown capability fixture coverage for \(name)"
            )
        }
    }

    @Test("note editor mode labels distinguish editing from preview")
    func noteEditorModeLabelsDistinguishEditingFromPreview() {
        #expect(NoteMarkdownEditorMode.source.title == "Source")
        #expect(NoteMarkdownEditorMode.live.title == "Edit")
        #expect(NoteMarkdownEditorMode.read.title == "Preview")
    }

    @Test("note detail uses native TextEditor for editable modes")
    func noteDetailUsesNativeTextEditorForEditableModes() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/HarcUI/HarcWindowRootView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("case .source, .live:"))
        #expect(source.contains("TextEditor(text: Binding("))
        #expect(source.contains(#".accessibilityIdentifier("harc.note.markdownTextEditor")"#))
        #expect(source.contains("case .read:"))
        #expect(source.contains(#".accessibilityIdentifier("harc.note.markdownPreview")"#))
    }

    @Test("note editor source keeps CodeMirror Markdown and app bridge capabilities")
    func noteEditorSourceKeepsCodeMirrorMarkdownAndAppBridgeCapabilities() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/HarcUI/Resources/NoteEditor/editor-entry.js"
            ),
            encoding: .utf8
        )

        let requiredSnippets = [
            #"import {markdown} from "@codemirror/lang-markdown";"#,
            "window.webkit?.messageHandlers?.harc?.postMessage",
            "window.HarcEditor =",
            "setText(text)",
            "getText()",
            "setMode(mode)",
            "setAttachmentBaseURL(url)",
            "insertMarkdown(markdown)",
            "showAttachmentError(message)",
            "setLinkTargets(targets)",
            "setMentionTargets(targets)",
            "autocompletion",
            "wikilinkCompletions",
            "mentionCompletions",
            "mentionTargetMatches",
            "mentionTargetRank",
            "typedMentionInsertText",
            "mentionClass",
            #"from: typed || bracketed ? before.from + before.text.indexOf("[") + 1 : before.from + 1"#,
            "from: before.from, to, insert",
            "cm-person-mention",
            #"!["source", "live", "read"].includes(mode)"#,
            "cm-md-heading-${level}",
            "cm-md-syntax-hidden",
            "cm-wikilink",
            "cm-inline-code",
            "TaskCheckboxWidget",
            "ListMarkerWidget",
            "cm-md-bold",
            "cm-md-italic",
            "cm-md-strike",
            "cm-md-blockquote",
            "cm-md-list-marker",
            "cm-md-list-text",
            "cm-md-codeblock-line",
            "cm-md-context-line",
            "cm-md-table-line",
            "cm-md-hr",
            "ImageAttachmentWidget",
            "const imageLink =",
            "readClipboardImage(file)",
            #"type: "pasteImage""#,
            "resolveAttachmentURL(path)",
            "cm-md-image",
            "attachment-error",
        ]

        for snippet in requiredSnippets {
            #expect(
                source.contains(snippet),
                "Missing note editor capability hook: \(snippet)"
            )
        }

        let css = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/HarcUI/Resources/NoteEditor/style.css"
            ),
            encoding: .utf8
        )

        #expect(css.contains("cm-entity-mention"))
        #expect(css.contains("cm-project-mention"))
        #expect(css.contains(".cm-md-image"))
        #expect(css.contains(".cm-md-image img"))
        #expect(css.contains(".attachment-error"))
    }

    @Test("note editor HTML loads only bundled local assets")
    func noteEditorHTMLLoadsOnlyBundledLocalAssets() throws {
        let html = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/HarcUI/Resources/NoteEditor/index.html"
            ),
            encoding: .utf8
        )

        #expect(html.contains(#"default-src 'self'"#))
        #expect(html.contains(#"<link rel="stylesheet" href="./style.css" />"#))
        #expect(html.contains(#"<script src="./editor.bundle.js"></script>"#))
        #expect(!html.contains("https://"))
    }
}
