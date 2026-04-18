import SwiftUI

/// Month-grid calendar. Shows a 7-column week grid for the current month.
/// Days with recordings get a dot indicator under the date.
/// Stateless — caller owns `month` / `selectedDay` / `daysWithRecordings`.
public struct MonthCalendarView: View {
    public let month: Date
    public let selectedDay: Date?
    public let daysWithRecordings: Set<Date>
    public let onPrevMonth: () -> Void
    public let onNextMonth: () -> Void
    public let onSelectDay: (Date) -> Void

    private let calendar = Calendar.current

    public init(
        month: Date,
        selectedDay: Date?,
        daysWithRecordings: Set<Date>,
        onPrevMonth: @escaping () -> Void,
        onNextMonth: @escaping () -> Void,
        onSelectDay: @escaping (Date) -> Void
    ) {
        self.month = month
        self.selectedDay = selectedDay
        self.daysWithRecordings = daysWithRecordings
        self.onPrevMonth = onPrevMonth
        self.onNextMonth = onNextMonth
        self.onSelectDay = onSelectDay
    }

    public var body: some View {
        VStack(spacing: HarcDesign.Space.xs) {
            header
            weekdayRow
            daysGrid
        }
    }

    private var header: some View {
        HStack {
            Button(action: onPrevMonth) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            Spacer()
            Text(monthTitle)
                .font(HarcDesign.Font.titleSm)
                .foregroundStyle(Color.harcOnSurface)
            Spacer()
            Button(action: onNextMonth) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { s in
                Text(s)
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var daysGrid: some View {
        let cells = monthCells()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
            ForEach(cells, id: \.self) { day in
                dayCell(for: day)
            }
        }
    }

    @ViewBuilder
    private func dayCell(for day: Date?) -> some View {
        if let day {
            let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
            let hasRec = daysWithRecordings.contains(calendar.startOfDay(for: day))
            let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
            Button {
                onSelectDay(day)
            } label: {
                VStack(spacing: 1) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(inMonth ? Color.harcOnSurface : Color.harcOnSurfaceVariant.opacity(0.4))
                    Circle()
                        .fill(hasRec ? Color.harcPrimary : Color.clear)
                        .frame(width: 4, height: 4)
                }
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.harcPrimary.opacity(0.18) : Color.clear)
                )
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(minHeight: 26)
        }
    }

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

    /// 7×6 = 42 cells, spanning the week that contains day-1 of the month
    /// through the week containing the last day.  Out-of-month cells
    /// still get a Date so arrow-key nav works.
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
