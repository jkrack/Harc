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

    /// System-audio fake that emits N buffers then HANGS — stream never finishes,
    /// never emits more. Models real ScreenCaptureKit when mic/sys cadences differ.
    actor FakeSystemHanging: SystemAudioCaptureSource {
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
                // DELIBERATELY do not call cont.finish() — simulates a live
                // sys stream that is slower than mic and hasn't delivered more yet.
            }
            return stream
        }
        func stop() async { continuation?.finish() }
    }

    /// Mic fake that cooperatively yields between buffers (`Task.yield`, not a
    /// wall-clock sleep) so a concurrently draining, faster system stream gets
    /// scheduling turns to enqueue buffers between mic ticks. Models the real
    /// cadence — sparse mic buffers, denser system-audio buffers — without being
    /// sensitive to thread-pool saturation under parallel test load.
    actor FakeMicPaced: MicCaptureSource {
        nonisolated let script: [AVAudioPCMBuffer]
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        init(script: [AVAudioPCMBuffer]) { self.script = script }
        func requestPermission() async throws {}
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBuffers(script)
            Task.detached {
                for buf in box.buffers {
                    cont.yield(buf)
                    await Task.yield()
                }
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

    @Test("mic pump survives a system stream that delivers fewer buffers than mic and doesn't finish")
    func micPumpSurvivesSlowSystemStream() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // 10 mic buffers, 1 sys buffer that stalls forever afterwards.
        let micBuffers = (0..<10).map { _ in makeConstantBuffer(0.1, frames: 1600) }
        let sysBuffers = [makeConstantBuffer(0.2, frames: 1600)]

        let mic = FakeMic(script: micBuffers)
        let sys = FakeSystemHanging(script: sysBuffers)
        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            destination: RecordingDestination(baseDirectory: base),
            transcriber: nil
        )

        try await session.start(at: Date())
        // Give the pump enough time to drain the 10-buffer mic stream.
        // If the pump deadlocks on sysIter.next(), this test will TIME OUT.
        try await Task.sleep(for: .milliseconds(500))
        let result = try await session.stop()

        // Verify the WAV has > 1 buffer's worth of frames.
        // 10 buffers × 1600 frames = 16000 frames = 1.0s at 16kHz.
        // If the deadlock bug is present, the file will have ~1600 frames (0.1s).
        let af = try AVAudioFile(forReading: result.wavURL)
        #expect(af.length > 5000, "expected >5000 frames; got \(af.length) (pump deadlocked?)")
    }

    @Test("fast system stream is mixed continuously, not dropped to ~25% duty cycle")
    func fastSystemStreamIsNotDropped() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Mic is SILENT and sparse (10 buffers, paced). System is a loud constant
        // arriving ~5× more often (50 small buffers). Both total 16000 frames = 1s.
        // The mixed WAV is therefore pure system audio. With the old single-slot
        // pump, ~4 of every 5 system buffers were dropped and zero-padded, so only
        // ~20–25% of samples carried the system tone. With the FIFO pump, every
        // system sample is mixed, so nearly the whole file should carry it.
        let micBuffers = (0..<10).map { _ in makeConstantBuffer(0.0, frames: 1600) }
        let sysBuffers = (0..<50).map { _ in makeConstantBuffer(0.5, frames: 320) }

        let mic = FakeMicPaced(script: micBuffers)
        let sys = FakeSystem(.enabled(sysBuffers))
        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            destination: RecordingDestination(baseDirectory: base),
            transcriber: nil
        )

        try await session.start(at: Date())
        try await Task.sleep(for: .milliseconds(800))
        let result = try await session.stop()

        let af = try AVAudioFile(forReading: result.wavURL)
        let frames = AVAudioFrameCount(af.length)
        #expect(frames > 12000, "expected ~16000 frames, got \(frames)")
        let buf = AVAudioPCMBuffer(pcmFormat: af.processingFormat, frameCapacity: frames)!
        try af.read(into: buf)

        // Measure continuity over the steady-state region, skipping the first
        // quarter where the system FIFO is still filling. With the old
        // single-slot pump ~75% of system buffers were dropped and the region
        // would be mostly silent (~25% carrying); the FIFO keeps it near-full.
        let data = buf.floatChannelData![0]
        let total = Int(buf.frameLength)
        let startIdx = total / 4
        var carrying = 0
        for i in startIdx..<total where abs(data[i]) > 0.4 { carrying += 1 }
        let ratio = Double(carrying) / Double(total - startIdx)
        #expect(
            ratio > 0.75,
            "expected system audio across >75% of the steady-state region; got \(Int(ratio * 100))% (buffers dropped instead of queued?)"
        )
    }
}
