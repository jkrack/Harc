import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcCore
import HarcClient
@testable import HarcAudio

@Suite("RecordingSession + transcription")
struct RecordingSessionTranscriptionTests {
    private final class SendableBuffers: @unchecked Sendable {
        let buffers: [AVAudioPCMBuffer]
        init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
    }

    actor FakeMic: MicCaptureSource {
        nonisolated let script: [AVAudioPCMBuffer]
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        init(script: [AVAudioPCMBuffer]) { self.script = script }
        func requestPermission() async throws {}
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBuffers(script)
            Task.detached { for b in box.buffers { cont.yield(b) }; cont.finish() }
            return stream
        }
        func stop() async { continuation?.finish() }
    }

    actor FakeSystem: SystemAudioCaptureSource {
        func requestPermission() async throws { throw AudioError.systemAudioPermissionDenied }
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            throw AudioError.systemAudioPermissionDenied
        }
        func stop() async {}
    }

    /// Fake transcribing client: returns canned text per-call.
    actor StubClient: TranscribingClient {
        var results: [TranscribeResult]
        init(results: [TranscribeResult]) { self.results = results }
        func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
            if results.isEmpty {
                return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
            }
            return results.removeFirst()
        }
    }

    private func makeConstantBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.2 }
        return buf
    }

    @Test("stop() returns .wav + .txt + .json when a transcriber is attached")
    func stopReturnsAllArtifacts() async throws {
        let base = URL(fileURLWithPath: "/tmp/harc-rst-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // 24000 frames = 1.5 s of audio in a single buffer: the pump will see one
        // full 1-s chunk (first 16000 frames → "one") and leave the remaining 0.5 s
        // (8000 frames) for the flush tail → "two".  A single buffer avoids the
        // race where stop()/cancel() interrupts the pump before a second buffer is
        // written.
        let mic = FakeMic(script: [
            makeConstantBuffer(frames: 24000),
        ])
        let sys = FakeSystem()
        let destination = RecordingDestination(baseDirectory: base)

        let stub = StubClient(results: [
            TranscribeResult(text: "one", words: [], speakers: [], processingMs: 1),
            TranscribeResult(text: "two", words: [], speakers: [], processingMs: 1),
        ])
        let transcriber = ChunkedTranscriber(
            client: stub,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05
        )

        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            destination: destination,
            transcriber: transcriber
        )
        try await session.start(at: Date())
        try await Task.sleep(nanoseconds: 500_000_000)
        let result = try await session.stop()

        #expect(FileManager.default.fileExists(atPath: result.wavURL.path))
        try #require(result.txtURL != nil)
        try #require(result.jsonURL != nil)
        #expect(FileManager.default.fileExists(atPath: result.txtURL!.path))
        #expect(FileManager.default.fileExists(atPath: result.jsonURL!.path))

        let txt = try String(contentsOf: result.txtURL!, encoding: .utf8)
        #expect(!txt.isEmpty)
        // Stub returned "one" and "two" — the flush tail must make it into the transcript.
        #expect(txt.contains("one"))
        #expect(txt.contains("two"))
    }
}
