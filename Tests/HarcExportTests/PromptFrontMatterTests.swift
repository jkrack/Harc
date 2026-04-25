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

    // MARK: render

    private func laTZ() -> TimeZone { TimeZone(identifier: "America/Los_Angeles")! }

    private func fixedDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 19
        comps.hour = 14; comps.minute = 32; comps.second = 0
        comps.timeZone = laTZ()
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    @Test("render — full set of fields in fixed order")
    func renderFull() {
        let input = ExportInput(
            title: "Standup with Jason",
            startedAt: fixedDate(),
            durationSeconds: 2820, // 47m
            tags: ["standup", "Jason", "Harc"],
            segments: [
                .init(speaker: 0, text: "Hi"),
                .init(speaker: 1, text: "Hey"),
            ]
        )
        let expected = """
        ---
        title: Standup with Jason
        recorded: 2026-04-19T14:32:00-07:00
        duration: 47m
        tags: standup, Jason, Harc
        speakers: 2
        ---
        """
        #expect(PromptFrontMatter.render(input, timeZone: laTZ()) == expected)
    }

    @Test("render — omits empty title")
    func renderOmitsEmptyTitle() {
        let input = ExportInput(
            title: "",
            startedAt: fixedDate(),
            durationSeconds: 30,
            segments: [.init(speaker: nil, text: "x")]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("title:"))
        #expect(out.contains("recorded: 2026-04-19T14:32:00-07:00"))
        #expect(out.contains("duration: 30s"))
    }

    @Test("render — omits duration when nil")
    func renderOmitsDuration() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: nil,
            segments: []
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("duration:"))
    }

    @Test("render — omits tags when empty")
    func renderOmitsTags() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 30,
            tags: [],
            segments: []
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("tags:"))
    }

    @Test("render — omits speakers when count < 2")
    func renderOmitsSpeakersSingle() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 30,
            segments: [.init(speaker: 0, text: "alone")]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("speakers:"))
    }

    @Test("render — tags with a colon force the whole tags line to be quoted")
    func renderQuotesTagsWithColon() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 30,
            tags: ["foo: bar", "baz"],
            segments: []
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("tags: \"foo: bar, baz\""))
    }

    @Test("render — emits duration line even when durationSeconds is 0")
    func renderEmitsDurationZero() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 0,
            segments: []
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("duration: 0s"))
    }

    @Test("render — emits participants line when all speakers overridden")
    func renderEmitsParticipantsFullOverride() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Jason", 1: "Amy"],
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("participants: Jason, Amy"))
        #expect(out.contains("speakers: 2"))
    }

    @Test("render — participants mixes names and Speaker N for partial override")
    func renderParticipantsPartial() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Jason"],
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("participants: Jason, Speaker 2"))
    }

    @Test("render — omits participants when speakerNames is empty")
    func renderOmitsParticipantsNoOverride() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("participants:"))
        #expect(out.contains("speakers: 2"))
    }

    @Test("render — omits participants for single-speaker recordings even with override")
    func renderOmitsParticipantsSingleSpeaker() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Jason"],
            segments: [.init(speaker: 0, text: "a")]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("participants:"))
        #expect(!out.contains("speakers:"))
    }

    @Test("render — participants with a colon in a name forces quoting")
    func renderParticipantsQuotesColon() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Foo: Bar", 1: "Amy"],
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("participants: \"Foo: Bar, Amy\""))
    }

    @Test("render without summary is byte-identical to the legacy single-arg render")
    func renderNoSummaryByteIdentical() {
        let input = ExportInput(
            title: "Q3 planning",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            durationSeconds: 3600,
            tags: ["team"],
            speakerNames: [0: "Amy", 1: "Jason"],
            segments: [
                .init(speaker: 0, text: "We should…"),
                .init(speaker: 1, text: "Agreed."),
            ]
        )
        let tz = TimeZone(identifier: "UTC")!
        let legacy = PromptFrontMatter.render(input, timeZone: tz)
        let overloaded = PromptFrontMatter.render(input, summary: nil, timeZone: tz)
        #expect(legacy == overloaded)
    }

    @Test("render with summary emits summary_model and summarized_at before closing ---")
    func renderWithSummaryEmitsNewKeys() {
        let input = ExportInput(
            title: "Q3 planning",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            durationSeconds: 3600,
            segments: [.init(speaker: nil, text: "hi")]
        )
        let summary = PromptSummaryBlock(
            summaryMarkdown: "s",
            actionItemsMarkdown: "a",
            modelID: "gemma-4-e2b-it-4bit",
            generatedAt: Date(timeIntervalSince1970: 1_714_003_800)
        )
        let tz = TimeZone(identifier: "UTC")!
        let out = PromptFrontMatter.render(input, summary: summary, timeZone: tz)

        #expect(out.contains("summary_model: gemma-4-e2b-it-4bit"))
        #expect(out.contains("summarized_at: 2024-04-25T00:10:00+00:00"))

        // Keys must appear INSIDE the front-matter block, before the closing ---.
        let lines = out.components(separatedBy: "\n")
        guard let openIdx = lines.firstIndex(of: "---"),
              let closeIdx = lines.lastIndex(of: "---") else {
            Issue.record("front-matter fences missing"); return
        }
        let modelLineIdx = lines.firstIndex(where: { $0.hasPrefix("summary_model:") })
        let dateLineIdx = lines.firstIndex(where: { $0.hasPrefix("summarized_at:") })
        if let modelIdx = modelLineIdx {
            #expect(openIdx < modelIdx && modelIdx < closeIdx)
        } else {
            Issue.record("summary_model line not found")
        }
        if let dateIdx = dateLineIdx {
            #expect(openIdx < dateIdx && dateIdx < closeIdx)
        } else {
            Issue.record("summarized_at line not found")
        }
    }

    @Test("render with summary escapes modelID via yamlScalar when it contains reserved chars")
    func renderSummaryModelYamlEscape() {
        let input = ExportInput(
            title: "x",
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            durationSeconds: nil,
            segments: [.init(speaker: nil, text: "hi")]
        )
        let summary = PromptSummaryBlock(
            summaryMarkdown: "s",
            actionItemsMarkdown: "a",
            modelID: "has: colon",
            generatedAt: Date(timeIntervalSince1970: 1_714_003_800)
        )
        let out = PromptFrontMatter.render(input, summary: summary, timeZone: TimeZone(identifier: "UTC")!)
        #expect(out.contains("summary_model: \"has: colon\""))
    }
}
