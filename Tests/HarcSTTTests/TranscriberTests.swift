import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("Transcriber", .tags(.slow))
struct TranscriberTests {
    @Test("transcribing short-speech.wav produces non-empty text and word timings")
    func transcribeShortSpeech() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )

        let transcriber = Transcriber()
        try await transcriber.loadModels()

        let result: TranscribeResult = try await transcriber.transcribe(audioPath: url.path)

        #expect(!result.text.isEmpty, "expected transcribed text from fixture")
        #expect(result.words.count > 0, "expected at least one word timing")
        #expect(result.processingMs > 0, "processingMs should be positive")
        // The fixture says "Hello. This is a test recording for Harc."
        // Don't assert exact words — ASR can vary. Just confirm it mentions "test".
        #expect(result.text.lowercased().contains("test"), "expected 'test' in transcription; got: \(result.text)")
    }

    @Test("transcribe before loadModels throws .modelNotLoaded")
    func transcribeBeforeLoadThrows() async throws {
        let transcriber = Transcriber()
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await transcriber.transcribe(audioPath: "/tmp/does-not-matter.wav")
        }
    }
}

extension Tag {
    @Tag static var slow: Self
}
