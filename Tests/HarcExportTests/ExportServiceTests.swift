import Testing
import Foundation
import AppKit
import HarcStore
@testable import HarcExport

@Suite("ExportService")
struct ExportServiceTests {
    @Test("defaultDestination uses the wav stem + format ext")
    func defaultDestination() {
        let rec = Recording(
            wavPath: "/tmp/harc/2026/2026-04-19/10-00-00.wav",
            startedAt: Date()
        )
        let md = ExportService.defaultDestination(for: rec, format: .markdown)
        let dx = ExportService.defaultDestination(for: rec, format: .docx)
        #expect(md.path == "/tmp/harc/2026/2026-04-19/10-00-00.md")
        #expect(dx.path == "/tmp/harc/2026/2026-04-19/10-00-00.docx")
    }

    @Test("writes a Markdown file to the given url")
    func writesMarkdown() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(
            wavPath: tmp.appendingPathComponent("x.wav").path,
            startedAt: Date(),
            transcriptText: "hello world"
        )
        let target = tmp.appendingPathComponent("x.md")
        try ExportService.write(recording: rec, format: .markdown, to: target)
        let contents = try String(contentsOf: target, encoding: .utf8)
        #expect(contents.contains("hello world"))
    }

    @Test("write .markdown includes summary, action items, and transcript when requested")
    func writesMarkdownWithSummary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: tmp.appendingPathComponent("x.wav").path,
            startedAt: date,
            transcriptText: "hello transcript",
            summaryMarkdown: "The team agreed.",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 2
        )
        let target = tmp.appendingPathComponent("x.md")
        try ExportService.write(recording: rec, format: .markdown, to: target)
        let contents = try String(contentsOf: target, encoding: .utf8)

        guard let summaryIdx = contents.range(of: "## Summary"),
              let actionIdx = contents.range(of: "## Action Items"),
              let transcriptIdx = contents.range(of: "## Transcript"),
              let bodyIdx = contents.range(of: "hello transcript") else {
            Issue.record("expected summary/action/transcript sections"); return
        }
        #expect(summaryIdx.lowerBound < actionIdx.lowerBound)
        #expect(actionIdx.lowerBound < transcriptIdx.lowerBound)
        #expect(transcriptIdx.lowerBound < bodyIdx.lowerBound)
        #expect(contents.contains("The team agreed."))
        #expect(contents.contains("- [ ] Jason: ship it"))
    }

    @Test("write .markdown can exclude summary explicitly")
    func writesMarkdownWithoutSummaryWhenExcluded() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: tmp.appendingPathComponent("x.wav").path,
            startedAt: date,
            transcriptText: "hello transcript",
            summaryMarkdown: "The team agreed.",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 2
        )
        let target = tmp.appendingPathComponent("x.md")
        try ExportService.write(recording: rec, format: .markdown, to: target, includeSummary: false)
        let contents = try String(contentsOf: target, encoding: .utf8)
        #expect(!contents.contains("## Summary"))
        #expect(!contents.contains("## Action Items"))
        #expect(!contents.contains("## Transcript"))
        #expect(contents.contains("hello transcript"))
    }

    @Test("write .docx includes summary, action items, and transcript when requested")
    func writesDocxWithSummary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: tmp.appendingPathComponent("x.wav").path,
            startedAt: date,
            transcriptText: "hello transcript",
            summaryMarkdown: "The team agreed.",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 2
        )
        let target = tmp.appendingPathComponent("x.docx")
        try ExportService.write(recording: rec, format: .docx, to: target)
        let data = try Data(contentsOf: target)
        var docAttrs: NSDictionary? = nil
        let decoded = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: &docAttrs
        ).string

        #expect(decoded.contains("Summary"))
        #expect(decoded.contains("The team agreed."))
        #expect(decoded.contains("Action Items"))
        #expect(decoded.contains("- [ ] Jason: ship it"))
        #expect(decoded.contains("Transcript"))
        #expect(decoded.contains("hello transcript"))
    }

    @Test("markdownString returns the renderer output")
    func markdownString() {
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(),
            transcriptText: "clipboard paste"
        )
        let s = ExportService.markdownString(for: rec)
        #expect(s.contains("clipboard paste"))
    }

    @Test("promptString = PromptFrontMatter.render + blank line + MarkdownExporter.render")
    func promptStringComposesHeaderAndBody() {
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptText: "hello body",
            tags: ["Acme"]
        )
        let input = ExportInputBuilder.build(from: rec)
        let expectedHeader = PromptFrontMatter.render(input)
        let expectedBody = MarkdownExporter.render(input)
        let prompt = ExportService.promptString(for: rec)
        #expect(prompt == expectedHeader + "\n\n" + expectedBody)
    }

    @Test("promptString — empty body yields header + single trailing newline")
    func promptStringEmptyBody() {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let prompt = ExportService.promptString(for: rec)
        let input = ExportInputBuilder.build(from: rec)
        let header = PromptFrontMatter.render(input)
        #expect(prompt == header + "\n")
        #expect(!prompt.contains("\n\n"))
    }

    @Test("defaultDestination for .prompt uses <stem>.prompt.md in the recording folder")
    func defaultDestinationPrompt() {
        let rec = Recording(
            wavPath: "/tmp/harc/2026/2026-04-19/10-00-00.wav",
            startedAt: Date()
        )
        let url = ExportService.defaultDestination(for: rec, format: .prompt)
        #expect(url.path == "/tmp/harc/2026/2026-04-19/10-00-00.prompt.md")
    }

    @Test("write .prompt writes the promptString bytes atomically")
    func writesPrompt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(
            wavPath: tmp.appendingPathComponent("x.wav").path,
            startedAt: Date(),
            transcriptText: "hello prompt",
            tags: ["demo"]
        )
        let target = tmp.appendingPathComponent("x.prompt.md")
        try ExportService.write(recording: rec, format: .prompt, to: target)
        let contents = try String(contentsOf: target, encoding: .utf8)
        #expect(contents == ExportService.promptString(for: rec))
        #expect(contents.hasPrefix("---\n"))
        #expect(contents.contains("tags: demo"))
        #expect(contents.contains("hello prompt"))
    }

    @Test("promptString with includeSummary=true and summary present inserts summary + action items + ## Transcript before body")
    func promptStringSummaryPresent() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: date,
            transcriptText: "Hello world",
            summaryMarkdown: "The team agreed.",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 2
        )
        let out = ExportService.promptString(for: rec, includeSummary: true)

        #expect(out.contains("summary_model: gemma-4-e2b-it-4bit"))
        #expect(out.contains("summarized_at:"))

        guard let summaryIdx = out.range(of: "## Summary"),
              let actionIdx = out.range(of: "## Action Items"),
              let transcriptIdx = out.range(of: "## Transcript"),
              let bodyIdx = out.range(of: "Hello world") else {
            Issue.record("expected headings + body"); return
        }
        #expect(summaryIdx.lowerBound < actionIdx.lowerBound)
        #expect(actionIdx.lowerBound < transcriptIdx.lowerBound)
        #expect(transcriptIdx.lowerBound < bodyIdx.lowerBound)

        #expect(out.contains("The team agreed."))
        #expect(out.contains("- [ ] Jason: ship it"))
    }

    @Test("promptString with includeSummary=false drops summary block even when columns are present")
    func promptStringSummaryExcluded() {
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: date,
            transcriptText: "Hello world",
            summaryMarkdown: "The team agreed.",
            actionItemsMarkdown: "- [ ] Jason: ship it",
            summaryModelID: "gemma-4-e2b-it-4bit",
            summaryGeneratedAt: date,
            summarySourceWordCount: 2
        )
        let out = ExportService.promptString(for: rec, includeSummary: false)
        #expect(!out.contains("## Summary"))
        #expect(!out.contains("## Action Items"))
        #expect(!out.contains("## Transcript"))
        #expect(!out.contains("summary_model:"))
        #expect(!out.contains("summarized_at:"))
        #expect(out.contains("Hello world"))
    }

    @Test("promptString with summary absent is byte-identical regardless of includeSummary flag")
    func promptStringSummaryAbsentIdempotent() {
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            transcriptText: "Hello"
        )
        let withFlag = ExportService.promptString(for: rec, includeSummary: true)
        let withoutFlag = ExportService.promptString(for: rec, includeSummary: false)
        let legacy = ExportService.promptString(for: rec)
        #expect(withFlag == withoutFlag)
        #expect(withFlag == legacy)
        #expect(!withFlag.contains("## Summary"))
        #expect(!withFlag.contains("## Transcript"))
    }
}
