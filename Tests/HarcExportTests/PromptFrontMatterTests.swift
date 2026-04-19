import Testing
import Foundation
@testable import HarcExport

@Suite("PromptFrontMatter")
struct PromptFrontMatterTests {

    // MARK: formatDuration

    @Test("formatDuration", arguments: [
        (0, "0s"),
        (1, "1s"),
        (59, "59s"),
        (60, "1m"),
        (119, "1m"),        // truncated (not rounded to 2m)
        (3599, "59m"),
        (3600, "1h 0m"),
        (5400, "1h 30m"),
        (86400, "24h 0m"),
    ])
    func formatDuration(input: Int, expected: String) {
        #expect(PromptFrontMatter.formatDuration(input) == expected)
    }

    // MARK: formatRecorded

    @Test("formatRecorded — ISO 8601 with supplied timezone")
    func formatRecordedLA() {
        // 2026-04-19 14:32:00 America/Los_Angeles = 2026-04-19T21:32:00Z
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 19
        comps.hour = 14; comps.minute = 32; comps.second = 0
        comps.timeZone = tz
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        #expect(PromptFrontMatter.formatRecorded(date, timeZone: tz) == "2026-04-19T14:32:00-07:00")
    }

    @Test("formatRecorded — UTC renders +00:00")
    func formatRecordedUTC() {
        let tz = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        #expect(PromptFrontMatter.formatRecorded(date, timeZone: tz) == "2023-11-14T22:13:20+00:00")
    }
}
