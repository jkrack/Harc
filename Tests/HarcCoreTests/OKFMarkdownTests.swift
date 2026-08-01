import Testing
import Foundation
@testable import HarcCore

@Suite("OKFMarkdown")
struct OKFMarkdownTests {

    @Test("render emits frontmatter, sections in order, and trailing newline")
    func renderFull() {
        let md = OKFMarkdown.render(OKFMarkdown.Fields(
            title: "Sync · pricing",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            wavFileName: "09-00-00.wav",
            tags: ["Amy", "Jason"],
            summaryMarkdown: "We decided things.",
            actionItemsMarkdown: "- [ ] Amy: ship it",
            transcript: "Amy: hello\n\nJason: hi"
        ))
        #expect(md.hasPrefix("---\ntype: Meeting Transcript\ntitle: \"Sync · pricing\"\n"))
        #expect(md.contains("resource: ./09-00-00.wav"))
        #expect(md.contains("tags: [\"Amy\", \"Jason\"]"))
        #expect(md.contains("\n## Summary\n\nWe decided things."))
        #expect(md.contains("\n## Action Items\n\n- [ ] Amy: ship it"))
        #expect(md.hasSuffix("## Transcript\n\nAmy: hello\n\nJason: hi\n"))
    }

    @Test("render omits empty summary/action/tag sections")
    func renderMinimal() {
        let md = OKFMarkdown.render(OKFMarkdown.Fields(
            title: "T",
            transcript: "words"
        ))
        #expect(!md.contains("## Summary"))
        #expect(!md.contains("## Action Items"))
        #expect(!md.contains("tags:"))
        #expect(!md.contains("resource:"))
    }

    @Test("titles with quotes and newlines are YAML-safe")
    func yamlEscaping() {
        let md = OKFMarkdown.render(OKFMarkdown.Fields(
            title: "He said \"go\"\nnow",
            transcript: "x"
        ))
        #expect(md.contains(#"title: "He said \"go\" now""#))
    }

    @Test("render places ## Notes between Action Items and Transcript")
    func renderNotesOrdering() {
        let md = OKFMarkdown.render(OKFMarkdown.Fields(
            title: "T",
            summaryMarkdown: "Sum",
            actionItemsMarkdown: "- [ ] do",
            notesMarkdown: "extra context here",
            transcript: "words"
        ))
        let actions = md.range(of: "## Action Items")!.lowerBound
        let notes = md.range(of: "## Notes")!.lowerBound
        let transcript = md.range(of: "## Transcript")!.lowerBound
        #expect(actions < notes)
        #expect(notes < transcript)
        #expect(md.contains("## Notes\n\nextra context here"))

        // Empty notes render no section.
        let bare = OKFMarkdown.render(OKFMarkdown.Fields(title: "T", transcript: "x"))
        #expect(!bare.contains("## Notes"))
    }

    @Test("renderSession emits type, member list, and no transcript section")
    func renderSession() {
        let md = OKFMarkdown.renderSession(OKFMarkdown.SessionFields(
            title: "Offsite day",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tags: ["Amy"],
            summaryMarkdown: "Everything combined.",
            actionItemsMarkdown: "- [ ] follow up",
            recordings: [
                .init(fileName: "10-00-00.md", title: "Standup", detail: "10:00 AM · 15 min"),
                .init(fileName: "14-00-00.md", title: "Retro"),
            ]
        ))
        #expect(md.hasPrefix("---\ntype: Session\ntitle: \"Offsite day\"\n"))
        #expect(md.contains("recordings:\n  - ./10-00-00.md\n  - ./14-00-00.md"))
        #expect(md.contains("\n## Summary\n\nEverything combined."))
        #expect(md.contains("\n## Action Items\n\n- [ ] follow up"))
        #expect(md.contains("\n## Recordings\n\n- [Standup](./10-00-00.md) — 10:00 AM · 15 min\n- [Retro](./14-00-00.md)"))
        #expect(!md.contains("## Transcript"))
    }

    @Test("regenerateDayIndex lists session docs after member docs")
    func dayIndexSessionOrdering() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("okf-session-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, title) in [
            ("10-00-00.md", "Standup"),
            ("14-00-00.md", "Retro"),
            ("session-10-00-00.md", "Offsite day"),
        ] {
            let content = "---\ntype: X\ntitle: \"\(title)\"\n---\nbody\n"
            try content.data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
        }
        OKFMarkdown.regenerateDayIndex(in: dir)

        let index = try String(
            contentsOf: dir.appendingPathComponent("index.md"), encoding: .utf8
        )
        let links = index.split(separator: "\n").filter { $0.hasPrefix("- [") }
        #expect(links.count == 3)
        #expect(links.last?.contains("session-10-00-00.md") == true)
        #expect(links.last?.contains("Offsite day") == true)
    }

    @Test("extractTranscript returns the transcript body")
    func extract() {
        let md = OKFMarkdown.render(OKFMarkdown.Fields(
            title: "T",
            summaryMarkdown: "Sum",
            transcript: "Amy: hello"
        ))
        #expect(OKFMarkdown.extractTranscript(from: md) == "Amy: hello")
    }

    @Test("extractTranscript survives '## Transcript' appearing in the summary")
    func extractShadowed() {
        let md = OKFMarkdown.render(OKFMarkdown.Fields(
            title: "T",
            summaryMarkdown: "Discussed the\n## Transcript\nheading itself.",
            transcript: "real body"
        ))
        #expect(OKFMarkdown.extractTranscript(from: md) == "real body")
    }

    @Test("extractTranscript is nil for non-OKF content")
    func extractForeign() {
        #expect(OKFMarkdown.extractTranscript(from: "just some text") == nil)
    }

    @Test("replacingTranscript preserves head, swaps body")
    func replace() {
        let md = OKFMarkdown.render(OKFMarkdown.Fields(
            title: "T",
            summaryMarkdown: "Sum",
            transcript: "old body"
        ))
        let replaced = OKFMarkdown.replacingTranscript(in: md, with: "new body")
        #expect(replaced != nil)
        #expect(replaced!.contains("## Summary\n\nSum"))
        #expect(OKFMarkdown.extractTranscript(from: replaced!) == "new body")
        #expect(!replaced!.contains("old body"))
    }

    @Test("day index lists documents by title, skips itself, deletes when empty")
    func dayIndex() throws {
        let base = URL(fileURLWithPath: "/tmp/harc-okf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let doc = base.appendingPathComponent("09-00-00.md")
        try OKFMarkdown.render(OKFMarkdown.Fields(title: "Standup", transcript: "x"))
            .write(to: doc, atomically: true, encoding: .utf8)

        OKFMarkdown.regenerateDayIndex(in: base)
        let indexURL = base.appendingPathComponent("index.md")
        let index = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(index.contains("- [Standup](./09-00-00.md)"))
        #expect(index.contains("type: Index"))

        // Regenerating must not list the index itself.
        OKFMarkdown.regenerateDayIndex(in: base)
        let again = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(!again.contains("(./index.md)"))

        // Removing the last document removes the index.
        try FileManager.default.removeItem(at: doc)
        OKFMarkdown.regenerateDayIndex(in: base)
        #expect(!FileManager.default.fileExists(atPath: indexURL.path))
    }
}
