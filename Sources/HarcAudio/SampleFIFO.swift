import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

/// Single-reader/single-writer FIFO of 16 kHz mono Float32 samples.
///
/// Used to align the system-audio stream with the mic stream on the mix
/// thread. The two streams arrive at different *buffer cadences* (the mic tap
/// hands over ~4096-frame buffers ~12×/sec; ScreenCaptureKit delivers smaller
/// audio buffers ~4× more often), but both carry the same real-time 16 kHz
/// sample rate once resampled. Buffering system samples here — instead of
/// keeping only the most recent buffer — means no system audio is dropped
/// when it arrives faster than the mic drives the mix.
///
/// Not thread-safe: only touched from the single mix loop in `RecordingSession`.
final class SampleFIFO {
    private var storage: [Float] = []
    private var readIndex = 0

    /// Samples available to read.
    var count: Int { storage.count - readIndex }

    /// Append the mono samples of a 16 kHz buffer to the tail.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        storage.append(contentsOf: UnsafeBufferPointer(start: data, count: n))
    }

    /// Remove up to `n` samples from the front and return them as a buffer in
    /// `format` (expected to be the 16 kHz mono target). Returns nil if empty.
    func take(_ n: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let k = min(n, count)
        guard k > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(k))
        else { return nil }
        out.frameLength = AVAudioFrameCount(k)
        let dst = out.floatChannelData![0]
        storage.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!.advanced(by: readIndex), count: k)
        }
        readIndex += k
        compact()
        return out
    }

    /// Reclaim the consumed prefix once it dominates, to bound memory over a
    /// long recording without paying an O(n) shift on every `take`.
    private func compact() {
        if readIndex > 4096 && readIndex * 2 > storage.count {
            storage.removeFirst(readIndex)
            readIndex = 0
        }
    }
}
