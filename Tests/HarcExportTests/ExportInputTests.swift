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
}
