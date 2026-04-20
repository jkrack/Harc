import Testing
import Foundation
import FluidAudio
@testable import HarcSTT

@Suite("VoicedStitcher")
struct VoicedStitcherTests {
    /// Build a VadSegment whose startTime/endTime convert to the requested
    /// sample indices at the given sample rate.
    private func seg(startSample: Int, endSample: Int, rate: Int) -> VadSegment {
        VadSegment(
            startTime: Double(startSample) / Double(rate),
            endTime: Double(endSample) / Double(rate)
        )
    }

    @Test("stitch — empty segments → empty compact buffer + empty regions")
    func emptySegments() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        let out = VoicedStitcher.stitch(samples: samples, segments: [], sampleRate: 8)
        #expect(out.compactSamples.isEmpty)
        #expect(out.regions.isEmpty)
    }

    @Test("stitch — single region copied verbatim")
    func singleRegion() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [seg(startSample: 2, endSample: 5, rate: 8)],
            sampleRate: 8
        )
        #expect(out.compactSamples == [2, 3, 4])
        #expect(out.regions.count == 1)
        #expect(out.regions[0].origStartSample == 2)
        #expect(out.regions[0].origEndSample == 5)
        #expect(out.regions[0].compactStartSample == 0)
        #expect(out.regions[0].sampleCount == 3)
    }

    @Test("stitch — two regions concatenated with cumulative compactStart")
    func twoRegions() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [
                seg(startSample: 1, endSample: 3, rate: 8),  // → [1,2]
                seg(startSample: 5, endSample: 7, rate: 8),  // → [5,6]
            ],
            sampleRate: 8
        )
        #expect(out.compactSamples == [1, 2, 5, 6])
        #expect(out.regions.count == 2)
        #expect(out.regions[0].compactStartSample == 0)
        #expect(out.regions[0].sampleCount == 2)
        #expect(out.regions[1].compactStartSample == 2)
        #expect(out.regions[1].sampleCount == 2)
    }

    @Test("stitch — out-of-bounds segment is clamped to samples")
    func clampedToBounds() {
        let samples: [Float] = [0, 1, 2, 3]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [seg(startSample: 2, endSample: 10, rate: 8)],
            sampleRate: 8
        )
        #expect(out.compactSamples == [2, 3])
        #expect(out.regions[0].origEndSample == 4) // clamped to samples.count
    }

    @Test("stitch — zero-length segment after clamp is dropped")
    func zeroLengthDropped() {
        let samples: [Float] = [0, 1, 2, 3]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [seg(startSample: 5, endSample: 7, rate: 8)],
            sampleRate: 8
        )
        #expect(out.compactSamples.isEmpty)
        #expect(out.regions.isEmpty)
    }
}
