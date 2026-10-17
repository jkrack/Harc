import Foundation
import HarcCore
import FluidAudio
import Testing
@testable import HarcSTT

@Suite("Diarization context and identity boundaries")
struct DiarizationWindowPlanTests {
    @Test func shortEmbeddingMaskExcludesOverlapSilenceAndOtherSpeakers() {
        let segments = [SpeakerSegment(speaker: 0, startMs: 0, endMs: 400),
                        SpeakerSegment(speaker: 1, startMs: 200, endMs: 600)]
        #expect(Diarizer.shortRecordingMask(speakerIndex: 0, segments: segments,
            frameCount: 10, windowDurationMs: 1000, rawSegmentation: [[1,0,0]]) == [1,1,0,0,0,0,0,0,0,0])
        #expect(Diarizer.shortRecordingMask(speakerIndex: 1, segments: segments,
            frameCount: 10, windowDurationMs: 1000, rawSegmentation: [[1,0,0]]) == [0,0,0,0,1,1,0,0,0,0])
        #expect(Diarizer.shortRecordingMask(speakerIndex: 0, segments: segments,
            frameCount: 0, windowDurationMs: 1000, rawSegmentation: [[1,0,0]]).isEmpty)
    }

    @Test func rawOverlapSurvivesMissingTrackedChannelAndDifferentFrameGrids() {
        let onlyTrackedSpeaker = [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)]
        let raw: [[Float]] = [[1,0,0], [1,1,0], [1,0,0]]
        #expect(Diarizer.shortRecordingMask(speakerIndex: 0, segments: onlyTrackedSpeaker,
            frameCount: 4, windowDurationMs: 1000, rawSegmentation: raw) == [1,0,0,1])
        #expect(Diarizer.shortRecordingMask(speakerIndex: 0, segments: onlyTrackedSpeaker,
            frameCount: 4, windowDurationMs: 1000, rawSegmentation: [[1,1,0]]) == [0,0,0,0])
    }

    @Test func missingOrMalformedRawSegmentationCannotAuthorizeVoiceSamples() {
        let segment = [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)]
        for raw: [[Float]] in [[], [[]], [[1,0]], [[1,0,Float.nan]], [[1,0,0.5]]] {
            #expect(Diarizer.shortRecordingMask(speakerIndex: 0, segments: segment,
                frameCount: 4, windowDurationMs: 1000, rawSegmentation: raw) == [0,0,0,0])
        }
    }

    @Test func rawOverlapClipsPaddingAndMergesOwnedWindowBoundary() throws {
        let raw: [[Float]] = [[1,1,0], [1,1,0], [1,0,0]]
        let first = try Diarizer.rawOverlapRanges(raw, sourceStartSample: 0, ownedSamples: 0..<800)
        let second = try Diarizer.rawOverlapRanges(raw, sourceStartSample: 0, ownedSamples: 800..<1600)
        #expect(first == [try SpeechOverlapRange(startMs: 0, endMs: 50)])
        #expect(second == [try SpeechOverlapRange(startMs: 50, endMs: 79)])
        #expect(try Diarizer.mergeOverlapRanges(first + second) == [try SpeechOverlapRange(startMs: 0, endMs: 79)])
        #expect(try Diarizer.rawOverlapRanges([[1,0,0]], sourceStartSample: 0,
            ownedSamples: 0..<1600).isEmpty)
        #expect(throws: (any Error).self) {
            try Diarizer.rawOverlapRanges([], sourceStartSample: 0, ownedSamples: 0..<1600)
        }
    }

    @Test func contextOverlapsButPublicationHasNoGapsOrDuplicates() {
        for size in [1, 2, 3, 10, 160_000] {
            for count in [0, 1, size, size + 1, size * 2, size * 3 + 7] {
                let windows = DiarizationWindowPlan.windows(sampleCount: count, windowSize: size)
                var next = 0
                for window in windows {
                    #expect(window.source.lowerBound >= 0)
                    #expect(window.source.upperBound <= count)
                    #expect(window.source.count == min(size, count))
                    #expect(window.owned.lowerBound == next)
                    #expect(!window.owned.isEmpty)
                    #expect(window.source.lowerBound <= window.owned.lowerBound)
                    #expect(window.source.upperBound >= window.owned.upperBound)
                    next = window.owned.upperBound
                }
                #expect(next == count)
            }
        }
    }

    @Test func shortTailRetainsRealPrecedingAudio() {
        let windows = DiarizationWindowPlan.windows(sampleCount: 200_000, windowSize: 160_000)
        #expect(windows.map(\.source) == [0..<160_000, 40_000..<200_000])
        #expect(windows.map(\.owned) == [0..<100_000, 100_000..<200_000])
    }

    @Test func trackerSeparatesWeaklySimilarVoicesAndRetainsStrongMatch() throws {
        let manager = Diarizer.makeManager()
        var first = [Float](repeating: 0, count: 256); first[0] = 1
        var same = first; same[0] = 0.95; same[1] = sqrt(1 - 0.95 * 0.95)
        var other = first; other[0] = 0.54; other[2] = sqrt(1 - 0.54 * 0.54)
        let enrolledCandidate = manager.speakerManager.assignSpeaker(first, speechDuration: 5, confidence: 1)
        let enrolled = try #require(enrolledCandidate)
        let repeatedCandidate = manager.speakerManager.assignSpeaker(same, speechDuration: 5, confidence: 1)
        let repeated = try #require(repeatedCandidate)
        let distinctCandidate = manager.speakerManager.assignSpeaker(other, speechDuration: 5, confidence: 1)
        let distinct = try #require(distinctCandidate)
        #expect(enrolled.id == repeated.id)
        #expect(enrolled.id != distinct.id)
    }
}
