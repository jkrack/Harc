import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("Transcriber VAD policy")
struct TranscriberVADPolicyTests {
    @Test("VAD bypasses short clips even when requested")
    func bypassesShortClips() {
        let rate = 16_000
        #expect(!Transcriber.shouldRunVAD(
            requested: true,
            sampleCount: 24 * rate,
            sampleRate: rate
        ))
    }

    @Test("VAD runs for longer clips when requested")
    func runsForLongerClips() {
        let rate = 16_000
        #expect(Transcriber.shouldRunVAD(
            requested: true,
            sampleCount: 31 * rate,
            sampleRate: rate
        ))
    }

    @Test("VAD stays off when disabled")
    func disabledStaysOff() {
        #expect(!Transcriber.shouldRunVAD(
            requested: false,
            sampleCount: 120 * 16_000,
            sampleRate: 16_000
        ))
    }
}

@Suite("Transcriber", .tags(.slow))
struct TranscriberTests {
    @Test(
        "transcribing short-speech.wav with vad: false produces non-empty text and word timings",
        .enabled(
            if: ProcessInfo.processInfo.environment["HARC_INTEGRATION_TESTS"] == "1",
            "Set HARC_INTEGRATION_TESTS=1 to run real transcription model tests."
        )
    )
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

    @Test(
        "transcribing short-speech.wav with vad: true keeps transcript similar and timestamps in range",
        .enabled(
            if: ProcessInfo.processInfo.environment["HARC_INTEGRATION_TESTS"] == "1",
            "Set HARC_INTEGRATION_TESTS=1 to run real transcription model tests."
        )
    )
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

    @Test("transcribe inside the failed-load cooldown throws .modelNotLoaded without re-attempting")
    func transcribeDuringCooldownThrows() async throws {
        let transcriber = Transcriber()
        // Simulate a load that just failed — the on-demand retry must be
        // gated by the cooldown, not hammer the network per request.
        await transcriber.setLastFailedLoadForTesting(Date())
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await transcriber.transcribe(audioPath: "/tmp/does-not-matter.wav", vad: false)
        }
        #expect(await transcriber.isLoaded == false)
    }

    @Test("load-retry cooldown decision")
    func loadRetryCooldownDecision() {
        let now = Date()
        // Never failed → always allowed.
        #expect(Transcriber.shouldAttemptLoad(lastFailedAt: nil, now: now))
        // Failed 5s ago with 30s cooldown → blocked.
        #expect(!Transcriber.shouldAttemptLoad(
            lastFailedAt: now.addingTimeInterval(-5), now: now, cooldown: 30
        ))
        // Failed 31s ago with 30s cooldown → allowed again.
        #expect(Transcriber.shouldAttemptLoad(
            lastFailedAt: now.addingTimeInterval(-31), now: now, cooldown: 30
        ))
    }
}

extension Tag {
    @Tag static var slow: Self
}
