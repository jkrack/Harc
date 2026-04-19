import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Renders an `ExportInput` to an Office Open XML (.docx) byte stream
/// using `NSAttributedString.data(from:documentAttributes:)`.
public enum DocxExporter {
#if canImport(AppKit)
    public static func render(_ input: ExportInput) throws -> Data {
        let attributed = buildAttributedString(input)
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

    private static func buildAttributedString(_ input: ExportInput) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
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

        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

        for segment in input.segments {
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let speaker = segment.speaker {
                out.append(NSAttributedString(
                    string: "Speaker \(speaker + 1): ",
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
#else
    public static func render(_ input: ExportInput) throws -> Data {
        throw ExportError.docxRenderFailed(underlying: "AppKit unavailable on this platform")
    }
#endif
}
