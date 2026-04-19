import Testing
import Foundation
@testable import HarcExport

@Suite("PromptFrontMatter")
struct PromptFrontMatterTests {

    // MARK: formatDuration

    @Test("formatDuration — 0 seconds", arguments: [
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
}
