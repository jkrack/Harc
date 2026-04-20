import Foundation

/// Renders an `ExportInput` to a minimal Markdown string.
///
/// Shape:
///   - Diarized input: `Speaker N: <text>` one line per segment.
///   - No-diarization input: plain paragraph(s), no prefix.
///
/// Deliberately does NOT escape `*`, `_`, `` ` ``, `[`, `#` — speech
/// transcripts use these naturally ("C#", "*must*", "#design"), and
/// over-escaping hurts downstream LLM parses more than it helps.
public enum MarkdownExporter {
    public static func render(_ input: ExportInput) -> String {
        var out = ""
        for segment in input.segments {
            let cleaned = sanitize(segment.text)
            guard !cleaned.isEmpty else { continue }
            if let label = SpeakerLabel.displayLabel(for: segment.speaker, names: input.speakerNames) {
                out += "\(label): \(cleaned)\n"
            } else {
                out += "\(cleaned)\n\n"
            }
        }
        while out.hasSuffix("\n") || out.hasSuffix(" ") {
            out.removeLast()
        }
        if !out.isEmpty { out += "\n" }
        return out
    }

    /// Strip control chars (except \n, \t), normalise line endings, trim.
    private static func sanitize(_ s: String) -> String {
        let normalised = s.replacingOccurrences(of: "\r\n", with: "\n")
                          .replacingOccurrences(of: "\r", with: "\n")
        let filtered = normalised.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A { return true }
            if v < 0x20 { return false }
            return true
        }
        return String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
