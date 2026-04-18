import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import HarcAudio

// Sendable box so non-Sendable AVAudioPCMBuffer arrays can be captured in @Sendable
// Task closures. Safe in fakes because the array is immutable after construction.
private final class SendableBuffers: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
    init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
}

@Suite("RecordingSession")
struct RecordingSessionTests {
    /// In-memory fake that emits the buffers you hand it, then finishes.
    actor FakeMic: MicCaptureSource {
        nonisolated let script: [AVAudioPCMBuffer]
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        init(script: [AVAudioPCMBuffer]) { self.script = script }
        func requestPermission() async throws {}
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBuffers(script)
            Task.detached {
                for buf in box.buffers { cont.yield(buf) }
                cont.finish()
            }
            return stream
        }
        func stop() async { continuation?.finish() }
    }

    actor FakeSystem: SystemAudioCaptureSource {
        enum Mode: Sendable { case enabled([AVAudioPCMBuffer]), denied }
        nonisolated let mode: Mode
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        init(_ mode: Mode) { self.mode = mode }
        func requestPermission() async throws {
            if case .denied = mode { throw AudioError.systemAudioPermissionDenied }
        }
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            guard case .enabled(let script) = mode else {
                throw AudioError.systemAudioPermissionDenied
            }
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBuffers(script)
            Task.detached {
                for buf in box.buffers { cont.yield(buf) }
                cont.finish()
            }
            return stream
        }
        func stop() async { continuation?.finish() }
    }

    private func makeConstantBuffer(
        _ value: Float,
        frames: AVAudioFrameCount,
        rate: Double = 16000,
        channels: AVAudioChannelCount = 1
    ) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = value }
        }
        return buf
    }

    private func makeTempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-session-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("session writes a WAV at the destination and returns its URL")
    func writesWAVAtDestination() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let mic = FakeMic(script: [
            makeConstantBuffer(0.2, frames: 16000),
            makeConstantBuffer(0.2, frames: 16000),
        ])
        let sys = FakeSystem(.enabled([
            makeConstantBuffer(0.1, frames: 16000),
            makeConstantBuffer(0.1, frames: 16000),
        ]))
        let destination = RecordingDestination(baseDirectory: base)

        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            destination: destination
        )

        try await session.start(at: Date())
        // Wait briefly for fake streams to drain.
        try await Task.sleep(nanoseconds: 300_000_000)
        let result = try await session.stop()
        let url = result.wavURL

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.hasPrefix(base.path))
        #expect(url.pathExtension == "wav")

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length >= 16000, "expected ≥1s recorded, got \(file.length) frames")
    }

    @Test("session gracefully degrades to mic-only when system audio permission is denied")
    func degradesMicOnly() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let mic = FakeMic(script: [makeConstantBuffer(0.3, frames: 16000)])
        let sys = FakeSystem(.denied)
        let destination = RecordingDestination(baseDirectory: base)

        let session = RecordingSession(mic: mic, systemAudio: sys, destination: destination)
        try await session.start(at: Date())
        try await Task.sleep(nanoseconds: 200_000_000)
        let result = try await session.stop()
        let url = result.wavURL

        #expect(FileManager.default.fileExists(atPath: url.path))
        let file = try AVAudioFile(forReading: url)
        #expect(file.length >= 15000, "expected ~1s recorded with mic-only, got \(file.length) frames")
    }
}
