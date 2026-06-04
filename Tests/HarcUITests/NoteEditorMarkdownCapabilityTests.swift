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

    @Test("note detail uses Source, WYSIWYG Edit, and rendered Preview surfaces")
    func noteDetailUsesExpectedEditorModeSurfaces() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/HarcUI/HarcWindowRootView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("case .source:"))
        #expect(source.contains("case .live:"))
        #expect(source.contains("NoteMarkdownWebView(text: noteBodyBinding"))
        #expect(source.contains("mode: .source"))
        #expect(source.contains("mode: .live"))
        #expect(source.contains("private static let noteWritingModes: [NoteMarkdownEditorMode] = [.live, .source]"))
        #expect(source.contains(#".accessibilityIdentifier("harc.note.writingModePicker")"#))
        #expect(source.contains(#".accessibilityIdentifier("harc.note.previewToggle")"#))
        #expect(source.contains("showsFormattingRibbon: prefs.markdownFormattingRibbonEnabled"))
        #expect(source.contains(#".accessibilityIdentifier("harc.note.markdownTextEditor")"#))
        #expect(source.contains(#".accessibilityIdentifier("harc.note.liveMarkdownEditor")"#))
        #expect(!source.contains("HStack(spacing: 0) {\n                noteTextEditorSurface(font: .body)"))
        #expect(source.contains("case .read:"))
        #expect(source.contains("mode: .read"))
        #expect(source.contains(#".accessibilityIdentifier("harc.note.markdownPreview")"#))
    }

    @Test("note editor source keeps Milkdown Markdown and app bridge capabilities")
    func noteEditorSourceKeepsMilkdownMarkdownAndAppBridgeCapabilities() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/HarcUI/Resources/NoteEditor/editor-entry.js"
            ),
            encoding: .utf8
        )

        let requiredSnippets = [
            #"import {Editor, defaultValueCtx, editorViewCtx, rootCtx, serializerCtx} from "@milkdown/kit/core";"#,
            #"import {commonmark} from "@milkdown/kit/preset/commonmark";"#,
            #"import MarkdownIt from "markdown-it";"#,
            "window.webkit?.messageHandlers?.harc?.postMessage",
            "window.HarcEditor =",
            "setText(text)",
            "getText()",
            "setMode(mode)",
            "flushChanges()",
            "setChangeCommitDelay(milliseconds)",
            "changeCommitDelay = 180",
            "flushPendingChange",
            "setAttachmentBaseURL(url)",
            "setFormattingRibbonVisible(isVisible)",
            "insertMarkdown(markdown)",
            "runMarkdownCommand(command)",
            "wrapSelection(prefix",
            "transformSelectedLines(transform)",
            "updateFormattingRibbonVisibility()",
            "renderPreview(markdown)",
            "markdownRenderer.render",
            "renderTaskLists(html)",
            "showAttachmentError(message)",
            "setLinkTargets(targets)",
            "setMentionTargets(targets)",
            "maybeShowCompletions",
            "showCompletions(matches, isWiki)",
            "typedMentionInsertText",
            "completion-project",
            #"!["source", "live", "read"].includes(mode)"#,
            "Editor.make()",
            "commonmark",
            "replaceAll(markdown)",
            "serializeMilkdown()",
            "sourceElement",
            "source-editor",
            "harc-context-block",
            "readClipboardImage(file)",
            "requestNativePasteboardImage()",
            #"type: "nativePasteboardImage""#,
            #"type: "pasteImage""#,
            "resolveAttachmentURL(path)",
            "decorateMilkdownSurface",
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

        #expect(css.contains(".ProseMirror"))
        #expect(css.contains("#source-editor"))
        #expect(css.contains("cm-entity-mention"))
        #expect(css.contains("completion-project"))
        #expect(css.contains("#format-ribbon"))
        #expect(css.contains(".ribbon-separator"))
        #expect(css.contains("#preview"))
        #expect(css.contains(".ProseMirror img"))
        #expect(css.contains("#preview hr"))
        #expect(css.contains("#preview table"))
        #expect(css.contains(".md-task-checkbox"))
        #expect(css.contains(".attachment-error"))
        #expect(css.contains("#completion-popover"))
    }

    @Test("note editor routes native macOS screenshot paste through Swift pasteboard")
    func noteEditorRoutesNativeMacOSScreenshotPasteThroughSwiftPasteboard() throws {
        let webViewSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/HarcUI/Notes/NoteMarkdownWebView.swift"),
            encoding: .utf8
        )
        let editorSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/HarcUI/Resources/NoteEditor/editor-entry.js"
            ),
            encoding: .utf8
        )
        let bundle = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/HarcUI/Resources/NoteEditor/editor.bundle.js"
            ),
            encoding: .utf8
        )

        #expect(webViewSource.contains(#"case "nativePasteboardImage":"#))
        #expect(webViewSource.contains("override func doCommand(by selector: Selector)"))
        #expect(webViewSource.contains(#"selector == #selector(NSText.paste(_:))"#))
        #expect(editorSource.contains("requestNativePasteboardImage();"))
        #expect(editorSource.contains(#"type: "nativePasteboardImage""#))
        #expect(bundle.contains("requestNativePasteboardImage();"))
        #expect(bundle.contains(#"type: "nativePasteboardImage""#))
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
        #expect(html.contains(#"<nav id="format-ribbon" aria-label="Markdown formatting" hidden>"#))
        #expect(html.contains(#"data-md-command="bold""#))
        #expect(html.contains(#"data-md-command="task-list""#))
        #expect(html.contains(#"data-md-command="table""#))
        #expect(html.contains(#"<textarea id="source-editor" aria-label="Raw Markdown note editor""#))
        #expect(html.contains(#"<main id="preview" aria-label="Markdown note preview" hidden></main>"#))
        #expect(html.contains(#"<link rel="stylesheet" href="./style.css" />"#))
        #expect(html.contains(#"<script src="./editor.bundle.js"></script>"#))
        #expect(!html.contains("https://"))
    }
}
