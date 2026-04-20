import Foundation
import HarcCore

/// Pure: convert Parakeet `Word`s from the compact (stitched) timeline
/// back to the original chunk timeline using the region table produced
/// by `VoicedStitcher.stitch`. `endMs` is bounded below by `startMs` so
/// each word's range remains well-formed after region-crossing.
public enum VADTimestampRemapper {
    public static func remap(
        words: [Word],
        regions: [VoicedRegion],
        sampleRate: Int = 16000
    ) -> [Word] {
        guard !regions.isEmpty else { return words }
        return words.map { word in
            let startMs = remapCompactMs(word.startMs, regions: regions, sampleRate: sampleRate)
            let endMs = remapCompactMs(word.endMs, regions: regions, sampleRate: sampleRate)
            return Word(text: word.text, startMs: startMs, endMs: max(startMs, endMs))
        }
    }

    /// Find the region containing `compactMs` and return the corresponding
    /// original-timeline ms. If `compactMs` is past the last region, returns
    /// the last region's tail (origEnd in ms).
    static func remapCompactMs(_ compactMs: Int, regions: [VoicedRegion], sampleRate: Int) -> Int {
        let compactSamples = compactMs * sampleRate / 1000
        var containing: VoicedRegion = regions.last!
        for r in regions {
            let regionCompactEnd = r.compactStartSample + r.sampleCount
            if compactSamples < regionCompactEnd {
                containing = r
                break
            }
        }
        let offsetIntoRegion = compactSamples - containing.compactStartSample
        let clamped = max(0, min(offsetIntoRegion, containing.sampleCount))
        let origSamples = containing.origStartSample + clamped
        return origSamples * 1000 / sampleRate
    }
}
