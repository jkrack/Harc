import Foundation
import HarcCore

public enum TranscriptWriter {
    /// Writes a `<wav-stem>.md` (OKF markdown: frontmatter + transcript) and
    /// `<wav-stem>.json` (full structured) alongside the given WAV URL, then
    /// regenerates the day directory's `index.md`. Uses atomic writes.
    ///
    /// The `.md` here carries no Summary section — summaries land minutes
    /// later via the background queue, and `RecordingStore` regenerates the
    /// projection from the DB row on every mutation.
    public static func writeSiblings(transcript: SessionTranscript, nextTo wavURL: URL) throws {
        let stem = wavURL.deletingPathExtension().lastPathComponent
        let parent = wavURL.deletingLastPathComponent()

        let mdURL = parent.appendingPathComponent("\(stem).md")
        let jsonURL = parent.appendingPathComponent("\(stem).json")

        let plain = TranscriptPlainTextRenderer.render(transcript)
        let startedAt = Self.startedAt(day: parent.lastPathComponent, stem: stem)
        let markdown = OKFMarkdown.render(OKFMarkdown.Fields(
            title: Self.defaultTitle(day: parent.lastPathComponent, stem: stem),
            startedAt: startedAt,
            wavFileName: wavURL.lastPathComponent,
            transcript: plain
        ))
        try Data(markdown.utf8).write(to: mdURL, options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let jsonData = try encoder.encode(transcript)
        try jsonData.write(to: jsonURL, options: .atomic)

        OKFMarkdown.regenerateDayIndex(in: parent)
    }

    /// "Meeting · 2026-07-24 09:00" from the storage layout's
    /// `YYYY-MM-DD/HH-mm-ss` convention; falls back to the raw stem for
    /// paths outside the convention.
    static func defaultTitle(day: String, stem: String) -> String {
        let timeParts = stem.split(separator: "-")
        guard day.count == 10, timeParts.count == 3 else { return "Meeting · \(stem)" }
        return "Meeting · \(day) \(timeParts[0]):\(timeParts[1])"
    }

    static func startedAt(day: String, stem: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.date(from: "\(day) \(stem)")
    }
}
