import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import HarcAudio

@Suite("RollingAudioBuffer")
struct RollingAudioBufferTests {

    private func floatBuffer(_ values: [Float]) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(values.count))!
        buf.frameLength = AVAudioFrameCount(values.count)
        for (i, v) in values.enumerated() { buf.floatChannelData![0][i] = v }
        return buf
    }

    /// Ramp of distinct values so a snapshot's *ordering* is verifiable, not
    /// just its length — an off-by-one in the wrap arithmetic still produces
    /// the right count.
    private func ramp(from: Int, count: Int) -> [Float] {
        (0..<count).map { Float(from + $0) / 32767.0 }
    }

    private func decoded(_ samples: [Int16]) -> [Int] {
        samples.map { Int($0) }
    }

    @Test("banks audio up to capacity and reports seconds available")
    func banksUpToCapacity() {
        let ring = RollingAudioBuffer(seconds: 1)   // 16000 samples
        #expect(ring.capacity == 16000)
        #expect(ring.isEmpty)

        ring.append(floatBuffer(ramp(from: 1, count: 8000)))
        #expect(ring.availableSeconds == 0.5)
        #expect(!ring.isEmpty)

        ring.append(floatBuffer(ramp(from: 8001, count: 8000)))
        #expect(ring.availableSeconds == 1.0)
    }

    @Test("keeps the most recent window once full, discarding the oldest")
    func discardsOldestWhenFull() {
        let ring = RollingAudioBuffer(seconds: 1)
        ring.append(floatBuffer(ramp(from: 1, count: 16000)))
        // 4000 more samples push the first 4000 out of the window.
        ring.append(floatBuffer(ramp(from: 16001, count: 4000)))

        #expect(ring.availableSeconds == 1.0)   // still exactly one second
        let snap = decoded(ring.snapshot())
        #expect(snap.count == 16000)
        // Oldest surviving sample is 4001; newest is 20000.
        #expect(snap.first == 4001)
        #expect(snap.last == 20000)
    }

    @Test("snapshot returns samples oldest-first across a wrap boundary")
    func snapshotOrderingAcrossWrap() {
        let ring = RollingAudioBuffer(seconds: 1)
        // Write 1.5 rings so the live window straddles the wrap point.
        ring.append(floatBuffer(ramp(from: 1, count: 24000)))

        let snap = decoded(ring.snapshot())
        #expect(snap.count == 16000)
        #expect(snap.first == 8001)
        #expect(snap.last == 24000)
        // Strictly increasing proves nothing got reordered at the seam.
        #expect(zip(snap, snap.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("lastSeconds trims to the most recent slice")
    func lastSecondsTrims() {
        let ring = RollingAudioBuffer(seconds: 2)
        ring.append(floatBuffer(ramp(from: 1, count: 32000)))

        let half = decoded(ring.snapshot(lastSeconds: 0.5))
        #expect(half.count == 8000)
        #expect(half.first == 24001)   // most recent half-second
        #expect(half.last == 32000)

        // Asking for more than is banked yields everything, not a crash.
        let all = ring.snapshot(lastSeconds: 99)
        #expect(all.count == 32000)
    }

    @Test("a burst longer than the ring leaves only its own tail")
    func oversizedBurstKeepsTail() {
        // Kept well inside Int16 range: a ramp past 32767 would clamp, and the
        // flat top would mask an ordering bug rather than expose one.
        let ring = RollingAudioBuffer(seconds: 0.25)   // 4000 samples
        ring.append(floatBuffer(ramp(from: 1, count: 10000)))

        let snap = decoded(ring.snapshot())
        #expect(snap.count == 4000)
        #expect(snap.first == 6001)
        #expect(snap.last == 10000)
    }

    @Test("snapshot does not consume, so the ring keeps running")
    func snapshotIsNonDestructive() {
        let ring = RollingAudioBuffer(seconds: 1)
        ring.append(floatBuffer(ramp(from: 1, count: 8000)))

        let first = ring.snapshot()
        let second = ring.snapshot()
        #expect(first == second)
        #expect(ring.availableSeconds == 0.5)
    }

    @Test("reset drops everything banked")
    func resetClears() {
        let ring = RollingAudioBuffer(seconds: 1)
        ring.append(floatBuffer(ramp(from: 1, count: 8000)))
        ring.reset()

        #expect(ring.isEmpty)
        #expect(ring.snapshot().isEmpty)
        #expect(ring.availableSeconds == 0)
    }

    @Test("mismatched formats are ignored rather than corrupting the ring")
    func ignoresWrongFormat() {
        let ring = RollingAudioBuffer(seconds: 1)
        let stereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 1000)!
        buf.frameLength = 1000

        ring.append(buf)
        #expect(ring.isEmpty)
    }

    @Test("round-trips through Float32 buffers preserving order and length")
    func roundTripsToBuffers() {
        let ring = RollingAudioBuffer(seconds: 1)
        ring.append(floatBuffer(ramp(from: 1, count: 5000)))

        let samples = ring.snapshot()
        let buffers = RollingAudioBuffer.buffers(from: samples, chunkFrames: 1024)

        #expect(buffers.count == 5)   // 4×1024 + 904
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        #expect(total == 5000)

        // Flatten and confirm the ramp survived the Int16 → Float32 return trip.
        var flat: [Float] = []
        for b in buffers {
            let ptr = b.floatChannelData![0]
            flat.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(b.frameLength)))
        }
        #expect(flat.count == 5000)
        #expect(Int((flat[0] * 32767.0).rounded()) == 1)
        #expect(Int((flat[4999] * 32767.0).rounded()) == 5000)
    }

    @Test("clamps out-of-range samples instead of wrapping to the opposite sign")
    func clampsOutOfRange() {
        let ring = RollingAudioBuffer(seconds: 1)
        ring.append(floatBuffer([2.0, -2.0, 0.0]))

        let snap = ring.snapshot()
        #expect(snap == [32767, -32767, 0])
    }
}
