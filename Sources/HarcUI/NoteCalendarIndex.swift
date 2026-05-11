import Foundation
import HarcStore

public enum NoteCalendarIndex {
    public static func daysWithNotes(
        _ notes: [Note],
        inMonthContaining month: Date,
        calendar: Calendar = .current
    ) -> Set<Date> {
        Set(notes.compactMap { note in
            let activityDate = max(note.createdAt, note.updatedAt)
            guard calendar.isDate(activityDate, equalTo: month, toGranularity: .month) else {
                return nil
            }
            return calendar.startOfDay(for: activityDate)
        })
    }
}
