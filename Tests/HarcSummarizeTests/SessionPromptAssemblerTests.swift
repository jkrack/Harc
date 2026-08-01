import Testing
import Foundation
import HarcCore
@testable import HarcSummarize

@Suite("SessionPromptAssembler")
struct SessionPromptAssemblerTests {

    private func part(
        text: String,
        speaker: Int = 0,
        name: String? = nil,
        startedAt: Date
    ) -> SessionPromptAssembler.Part {
        // One word per whitespace token, 100ms apiece, all in one segment.
        let tokens = text.split(separator: " ").map(String.init)
        let words = tokens.enumerated().map { i, t in
            Word(text: t, startMs: i * 100, endMs: i * 100 + 90)
        }
        let segment = SpeakerSegment(speaker: speaker, startMs: 0, endMs: tokens.count * 100)
        var names: [Int: String] = [:]
        if let name { names[speaker] = name }
        return .init(
            joinedText: text,
            words: words,
            speakers: [segment],
            speakerNames: names,
            startedAt: startedAt
        )
    }

    @Test("parts are ordered by startedAt with separators between them")
    func orderingAndSeparators() {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = early.addingTimeInterval(4 * 3600)
        // Pass out of order — assembly must sort.
        let result = SessionPromptAssembler.make(parts: [
            part(text: "afternoon words", name: "Jason", startedAt: late),
            part(text: "morning words", name: "Jason", startedAt: early),
        ])

        #expect(result.utterances.count == 4)
        #expect(result.utterances[0].speaker == nil)
        #expect(result.utterances[0].text.hasPrefix("— Recording started "))
        #expect(result.utterances[1].text == "morning words")
        #expect(result.utterances[2].speaker == nil)
        #expect(result.utterances[3].text == "afternoon words")

        // Person-resolved names carry through, unifying speakers across parts.
        #expect(result.utterances[1].speaker == "Jason")
        #expect(result.utterances[3].speaker == "Jason")
    }

    @Test("a single non-empty part gets no separator")
    func singlePartNoSeparator() {
        let result = SessionPromptAssembler.make(parts: [
            part(text: "solo recording", startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        #expect(result.utterances.count == 1)
        #expect(result.utterances[0].text == "solo recording")
    }

    @Test("empty parts are dropped, separator and all")
    func emptyPartsDropped() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let result = SessionPromptAssembler.make(parts: [
            part(text: "real words here", startedAt: base),
            .init(joinedText: "", words: [], speakers: [], speakerNames: [:],
                  startedAt: base.addingTimeInterval(3600)),
        ])
        // Only one surviving part → no separators at all.
        #expect(result.utterances.count == 1)
        #expect(result.utterances[0].text == "real words here")
    }

    @Test("unnamed speakers fall back to per-part default labels")
    func defaultLabels() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let result = SessionPromptAssembler.make(parts: [
            part(text: "first sitting", speaker: 0, startedAt: base),
            part(text: "second sitting", speaker: 1, startedAt: base.addingTimeInterval(3600)),
        ])
        let labels = result.utterances.compactMap(\.speaker)
        #expect(labels == ["Speaker 1", "Speaker 2"])
    }

    @Test("no parts yields an empty transcript")
    func noParts() {
        let result = SessionPromptAssembler.make(parts: [])
        #expect(result.utterances.isEmpty)
    }
}
