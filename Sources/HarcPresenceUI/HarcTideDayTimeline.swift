import SwiftUI

/// Daily recording intervals, rather than invented audio-energy samples.
public struct HarcTideDayTimeline: View {
    let intervals: [DateInterval]
    let day: Date
    @Environment(\.calendar) private var calendar

    public init(intervals: [DateInterval], day: Date = .now) {
        self.intervals = intervals
        self.day = day
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Canvas { context2D, size in
                guard let bounds = calendar.dateInterval(of: .day, for: day) else { return }
                let baseline = size.height - 8
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: baseline))
                axis.addLine(to: CGPoint(x: size.width, y: baseline))
                context2D.stroke(axis, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                for interval in intervals {
                    let start = max(interval.start, bounds.start)
                    let end = min(interval.end, bounds.end)
                    guard end > start else { continue }
                    let x = start.timeIntervalSince(bounds.start) / bounds.duration * size.width
                    let width = max(2, end.timeIntervalSince(start) / bounds.duration * size.width)
                    let rect = CGRect(x: x, y: 8, width: width, height: max(1, baseline - 8))
                    context2D.fill(Path(roundedRect: rect, cornerRadius: min(5, width / 2)),
                                   with: .color(HarcTideStyle.ocean.opacity(0.8)))
                }
                if bounds.contains(context.date) {
                    let x = context.date.timeIntervalSince(bounds.start) / bounds.duration * size.width
                    HarcTideStyle.drawNowDot(in: context2D, at: CGPoint(x: x, y: baseline))
                }
            }
        }
        .accessibilityLabel("Recordings across the day")
        .accessibilityValue("Each blue interval represents a recording; the dot marks the current time")
    }
}
