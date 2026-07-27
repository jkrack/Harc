import AppKit
import HarcExport
import HarcStore
import SwiftUI
import UniformTypeIdentifiers

enum RecordingExportOption: String, CaseIterable, Identifiable {
    case markdown
    case docx
    case prompt

    var id: String { rawValue }

    var format: ExportFormat {
        switch self {
        case .markdown: return .markdown
        case .docx: return .docx
        case .prompt: return .prompt
        }
    }

    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .docx: return "DOCX"
        case .prompt: return "LLM Prompt"
        }
    }

    var description: String {
        switch self {
        case .markdown:
            return "Clean transcript Markdown for sharing and long-term storage."
        case .docx:
            return "Word document with transcript content and optional summary sections."
        case .prompt:
            return "Markdown with front matter tuned for pasting into an LLM."
        }
    }

    var iconName: String {
        switch self {
        case .markdown: return "doc.plaintext"
        case .docx: return "doc.richtext"
        case .prompt: return "sparkles"
        }
    }
}

struct RecordingExportDraft: Equatable {
    var option: RecordingExportOption
    var includeSummary: Bool

    init(option: RecordingExportOption = .markdown, includeSummary: Bool = true) {
        self.option = option
        self.includeSummary = includeSummary
    }

    var format: ExportFormat { option.format }

    func defaultURL(for recording: Recording) -> URL {
        ExportService.defaultDestination(for: recording, format: format)
    }

    func defaultFilename(for recording: Recording) -> String {
        defaultURL(for: recording).lastPathComponent
    }

    var contentType: UTType? {
        UTType(filenameExtension: format.filenameExtension)
    }
}

struct RecordingExportSheet: View {
    let recording: Recording
    @Binding var draft: RecordingExportDraft
    let onCancel: () -> Void
    let onExported: () -> Void

    @State private var exportError: String?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            formatPicker
            options
            destinationPreview
            if let exportError {
                InlineExportError(message: exportError)
            }
            footer
        }
        .padding(22)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Export Recording")
                .font(.harcTitle.weight(.semibold))
            Text(recording.displayTitle)
                .font(.harcLabel)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Format")
                .font(.harcTitle)
            ForEach(RecordingExportOption.allCases) { option in
                Button {
                    draft.option = option
                    exportError = nil
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: option.iconName)
                            .frame(width: 20)
                            .foregroundStyle(draft.option == option ? HarcBrand.live : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(option.title)
                                    .font(.harcLabel.weight(.semibold))
                                Spacer()
                                Text(".\(option.format.filenameExtension)")
                                    .font(.harcCaption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(option.description)
                                .font(.harcCaption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(formatBackground(for: option))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include summary and action items when available", isOn: $draft.includeSummary)
            Text(summaryOptionDescription)
                .font(.harcCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var destinationPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Filename")
                .font(.harcTitle)
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(draft.defaultFilename(for: recording))
                    .font(.harcBody.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel, action: onCancel)
            Spacer()
            Button {
                runExport()
            } label: {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Choose Destination...", systemImage: "square.and.arrow.up")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isExporting)
        }
    }

    private var summaryOptionDescription: String {
        if hasSummaryContent {
            return "The selected export can include this recording's summary and action items."
        }
        return "This recording does not have a generated summary yet, so the export will contain the transcript."
    }

    private var hasSummaryContent: Bool {
        !(recording.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(recording.actionItemsMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func formatBackground(for option: RecordingExportOption) -> some ShapeStyle {
        draft.option == option ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)
    }

    private func runExport() {
        let panel = NSSavePanel()
        let defaultURL = draft.defaultURL(for: recording)
        panel.directoryURL = defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultURL.lastPathComponent
        if let contentType = draft.contentType {
            panel.allowedContentTypes = [contentType]
        } else {
            panel.allowedContentTypes = []
        }
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            do {
                try ExportService.write(
                    recording: recording,
                    format: draft.format,
                    to: url,
                    includeSummary: draft.includeSummary
                )
                exportError = nil
                isExporting = false
                onExported()
            } catch {
                isExporting = false
                exportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct InlineExportError: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harc(.failure))
            Text(message)
                .font(.harcBody)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.harc(.failure).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
