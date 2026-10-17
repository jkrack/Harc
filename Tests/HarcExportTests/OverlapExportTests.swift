import Foundation
import Testing
import HarcClient
import HarcCore
import HarcStore
@testable import HarcExport

@Suite("Overlap attribution in exports")
struct OverlapExportTests {
    @Test func documentAndSubtitleOutputsDoNotNameMixedWords() throws {
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "before mixed after", words: [
                .init(text: "before", startMs: 0, endMs: 100),
                .init(text: "mixed", startMs: 100, endMs: 300),
                .init(text: "after", startMs: 300, endMs: 400)
            ], speakers: [.init(speaker: 0, startMs: 0, endMs: 400)], chunks: [])
        transcript.overlapRanges = [try SpeechOverlapRange(startMs: 250, endMs: 300)]
        let segments = ExportInputBuilder.collapseToSegments(transcript: transcript)
        #expect(segments.map(\.speaker) == [nil, 0, nil, 0])
        #expect(segments.map(\.text) == [
            "Overlapping voices detected. Speaker attribution may be incomplete.",
            "before", "Overlapping voices: mixed", "after"
        ])
        let input = ExportInput(title: "Overlap", startedAt: Date(), durationSeconds: 1,
                                speakerNames: [0: "Alice"], segments: segments)
        #expect(MarkdownExporter.render(input).contains("Overlapping voices: mixed"))
        let cues = SubtitleExporter.makeCues(words: transcript.words, speakers: transcript.speakers,
                                            notices: [], overlapRanges: transcript.overlapRanges)
        #expect(cues.map(\.speaker) == [0, nil, 0])
        #expect(cues.map(\.text) == ["before", "Overlapping voices: mixed", "after"])
        #expect(cues.allSatisfy { $0.endMs > $0.startMs })
        for rendered in [SubtitleExporter.srt(cues: cues, speakerNames: [0: "Alice"]),
                         SubtitleExporter.vtt(cues: cues, speakerNames: [0: "Alice"])] {
            #expect(rendered.contains("Overlapping voices: mixed"))
            #expect(!rendered.contains("Alice: mixed"))
        }
        transcript.words = []
        #expect(ExportInputBuilder.collapseToSegments(transcript: transcript).map(\.speaker) == [nil, nil])
    }

    @Test func fileExportsCarrySavedOverlapEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("transcript.json")
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "mixed", words: [.init(text: "mixed", startMs: 0, endMs: 500)],
            speakers: [.init(speaker: 0, startMs: 0, endMs: 500)], chunks: [])
        transcript.overlapRanges = [try SpeechOverlapRange(startMs: 0, endMs: 500)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(transcript).write(to: sidecar)
        var recording = Recording(wavPath: "/tmp/fixture.wav", startedAt: transcript.startedAt)
        recording.jsonPath = sidecar.path
        recording.speakerNames = [0: "Alice"]
        for (index, format) in [ExportFormat.markdown, .prompt, .srt, .vtt].enumerated() {
            let destination = directory.appendingPathComponent("export-\(index)")
            try ExportService.write(recording: recording, format: format, to: destination, includeSummary: false)
            let rendered = try String(contentsOf: destination, encoding: .utf8)
            #expect(rendered.contains("Overlapping voices: mixed"))
            #expect(!rendered.contains("Alice"))
        }
    }

    @Test func simultaneousFailureAndOverlapNoticesRemainReadable() throws {
        let failed = UntranscribedAudioMarker.text(startMs: 1000, endMs: 1500)
        let cues = SubtitleExporter.makeCues(words: [], speakers: [],
            notices: UntranscribedAudioMarker.parse(in: failed),
            overlapRanges: [try SpeechOverlapRange(startMs: 1000, endMs: 1500)])
        #expect(cues.allSatisfy { $0.endMs > $0.startMs })
        #expect(cues.map(\.text).joined().contains(failed))
        #expect(cues.map(\.text).joined().contains("Overlapping voices detected."))
    }

    @Test func unrecognizedOverlapStillProducesAnUnattributedCue() throws {
        let cues = SubtitleExporter.makeCues(words: [
            .init(text: "before", startMs: 0, endMs: 500),
            .init(text: "after", startMs: 2000, endMs: 2500)
        ], speakers: [.init(speaker: 0, startMs: 0, endMs: 3000)], notices: [],
            overlapRanges: [try SpeechOverlapRange(startMs: 1000, endMs: 1500)])
        #expect(cues.map(\.text) == ["before", "Overlapping voices detected.", "after"])
        #expect(cues.map(\.speaker) == [0, nil, 0])
        #expect(cues[1].startMs == 1000)
        #expect(cues[1].endMs == 1500)
    }
}
