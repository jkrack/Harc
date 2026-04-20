import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("VADTimestampRemapper")
struct VADTimestampRemapperTests {
    /// Rate: 8 samples/sec so 1 sample = 125 ms. Makes arithmetic easy.
    private let rate = 8

    /// Three voiced regions in the original:
    ///   region 0: orig [0,   1000ms)  → compact [0,   1000ms)
    ///   region 1: orig [2000,3000ms)  → compact [1000,2000ms)
    ///   region 2: orig [5000,5500ms)  → compact [2000,2500ms)
    /// Sample counts at 8Hz: 8, 8, 4 → compact = 20 samples.
    private var regions: [VoicedRegion] {
        [
            VoicedRegion(origStartSample: 0,  origEndSample: 8,  compactStartSample: 0),
            VoicedRegion(origStartSample: 16, origEndSample: 24, compactStartSample: 8),
            VoicedRegion(origStartSample: 40, origEndSample: 44, compactStartSample: 16),
        ]
    }

    @Test("remap — empty regions returns words unchanged")
    func emptyRegions() {
        let words = [Word(text: "hi", startMs: 100, endMs: 200)]
        #expect(VADTimestampRemapper.remap(words: words, regions: []) == words)
    }

    @Test("remap — word entirely in first region preserves ms (compactStart == origStart == 0)")
    func firstRegion() {
        let words = [Word(text: "a", startMs: 250, endMs: 750)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out == [Word(text: "a", startMs: 250, endMs: 750)])
    }

    @Test("remap — word entirely in second region shifts by region offset")
    func secondRegion() {
        // compact ms 1000..1500 corresponds to orig region[1] offset 0..500 → 2000..2500
        let words = [Word(text: "b", startMs: 1000, endMs: 1500)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out == [Word(text: "b", startMs: 2000, endMs: 2500)])
    }

    @Test("remap — word at a region boundary maps to the new region's start")
    func regionBoundary() {
        // compact ms 1000 = exactly the boundary; start should be region[1].origStart = 2000.
        let words = [Word(text: "c", startMs: 1000, endMs: 1125)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out[0].startMs == 2000)
        #expect(out[0].endMs == 2125)
    }

    @Test("remap — word past all regions clamps to final region's tail")
    func pastAllRegions() {
        // compact ms 3000 is past compact end (2500). Clamp into region[2]'s tail (origEnd = 5500ms).
        let words = [Word(text: "d", startMs: 3000, endMs: 3500)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out[0].startMs == 5500)
        #expect(out[0].endMs == 5500)
    }

    @Test("remap — consecutive words preserve monotonic non-decreasing start times")
    func monotonic() {
        let words = [
            Word(text: "w1", startMs: 100, endMs: 500),
            Word(text: "w2", startMs: 600, endMs: 900),
            Word(text: "w3", startMs: 1100, endMs: 1400),
            Word(text: "w4", startMs: 2100, endMs: 2300),
        ]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        var prev = -1
        for w in out {
            #expect(w.startMs >= prev)
            prev = w.startMs
        }
    }
}
