import Testing
import Foundation
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
}
