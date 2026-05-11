import Foundation
import Testing
import HarcStore
@testable import HarcUI

struct NoteSidebarGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("pinned and recent notes are separated without duplication")
    func pinnedAndRecentAreSeparatedWithoutDuplication() {
        let now = date(year: 2026, month: 5, day: 11, hour: 12)
        let pinned = note(id: "pinned", title: "Pinned", createdAt: now, updatedAt: now, pinned: true)
        let recent = note(id: "recent", title: "Recent", createdAt: now.addingTimeInterval(-60), updatedAt: now.addingTimeInterval(-60))
        let older = note(id: "older", title: "Older", createdAt: now.addingTimeInterval(-120), updatedAt: now.addingTimeInterval(-120))

        let grouping = NoteSidebarGrouping.make(
            notes: [older, pinned, recent],
            calendar: calendar,
            now: now,
            recentLimit: 1
        )

        #expect(grouping.pinned.map(\.id) == ["pinned"])
        #expect(grouping.recent.map(\.id) == ["recent"])
        #expect(grouping.buckets.flatMap(\.notes).map(\.id) == ["older"])
        #expect(grouping.defaultExpandedBucketIDs.contains("pinned"))
        #expect(grouping.defaultExpandedBucketIDs.contains("recent"))
    }

    @Test("notes sort by latest activity date")
    func notesSortByLatestActivityDate() {
        let now = date(year: 2026, month: 5, day: 11, hour: 12)
        let createdRecently = note(
            id: "created",
            title: "Created",
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120)
        )
        let updatedRecently = note(
            id: "updated",
            title: "Updated",
            createdAt: now.addingTimeInterval(-10_000),
            updatedAt: now.addingTimeInterval(-60)
        )

        let grouping = NoteSidebarGrouping.make(
            notes: [createdRecently, updatedRecently],
            calendar: calendar,
            now: now,
            recentLimit: 2
        )

        #expect(grouping.recent.map(\.id) == ["updated", "created"])
    }

    @Test("date buckets produce relative and month labels")
    func dateBucketsProduceRelativeAndMonthLabels() {
        let now = date(year: 2026, month: 5, day: 13, hour: 12)
        let yesterday = date(year: 2026, month: 5, day: 12, hour: 9)
        let thisWeek = date(year: 2026, month: 5, day: 11, hour: 9)
        let lastMonth = date(year: 2026, month: 4, day: 25, hour: 9)
        let todayNote = note(id: "today", title: "Today", createdAt: now, updatedAt: now)
        let yesterdayNote = note(id: "yesterday", title: "Yesterday", createdAt: yesterday, updatedAt: yesterday)
        let weekNote = note(id: "week", title: "Week", createdAt: thisWeek, updatedAt: thisWeek)
        let monthNote = note(id: "month", title: "Month", createdAt: lastMonth, updatedAt: lastMonth)

        let grouping = NoteSidebarGrouping.make(
            notes: [monthNote, weekNote, yesterdayNote, todayNote],
            calendar: calendar,
            now: now,
            recentLimit: 0
        )

        #expect(grouping.buckets.map(\.label) == ["Today", "Yesterday", "This Week", "April 2026"])
        #expect(grouping.buckets.first?.defaultExpanded == true)
        #expect(grouping.buckets.dropFirst().allSatisfy { !$0.defaultExpanded })
    }

    @Test("selected day filters by activity date")
    func selectedDayFiltersByActivityDate() {
        let now = date(year: 2026, month: 5, day: 11, hour: 12)
        let selectedDay = date(year: 2026, month: 5, day: 10, hour: 9)
        let updatedOnSelectedDay = note(
            id: "updated",
            title: "Updated",
            createdAt: date(year: 2026, month: 5, day: 1, hour: 9),
            updatedAt: selectedDay
        )
        let other = note(id: "other", title: "Other", createdAt: now, updatedAt: now)

        let grouping = NoteSidebarGrouping.make(
            notes: [updatedOnSelectedDay, other],
            selectedDay: selectedDay,
            calendar: calendar,
            now: now,
            recentLimit: 5
        )

        #expect(grouping.recent.map(\.id) == ["updated"])
        #expect(grouping.buckets.isEmpty)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }

    private func note(
        id: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        pinned: Bool = false
    ) -> Note {
        Note(
            id: id,
            title: title,
            body: "\(title) body",
            pinned: pinned,
            createdAt: createdAt,
            updatedAt: updatedAt,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).md")
        )
    }
}
