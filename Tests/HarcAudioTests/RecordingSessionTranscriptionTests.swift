import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcCore
import HarcClient
@testable import HarcAudio

@Suite("RecordingSession + transcription")
struct RecordingSessionTranscriptionTests {
    private enum TestFailure: Error { case unexpectedCommitOutcome }

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

    private struct SlowDiarizationError: LocalizedError {
        var errorDescription: String? { "delayed diarization failure" }
    }

    actor SlowFailingDiarizer: DiarizingClient {
        func diarize(audioPath: String) async throws -> DiarizeResult {
            try await Task.sleep(for: .milliseconds(350))
            throw SlowDiarizationError()
        }
    }

    /// Resume once the transcriber has assembled its first chunk, or after
    /// `timeout` — whichever comes first. Returning on timeout rather than
    /// failing here keeps the diagnosis in the assertions below, which say what
    /// was actually missing from the transcript.
    private func awaitFirstChunk(
        _ updates: AsyncStream<TranscriptUpdate>,
        timeout: Duration
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in updates { return }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func makeConstantBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.2 }
        return buf
    }

    @Test("standalone commit publishes WAV and transcript siblings")
    func standaloneCommitPublishesAllArtifacts() async throws {
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
            // Canned-result stub: the sparse-VAD fallback and the live-preview
            // pass would each consume extra queued results — this test is about
            // artifact files, not VAD or previews.
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )

        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            transcriber: transcriber
        )
        try await session.start(at: Date())

        // Wait for the first chunk to actually land rather than sleeping a fixed
        // 500 ms and hoping the pump got there. The pump polls every 50 ms, but
        // under parallel test load that window isn't guaranteed: if no chunk has
        // been consumed by the time stop() runs, finalize sees the whole 1.5 s as
        // one pending chunk, emits only "one", and the flush tail "two" never
        // exists. That raced at ~3/40 runs. `updates` yields once per assembled
        // chunk, so awaiting the first element is exactly the precondition this
        // test needs. Bounded so a real hang still fails instead of hanging.
        await awaitFirstChunk(transcriber.updates, timeout: .seconds(10))

        let captured = try await session.stop()
        #expect(FileManager.default.fileExists(atPath: captured.localMasterURL.path))
        #expect(captured.transcript != nil)
        #expect(captured.transcript?.startedAt == captured.startedAt)
        #expect(captured.transcript?.endedAt == captured.endedAt)

        let outcome = try await StandaloneRecordingCommitter(destination: destination).commit(captured)
        guard case .standalonePublished(let acceptedCapture, let result) = outcome else {
            throw TestFailure.unexpectedCommitOutcome
        }

        #expect(FileManager.default.fileExists(atPath: result.wavURL.path))
        #expect(!FileManager.default.fileExists(atPath: captured.localMasterURL.path))
        #expect(acceptedCapture.startedAt == captured.startedAt)
        #expect(acceptedCapture.endedAt == captured.endedAt)
        try #require(result.txtURL != nil)
        try #require(result.jsonURL != nil)
        #expect(FileManager.default.fileExists(atPath: result.txtURL!.path))
        #expect(FileManager.default.fileExists(atPath: result.jsonURL!.path))

        let txt = try String(contentsOf: result.txtURL!, encoding: .utf8)
        #expect(!txt.isEmpty)
        // Stub returned "one" and "two" — the flush tail must make it into the transcript.
        #expect(txt.contains("one"))
        #expect(txt.contains("two"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let persisted = try decoder.decode(
            SessionTranscript.self,
            from: Data(contentsOf: result.jsonURL!)
        )
        #expect(persisted.audioPath == result.wavURL.path)
        #expect(abs(persisted.startedAt.timeIntervalSince(captured.startedAt)) < 0.000_001)
        #expect(abs(persisted.endedAt.timeIntervalSince(captured.endedAt)) < 0.000_001)
    }

    @Test("capture endedAt is sampled before slow post-stop finalization")
    func endedAtExcludesFinalizationLatency() async throws {
        let mic = FakeMic(script: [makeConstantBuffer(frames: 1600)])
        let transcriber = ChunkedTranscriber(
            client: StubClient(results: [
                TranscribeResult(text: "captured", words: [], speakers: [], processingMs: 1),
            ]),
            diarizer: SlowFailingDiarizer(),
            vadEnabled: false,
            chunkDurationSeconds: 60,
            pollIntervalSeconds: 0.05,
            livePreviewIntervalSeconds: 0,
            chunkOverlapSeconds: 0
        )
        let session = RecordingSession(
            mic: mic,
            systemAudio: FakeSystem(),
            transcriber: transcriber
        )
        try await session.start(at: Date())
        try await Task.sleep(for: .milliseconds(100))

        let captured = try await session.stop()
        let returnedAt = Date()
        defer { try? FileManager.default.removeItem(at: captured.localMasterURL) }

        #expect(returnedAt.timeIntervalSince(captured.endedAt) >= 0.30)
        #expect(captured.transcript?.endedAt == captured.endedAt)
        #expect(captured.warnings.contains(
            .diarizationFailed(message: "delayed diarization failure")
        ))
    }
}
