import Foundation

/// Overlapping model context with disjoint publication intervals. No source
/// samples are fabricated, omitted or published by two windows.
enum DiarizationWindowPlan {
    struct Window: Equatable { let source: Range<Int>; let owned: Range<Int> }
    static func windows(sampleCount: Int, windowSize: Int) -> [Window] {
        precondition(sampleCount >= 0 && windowSize > 0)
        guard sampleCount > 0 else { return [] }
        let step = max(1, windowSize / 2)
        var sources: [Range<Int>] = [0..<min(sampleCount, windowSize)]
        while sources.last!.upperBound < sampleCount {
            let previous = sources.last!.lowerBound
            let start = previous + min(step, sampleCount - windowSize - previous)
            sources.append(start..<(start + windowSize))
        }
        var lower = 0
        return sources.indices.map { index in
            let upper: Int
            if index + 1 < sources.count {
                let nextStart = sources[index + 1].lowerBound
                upper = nextStart + (sources[index].upperBound - nextStart) / 2
            } else { upper = sampleCount }
            defer { lower = upper }
            return Window(source: sources[index], owned: lower..<upper)
        }
    }
}
