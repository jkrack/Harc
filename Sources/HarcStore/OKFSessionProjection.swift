import Foundation
import HarcCore

/// Regenerates a session's `session-*.md` artifact from its database row and
/// member recordings. Like `OKFProjection`, the DB is authoritative and the
/// file is a wholesale-rewritten projection; best-effort by design — a
/// file-system failure never fails the DB write.
public enum OKFSessionProjection {

    /// Derived `.md` path for a session: the first member's day directory,
    /// filename `session-<first member's wav basename>.md`. Deriving from the
    /// wav basename (already `HH-mm-ss`) keeps the name in lockstep with the
    /// member files, and the `session-` prefix sorts after every `HH-mm-ss.md`
    /// so the day index lists sessions at the bottom with no index changes.
    /// Nil when the session has no members to anchor to.
    public static func markdownURL(members: [Recording]) -> URL? {
        guard let first = members.first else { return nil }
        let wavURL = URL(fileURLWithPath: first.wavPath)
        let base = wavURL.deletingPathExtension().lastPathComponent
        return wavURL
            .deletingLastPathComponent()
            .appendingPathComponent("session-\(base).md")
    }

    /// Write (or rewrite) the session document. `members` must be ALL of the
    /// session's recordings in position order — soft-deleted rows included,
    /// so the filename anchor (first member) stays stable while a member sits
    /// in the soft-deleted state. Only active members are rendered.
    @discardableResult
    public static func write(session: Session, members: [Recording]) -> URL? {
        guard let mdURL = markdownURL(members: members) else { return nil }

        let active = members.filter { $0.deletedAt == nil }

        var tags: [String] = []
        for member in active {
            for tag in member.tags where !tags.contains(tag) { tags.append(tag) }
        }

        let links = active.map { member -> OKFMarkdown.SessionLink in
            let fileName = URL(fileURLWithPath: member.wavPath)
                .deletingPathExtension()
                .appendingPathExtension("md")
                .lastPathComponent
            return OKFMarkdown.SessionLink(
                fileName: fileName,
                title: member.displayTitle,
                detail: detail(for: member)
            )
        }

        let markdown = OKFMarkdown.renderSession(OKFMarkdown.SessionFields(
            title: session.displayTitle,
            startedAt: members.first?.startedAt,
            tags: tags,
            summaryMarkdown: session.summaryMarkdown,
            actionItemsMarkdown: session.actionItemsMarkdown,
            notesMarkdown: session.notesMarkdown,
            recordings: links
        ))

        do {
            try Data(markdown.utf8).write(to: mdURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-store: OKF session projection write failed for \(mdURL.path): \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
        OKFMarkdown.regenerateDayIndex(in: mdURL.deletingLastPathComponent())
        return mdURL
    }

    /// Remove the session document (dissolve/delete path) and refresh the
    /// day index. Best-effort.
    public static func remove(members: [Recording]) {
        guard let mdURL = markdownURL(members: members) else { return }
        try? FileManager.default.removeItem(at: mdURL)
        OKFMarkdown.regenerateDayIndex(in: mdURL.deletingLastPathComponent())
    }

    /// "10:04 AM · 42 min" — start time plus duration when known.
    private static func detail(for member: Recording) -> String? {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        var parts = [time.string(from: member.startedAt)]
        if let ended = member.endedAt {
            let minutes = Int((ended.timeIntervalSince(member.startedAt) / 60).rounded())
            parts.append(minutes < 1 ? "under a minute" : "\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }
}
