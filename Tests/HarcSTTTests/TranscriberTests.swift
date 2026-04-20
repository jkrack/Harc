import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("Transcriber", .tags(.slow))
struct TranscriberTests {
    @Test("transcribing short-speech.wav with vad: false produces non-empty text and word timings")
    func transcribeShortSpeechVADOff() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )

        let transcriber = Transcriber()
        try await transcriber.loadModels()

        let result: TranscribeResult = try await transcriber.transcribe(audioPath: url.path, vad: false)

        #expect(!result.text.isEmpty, "expected transcribed text from fixture")
        #expect(result.words.count > 0, "expected at least one word timing")
        #expect(result.processingMs > 0, "processingMs should be positive")
        #expect(result.text.lowercased().contains("test"), "expected 'test' in transcription; got: \(result.text)")
    }

    @Test("transcribing short-speech.wav with vad: true keeps transcript similar and timestamps in range")
    func transcribeShortSpeechVADOn() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )

        let transcriber = Transcriber()
        try await transcriber.loadModels()

        let result: TranscribeResult = try await transcriber.transcribe(audioPath: url.path, vad: true)

        #expect(!result.text.isEmpty, "expected transcribed text from fixture")
        // Fixture is ~3 seconds of speech with minimal silence — VAD should not produce empty output.
        #expect(result.text.lowercased().contains("test"), "expected 'test' in transcription; got: \(result.text)")
        // Every word's timestamps must fit within the fixture's 3-second duration.
        for w in result.words {
            #expect(w.startMs >= 0, "negative startMs: \(w)")
            #expect(w.endMs <= 3_200, "endMs past fixture duration: \(w)")   // 3s + tiny padding slack
            #expect(w.endMs >= w.startMs, "endMs before startMs: \(w)")
        }
    }

    @Test("transcribe before loadModels throws .modelNotLoaded (vad: false)")
    func transcribeBeforeLoadThrows() async throws {
        let transcriber = Transcriber()
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await transcriber.transcribe(audioPath: "/tmp/does-not-matter.wav", vad: false)
        }
    }
}

extension Tag {
    @Tag static var slow: Self
}
