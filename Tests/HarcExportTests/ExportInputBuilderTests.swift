import Testing
import Foundation
import HarcStore
@testable import HarcExport

@Suite("ExportInputBuilder")
struct ExportInputBuilderTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        return try #require(url)
    }

    @Test("three speakers → three collapsed segments in order")
    func threeSpeakers() throws {
        let url = try fixtureURL("three-speakers")
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: url.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            tags: ["Acme"]
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.isDiarized)
        #expect(input.segments.count == 3)
        #expect(input.segments[0].speaker == 0)
        #expect(input.segments[1].speaker == 1)
        #expect(input.segments[2].speaker == 2)
        #expect(input.segments[0].text.contains("Hello"))
        #expect(input.tags == ["Acme"])
    }

    @Test("single-speaker JSON still emits attributed segments")
    func singleSpeaker() throws {
        let url = try fixtureURL("single-speaker")
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: url.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.segments.count == 1)
        #expect(input.segments[0].speaker == 0)
    }

    @Test("empty speakers array → single nil-speaker segment with joinedText")
    func noDiarization() throws {
        let url = try fixtureURL("no-diarization")
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: url.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(!input.isDiarized)
        #expect(input.segments.count == 1)
        #expect(input.segments[0].speaker == nil)
        #expect(input.segments[0].text == "No speakers here just text")
    }

    @Test("missing JSON with transcriptText → fallback single segment")
    func fallbackToTranscriptText() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: "/tmp/does-not-exist.json",
            startedAt: Date(),
            transcriptText: "plain fallback text"
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.segments.count == 1)
        #expect(input.segments[0].speaker == nil)
        #expect(input.segments[0].text == "plain fallback text")
    }

    @Test("missing JSON and nil transcriptText → empty segments")
    func totallyEmpty() {
        let rec = Recording(wavPath: "/tmp/fake.wav", startedAt: Date())
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.segments.isEmpty)
        #expect(input.tags.isEmpty)
    }

    @Test("tags flow from Recording.tags into ExportInput")
    func tagsFlow() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi",
            tags: ["Acme", "Q3"]
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.tags == ["Acme", "Q3"])
    }

    @Test("tags default to empty when Recording has none")
    func tagsEmptyByDefault() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi"
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.tags.isEmpty)
    }

    @Test("speakerNames flow from Recording.speakerNames into ExportInput")
    func speakerNamesFlow() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi",
            speakerNames: [0: "Jason", 1: "Amy"]
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.speakerNames == [0: "Jason", 1: "Amy"])
    }

    @Test("speakerNames defaults to empty when Recording has none")
    func speakerNamesEmptyByDefault() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi"
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.speakerNames.isEmpty)
    }
}
