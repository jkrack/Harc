import Testing
import Foundation
import AVFoundation
import FluidAudio
@testable import HarcSTT

/// Parakeet Unified EN spike — go/no-go evidence for the experimental
/// English model (`FluidInference/parakeet-unified-en-0.6b-coreml`).
///
/// The batch `UnifiedAsrManager.transcribe` returns only a `String`, but
/// `StreamingUnifiedAsrManager` exposes `consumeWordTimings()` (start/end
/// seconds on the global timeline, sub-word tokens merged on `▁`
/// boundaries) — the word→speaker attribution shape Harc's diarization
/// and per-word JSON export require. This suite is the empirical gate:
/// text quality, punctuation, and monotonic in-range word timings on the
/// same fixture the v2 tests use.
///
/// First run downloads the Unified model (~500 MB) via FluidAudio's
/// ModelHub into ~/Library/Application Support/FluidAudio/Models.
@Suite("Parakeet Unified spike", .tags(.slow))
struct ParakeetUnifiedSpikeTests {
    @Test("unified streaming path yields text, punctuation, and monotonic word timings on the fixture")
    func unifiedFixtureGate() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )

        let manager = StreamingUnifiedAsrManager()
        try await manager.loadModels()

        // Feed the whole fixture as one buffer, then flush.
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        try file.read(into: buffer)

        let started = Date()
        try await manager.appendAudio(buffer)
        let text = try await manager.finish()
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let words = await manager.consumeWordTimings()
        await manager.cleanup()

        let durationSeconds = Double(file.length) / format.sampleRate

        // Gate 1: non-empty, recognizable text.
        #expect(!text.isEmpty, "expected transcribed text from fixture")
        #expect(text.lowercased().contains("test"), "expected 'test' in transcription; got: \(text)")

        // Gate 2: punctuation/capitalization survive the streaming decode.
        #expect(text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil,
                "expected sentence punctuation; got: \(text)")
        #expect(text.first?.isUppercase == true, "expected leading capital; got: \(text)")

        // Gate 3 (decisive): word timings present, monotonic, in range.
        #expect(words.count > 0, "expected word timings from consumeWordTimings()")
        var previousStart = -Double.infinity
        for w in words {
            #expect(w.startTime >= previousStart, "word starts must be monotonic: \(words)")
            #expect(w.endTime >= w.startTime, "word end must not precede start: \(w)")
            // Allow ~1s slack past nominal duration for the provisional
            // frontier-token end documented on consumeTokenTimings().
            #expect(w.startTime >= 0 && w.endTime <= durationSeconds + 1.0,
                    "word timing out of fixture range (0–\(durationSeconds)s): \(w)")
            previousStart = w.startTime
        }

        // Evidence for the spike report (visible with --verbose).
        print("UNIFIED-SPIKE text: \(text)")
        print("UNIFIED-SPIKE words(\(words.count)): \(words.map { "\($0.word)[\(String(format: "%.2f", $0.startTime))-\(String(format: "%.2f", $0.endTime))]" }.joined(separator: " "))")
        print("UNIFIED-SPIKE latencyMs: \(elapsedMs) for \(String(format: "%.1f", durationSeconds))s audio")
    }

    @Test("v2 baseline on the same fixture, for the comparison table")
    func v2Baseline() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let transcriber = Transcriber()
        try await transcriber.loadModels()
        let started = Date()
        let result = try await transcriber.transcribe(audioPath: url.path, vad: false)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        print("V2-BASELINE text: \(result.text)")
        print("V2-BASELINE words: \(result.words.count), processingMs: \(result.processingMs), wallMs: \(elapsedMs)")
        #expect(!result.text.isEmpty)
    }

    @Test("Transcriber(engine: .unified) transcribes the fixture end-to-end with word timings")
    func unifiedEngineEndToEnd() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let transcriber = Transcriber(engine: .unified)
        try await transcriber.loadModels()
        let result = try await transcriber.transcribe(audioPath: url.path, vad: false)

        #expect(!result.text.isEmpty)
        #expect(result.text.lowercased().contains("test"), "got: \(result.text)")
        #expect(result.words.count > 0, "unified engine must produce word timings")
        var previousStart = Int.min
        for w in result.words {
            #expect(w.startMs >= previousStart, "word starts must be monotonic")
            #expect(w.endMs >= w.startMs)
            previousStart = w.startMs
        }
        print("UNIFIED-ENGINE text: \(result.text), words: \(result.words.count), processingMs: \(result.processingMs)")
    }
}

@Suite("ASR engine selection")
struct ASREngineSelectionTests {
    @Test("engine parse: known values, nil, and unknown fallback")
    func parseEngine() {
        #expect(HarcSTTCLI.parseEngine("v2") == .v2)
        #expect(HarcSTTCLI.parseEngine("unified") == .unified)
        #expect(HarcSTTCLI.parseEngine(nil) == .v2)
        #expect(HarcSTTCLI.parseEngine("") == .v2)
        #expect(HarcSTTCLI.parseEngine("whisper") == .v2)
    }

    @Test("pcm buffer round-trips samples for the unified feed path")
    func pcmBufferRoundTrip() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0]
        let buffer = Transcriber.pcmBuffer(from: samples, sampleRate: 16_000)
        let unwrapped = try! #require(buffer)
        #expect(unwrapped.frameLength == 4)
        #expect(unwrapped.format.sampleRate == 16_000)
        #expect(unwrapped.format.channelCount == 1)
        let data = unwrapped.floatChannelData![0]
        for (i, s) in samples.enumerated() {
            #expect(abs(data[i] - s) < 1e-6)
        }
    }
}
