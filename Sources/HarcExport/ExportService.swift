import Foundation
import HarcStore

public enum ExportFormat: Sendable {
    case markdown
    case docx
    case prompt

    public var filenameExtension: String {
        switch self {
        case .markdown: return "md"
        case .docx:     return "docx"
        case .prompt:   return "md"
        }
    }
}

/// Thin façade over renderers + filesystem. UI calls these; renderers stay
/// pure and testable.
public enum ExportService {
    /// Default destination: same folder and stem as the recording's .wav,
    /// with the format's extension.
    public static func defaultDestination(for recording: Recording, format: ExportFormat) -> URL {
        let wav = URL(fileURLWithPath: recording.wavPath)
        let stem = wav.deletingPathExtension().lastPathComponent
        let folder = wav.deletingLastPathComponent()
        switch format {
        case .markdown, .docx:
            return folder.appendingPathComponent("\(stem).\(format.filenameExtension)")
        case .prompt:
            return folder.appendingPathComponent("\(stem).prompt.md")
        }
    }

    /// Render + write to `url`. Atomic write.
    public static func write(
        recording: Recording,
        format: ExportFormat,
        to url: URL,
        includeSummary: Bool = true
    ) throws {
        let input = ExportInputBuilder.build(from: recording)
        let data: Data
        switch format {
        case .markdown:
            data = Data(markdownString(for: recording, includeSummary: includeSummary).utf8)
        case .docx:
            let summary = includeSummary ? PromptSummaryBlock.make(from: recording) : nil
            data = try DocxExporter.render(input, summary: summary)
        case .prompt:
            data = Data(ExportService.promptString(for: recording, includeSummary: includeSummary).utf8)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileWriteOutOfSpaceError:
                    throw ExportError.diskFull
                case NSFileWriteNoPermissionError:
                    throw ExportError.permissionDenied(url: url)
                default:
                    break
                }
            }
            throw ExportError.writeFailed(url: url, underlying: error.localizedDescription)
        }
    }

    /// Render Markdown only, return the string. Retained for a future
    /// "Copy Markdown" UI action (deliberately not wired in v1 per the
    /// Copy-for-Prompt spec §8 — all current Copy actions use
    /// `promptString` or plain-text segment join).
    public static func markdownString(
        for recording: Recording,
        includeSummary: Bool = true
    ) -> String {
        let input = ExportInputBuilder.build(from: recording)
        let body = MarkdownExporter.render(input)
        guard includeSummary, let summary = PromptSummaryBlock.make(from: recording) else {
            return body
        }
        return compose(header: "", summaryBlock: renderSummaryBlock(summary), body: body)
    }

    /// Render the prompt-formatted blob. When `includeSummary` is true AND the
    /// recording has a complete summary (all four required columns populated),
    /// prepends `## Summary` + `## Action Items` above a `## Transcript` heading
    /// and the body. Falls back to today's byte-identical output when summary
    /// is absent or excluded. Pure.
    public static func promptString(for recording: Recording, includeSummary: Bool = true) -> String {
        let input = ExportInputBuilder.build(from: recording)
        let summary = includeSummary ? PromptSummaryBlock.make(from: recording) : nil
        let header = PromptFrontMatter.render(input, summary: summary)
        let body = MarkdownExporter.render(input)
        let summaryBlock = summary.map(Self.renderSummaryBlock) ?? ""
        return Self.compose(header: header, summaryBlock: summaryBlock, body: body)
    }

    private static func renderSummaryBlock(_ s: PromptSummaryBlock) -> String {
        """
        ## Summary
        \(s.summaryMarkdown)

        ## Action Items
        \(s.actionItemsMarkdown)
        """
    }

    /// Joins the three composed pieces. Inserts `## Transcript\n` between the
    /// summary block and the body only when both are present — today's
    /// summary-less prompt output stays byte-identical (no new headings).
    private static func compose(header: String, summaryBlock: String, body: String) -> String {
        switch (body.isEmpty, summaryBlock.isEmpty) {
        case (true, true):
            return header.isEmpty ? "" : header + "\n"
        case (true, false):
            return [header, summaryBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case (false, true):
            return [header, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case (false, false):
            return [header, summaryBlock, "## Transcript\n" + body]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
    }
}
