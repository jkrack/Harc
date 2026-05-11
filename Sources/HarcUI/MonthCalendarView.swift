import SwiftUI

/// Month-grid calendar for the library sidebar. Shows a 7-column week grid
/// with compact dot indicators under each day that has recordings or notes.
///
/// Stateless — caller owns `month`, `selectedDay`, and the day marker sets.
public struct MonthCalendarView: View {
    public let month: Date
    public let selectedDay: Date?
    public let daysWithRecordings: Set<Date>
    public let daysWithNotes: Set<Date>
    public let onPrevMonth: () -> Void
    public let onNextMonth: () -> Void
    public let onSelectDay: (Date) -> Void

    private let calendar = Calendar.current

    public init(
        month: Date,
        selectedDay: Date?,
        daysWithRecordings: Set<Date>,
        daysWithNotes: Set<Date> = [],
        onPrevMonth: @escaping () -> Void,
        onNextMonth: @escaping () -> Void,
        onSelectDay: @escaping (Date) -> Void
    ) {
        self.month = month
        self.selectedDay = selectedDay
        self.daysWithRecordings = daysWithRecordings
        self.daysWithNotes = daysWithNotes
        self.onPrevMonth = onPrevMonth
        self.onNextMonth = onNextMonth
        self.onSelectDay = onSelectDay
    }

    public var body: some View {
        VStack(spacing: 6) {
            header
            weekdayRow
            daysGrid
        }
    }

    // MARK: - Header (month label + nav)

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: onPrevMonth) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(monthTitle)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onNextMonth) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Weekday header row

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { s in
                Text(s)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 7×6 day grid

    private var daysGrid: some View {
        let cells = monthCells()
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
            spacing: 2
        ) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                dayCell(for: day)
            }
        }
    }

    @ViewBuilder
    private func dayCell(for day: Date?) -> some View {
        if let day {
            let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
            let startOfDay = calendar.startOfDay(for: day)
            let hasRec = daysWithRecordings.contains(startOfDay)
            let hasNote = daysWithNotes.contains(startOfDay)
            let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
            Button {
                onSelectDay(day)
            } label: {
                VStack(spacing: 1) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            isSelected
                                ? Color.white
                                : (inMonth ? Color.primary : Color.secondary.opacity(0.4))
                        )
                    markerRow(hasRecording: hasRec, hasNote: hasNote, isSelected: isSelected)
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .help(dayTooltip(for: day, hasRecording: hasRec, hasNote: hasNote))
        } else {
            Color.clear.frame(minHeight: 24)
        }
    }

    private func markerRow(hasRecording: Bool, hasNote: Bool, isSelected: Bool) -> some View {
        HStack(spacing: 2) {
            Circle()
                .fill(hasRecording ? (isSelected ? Color.white : Color.accentColor) : Color.clear)
                .frame(width: 4, height: 4)
            Circle()
                .fill(hasNote ? (isSelected ? Color.white.opacity(0.75) : Color.purple) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(height: 4)
    }

    private func dayTooltip(for day: Date, hasRecording: Bool, hasNote: Bool) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        let suffix: String
        switch (hasRecording, hasNote) {
        case (true, true): suffix = " — has recordings and notes"
        case (true, false): suffix = " — has recordings"
        case (false, true): suffix = " — has notes"
        case (false, false): suffix = ""
        }
        return "\(fmt.string(from: day))\(suffix)"
    }

    // MARK: - Helpers

    private var monthTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        return fmt.string(from: month)
    }

    private var weekdaySymbols: [String] {
        var syms = calendar.shortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        syms = Array(syms[shift...] + syms[..<shift])
        return syms.map { String($0.prefix(1)) }
    }

    /// 7×6 = 42 cells, spanning the week containing day-1 through the week
    /// containing the last day. Out-of-month cells still get a Date so
    /// arrow-key nav stays consistent.
    private func monthCells() -> [Date?] {
        let comps = calendar.dateComponents([.year, .month], from: month)
        guard let firstOfMonth = calendar.date(from: comps) else { return [] }
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstOfMonth) else { return [] }
        return (0..<42).map { offset in
            calendar.date(byAdding: .day, value: offset, to: gridStart)
        }
    }
}
