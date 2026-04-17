import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("Diarizer", .tags(.slow))
struct DiarizerTests {
    @Test("diarizing short-speech.wav returns at least one speaker segment")
    func diarizeShortSpeech() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let diarizer = Diarizer()
        try await diarizer.loadModels()

        let segments = try await diarizer.diarize(audioPath: url.path)

        #expect(segments.count >= 1, "expected at least one speaker segment")
        for segment in segments {
            #expect(segment.endMs > segment.startMs, "segment ends should come after starts")
        }
    }

    @Test("diarize before loadModels throws .modelNotLoaded")
    func diarizeBeforeLoadThrows() async throws {
        let diarizer = Diarizer()
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await diarizer.diarize(audioPath: "/tmp/whatever.wav")
        }
    }
}
