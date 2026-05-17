import Foundation

/// Human-friendly relative timestamps like "2m ago", "1h ago", "Yesterday", "Nov 12".
/// Deterministic — a `now` override is accepted for tests.
public enum RelativeTimeFormatter {
    public static func format(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if cal.isDate(date, inSameDayAs: now) { return "\(hours)h ago" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        // Within the last 7 days → weekday name
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: now),
           date >= cal.startOfDay(for: weekAgo) {
            let f = DateFormatter(); f.dateFormat = "EEEE"
            return f.string(from: date)
        }
        // Within the same year → "Nov 12"
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return f.string(from: date)
        }
        // Older → "Nov 12 2024"
        let f = DateFormatter(); f.dateFormat = "MMM d yyyy"
        return f.string(from: date)
    }

    public static func relativeOrDated(
        _ date: Date,
        now: Date = Date(),
        threshold: TimeInterval = 180 * 86_400
    ) -> String {
        if now.timeIntervalSince(date) <= threshold {
            return format(date, now: now)
        }

        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy, h:mm a"
        return f.string(from: date)
    }
}
