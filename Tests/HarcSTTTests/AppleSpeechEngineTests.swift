import AVFoundation
import CoreMedia
import Foundation
import HarcCore
import Speech
import Testing
@testable import HarcSTT

@Suite("Apple on-device speech timing")
struct AppleSpeechEngineTests {
    private func timed(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
        var value = AttributedString(text)
        value.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 48_000),
            end: CMTime(seconds: end, preferredTimescale: 48_000)
        )
        return value
    }

    @Test("default engine is Apple, without silently selecting a legacy engine")
    func defaultEngine() async {
        #expect(await Transcriber().engine == .apple)
        #expect(HarcSTTCLI.parseEngine(nil) == .apple)
        #expect(HarcSTTCLI.parseEngine("apple") == .apple)
        #expect(HarcSTTCLI.parseEngine("unified") == .unified)
    }

    @Test("timing preserves gaps and subword boundaries for speaker alignment")
    func timings() throws {
        let text = timed(" Good", 0.1, 0.3) + timed(" morning", 1.2, 1.7) + timed(".", 1.7, 1.8)
        let words = try AppleSpeechEngine.timedWords(from: text, durationSeconds: 3)
        #expect(words.map(\.startMs) == [100, 1200, 1700])
        #expect(words.map(\.endMs) == [300, 1700, 1800])
        let display = Word.displayWords(from: words)
        #expect(display.map(\.text) == ["Good", "morning."])
        #expect(display[1].endMs == 1800)
        #expect(display[1].resolvedSpeakerIndex(in: [SpeakerSegment(speaker: 2, startMs: 1000, endMs: 2000)]) == 2)
    }

    @Test("untimed whitespace keeps lexical boundaries")
    func whitespace() throws {
        let text = timed(" Hello", 0, 0.3) + AttributedString(" ") + timed("world", 0.5, 1)
        let words = try AppleSpeechEngine.timedWords(from: text, durationSeconds: 2)
        #expect(Word.displayWords(from: words).map(\.text) == ["Hello", "world"])
    }

    @Test("final-result seams retain whitespace and cannot join different words")
    func finalBoundaries() throws {
        for trailing in ["", " "] {
            var text = timed(" Hello world", 0, 1) + AttributedString(trailing)
            AppleSpeechEngine.appendFinal(timed("Again", 1.2, 2), to: &text)
            #expect(String(text.characters) == " Hello world Again")
            let words = try AppleSpeechEngine.timedWords(from: text, durationSeconds: 3)
            #expect(Word.displayWords(from: words).map(\.text) == ["Hello world", "Again"])
        }
    }

    @Test("missing lexical timing is a failure, not a partial transcript")
    func missingTiming() {
        #expect(throws: DaemonError.self) {
            try AppleSpeechEngine.timedWords(from: AttributedString("missing"), durationSeconds: 3)
        }
    }

    @Test("negative and out of file times are rejected")
    func invalidTiming() {
        for value in [timed("word", -1, 1), timed("word", 1, 5), timed("word", 2, 1)] {
            #expect(throws: DaemonError.self) {
                try AppleSpeechEngine.timedWords(from: value, durationSeconds: 3)
            }
        }
    }

    @Test("cancelled request does not start file analysis")
    func cancelledBeforeStart() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleSpeechEngine.transcribe(audioPath: "/nonexistent/private-recording.wav")
        }
        do {
            _ = try await task.value
            Issue.record("cancelled transcription unexpectedly succeeded")
        } catch is CancellationError {} catch {
            Issue.record("expected cancellation, received \(error)")
        }
    }

    @Test("missing file fails locally without exposing path")
    func missingFile() async {
        await #expect(throws: DaemonError.audioLoadFailed("Could not open audio for Apple speech")) {
            try await AppleSpeechEngine.transcribe(audioPath: "/nonexistent/private-recording.wav")
        }
    }
}
