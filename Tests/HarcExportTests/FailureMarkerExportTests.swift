import Foundation
import Testing
import HarcClient
import HarcCore
@testable import HarcExport

@Suite("Failure notices in exports")
struct FailureMarkerExportTests {
    @Test func documentAndSubtitlePathsRetainUnattributedNotice() {
        let notice = UntranscribedAudioMarker.text(startMs: 1000, endMs: 2000)
        let transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/failure.wav",
            joinedText: "Hello \(notice) Bye",
            words: [.init(text: "Hello", startMs: 0, endMs: 500), .init(text: "Bye", startMs: 2000, endMs: 2500)],
            speakers: [.init(speaker: 0, startMs: 0, endMs: 3000)], chunks: [])
        let segments = ExportInputBuilder.collapseToSegments(transcript: transcript)
        #expect(segments.map(\.text) == ["Hello", notice, "Bye"])
        #expect(segments.map(\.speaker) == [0, nil, 0])
        var untimed = transcript
        untimed.words = []
        #expect(ExportInputBuilder.collapseToSegments(transcript: untimed) ==
                [.init(speaker: nil, text: transcript.joinedText)])
        let cues = SubtitleExporter.makeCues(words: transcript.words, speakers: transcript.speakers,
                                            notices: UntranscribedAudioMarker.parse(in: transcript.joinedText))
        #expect(cues.map(\.text) == ["Hello", notice, "Bye"])
        #expect(cues.map(\.speaker) == [0, nil, 0])
        #expect(cues[1].startMs == 1000)
        #expect(cues[1].endMs == 2000)
        #expect(SubtitleExporter.srt(cues: cues, speakerNames: [0: "Alex"]).contains(notice))
        #expect(SubtitleExporter.vtt(cues: cues, speakerNames: [0: "Alex"]).contains(notice))
    }
}
