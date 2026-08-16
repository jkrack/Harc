import Foundation
import Synchronization
@preconcurrency import AVFoundation

/// A tiny, lock-free bridge from the capture writer queue to the Capture UI.
///
/// Metering runs only after a buffer has left the real-time Core Audio tap and
/// entered Harc's preallocated handoff. Sampling is capped so the visual never
/// competes with canonical conversion or durable writes.
final class HarcMobileAudioLevelMeter: @unchecked Sendable {
    private let levelBits = Atomic<UInt32>(Float(0).bitPattern)

    var level: Float {
        Float(bitPattern: levelBits.load(ordering: .relaxed))
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        let target = Self.normalizedLevel(buffer)
        let current = level
        let response: Float = target > current ? 0.62 : 0.16
        let smoothed = current + ((target - current) * response)
        levelBits.store(
            min(max(smoothed, 0), 1).bitPattern,
            ordering: .relaxed
        )
    }

    func reset() {
        levelBits.store(Float(0).bitPattern, ordering: .relaxed)
    }

    private static func normalizedLevel(
        _ buffer: AVAudioPCMBuffer
    ) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        // At most 256 frames per channel are inspected. This is a presence
        // meter, not signal analysis, and intentionally stays negligible next
        // to conversion and storage work.
        let sampleStep = max(1, frameCount / 256)
        let stride = max(1, buffer.stride)
        var sumOfSquares: Float = 0
        var sampleCount = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return 0 }
            for channel in 0 ..< channelCount {
                let samples = channels[channel]
                var frame = 0
                while frame < frameCount {
                    let value = samples[frame * stride]
                    sumOfSquares += value * value
                    sampleCount += 1
                    frame += sampleStep
                }
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return 0 }
            for channel in 0 ..< channelCount {
                let samples = channels[channel]
                var frame = 0
                while frame < frameCount {
                    let value = Float(samples[frame * stride])
                        / Float(Int16.max)
                    sumOfSquares += value * value
                    sampleCount += 1
                    frame += sampleStep
                }
            }
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { return 0 }
            for channel in 0 ..< channelCount {
                let samples = channels[channel]
                var frame = 0
                while frame < frameCount {
                    let value = Float(samples[frame * stride])
                        / Float(Int32.max)
                    sumOfSquares += value * value
                    sampleCount += 1
                    frame += sampleStep
                }
            }
        case .pcmFormatFloat64, .otherFormat:
            return 0
        @unknown default:
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumOfSquares / Float(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_01))
        let audibleRange = min(max((decibels + 52) / 46, 0), 1)
        return pow(audibleRange, 0.72)
    }
}
