import Foundation

/// Renders the YAML front-matter block that prefixes the prompt-formatted
/// export. Internal to `HarcExport`; consumed by `ExportService.promptString`.
enum PromptFrontMatter {

    /// Format a non-negative duration as the compact shape used in the YAML
    /// `duration:` field: `<N>s` for < 60s, `<N>m` for < 1h, `<H>h <M>m`
    /// at 1h+. Minutes and hours truncate — `119s → "1m"`, not `"2m"`.
    static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}
