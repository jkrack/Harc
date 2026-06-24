import Foundation
import HarcStore

// Date/note grouping and label helpers for `HarcWindowRootView`, plus sidebar
// section presentation. Extracted from the view file. These were `private`
// extensions in that file; they are `internal` here so the view (now in a
// separate file) can call them.

extension LibrarySidebarSection {
    var sidebarTitle: String {
        switch self {
        case .recordings: return "Recent Recordings"
        case .notes: return "Active Notes"
        case .projects: return "Projects"
        case .people: return "People"
        }
    }

    var sidebarIconName: String {
        switch self {
        case .recordings: return "waveform"
        case .notes: return "note.text"
        case .projects: return "folder"
        case .people: return "person.2"
        }
    }
}

// MARK: - Date grouping

extension HarcWindowRootView {
    struct DateBucket {
        let label: String
        let recordings: [Recording]
    }

    struct NoteBucket {
        let label: String
        let notes: [Note]
    }

    static func noteBuckets(from notes: [Note]) -> [NoteBucket] {
        var grouped: [String: [Note]] = [:]
        var labels: [String] = []

        for note in notes {
            let label = note.folderPath?.isEmpty == false ? note.folderPath! : "Unfiled"
            if grouped[label] == nil {
                grouped[label] = []
                labels.append(label)
            }
            grouped[label, default: []].append(note)
        }

        labels.sort(by: noteBucketSort)
        return labels.compactMap { label in
            guard let notes = grouped[label] else { return nil }
            return NoteBucket(label: label, notes: notes)
        }
    }

    static func noteBucketSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "Unfiled" { return false }
        if rhs == "Unfiled" { return true }
        return lhs > rhs
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
}

extension String {
    var harcTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
