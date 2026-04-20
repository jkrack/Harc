import Foundation

/// Single source of truth for the user-visible speaker label. Consumed
/// by `MarkdownExporter`, `DocxExporter`, and `PromptFrontMatter` so the
/// fallback ("Speaker N") and the override lookup never drift across
/// renderers.
public enum SpeakerLabel {
    /// Returns the override name for `speaker` if present and non-empty
    /// after trim; otherwise `"Speaker \(speaker + 1)"`. Returns `nil`
    /// when `speaker` is `nil` (un-diarized segment — callers omit the
    /// prefix entirely).
    public static func displayLabel(for speaker: Int?, names: [Int: String]) -> String? {
        guard let id = speaker else { return nil }
        if let raw = names[id] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Speaker \(id + 1)"
    }
}
