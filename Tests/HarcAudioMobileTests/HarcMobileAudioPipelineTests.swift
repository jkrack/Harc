import AVFoundation
import Foundation
import Testing
@testable import HarcAudioMobile

@Suite("Mobile real-time audio pipeline")
struct HarcMobileAudioPipelineTests {
    @Test("48 kHz stereo hardware PCM becomes 16 kHz mono Int16")
    func canonicalConversion() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let input = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 48_000
        ))
        input.frameLength = 48_000
        for channel in 0..<2 {
            let samples = try #require(input.floatChannelData?[channel])
            for frame in 0..<48_000 { samples[frame] = 0.25 }
        }

        let converter = try HarcMobileCanonicalPCMConverter(
            inputFormat: format
        )
        var bytes = try converter.convert(input)
        bytes.append(try converter.finish())

        #expect(bytes.count.isMultiple(of: 2))
        #expect(bytes.count == 16_000 * 2)
        let sample: Int16 = bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: Int16.self)
        }
        #expect(abs(Int(sample)) > 4_000)
    }

    @Test("bounded handoff drops instead of blocking when all slots are full")
    func boundedHandoff() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let source = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 128
        ))
        source.frameLength = 128
        let handoff = try HarcMobileAudioHandoff(
            format: format,
            frameCapacity: 128,
            slotCount: 2
        )

        #expect(handoff.offer(source, hostTime: 1))
        #expect(handoff.offer(source, hostTime: 2))
        #expect(!handoff.offer(source, hostTime: 3))

        let first = try #require(handoff.take())
        #expect(first.hostTime == 1)
        handoff.release(first)
        #expect(handoff.offer(source, hostTime: 4))
        let second = try #require(handoff.take())
        handoff.release(second)
        let afterDrop = try #require(handoff.take())
        #expect(afterDrop.hostTime == 4)
        #expect(afterDrop.droppedInputFramesBeforeThisBuffer == 128)
        handoff.release(afterDrop)
    }
}
