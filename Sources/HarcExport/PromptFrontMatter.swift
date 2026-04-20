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

    /// ISO 8601 with an explicit offset — e.g. `2026-04-19T14:32:00-07:00`.
    /// The `timeZone` parameter exists for deterministic tests; production
    /// callers pass `.current`.
    static func formatRecorded(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }

    /// Render a string as a YAML scalar. Returns the input unchanged if the
    /// value is safe as a plain (unquoted) scalar; otherwise returns a
    /// double-quoted scalar with escapes. Strips control chars below 0x20
    /// except for `\n` and `\t` (which are escaped), matching
    /// `MarkdownExporter.sanitize()`'s policy.
    static func yamlScalar(_ value: String) -> String {
        // Strip disallowed control chars first (same policy as
        // MarkdownExporter, except we handle \n/\t via escapes instead
        // of passing them through).
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A { return true }   // \t, \n — escaped below
            if v < 0x20 { return false }                // drop other control chars
            return true
        }))

        if mustQuote(filtered) {
            return "\"\(doubleQuoteEscape(filtered))\""
        }
        return filtered
    }

    /// Count of distinct non-nil speaker ids in `segments`. Returns 0 for
    /// un-diarized input. Used to decide whether the `speakers:` field is
    /// emitted (only when >= 2).
    static func speakerCount(in segments: [ExportInput.Segment]) -> Int {
        var seen: Set<Int> = []
        for s in segments {
            if let id = s.speaker { seen.insert(id) }
        }
        return seen.count
    }

    private static let reservedLeadingChars: Set<Character> = [
        "!", "&", "*", "-", ":", "?", "{", "}", "[", "]", ",",
        "#", "|", ">", "'", "\"", "%", "@", "`",
    ]

    private static func mustQuote(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if let first = s.first, reservedLeadingChars.contains(first) { return true }
        if let first = s.first, first.isWhitespace { return true }
        if let last = s.last, last.isWhitespace { return true }
        if s.contains("\n") || s.contains("\r") || s.contains("\t") { return true }
        if s.contains(": ") || s.hasSuffix(":") { return true }
        if s.contains(" #") { return true }
        if s.contains("\"") || s.contains("\\") { return true }
        return false
    }

    private static func doubleQuoteEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
