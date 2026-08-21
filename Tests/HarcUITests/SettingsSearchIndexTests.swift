import Testing
@testable import HarcUI

struct SettingsSearchIndexTests {
    @Test("every pane is reachable by search")
    func everyPaneIsIndexed() {
        for pane in SettingsPane.allCases {
            let entries = SettingsSearchIndex.entries.filter { $0.pane == pane }
            #expect(
                !entries.isEmpty,
                "\(pane.title) has no search entries — it can only be found by scrolling the sidebar."
            )
        }
    }

    @Test("an empty or whitespace query matches nothing")
    func emptyQueryMatchesNothing() {
        #expect(SettingsSearchIndex.results(for: "").isEmpty)
        #expect(SettingsSearchIndex.results(for: "   ").isEmpty)
    }

    /// The point of the keyword lists: settings are findable by the name the
    /// user knows, not only the label Harc prints. "Diarization" appears
    /// nowhere in the visible label "Speakers".
    @Test(
        "settings are findable by the word a user would actually type",
        arguments: [
            ("diarization", SettingsPane.transcription),
            ("vad", SettingsPane.transcription),
            ("jargon", SettingsPane.transcription),
            ("push to talk", SettingsPane.dictation),
            ("gemma", SettingsPane.ai),
            ("hugging face", SettingsPane.ai),
            ("uninstall", SettingsPane.about),
            ("tcc", SettingsPane.about),
            ("zoom", SettingsPane.recording),
            ("login item", SettingsPane.general),
            ("last seen", SettingsPane.hostSync),
            ("grpc", SettingsPane.hostSync),
            ("missing recordings", SettingsPane.hostSync),
        ]
    )
    func findsByKeyword(query: String, expected: SettingsPane) {
        let panes = Set(SettingsSearchIndex.results(for: query).map(\.pane))
        #expect(
            panes.contains(expected),
            "\"\(query)\" should surface a setting in \(expected.title); matched \(panes.map(\.title))"
        )
    }

    @Test("matching ignores case and surrounding whitespace")
    func matchingIsCaseAndWhitespaceInsensitive() {
        let plain = SettingsSearchIndex.results(for: "vocabulary")
        let shouty = SettingsSearchIndex.results(for: "  VOCABULARY  ")
        #expect(!plain.isEmpty)
        #expect(plain.map(\.id) == shouty.map(\.id))
    }

    @Test("a pane's own name finds its settings")
    func paneTitleMatches() {
        for pane in SettingsPane.allCases {
            let panes = Set(SettingsSearchIndex.results(for: pane.title).map(\.pane))
            #expect(panes.contains(pane), "Searching \"\(pane.title)\" should reach that pane.")
        }
    }

    @Test("entry identifiers are unique")
    func entryIDsAreUnique() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        #expect(ids.count == Set(ids).count, "Duplicate search entries render as duplicate sidebar rows.")
    }
}
