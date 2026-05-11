import Foundation
import Testing
import HarcStore
@testable import HarcUI

struct NoteCalendarIndexTests {
    @Test("calendar note dots use latest note activity")
    func calendarNoteDotsUseLatestActivity() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_172_800)
        let note = Note(
            id: "note-1",
            title: "Today",
            body: "Updated today.",
            createdAt: created,
            updatedAt: updated,
            fileURL: URL(fileURLWithPath: "/tmp/note.md")
        )

        let days = NoteCalendarIndex.daysWithNotes(
            [note],
            inMonthContaining: updated,
            calendar: calendar
        )

        #expect(days == [calendar.startOfDay(for: updated)])
    }
}
