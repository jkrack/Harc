import Foundation
import HarcStore

// Date grouping and label helpers for `HarcWindowRootView`, plus sidebar
// section presentation. Extracted from the view file. These were `private`
// extensions in that file; they are `internal` here so the view (now in a
// separate file) can call them.


// MARK: - Date grouping

extension HarcWindowRootView {
    struct DateBucket {
        let label: String
        let recordings: [Recording]
        /// Sessions whose day falls in this bucket — rendered first, as peer
        /// rows above the individual recordings (no disclosure nesting).
        let sessions: [SessionOverview]

        init(label: String, recordings: [Recording], sessions: [SessionOverview] = []) {
            self.label = label
            self.recordings = recordings
            self.sessions = sessions
        }
    }

    /// Groups recordings (assumed already sorted newest-first by the VM) into
    /// human-readable date buckets: Today, Yesterday, This Week, then
    /// month-and-year labels for older entries. Sessions land in the same
    /// buckets keyed off their local day.
    static func dateBuckets(from recordings: [Recording], sessions: [SessionOverview] = []) -> [DateBucket] {
        let cal = Calendar.current
        let now = Date()
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: now),
              let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        else {
            return [DateBucket(label: "All", recordings: recordings, sessions: sessions)]
        }

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"

        func label(for date: Date) -> String {
            if cal.isDate(date, inSameDayAs: now) { return "Today" }
            if cal.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
            if date >= weekStart { return "This Week" }
            return monthFormatter.string(from: date)
        }

        var recordingsByLabel: [String: [Recording]] = [:]
        var sessionsByLabel: [String: [SessionOverview]] = [:]
        var order: [String] = []

        func noteLabel(_ l: String) {
            if !order.contains(l) { order.append(l) }
        }

        for rec in recordings {
            let l = label(for: rec.startedAt)
            noteLabel(l)
            recordingsByLabel[l, default: []].append(rec)
        }
        for overview in sessions {
            guard let day = LibraryViewModel.dayDate(fromKey: overview.session.day) else { continue }
            let l = label(for: day.addingTimeInterval(12 * 3600))
            noteLabel(l)
            sessionsByLabel[l, default: []].append(overview)
        }

        // Named buckets keep their fixed precedence; month buckets keep the
        // newest-first order they were first seen in.
        let fixed = ["Today", "Yesterday", "This Week"]
        var ordered: [String] = fixed.filter { order.contains($0) }
        ordered.append(contentsOf: order.filter { !fixed.contains($0) })

        return ordered.map { l in
            DateBucket(
                label: l,
                recordings: recordingsByLabel[l] ?? [],
                sessions: sessionsByLabel[l] ?? []
            )
        }
    }

    /// The session row's secondary line: "N recordings · total duration".
    static func sessionSecondaryLine(for overview: SessionOverview) -> String {
        var parts: [String] = [Pluralize.count(overview.memberIDs.count, "recording")]
        if overview.totalSeconds > 0 {
            let anchor = Date(timeIntervalSince1970: 0)
            parts.append(formatDuration(from: anchor, to: anchor.addingTimeInterval(overview.totalSeconds)))
        }
        return parts.joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Format duration between two dates as h:mm:ss or m:ss.
    static func formatDuration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        let h = seconds / 3600
        let m = (seconds / 60) % 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// The row's secondary line: time · duration · speakers — the facts that
    /// used to masquerade as the title, demoted to context.
    static func rowSecondaryLine(for rec: Recording) -> String {
        var parts: [String] = []

        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        parts.append(fmt.string(from: rec.startedAt))

        if let endedAt = rec.endedAt {
            parts.append(formatDuration(from: rec.startedAt, to: endedAt))
        }

        // speakerNames is populated by diarization at save; its count is the
        // cheap, already-on-the-row source for "how many voices".
        if rec.speakerNames.count > 1 {
            parts.append(Pluralize.count(rec.speakerNames.count, "speaker"))
        }

        return parts.joined(separator: " · ")
    }
}

extension String {
    var harcTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
