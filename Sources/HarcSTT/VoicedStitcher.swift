import Foundation
import FluidAudio

/// Maps a subrange of the original sample buffer to its offset in the
/// compact (stitched) buffer. `compactStartSample` is the first sample
/// index of this region in the compact buffer; the region ends at
/// `compactStartSample + sampleCount`.
public struct VoicedRegion: Equatable, Sendable {
    public let origStartSample: Int
    public let origEndSample: Int
    public let compactStartSample: Int

    public var sampleCount: Int { origEndSample - origStartSample }

    public init(origStartSample: Int, origEndSample: Int, compactStartSample: Int) {
        self.origStartSample = origStartSample
        self.origEndSample = origEndSample
        self.compactStartSample = compactStartSample
    }
}

/// Output of `VoicedStitcher.stitch`: the compact sample buffer plus
/// the ordered region table used by `VADTimestampRemapper`.
public struct StitchResult: Equatable, Sendable {
    public let compactSamples: [Float]
    public let regions: [VoicedRegion]

    public init(compactSamples: [Float], regions: [VoicedRegion]) {
        self.compactSamples = compactSamples
        self.regions = regions
    }
}

/// Pure: concatenate the voiced regions of `samples` into a compact
/// `[Float]` and record each region's placement in the compact buffer.
/// Out-of-bounds segments are clamped; zero-length results are dropped.
public enum VoicedStitcher {
    public static func stitch(
        samples: [Float],
        segments: [VadSegment],
        sampleRate: Int = 16000
    ) -> StitchResult {
        var compact: [Float] = []
        compact.reserveCapacity(
            segments.reduce(0) { $0 + $1.sampleCount(sampleRate: sampleRate) }
        )
        var regions: [VoicedRegion] = []
        regions.reserveCapacity(segments.count)
        var compactCursor = 0
        for seg in segments {
            let lo = max(0, seg.startSample(sampleRate: sampleRate))
            let hi = min(samples.count, seg.endSample(sampleRate: sampleRate))
            guard lo < hi else { continue }
            compact.append(contentsOf: samples[lo..<hi])
            regions.append(VoicedRegion(
                origStartSample: lo,
                origEndSample: hi,
                compactStartSample: compactCursor
            ))
            compactCursor += (hi - lo)
        }
        return StitchResult(compactSamples: compact, regions: regions)
    }
}
