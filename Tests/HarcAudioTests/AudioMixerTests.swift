import Testing
import Foundation
import AVFoundation
@testable import HarcAudio

@Suite("AudioMixer")
struct AudioMixerTests {
    private func makeFormat(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    private func makeConstantBuffer(
        value: Float,
        frames: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = value }
        }
        return buf
    }

    @Test("mixer resamples 48 kHz stereo mic buffer to 16 kHz mono with ~constant amplitude")
    func resamplesMicBuffer() throws {
        let mixer = AudioMixer()
        let inputFormat = makeFormat(rate: 48000, channels: 2)
        let input = makeConstantBuffer(value: 0.5, frames: 48000, format: inputFormat)

        let out = try mixer.processMic(input)
        #expect(out.format.sampleRate == 16000)
        #expect(out.format.channelCount == 1)
        #expect(out.frameLength == 16000, "expected ~16000 frames, got \(out.frameLength)")

        // Mono-sum of a stereo 0.5-constant is ~0.5 (per-channel average).
        // Resampling preserves amplitude for constants.
        let first = out.floatChannelData![0][0]
        #expect(abs(first - 0.5) < 0.05, "expected ~0.5, got \(first)")
    }

    @Test("mixer sums mic and system tracks sample-aligned when fed equal-length buffers")
    func sumsMicAndSystem() throws {
        let mixer = AudioMixer()
        let micIn = makeFormat(rate: 16000, channels: 1)
        let sysIn = makeFormat(rate: 16000, channels: 1)

        let mic = makeConstantBuffer(value: 0.2, frames: 1600, format: micIn)
        let sys = makeConstantBuffer(value: 0.3, frames: 1600, format: sysIn)

        let micOut = try mixer.processMic(mic)
        let sysOut = try mixer.processSystem(sys)
        let summed = try mixer.sum(mic: micOut, system: sysOut)

        #expect(summed.format.sampleRate == 16000)
        #expect(summed.format.channelCount == 1)
        #expect(summed.frameLength == 1600)
        let first = summed.floatChannelData![0][0]
        #expect(abs(first - 0.5) < 0.01, "expected 0.2 + 0.3 = 0.5, got \(first)")
    }

    @Test("mixer clamps summed output to [-1, 1] to prevent clipping overflow")
    func clampsToUnitRange() throws {
        let mixer = AudioMixer()
        let fmt = makeFormat(rate: 16000, channels: 1)

        // Two hot signals that would sum to 1.6 without clamping.
        let a = makeConstantBuffer(value: 0.8, frames: 800, format: fmt)
        let b = makeConstantBuffer(value: 0.8, frames: 800, format: fmt)

        let summed = try mixer.sum(mic: a, system: b)
        let first = summed.floatChannelData![0][0]
        #expect(first <= 1.0, "expected clamp to 1.0, got \(first)")
        #expect(first >= 1.0 - 0.01, "expected exactly 1.0 after clamp, got \(first)")
    }

    @Test("processSystem converts 48 kHz stereo to 16 kHz mono")
    func processesSystemBuffer() throws {
        let mixer = AudioMixer()
        let input = makeConstantBuffer(
            value: 0.3,
            frames: 48000,
            format: makeFormat(rate: 48000, channels: 2)
        )
        let out = try mixer.processSystem(input)
        #expect(out.format.sampleRate == 16000)
        #expect(out.format.channelCount == 1)
        #expect(out.frameLength == 16000)
    }
}
