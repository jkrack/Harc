import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

/// Resamples incoming mic and system-audio buffers to 16 kHz mono Float32,
/// then sums aligned chunks. Not Sendable — hold on a single actor.
public final class AudioMixer {
    public static let targetSampleRate: Double = 16000
    public static let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioMixer.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    private var micConverter: AVAudioConverter?
    private var micInputFormat: AVAudioFormat?
    private var systemConverter: AVAudioConverter?
    private var systemInputFormat: AVAudioFormat?

    public init() {}

    public func processMic(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try convert(
            buffer,
            converter: &micConverter,
            inputFormat: &micInputFormat,
            label: "mic"
        )
    }

    public func processSystem(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try convert(
            buffer,
            converter: &systemConverter,
            inputFormat: &systemInputFormat,
            label: "system"
        )
    }

    /// Sample-wise sum of two mono 16 kHz buffers, clamped to [-1, 1].
    /// If lengths differ, sums the shorter prefix.
    public func sum(mic: AVAudioPCMBuffer, system: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard mic.format == AudioMixer.targetFormat,
              system.format == AudioMixer.targetFormat
        else {
            throw AudioError.conversionFailed("sum: both inputs must be in target format")
        }
        let frames = min(mic.frameLength, system.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioMixer.targetFormat, frameCapacity: frames) else {
            throw AudioError.conversionFailed("sum: allocation failed")
        }
        out.frameLength = frames
        let m = mic.floatChannelData![0]
        let s = system.floatChannelData![0]
        let o = out.floatChannelData![0]
        for i in 0..<Int(frames) {
            var v = m[i] + s[i]
            if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
            o[i] = v
        }
        return out
    }

    // Number of extra input frames appended to warm up the sinc filter so that
    // the first output sample is stable when using .pre priming.
    private static let primeExtension = 64

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?,
        inputFormat: inout AVAudioFormat?,
        label: String
    ) throws -> AVAudioPCMBuffer {
        if converter == nil || inputFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: AudioMixer.targetFormat) else {
                throw AudioError.conversionFailed("\(label): no converter for \(buffer.format)")
            }
            // .pre fills the filter delay with the first input sample instead of
            // zeros, eliminating the sinc ramp-up at the start of each chunk.
            c.primeMethod = .pre
            converter = c
            inputFormat = buffer.format
        }

        // Extend the input buffer by primeExtension frames of the same last-sample
        // value so the converter can produce the expected number of output frames
        // even though .pre consumes some input for filter priming.
        let inputFrames = Int(buffer.frameLength)
        let extraInput = AudioMixer.primeExtension
        let totalInput = inputFrames + extraInput
        let channelCount = Int(buffer.format.channelCount)

        guard let extended = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: AVAudioFrameCount(totalInput)
        ) else {
            throw AudioError.conversionFailed("\(label): extended buffer allocation failed")
        }
        extended.frameLength = AVAudioFrameCount(totalInput)

        for ch in 0..<channelCount {
            let src = buffer.floatChannelData![ch]
            let dst = extended.floatChannelData![ch]
            // Copy original frames
            dst.update(from: src, count: inputFrames)
            // Pad with the last sample value
            let lastValue = inputFrames > 0 ? src[inputFrames - 1] : 0.0
            for i in inputFrames..<totalInput { dst[i] = lastValue }
        }

        // Expected output frame count from the original (unextended) input
        let expectedOutput = AVAudioFrameCount(
            Double(inputFrames) * AudioMixer.targetSampleRate / buffer.format.sampleRate
        )
        let capacity = expectedOutput + AVAudioFrameCount(extraInput) + 4

        guard let out = AVAudioPCMBuffer(pcmFormat: AudioMixer.targetFormat, frameCapacity: capacity) else {
            throw AudioError.conversionFailed("\(label): output allocation failed")
        }

        var error: NSError?
        // Use a reference-type box so Swift 6 doesn't flag the closure's mutation
        // as a captured-var concurrency hazard. The inputBlock runs synchronously
        // inside convert(); there's no actual concurrency, but the API types the
        // closure as @Sendable.
        let delivered = DeliveredFlag()
        let status = converter!.convert(to: out, error: &error) { _, outStatus in
            if delivered.value {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            delivered.value = true
            return extended
        }

        if status == .error, let error {
            throw AudioError.conversionFailed("\(label): \(error.localizedDescription)")
        }

        // Truncate to exactly the expected output length
        out.frameLength = min(out.frameLength, expectedOutput)
        return out
    }
}

/// Ref-type box so AudioMixer's synchronous-but-@Sendable inputBlock can toggle a flag
/// without triggering Swift 6's captured-var concurrency diagnostic.
private final class DeliveredFlag: @unchecked Sendable {
    var value = false
}
