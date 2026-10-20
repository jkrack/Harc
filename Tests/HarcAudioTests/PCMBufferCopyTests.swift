import Testing
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import HarcAudio

@Suite("PCM capture boundaries")
struct PCMBufferCopyTests {
    @Test("native PCM copies and priming preserve interleaved and planar Int16 frames",
          arguments: [false, true])
    func int16Copy(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000,
            channels: 2, interleaved: interleaved
        ))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        input.frameLength = 4
        let list = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        for channel in list.indices {
            let samples = try #require(list[channel].mData).assumingMemoryBound(to: Int16.self)
            for index in 0..<(4 * Int(list[channel].mNumberChannels)) {
                samples[index] = Int16(100 + channel * 20 + index)
            }
        }
        let copy = try PCMBufferCopy.copy(input, repeatingLastFrame: 2)
        #expect(copy.frameLength == 6)
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for channel in list.indices {
            let original = try #require(list[channel].mData).assumingMemoryBound(to: Int16.self)
            let actual = try #require(output[channel].mData).assumingMemoryBound(to: Int16.self)
            let channels = Int(list[channel].mNumberChannels)
            for index in 0..<(4 * channels) { #expect(actual[index] == original[index]) }
            for frame in 4..<6 {
                for sample in 0..<channels {
                    #expect(actual[frame * channels + sample] == original[3 * channels + sample])
                }
            }
            original[0] = 0
            #expect(actual[0] != 0, "capture copies must own their sample storage")
        }
    }

    @Test("mixer accepts the Int16 formats produced by system capture", arguments: [false, true])
    func mixerAcceptsInt16(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48000,
            channels: 2, interleaved: interleaved
        ))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        input.frameLength = 4800
        for plane in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
            let samples = try #require(plane.mData).assumingMemoryBound(to: Int16.self)
            for index in 0..<(4800 * Int(plane.mNumberChannels)) { samples[index] = 8192 }
        }
        let mixed = try AudioMixer().processSystem(input)
        #expect(mixed.frameLength == 1600)
        #expect(abs(mixed.floatChannelData![0][1000] - 0.25) < 0.01)
    }

    @Test("CoreMedia capture preserves complete frames and rejects truncated data", arguments: [false, true])
    func coreMediaCopy(truncated: Bool) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 2, interleaved: true
        ))
        var asbd = format.streamDescription.pointee
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description
        ) == noErr)
        let byteCount = truncated ? 12 : 16
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ) == noErr)
        let bytes: [Int16] = [100, 200, 300, 400, 500, 600, 700, 800]
        let data = try #require(block)
        let status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: byteCount)
        }
        #expect(status == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 16000),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let creationStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: description,
            sampleCount: 4, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        if truncated {
            // SDK versions may reject inconsistent byte counts at construction
            // or at the PCM copy boundary. Neither may yield a usable buffer.
            if let sample {
                #expect(SystemAudioCapture.convertToPCM(sample) == nil)
            } else {
                #expect(creationStatus != noErr)
            }
            return
        }
        #expect(creationStatus == noErr)
        let readySample = try #require(sample)
        let copy = try #require(SystemAudioCapture.convertToPCM(readySample))
        #expect(copy.frameLength == 4)
        let plane = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)[0]
        let samples = try #require(plane.mData).assumingMemoryBound(to: Int16.self)
        #expect(Array(UnsafeBufferPointer(start: samples, count: 8)) == bytes)
    }
}
