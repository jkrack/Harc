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
    }

    /// Groups recordings (assumed already sorted newest-first by the VM) into
    /// human-readable date buckets: Today, Yesterday, This Week, then
    /// month-and-year labels for older entries.
    static func dateBuckets(from recordings: [Recording]) -> [DateBucket] {
        let cal = Calendar.current
        let now = Date()
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: now),
              let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        else {
            return [DateBucket(label: "All", recordings: recordings)]
        }

        var today: [Recording] = []
        var yesterdayBucket: [Recording] = []
        var thisWeek: [Recording] = []
        var older: [String: [Recording]] = [:]
        var olderOrder: [String] = []

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"

        for rec in recordings {
            let date = rec.startedAt
            if cal.isDate(date, inSameDayAs: now) {
                today.append(rec)
            } else if cal.isDate(date, inSameDayAs: yesterday) {
                yesterdayBucket.append(rec)
            } else if date >= weekStart {
                thisWeek.append(rec)
            } else {
                let label = monthFormatter.string(from: date)
                if older[label] == nil {
                    older[label] = []
                    olderOrder.append(label)
                }
                older[label]!.append(rec)
            }
        }

        var buckets: [DateBucket] = []
        if !today.isEmpty { buckets.append(DateBucket(label: "Today", recordings: today)) }
        if !yesterdayBucket.isEmpty { buckets.append(DateBucket(label: "Yesterday", recordings: yesterdayBucket)) }
        if !thisWeek.isEmpty { buckets.append(DateBucket(label: "This Week", recordings: thisWeek)) }
        for label in olderOrder {
            if let recs = older[label], !recs.isEmpty {
                buckets.append(DateBucket(label: label, recordings: recs))
            }
        }
        return buckets
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
