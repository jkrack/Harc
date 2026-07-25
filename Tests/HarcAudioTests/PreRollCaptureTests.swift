import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import HarcAudio

private final class SendableBufferBox: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
    init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
}

@Suite("PreRollCapture")
struct PreRollCaptureTests {

    /// Mic fake that keeps its stream open after the script drains, so the
    /// capture stays in `.listening` the way a real always-on mic would.
    actor HoldingMic: MicCaptureSource {
        nonisolated let script: [AVAudioPCMBuffer]
        nonisolated let permissionError: (any Error)?
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        private(set) var stopCount = 0

        init(script: [AVAudioPCMBuffer], permissionError: (any Error)? = nil) {
            self.script = script
            self.permissionError = permissionError
        }

        func requestPermission() async throws {
            if let permissionError { throw permissionError }
        }

        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBufferBox(script)
            Task.detached { for b in box.buffers { cont.yield(b) } }
            return stream
        }

        func stop() async {
            stopCount += 1
            continuation?.finish()
            continuation = nil
        }
    }

    /// Mic fake whose stream ends on its own, the way a real tap does when the
    /// device changes or another consumer takes the mic.
    actor EndingMic: MicCaptureSource {
        func requestPermission() async throws {}

        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            cont.finish()
            return stream
        }

        func stop() async {}
    }

    /// A ring whose mic dies has to say so. It used to stay in `.listening`
    /// forever, banking nothing — and since the UI published only the banked
    /// count, a dead ring was indistinguishable from a healthy idle one and
    /// the panel kept claiming "Ready to capture the last 0s".
    @Test("a mic stream that ends marks the ring failed")
    func endedStreamMarksFailure() async throws {
        let capture = PreRollCapture(mic: EndingMic(), windowSeconds: 60)
        await capture.start()

        var state = await capture.state
        for _ in 0..<200 where state == .listening {
            try await Task.sleep(for: .milliseconds(10))
            state = await capture.state
        }

        guard case .failed = state else {
            Issue.record("expected .failed after the stream ended, got \(state)")
            return
        }
        #expect(await capture.bankedSeconds == 0)
    }

    private func buffer(_ value: Float, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = value }
        return buf
    }

    /// Poll until the ring has banked something, rather than sleeping a fixed
    /// interval and hoping — the same race that made the transcriber test flaky.
    private func waitForBankedAudio(
        _ capture: PreRollCapture,
        atLeast seconds: TimeInterval,
        timeout: TimeInterval = 5
    ) async -> TimeInterval {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let banked = await capture.bankedSeconds
            if banked >= seconds { return banked }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await capture.bankedSeconds
    }

    @Test("banks incoming mic audio while listening")
    func banksWhileListening() async {
        let mic = HoldingMic(script: [buffer(0.3, frames: 16000)])
        let capture = PreRollCapture(mic: mic, windowSeconds: 10)

        await capture.start()
        #expect(await capture.state == .listening)

        let banked = await waitForBankedAudio(capture, atLeast: 0.9)
        #expect(banked >= 0.9, "expected ~1s banked, got \(banked)")
    }

    @Test("promote hands over the banked audio and clears the ring")
    func promoteHandsOverAndClears() async {
        let mic = HoldingMic(script: [buffer(0.3, frames: 16000)])
        let capture = PreRollCapture(mic: mic, windowSeconds: 10)

        await capture.start()
        _ = await waitForBankedAudio(capture, atLeast: 0.9)

        let samples = await capture.promote()
        #expect(samples.count >= 14000, "expected ~16000 samples, got \(samples.count)")

        // The same seconds must never be prependable to a second recording.
        #expect(await capture.bankedSeconds == 0)
        #expect(await capture.state == .stopped)
        #expect(await mic.stopCount == 1)
    }

    @Test("promote can trim to a shorter window than what is banked")
    func promoteTrimsToWindow() async {
        let mic = HoldingMic(script: [buffer(0.3, frames: 32000)])   // 2 s
        let capture = PreRollCapture(mic: mic, windowSeconds: 10)

        await capture.start()
        _ = await waitForBankedAudio(capture, atLeast: 1.9)

        let samples = await capture.promote(seconds: 0.5)
        #expect(samples.count == 8000)
    }

    @Test("the window is bounded — old audio falls off rather than growing")
    func windowIsBounded() async {
        // 1-second window fed 3 seconds of audio.
        let mic = HoldingMic(script: [buffer(0.3, frames: 48000)])
        let capture = PreRollCapture(mic: mic, windowSeconds: 1)

        await capture.start()
        _ = await waitForBankedAudio(capture, atLeast: 1.0)

        let banked = await capture.bankedSeconds
        #expect(banked == 1.0, "ring must saturate at its window, got \(banked)")
    }

    @Test("clear wipes the window without stopping capture")
    func clearWipesWithoutStopping() async {
        let mic = HoldingMic(script: [buffer(0.3, frames: 16000)])
        let capture = PreRollCapture(mic: mic, windowSeconds: 10)

        await capture.start()
        _ = await waitForBankedAudio(capture, atLeast: 0.9)

        await capture.clear()
        #expect(await capture.bankedSeconds == 0)
        #expect(await capture.state == .listening, "clear must not end capture")
    }

    @Test("a denied mic fails softly instead of throwing")
    func deniedMicFailsSoftly() async {
        let mic = HoldingMic(script: [], permissionError: AudioError.micPermissionDenied)
        let capture = PreRollCapture(mic: mic, windowSeconds: 10)

        // Must not throw: failing to bank pre-roll can never be allowed to
        // block the user from starting an ordinary recording.
        await capture.start()

        if case .failed = await capture.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(await capture.state)")
        }
        #expect(await capture.bankedSeconds == 0)
    }

    @Test("starting twice does not open a second mic tap")
    func startIsIdempotent() async {
        let mic = HoldingMic(script: [buffer(0.3, frames: 16000)])
        let capture = PreRollCapture(mic: mic, windowSeconds: 10)

        await capture.start()
        _ = await waitForBankedAudio(capture, atLeast: 0.9)
        await capture.start()

        #expect(await capture.state == .listening)
        // One promote drains one tap's worth; a doubled tap would double this.
        let samples = await capture.promote()
        #expect(samples.count <= 16000 + 1000)
    }
}
