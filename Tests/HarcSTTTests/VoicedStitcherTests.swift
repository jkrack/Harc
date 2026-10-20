import Testing
import Foundation
import FluidAudio
import HarcCore
@testable import HarcSTT

@Suite("VoicedStitcher")
struct VoicedStitcherTests {
    @Test("short speech gaps retain exact samples and original timestamps while long silence is removed")
    func retainsShortSpeechGaps() {
        let samples = (0..<4000).map(Float.init)
        let out = VoicedStitcher.stitch(samples: samples, segments: [
            seg(startSample: 1000, endSample: 1200, rate: 1000),
            seg(startSample: 1256, endSample: 1400, rate: 1000),
            seg(startSample: 3000, endSample: 3200, rate: 1000),
        ], sampleRate: 1000, preservingGapsUpTo: 0.1)
        #expect(out.compactSamples == Array(samples[1000..<1400]) + Array(samples[3000..<3200]))
        #expect(out.regions.count == 2)
        let words = VADTimestampRemapper.remap(words: [
            Word(text: "gap", startMs: 230, endMs: 280),
            Word(text: "later", startMs: 450, endMs: 500),
        ], regions: out.regions, sampleRate: 1000)
        #expect(words == [Word(text: "gap", startMs: 1230, endMs: 1280),
                          Word(text: "later", startMs: 3050, endMs: 3100)])
    }

    @Test("gap preservation includes the threshold and leaves longer gaps trimmed")
    func gapThreshold() {
        let samples = (0..<500).map(Float.init)
        let out = VoicedStitcher.stitch(samples: samples, segments: [
            seg(startSample: 0, endSample: 100, rate: 1000),
            seg(startSample: 200, endSample: 300, rate: 1000),
            seg(startSample: 401, endSample: 450, rate: 1000),
        ], sampleRate: 1000, preservingGapsUpTo: 0.1)
        #expect(out.compactSamples == Array(samples[0..<300]) + Array(samples[401..<450]))
        #expect(out.regions.count == 2)
    }

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
