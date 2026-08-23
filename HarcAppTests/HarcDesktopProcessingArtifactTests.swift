import Foundation
import HarcClient
import HarcProtocol
import Testing
@testable import Harc

@Suite("Desktop processing artifact framing")
struct HarcDesktopProcessingArtifactTests {
    @Test("complete evidence covers the exact canonical master")
    func completeCoverage() throws {
        let coverage = try HarcDesktopProcessingArtifactBuilder.makeCoverage(
            totalFrames: 48_000,
            evidence: .complete
        )
        #expect(coverage.coveredRanges.count == 1)
        #expect(coverage.coveredRanges[0].startFrame == 0)
        #expect(coverage.coveredRanges[0].endFrameExclusive == 48_000)
        #expect(coverage.degradedRanges.isEmpty)
        #expect(coverage.failedRanges.isEmpty)
    }

    @Test("failed milliseconds split covered frames without hiding audio")
    func failedCoverage() throws {
        let evidence = TranscriptProcessingCoverage(failedRanges: [
            TranscriptCoverageIssue(
                startMs: 1_000,
                endMs: 2_000,
                reasonCode: "stt.chunk_failed"
            ),
            // Adjacent and overlapping failures collapse into one canonical
            // range, which is required when source chunks used overlap.
            TranscriptCoverageIssue(
                startMs: 1_900,
                endMs: 2_500,
                reasonCode: "stt.timeout"
            ),
        ])
        let coverage = try HarcDesktopProcessingArtifactBuilder.makeCoverage(
            totalFrames: 48_000,
            evidence: evidence
        )
        #expect(coverage.coveredRanges.count == 2)
        #expect(coverage.coveredRanges[0].startFrame == 0)
        #expect(coverage.coveredRanges[0].endFrameExclusive == 16_000)
        #expect(coverage.failedRanges.count == 1)
        #expect(coverage.failedRanges[0].frames.startFrame == 16_000)
        #expect(coverage.failedRanges[0].frames.endFrameExclusive == 40_000)
        #expect(
            coverage.failedRanges[0].reasonCode == "stt.multiple_failures"
        )
        #expect(coverage.coveredRanges[1].startFrame == 40_000)
        #expect(coverage.coveredRanges[1].endFrameExclusive == 48_000)
    }

    @Test("overlapping degraded and failed claims fail closed")
    func conflictingCoverage() {
        let evidence = TranscriptProcessingCoverage(
            degradedRanges: [
                TranscriptCoverageIssue(
                    startMs: 0,
                    endMs: 1_000,
                    reasonCode: "stt.low_confidence"
                ),
            ],
            failedRanges: [
                TranscriptCoverageIssue(
                    startMs: 500,
                    endMs: 1_500,
                    reasonCode: "stt.chunk_failed"
                ),
            ]
        )
        #expect(throws: (any Error).self) {
            try HarcDesktopProcessingArtifactBuilder.makeCoverage(
                totalFrames: 32_000,
                evidence: evidence
            )
        }
    }

    @Test("bundle requests begin once and preserve contiguous one-MiB frames")
    func requestsAreContiguous() throws {
        let bundle = Data(
            repeating: 0xa5,
            count: HarcProcessingBundleV1.maximumHeaderBytes + 37
        )
        let submission = HarcDesktopProcessingSubmission(
            exactSignedMetadata: Data("signed".utf8),
            exactBundle: bundle
        )
        let requests = HarcDesktopProcessingArtifactBuilder.requests(
            for: submission
        )
        #expect(requests.count == 3)
        guard case .begin(let begin) = requests[0].value else {
            Issue.record("First request was not begin")
            return
        }
        #expect(
            begin.exactSignedProcessingArtifact.framedBytes
                == submission.exactSignedMetadata
        )

        var reconstructed = Data()
        for (position, request) in requests.dropFirst().enumerated() {
            guard case .frame(let frame) = request.value else {
                Issue.record("Request was not a frame")
                return
            }
            #expect(frame.frameIndex == UInt32(position))
            #expect(frame.byteOffset == UInt64(reconstructed.count))
            #expect(!frame.data.isEmpty)
            #expect(
                frame.data.count
                    <= HarcProcessingBundleV1.maximumHeaderBytes
            )
            reconstructed.append(frame.data)
        }
        #expect(reconstructed == bundle)
    }
}
