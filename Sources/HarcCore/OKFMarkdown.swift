import Foundation

/// Open Knowledge Format (OKF v0.1) rendering for Harc's canonical
/// per-recording markdown artifact and per-day `index.md` navigation files.
///
/// The `.md` sibling next to each WAV is a *projection* of the database row
/// (the DB stays authoritative): YAML frontmatter (`type`, `title`,
/// `resource`, `tags`, `timestamp`) followed by `## Summary`,
/// `## Action Items` (when present), and `## Transcript`. It is rewritten
/// wholesale whenever the row changes — external edits to generated
/// sections are not preserved.
public enum OKFMarkdown {

    public static let documentType = "Meeting Transcript"
    public static let transcriptHeader = "## Transcript"

    public struct Fields: Sendable {
        public var title: String
        public var startedAt: Date?
        public var wavFileName: String?
        public var tags: [String]
        public var summaryMarkdown: String?
        public var actionItemsMarkdown: String?
        public var notesMarkdown: String?
        public var transcript: String

        public init(
            title: String,
            startedAt: Date? = nil,
            wavFileName: String? = nil,
            tags: [String] = [],
            summaryMarkdown: String? = nil,
            actionItemsMarkdown: String? = nil,
            notesMarkdown: String? = nil,
            transcript: String
        ) {
            self.title = title
            self.startedAt = startedAt
            self.wavFileName = wavFileName
            self.tags = tags
            self.summaryMarkdown = summaryMarkdown
            self.actionItemsMarkdown = actionItemsMarkdown
            self.notesMarkdown = notesMarkdown
            self.transcript = transcript
        }
    }

    // MARK: - Rendering

    public static func render(_ f: Fields) -> String {
        var front: [String] = ["---", "type: \(documentType)"]
        front.append("title: \(yamlString(f.title))")
        if let wav = f.wavFileName, !wav.isEmpty {
            front.append("resource: ./\(wav)")
        }
        let tags = f.tags.filter { !$0.isEmpty }
        if !tags.isEmpty {
            front.append("tags: [\(tags.map(yamlString).joined(separator: ", "))]")
        }
        if let date = f.startedAt {
            front.append("timestamp: \(iso8601.string(from: date))")
        }
        front.append("---")

        var sections: [String] = [front.joined(separator: "\n")]
        if let s = f.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            sections.append("## Summary\n\n\(s)")
        }
        if let a = f.actionItemsMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !a.isEmpty {
            sections.append("## Action Items\n\n\(a)")
        }
        if let n = f.notesMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty {
            sections.append("## Notes\n\n\(n)")
        }
        let transcript = f.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("\(transcriptHeader)\n\n\(transcript)")
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Session documents

    public static let sessionDocumentType = "Session"

    /// One member link in a session document's `## Recordings` section.
    public struct SessionLink: Sendable {
        /// The member document's filename within the same day directory,
        /// e.g. `"10-04-00.md"`.
        public var fileName: String
        public var title: String
        /// Optional secondary text after the link, e.g. `"10:04 AM · 42 min"`.
        public var detail: String?

        public init(fileName: String, title: String, detail: String? = nil) {
            self.fileName = fileName
            self.title = title
            self.detail = detail
        }
    }

    public struct SessionFields: Sendable {
        public var title: String
        public var startedAt: Date?
        public var tags: [String]
        public var summaryMarkdown: String?
        public var actionItemsMarkdown: String?
        public var notesMarkdown: String?
        public var recordings: [SessionLink]

        public init(
            title: String,
            startedAt: Date? = nil,
            tags: [String] = [],
            summaryMarkdown: String? = nil,
            actionItemsMarkdown: String? = nil,
            notesMarkdown: String? = nil,
            recordings: [SessionLink] = []
        ) {
            self.title = title
            self.startedAt = startedAt
            self.tags = tags
            self.summaryMarkdown = summaryMarkdown
            self.actionItemsMarkdown = actionItemsMarkdown
            self.notesMarkdown = notesMarkdown
            self.recordings = recordings
        }
    }

    /// Render a session document — a grouping projection over a day's
    /// recordings. Deliberately carries no transcript section: the member
    /// documents own their transcripts, and duplicating an hour of text
    /// into a second file that must be kept in sync is the failure mode
    /// OKF projections exist to avoid.
    public static func renderSession(_ f: SessionFields) -> String {
        var front: [String] = ["---", "type: \(sessionDocumentType)"]
        front.append("title: \(yamlString(f.title))")
        let tags = f.tags.filter { !$0.isEmpty }
        if !tags.isEmpty {
            front.append("tags: [\(tags.map(yamlString).joined(separator: ", "))]")
        }
        if let date = f.startedAt {
            front.append("timestamp: \(iso8601.string(from: date))")
        }
        if !f.recordings.isEmpty {
            front.append("recordings:")
            for link in f.recordings {
                front.append("  - ./\(link.fileName)")
            }
        }
        front.append("---")

        var sections: [String] = [front.joined(separator: "\n")]
        if let s = f.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            sections.append("## Summary\n\n\(s)")
        }
        if let a = f.actionItemsMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !a.isEmpty {
            sections.append("## Action Items\n\n\(a)")
        }
        if let n = f.notesMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty {
            sections.append("## Notes\n\n\(n)")
        }
        if !f.recordings.isEmpty {
            let lines = f.recordings.map { link in
                var line = "- [\(link.title)](./\(link.fileName))"
                if let detail = link.detail, !detail.isEmpty {
                    line += " — \(detail)"
                }
                return line
            }
            sections.append("## Recordings\n\n\(lines.joined(separator: "\n"))")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Reading back

    /// The transcript section body of a rendered document, or nil when the
    /// marker is absent (a file we didn't write). Matches the LAST
    /// `## Transcript` heading at line start so summary prose mentioning the
    /// literal string can't shadow the real section.
    public static func extractTranscript(from markdown: String) -> String? {
        guard let range = lastTranscriptHeaderRange(in: markdown) else { return nil }
        return String(markdown[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace the transcript section, preserving frontmatter + summary as
    /// they are on disk. Nil when the marker is absent.
    public static func replacingTranscript(
        in markdown: String,
        with newTranscript: String
    ) -> String? {
        guard let range = lastTranscriptHeaderRange(in: markdown) else { return nil }
        let head = String(markdown[..<range.upperBound])
        return head + "\n" + newTranscript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func lastTranscriptHeaderRange(in markdown: String) -> Range<String.Index>? {
        // Header at the start of a line, consuming its trailing newline-ish
        // whitespace so extraction starts at the body.
        if let r = markdown.range(of: "\n\(transcriptHeader)\n", options: .backwards) { return r }
        if markdown.hasPrefix("\(transcriptHeader)\n") {
            return markdown.range(of: "\(transcriptHeader)\n")
        }
        return nil
    }

    // MARK: - Day index

    /// Regenerate `index.md` for a day directory: one link per meeting
    /// `.md`, sorted by filename (which is time-of-day). Reads each file's
    /// frontmatter `title:` for the link text. Removes the index when the
    /// directory has no meeting documents left.
    public static func regenerateDayIndex(in directory: URL) {
        let fm = FileManager.default
        let indexURL = directory.appendingPathComponent("index.md")
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        let docs = files
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != "index.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !docs.isEmpty else {
            try? fm.removeItem(at: indexURL)
            return
        }

        let day = directory.lastPathComponent
        var lines = [
            "---",
            "type: Index",
            "title: \(yamlString("Meetings · \(day)"))",
            "---",
            "",
        ]
        for doc in docs {
            let name = doc.lastPathComponent
            let title = frontmatterTitle(of: doc) ?? doc.deletingPathExtension().lastPathComponent
            lines.append("- [\(title)](./\(name))")
        }
        try? (lines.joined(separator: "\n") + "\n")
            .data(using: .utf8)?
            .write(to: indexURL, options: .atomic)
    }

    private static func frontmatterTitle(of url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard line.hasPrefix("title: ") else { continue }
            var value = String(line.dropFirst("title: ".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return value
        }
        return nil
    }

    // MARK: - Helpers

    private static var iso8601: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private static func yamlString(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        + "\""
    }
}
