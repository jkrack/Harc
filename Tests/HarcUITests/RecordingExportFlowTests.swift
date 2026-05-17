import Foundation
import HarcStore
import Testing
@testable import HarcUI

@Suite("RecordingExportFlow")
struct RecordingExportFlowTests {
    @Test("export draft previews the filename for the selected format")
    func defaultFilenameFollowsSelectedFormat() {
        let recording = Recording(
            wavPath: "/tmp/harc/Team Sync.wav",
            startedAt: Date(timeIntervalSince1970: 0),
            transcriptText: "Hello"
        )

        #expect(RecordingExportDraft(option: .markdown).defaultFilename(for: recording) == "Team Sync.md")
        #expect(RecordingExportDraft(option: .docx).defaultFilename(for: recording) == "Team Sync.docx")
        #expect(RecordingExportDraft(option: .prompt).defaultFilename(for: recording) == "Team Sync.prompt.md")
    }

    @Test("export options explain the resulting artifact")
    func optionsExposeDescriptions() {
        #expect(RecordingExportOption.markdown.title == "Markdown")
        #expect(RecordingExportOption.markdown.description.contains("transcript"))
        #expect(RecordingExportOption.docx.description.contains("summary"))
        #expect(RecordingExportOption.prompt.description.contains("LLM"))
    }

    @Test("draft keeps the include summary choice separate from format")
    func includeSummaryChoicePersistsAcrossFormatChanges() {
        var draft = RecordingExportDraft(option: .markdown, includeSummary: false)

        draft.option = .prompt

        #expect(draft.format == .prompt)
        #expect(draft.includeSummary == false)
    }
}
