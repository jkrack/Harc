import Testing
import Foundation
import AppKit
@testable import HarcExport

@Suite("DocxExporter")
struct DocxExporterTests {
    private func input(segments: [ExportInput.Segment]) -> ExportInput {
        ExportInput(
            title: "Team sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 125,
            segments: segments
        )
    }

    @Test("produces a non-empty docx with ZIP magic bytes")
    func producesZipBytes() throws {
        let data = try DocxExporter.render(input(segments: [
            .init(speaker: 0, text: "Hello."),
            .init(speaker: 1, text: "Hi."),
        ]))
        #expect(data.count > 100)
        let head = Array(data.prefix(4))
        #expect(head == [0x50, 0x4B, 0x03, 0x04])
    }

    @Test("empty segments still produces a valid docx")
    func emptyIsValid() throws {
        let data = try DocxExporter.render(input(segments: []))
        #expect(data.count > 100)
        let head = Array(data.prefix(4))
        #expect(head == [0x50, 0x4B, 0x03, 0x04])
    }

    @Test("plain-text round-trip preserves content")
    func roundTripContent() throws {
        let data = try DocxExporter.render(input(segments: [
            .init(speaker: 0, text: "Ship it."),
        ]))
        var docAttrs: NSDictionary? = nil
        let decoded = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: &docAttrs
        )
        #expect(decoded.string.contains("Ship it."))
        #expect(decoded.string.contains("Speaker 1"))
    }
}
