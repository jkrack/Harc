import Testing
import Foundation
@testable import HarcExport

@Suite("MarkdownExporter")
struct MarkdownExporterTests {
    private func input(segments: [ExportInput.Segment]) -> ExportInput {
        ExportInput(title: "t", startedAt: Date(), durationSeconds: nil, segments: segments)
    }

    @Test("diarized: speaker-prefixed flat lines")
    func diarized() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 0, text: "We should ship this next week."),
            .init(speaker: 1, text: "Agreed, let's scope the dependencies."),
            .init(speaker: 0, text: "I'll file the tickets tonight."),
        ]))
        #expect(result == """
            Speaker 1: We should ship this next week.
            Speaker 2: Agreed, let's scope the dependencies.
            Speaker 1: I'll file the tickets tonight.

            """)
    }

    @Test("zero speakers: plain paragraph, no prefix")
    func plain() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: nil, text: "A run-on paragraph with no turns."),
        ]))
        #expect(result == "A run-on paragraph with no turns.\n")
    }

    @Test("single speaker still prefixed")
    func singleSpeaker() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 2, text: "Solo."),
        ]))
        #expect(result == "Speaker 3: Solo.\n")
    }

    @Test("empty segments → empty output")
    func empty() {
        #expect(MarkdownExporter.render(input(segments: [])) == "")
    }

    @Test("special chars pass through unescaped")
    func specialCharsPassThrough() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 0, text: "I love C# and *bold* text and #channels."),
        ]))
        #expect(result.contains("C# and *bold* text and #channels"))
    }

    @Test("\\r\\n normalised to \\n")
    func crlfNormalised() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 0, text: "line 1\r\nline 2"),
        ]))
        #expect(!result.contains("\r"))
    }

    @Test("control chars stripped")
    func controlCharsStripped() {
        let text = "hello\u{0000}\u{0001}world"
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: nil, text: text),
        ]))
        #expect(result.contains("helloworld"))
        #expect(!result.contains("\u{0000}"))
    }

    @Test("override names replace Speaker N in the body")
    func overrideNamesRender() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            tags: [],
            speakerNames: [0: "Jason", 1: "Amy"],
            segments: [
                .init(speaker: 0, text: "morning"),
                .init(speaker: 1, text: "hey"),
            ]
        )
        let out = MarkdownExporter.render(input)
        #expect(out.contains("Jason: morning"))
        #expect(out.contains("Amy: hey"))
        #expect(!out.contains("Speaker 1:"))
        #expect(!out.contains("Speaker 2:"))
    }

    @Test("partial override mixes names and Speaker N fallback")
    func partialOverride() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            tags: [],
            speakerNames: [0: "Jason"],
            segments: [
                .init(speaker: 0, text: "morning"),
                .init(speaker: 1, text: "hey"),
            ]
        )
        let out = MarkdownExporter.render(input)
        #expect(out.contains("Jason: morning"))
        #expect(out.contains("Speaker 2: hey"))
    }
}
