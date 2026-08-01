import Foundation
import HarcCore

/// Regenerates a recording's canonical `.md` artifact from its database row.
/// The DB is authoritative; the file is a projection rewritten wholesale
/// after every mutation (summary landing, speaker rename, transcript edit,
/// title/tag changes). Best-effort by design — file-system failure must
/// never fail the DB write, so callers use `write(recording:)` fire-and-forget.
public enum OKFProjection {

    /// Derived `.md` path for a recording (next to its WAV).
    public static func markdownURL(for recording: Recording) -> URL {
        URL(fileURLWithPath: recording.wavPath)
            .deletingPathExtension()
            .appendingPathExtension("md")
    }

    @discardableResult
    public static func write(recording: Recording) -> URL? {
        let wavURL = URL(fileURLWithPath: recording.wavPath)
        let mdURL = markdownURL(for: recording)
        let parent = wavURL.deletingLastPathComponent()

        // Transcript body: the DB mirror is the source of truth; if it's
        // missing (legacy row), preserve whatever the file already carries.
        let existing = try? String(contentsOf: mdURL, encoding: .utf8)
        let transcript = recording.transcriptText
            ?? existing.flatMap { OKFMarkdown.extractTranscript(from: $0) }
            ?? ""

        let speakerTags = recording.speakerNames
            .sorted { $0.key < $1.key }
            .map(\.value)
        var tags = recording.tags
        for name in speakerTags where !tags.contains(name) { tags.append(name) }

        let title = recording.title
            ?? recording.suggestedTitle
            ?? defaultTitle(startedAt: recording.startedAt)

        let markdown = OKFMarkdown.render(OKFMarkdown.Fields(
            title: title,
            startedAt: recording.startedAt,
            wavFileName: wavURL.lastPathComponent,
            tags: tags,
            summaryMarkdown: recording.summaryMarkdown,
            actionItemsMarkdown: recording.actionItemsMarkdown,
            notesMarkdown: recording.notesMarkdown,
            transcript: transcript
        ))

        do {
            try Data(markdown.utf8).write(to: mdURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-store: OKF projection write failed for \(mdURL.path): \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
        OKFMarkdown.regenerateDayIndex(in: parent)
        return mdURL
    }

    private static func defaultTitle(startedAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting · \(f.string(from: startedAt))"
    }
}
