import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Renders an `ExportInput` to an Office Open XML (.docx) byte stream
/// using `NSAttributedString.data(from:documentAttributes:)`.
public enum DocxExporter {
#if canImport(AppKit)
    public static func render(_ input: ExportInput) throws -> Data {
        try render(input, summary: nil)
    }

    public static func render(_ input: ExportInput, summary: PromptSummaryBlock?) throws -> Data {
        let attributed = buildAttributedString(input, summary: summary)
        let range = NSRange(location: 0, length: attributed.length)
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML
        ]
        do {
            return try attributed.data(from: range, documentAttributes: attrs)
        } catch {
            throw ExportError.docxRenderFailed(underlying: error.localizedDescription)
        }
    }

    private static func buildAttributedString(
        _ input: ExportInput,
        summary: PromptSummaryBlock?
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let headingFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

        out.append(NSAttributedString(
            string: input.title + "\n",
            attributes: [.font: titleFont]
        ))

        let metaFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var meta = df.string(from: input.startedAt)
        if let secs = input.durationSeconds, secs > 0 {
            let m = secs / 60, s = secs % 60
            meta += "  ·  \(m)m \(s)s"
        }
        out.append(NSAttributedString(
            string: meta + "\n\n",
            attributes: [
                .font: metaFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))

        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.lineHeightMultiple = 1.15

        if let summary {
            appendSection(
                title: "Summary",
                body: summary.summaryMarkdown,
                to: out,
                headingFont: headingFont,
                bodyFont: bodyFont,
                paragraphStyle: para
            )
            appendSection(
                title: "Action Items",
                body: summary.actionItemsMarkdown,
                to: out,
                headingFont: headingFont,
                bodyFont: bodyFont,
                paragraphStyle: para
            )
            if input.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                out.append(NSAttributedString(
                    string: "Transcript\n",
                    attributes: [
                        .font: headingFont,
                        .paragraphStyle: para
                    ]
                ))
            }
        }

        for segment in input.segments {
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let label = SpeakerLabel.displayLabel(for: segment.speaker, names: input.speakerNames) {
                out.append(NSAttributedString(
                    string: "\(label): ",
                    attributes: [
                        .font: labelFont,
                        .paragraphStyle: para
                    ]
                ))
                out.append(NSAttributedString(
                    string: segment.text + "\n",
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: para
                    ]
                ))
            } else {
                out.append(NSAttributedString(
                    string: segment.text + "\n",
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: para
                    ]
                ))
            }
        }
        return out
    }

    private static func appendSection(
        title: String,
        body: String,
        to out: NSMutableAttributedString,
        headingFont: NSFont,
        bodyFont: NSFont,
        paragraphStyle: NSParagraphStyle
    ) {
        out.append(NSAttributedString(
            string: "\(title)\n",
            attributes: [
                .font: headingFont,
                .paragraphStyle: paragraphStyle
            ]
        ))
        out.append(NSAttributedString(
            string: "\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n",
            attributes: [
                .font: bodyFont,
                .paragraphStyle: paragraphStyle
            ]
        ))
    }
#else
    public static func render(_ input: ExportInput) throws -> Data {
        throw ExportError.docxRenderFailed(underlying: "AppKit unavailable on this platform")
    }

    public static func render(_ input: ExportInput, summary: PromptSummaryBlock?) throws -> Data {
        throw ExportError.docxRenderFailed(underlying: "AppKit unavailable on this platform")
    }
#endif
}
