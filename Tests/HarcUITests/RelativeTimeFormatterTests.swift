import Testing
import Foundation
@testable import HarcUI

@Suite("RelativeTimeFormatter")
struct RelativeTimeFormatterTests {
    private func ref(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test("less than a minute → just now")
    func justNow() {
        let now = ref(2026, 4, 18)
        #expect(RelativeTimeFormatter.format(now.addingTimeInterval(-30), now: now) == "just now")
    }

    @Test("minutes ago")
    func minutesAgo() {
        let now = ref(2026, 4, 18)
        #expect(RelativeTimeFormatter.format(now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
    }

    @Test("hours ago (same day)")
    func hoursAgo() {
        let now = ref(2026, 4, 18, 18)
        let earlier = ref(2026, 4, 18, 9)
        #expect(RelativeTimeFormatter.format(earlier, now: now) == "9h ago")
    }

    @Test("yesterday")
    func yesterday() {
        let now = ref(2026, 4, 18, 10)
        let y = ref(2026, 4, 17, 22)
        #expect(RelativeTimeFormatter.format(y, now: now) == "Yesterday")
    }

    @Test("within last week → weekday name")
    func weekday() {
        let now = ref(2026, 4, 18)
        let d = ref(2026, 4, 14)
        let out = RelativeTimeFormatter.format(d, now: now)
        #expect(out.count > 3)
    }

    @Test("same year older → MMM d")
    func monthDay() {
        let now = ref(2026, 4, 18)
        let d = ref(2026, 1, 5)
        #expect(RelativeTimeFormatter.format(d, now: now) == "Jan 5")
    }

    @Test("different year → MMM d yyyy")
    func withYear() {
        let now = ref(2026, 4, 18)
        let d = ref(2025, 11, 12)
        #expect(RelativeTimeFormatter.format(d, now: now) == "Nov 12 2025")
    }

    @Test("relativeOrDated uses relative format within threshold")
    func relativeOrDatedRecent() {
        let now = ref(2026, 4, 18, 12)
        let d = ref(2026, 4, 18, 10)
        #expect(RelativeTimeFormatter.relativeOrDated(d, now: now) == "2h ago")
    }

    @Test("relativeOrDated includes year and time beyond threshold")
    func relativeOrDatedOld() {
        let now = ref(2026, 4, 18, 12)
        let d = ref(2025, 10, 1, 7, 25)
        #expect(RelativeTimeFormatter.relativeOrDated(d, now: now) == "Oct 1, 2025, 7:25 AM")
    }
}
