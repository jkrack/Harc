import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

/// Fixed-capacity ring of the most recent 16 kHz mono audio, kept in memory so
/// a recording can start *in the past*.
///
/// This is the storage behind retroactive record: capture runs continuously at
/// no marginal cost (the whole point of local inference), and the user decides
/// after the fact that the last few minutes were worth keeping. When a
/// recording starts, whatever is banked here is prepended to the WAV.
///
/// Samples are stored as Int16 rather than Float32 for two reasons: it halves
/// the resident cost of an always-on buffer, and 16-bit is already the WAV
/// output format, so the conversion is not a loss — it is the same rounding
/// `AudioFileWriter` would apply on the way to disk anyway.
///
/// At 16 kHz mono Int16 the cost is 32 KB/s — about 1.9 MB per minute, so a
/// 15-minute ring is ~29 MB.
///
/// Not thread-safe on its own; `PreRollCapture` owns one and serializes access.
public final class RollingAudioBuffer {
    public static let sampleRate: Double = 16000

    /// Total samples the ring can hold.
    public let capacity: Int

    private var storage: [Int16]
    /// Where the next sample goes. Wraps at `capacity`.
    private var writeIndex = 0
    /// Samples currently readable, saturating at `capacity`.
    private var available = 0

    public init(seconds: TimeInterval) {
        precondition(seconds > 0, "pre-roll window must be positive")
        self.capacity = Int(seconds * Self.sampleRate)
        self.storage = [Int16](repeating: 0, count: capacity)
    }

    /// Seconds of audio currently banked.
    public var availableSeconds: TimeInterval {
        Double(available) / Self.sampleRate
    }

    public var isEmpty: Bool { available == 0 }

    /// Append a 16 kHz mono Float32 buffer. Buffers in any other format are
    /// ignored rather than throwing — this sits on the capture path, where a
    /// dropped pre-roll buffer must never be able to interrupt live audio.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate == Self.sampleRate,
              buffer.format.channelCount == 1,
              let data = buffer.floatChannelData?[0]
        else { return }
        append(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Append raw mono Float32 samples, converting to Int16 with clamping.
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }

        // A single burst longer than the ring can only leave its own tail.
        // Skipping the doomed prefix keeps this O(capacity) instead of O(n).
        let start = max(0, samples.count - capacity)
        for i in start..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            storage[writeIndex] = Int16(clamped * 32767.0)
            writeIndex = (writeIndex + 1) % capacity
        }
        available = min(capacity, available + (samples.count - start))
    }

    /// The banked audio, oldest sample first.
    ///
    /// `lastSeconds` trims to the most recent slice; nil returns everything
    /// banked. Reading does not consume — the ring keeps running, so the user
    /// can save a window and still have context for the next one.
    public func snapshot(lastSeconds: TimeInterval? = nil) -> [Int16] {
        guard available > 0 else { return [] }

        var wanted = available
        if let lastSeconds {
            wanted = min(available, max(0, Int(lastSeconds * Self.sampleRate)))
        }
        guard wanted > 0 else { return [] }

        // The oldest wanted sample sits `wanted` positions behind the write head.
        let startIndex = ((writeIndex - wanted) % capacity + capacity) % capacity
        var out = [Int16]()
        out.reserveCapacity(wanted)
        if startIndex + wanted <= capacity {
            out.append(contentsOf: storage[startIndex..<(startIndex + wanted)])
        } else {
            let firstRun = capacity - startIndex
            out.append(contentsOf: storage[startIndex..<capacity])
            out.append(contentsOf: storage[0..<(wanted - firstRun)])
        }
        return out
    }

    /// Drop everything banked. Called when capture stops, and after a snapshot
    /// has been promoted into a real recording, so the same audio can't be
    /// silently prepended to a second one.
    public func reset() {
        writeIndex = 0
        available = 0
    }

    // MARK: - Conversion

    /// Repackage Int16 samples as 16 kHz mono Float32 buffers of at most
    /// `chunkFrames` each, ready to hand to `AudioFileWriter`.
    ///
    /// Chunked because a 15-minute pre-roll is ~14 M samples, and one buffer
    /// that size is a needless allocation spike on the path that starts a
    /// recording — the moment latency is most visible to the user.
    public static func buffers(
        from samples: [Int16],
        chunkFrames: Int = 16000
    ) -> [AVAudioPCMBuffer] {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              )
        else { return [] }

        var out: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < samples.count {
            let n = min(chunkFrames, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(n)
            ) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            let dst = buf.floatChannelData![0]
            for i in 0..<n {
                dst[i] = Float(samples[offset + i]) / 32767.0
            }
            out.append(buf)
            offset += n
        }
        return out
    }
}
