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

    // MARK: yamlScalar

    @Test("yamlScalar — plain string passes through unquoted")
    func yamlScalarPlain() {
        #expect(PromptFrontMatter.yamlScalar("Standup with Jason") == "Standup with Jason")
        #expect(PromptFrontMatter.yamlScalar("Harc, standup") == "Harc, standup")
    }

    @Test("yamlScalar — mid-value ` #` (space-then-hash) forces quoting")
    func yamlScalarSpaceHash() {
        #expect(PromptFrontMatter.yamlScalar("Sprint 12 #backlog") == "\"Sprint 12 #backlog\"")
    }

    @Test("yamlScalar — values with : get quoted")
    func yamlScalarColon() {
        // A colon followed by space requires quoting per YAML 1.2.
        #expect(PromptFrontMatter.yamlScalar("foo: bar") == "\"foo: bar\"")
    }

    @Test("yamlScalar — leading-indicator characters get quoted")
    func yamlScalarIndicator() {
        #expect(PromptFrontMatter.yamlScalar("- dash lead") == "\"- dash lead\"")
        #expect(PromptFrontMatter.yamlScalar("# hash lead") == "\"# hash lead\"")
        #expect(PromptFrontMatter.yamlScalar("@at lead") == "\"@at lead\"")
    }

    @Test("yamlScalar — double-quoted escapes handle quotes and backslash")
    func yamlScalarEscapes() {
        #expect(PromptFrontMatter.yamlScalar(#"he said "hi""#) == #""he said \"hi\"""#)
        #expect(PromptFrontMatter.yamlScalar(#"path\to"#) == #""path\\to""#)
    }

    @Test("yamlScalar — whitespace-only/leading-or-trailing-space gets quoted")
    func yamlScalarWhitespace() {
        #expect(PromptFrontMatter.yamlScalar(" leading") == "\" leading\"")
        #expect(PromptFrontMatter.yamlScalar("trailing ") == "\"trailing \"")
        #expect(PromptFrontMatter.yamlScalar("") == "\"\"")
    }

    @Test("yamlScalar — newlines and tabs get escaped")
    func yamlScalarControlChars() {
        #expect(PromptFrontMatter.yamlScalar("a\nb") == "\"a\\nb\"")
        #expect(PromptFrontMatter.yamlScalar("a\tb") == "\"a\\tb\"")
    }

    @Test("yamlScalar — control chars below 0x20 are stripped before decision")
    func yamlScalarControlStripped() {
        // \u{0001} (SOH) gets stripped → just "ab", passes through plain.
        #expect(PromptFrontMatter.yamlScalar("a\u{0001}b") == "ab")
    }

    // MARK: speakerCount

    @Test("speakerCount — empty segments → 0")
    func speakerCountEmpty() {
        #expect(PromptFrontMatter.speakerCount(in: []) == 0)
    }

    @Test("speakerCount — nil-speaker segments don't count")
    func speakerCountNilOnly() {
        let segs: [ExportInput.Segment] = [
            .init(speaker: nil, text: "a"),
            .init(speaker: nil, text: "b"),
        ]
        #expect(PromptFrontMatter.speakerCount(in: segs) == 0)
    }

    @Test("speakerCount — distinct speaker ids are counted once each")
    func speakerCountDistinct() {
        let segs: [ExportInput.Segment] = [
            .init(speaker: 0, text: "a"),
            .init(speaker: 1, text: "b"),
            .init(speaker: 0, text: "c"),      // duplicate id
            .init(speaker: 2, text: "d"),
        ]
        #expect(PromptFrontMatter.speakerCount(in: segs) == 3)
    }

    @Test("speakerCount — mixed nil and ids")
    func speakerCountMixed() {
        let segs: [ExportInput.Segment] = [
            .init(speaker: nil, text: "a"),
            .init(speaker: 0, text: "b"),
        ]
        #expect(PromptFrontMatter.speakerCount(in: segs) == 1)
    }
}
