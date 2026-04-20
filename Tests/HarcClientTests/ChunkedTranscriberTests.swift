import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcCore
@testable import HarcClient

@Suite("ChunkedTranscriber")
struct ChunkedTranscriberTests {
    /// Fake client that returns canned results based on call count.
    actor FakeClient: TranscribingClient {
        var calls: [(path: String, diarize: Bool, vad: Bool)] = []
        var results: [TranscribeResult]
        init(results: [TranscribeResult]) { self.results = results }
        func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
            calls.append((audioPath, diarize, vad))
            if results.isEmpty {
                return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
            }
            return results.removeFirst()
        }
    }

    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-ct-\(UUID().uuidString.prefix(8)).wav")
    }

    private func writeSineWAV(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        try file.write(from: buf)
    }

    @Test("finalize assembles chunk results with rebased word timings")
    func assemblesMultipleChunks() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 2.5)

        let fake = FakeClient(results: [
            TranscribeResult(
                text: "hello",
                words: [Word(text: "hello", startMs: 0, endMs: 500)],
                speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)],
                processingMs: 10
            ),
            TranscribeResult(
                text: "world",
                words: [Word(text: "world", startMs: 0, endMs: 400)],
                speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)],
                processingMs: 12
            ),
            TranscribeResult(
                text: "tail",
                words: [Word(text: "tail", startMs: 0, endMs: 200)],
                speakers: [],
                processingMs: 5
            ),
        ])

        let transcriber = ChunkedTranscriber(
            client: fake,
            diarize: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05
        )
        await transcriber.start(audioURL: url)
        // Give the pump time to consume 2 full chunks.
        try await Task.sleep(nanoseconds: 500_000_000)

        let start = Date().addingTimeInterval(-3)
        let end = Date()
        let transcript = try await transcriber.finalize(startedAt: start, endedAt: end)

        #expect(transcript.chunks.count == 3, "expected 2 full + 1 tail chunk, got \(transcript.chunks.count)")
        #expect(transcript.joinedText == "hello world tail")
        // Second chunk's "world" word was at chunk-local 0ms; should rebase to 1000ms.
        let worldWord = transcript.words.first { $0.text == "world" }
        #expect(worldWord?.startMs == 1000, "expected world rebased to 1000ms, got \(worldWord?.startMs ?? -1)")
        // Tail chunk's "tail" word was at chunk-local 0ms; should rebase to 2000ms.
        let tailWord = transcript.words.first { $0.text == "tail" }
        #expect(tailWord?.startMs == 2000)
    }

    @Test("vadEnabled:false forwards vad=false to client per chunk")
    func vadEnabledForwardsToClient() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.2)

        let fake = FakeClient(results: [
            TranscribeResult(text: "one", words: [], speakers: [], processingMs: 1),
            TranscribeResult(text: "two", words: [], speakers: [], processingMs: 1),
        ])

        let transcriber = ChunkedTranscriber(
            client: fake,
            diarize: false,
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)

        _ = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        #expect(await fake.calls.first?.vad == false)
    }

    @Test("applies vocabulary to chunk text and joinedText")
    func vocabularyIsApplied() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.2)

        let fake = FakeClient(results: [
            TranscribeResult(
                text: "Arakeet is up",
                words: [Word(text: "Arakeet", startMs: 0, endMs: 500)],
                speakers: [],
                processingMs: 1
            ),
            TranscribeResult(
                text: "arakeet again",
                words: [Word(text: "arakeet", startMs: 0, endMs: 400)],
                speakers: [],
                processingMs: 1
            ),
        ])

        let vocab = Vocabulary(entries: [VocabularyEntry(from: "Arakeet", to: "Parakeet")])
        let transcriber = ChunkedTranscriber(
            client: fake,
            diarize: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            vocabulary: vocab
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)

        let final = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        // Both chunks rewritten with case preservation; joinedText reflects per-chunk passes.
        let chunkTexts = final.chunks.map(\.text)
        #expect(chunkTexts.contains("Parakeet is up"))
        #expect(chunkTexts.contains("parakeet again"))
        #expect(!final.joinedText.contains("Arakeet"))
    }
}
