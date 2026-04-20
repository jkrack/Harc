import Testing
import Foundation
@testable import HarcExport

@Suite("ExportInput")
struct ExportInputTests {
    @Test("isDiarized true when any segment has a speaker id")
    func detectsDiarized() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: [
                .init(speaker: nil, text: "hi"),
                .init(speaker: 1, text: "there"),
            ]
        )
        #expect(input.isDiarized)
    }

    @Test("isDiarized false when all segments are speaker-nil")
    func detectsPlain() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: [.init(speaker: nil, text: "a paragraph")]
        )
        #expect(!input.isDiarized)
    }

    @Test("tags defaults to empty when omitted")
    func tagsDefaultsEmpty() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: []
        )
        #expect(input.tags.isEmpty)
    }

    @Test("tags round-trip via initializer")
    func tagsRoundTrip() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            tags: ["Harc", "standup"],
            segments: []
        )
        #expect(input.tags == ["Harc", "standup"])
    }

    @Test("speakerNames defaults to empty when omitted")
    func speakerNamesDefaultsEmpty() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: []
        )
        #expect(input.speakerNames.isEmpty)
    }

    @Test("speakerNames round-trips via initializer")
    func speakerNamesRoundTrip() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            speakerNames: [0: "Jason", 1: "Amy"],
            segments: []
        )
        #expect(input.speakerNames == [0: "Jason", 1: "Amy"])
    }
}
