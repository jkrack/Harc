import Foundation
import HarcStore

struct NoteSidebarGrouping: Equatable {
    struct Bucket: Equatable, Identifiable {
        let id: String
        let label: String
        let notes: [Note]
        let defaultExpanded: Bool
    }

    let pinned: [Note]
    let recent: [Note]
    let buckets: [Bucket]

    var isEmpty: Bool {
        pinned.isEmpty && recent.isEmpty && buckets.allSatisfy(\.notes.isEmpty)
    }

    var defaultExpandedBucketIDs: Set<String> {
        Set(buckets.filter(\.defaultExpanded).map(\.id))
            .union(pinned.isEmpty ? [] : ["pinned"])
            .union(recent.isEmpty ? [] : ["recent"])
    }

    static func make(
        notes: [Note],
        selectedDay: Date? = nil,
        calendar: Calendar = .current,
        now: Date = Date(),
        recentLimit: Int = 5
    ) -> NoteSidebarGrouping {
        let filtered = notes.filter { note in
            guard let selectedDay else { return true }
            return calendar.isDate(note.activityDate, inSameDayAs: selectedDay)
        }
        let sorted = filtered.sorted(by: noteSort)
        let pinned = sorted.filter(\.pinned)
        let unpinned = sorted.filter { !$0.pinned }
        let recent = Array(unpinned.prefix(recentLimit))
        let recentIDs = Set(recent.map(\.id))
        let bucketed = unpinned.filter { !recentIDs.contains($0.id) }

        return NoteSidebarGrouping(
            pinned: pinned,
            recent: recent,
            buckets: makeBuckets(notes: bucketed, calendar: calendar, now: now)
        )
    }

    private static func makeBuckets(notes: [Note], calendar: Calendar, now: Date) -> [Bucket] {
        guard !notes.isEmpty else { return [] }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let weekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        )

        var today: [Note] = []
        var yesterdayNotes: [Note] = []
        var thisWeek: [Note] = []
        var older: [String: [Note]] = [:]
        var olderOrder: [String] = []

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "MMMM yyyy"

        for note in notes {
            let date = note.activityDate
            if calendar.isDate(date, inSameDayAs: now) {
                today.append(note)
            } else if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
                yesterdayNotes.append(note)
            } else if let weekStart, date >= weekStart {
                thisWeek.append(note)
            } else {
                let label = monthFormatter.string(from: date)
                if older[label] == nil {
                    older[label] = []
                    olderOrder.append(label)
                }
                older[label, default: []].append(note)
            }
        }

        var buckets: [Bucket] = []
        if !today.isEmpty {
            buckets.append(Bucket(id: "today", label: "Today", notes: today, defaultExpanded: true))
        }
        if !yesterdayNotes.isEmpty {
            buckets.append(Bucket(id: "yesterday", label: "Yesterday", notes: yesterdayNotes, defaultExpanded: false))
        }
        if !thisWeek.isEmpty {
            buckets.append(Bucket(id: "this-week", label: "This Week", notes: thisWeek, defaultExpanded: false))
        }

        olderOrder.sort { lhs, rhs in
            guard let lhsDate = older[lhs]?.first?.activityDate,
                  let rhsDate = older[rhs]?.first?.activityDate else {
                return lhs > rhs
            }
            return lhsDate > rhsDate
        }

        for label in olderOrder {
            guard let notes = older[label] else { continue }
            let isCurrentMonth = notes.contains { calendar.isDate($0.activityDate, equalTo: now, toGranularity: .month) }
            buckets.append(Bucket(
                id: "month-\(label)",
                label: label,
                notes: notes,
                defaultExpanded: isCurrentMonth
            ))
        }

        return buckets
    }

    private static func noteSort(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.activityDate != rhs.activityDate { return lhs.activityDate > rhs.activityDate }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

private extension Note {
    var activityDate: Date {
        max(createdAt, updatedAt)
    }
}
