import Foundation
import CryptoKit
import HarcClientStore
import HarcTransfer
import HarcClient
import HarcCore
import HarcDomain
import HarcProtocol
import Testing
@testable import Harc

@Suite("Desktop processing artifact framing")
struct HarcDesktopProcessingArtifactTests {
    @Test func processingStatusPreservesOptionalSelectedArtifactDigest() throws {
        var status = Harc_V1_ProcessingStatusV1()
        let absent = try Harc_V1_ProcessingStatusV1(serializedBytes: status.serializedData())
        #expect(!absent.hasSelectedEdgeBundleSha256)
        let digest = Data(repeating: 42, count: 32)
        status.selectedEdgeBundleSha256.value = digest
        let selected = try Harc_V1_ProcessingStatusV1(serializedBytes: status.serializedData())
        #expect(selected.hasSelectedEdgeBundleSha256)
        #expect(selected.selectedEdgeBundleSha256.value == digest)
    }

    @Test @MainActor func processingCompletionAndSubmissionPathFollowSidecarGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try DeviceID(Data(repeating: 2, count: 32))
        let origin = OriginRecordingID(deviceID: device, recordingUUID: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let capture = try FinalizedCapture(producingDeviceID: device, originRecordingID: origin,
            captureStartedAt: now, captureEndedAt: now.addingTimeInterval(1),
            captureStartedMonotonicNanoseconds: 0, captureEndedMonotonicNanoseconds: 1_000_000_000,
            finalizationReason: .userStopped, totalCanonicalFrames: 16_000, totalCanonicalBytes: 32_000,
            canonicalPCMSHA256: CanonicalPCMHash(Data(repeating: 1, count: 32)), discontinuities: [])
        func sidecar(_ text: String) throws -> Data {
            let transcript = SessionTranscript(startedAt: now, endedAt: now.addingTimeInterval(1),
                audioPath: root.appendingPathComponent("audio.wav").path, joinedText: text,
                words: [], speakers: [], chunks: [])
            return try JSONEncoder().encode(HarcDesktopClientCaptureSidecar(capture: capture,
                transcript: transcript, speakerEmbeddings: nil, persistedAt: now))
        }
        let first = try sidecar("first"), changed = try sidecar("changed")
        let firstDigest = Data(SHA256.hash(data: first)), changedDigest = Data(SHA256.hash(data: changed))
        let sidecarURL = captures.appendingPathComponent("\(origin.recordingUUID.uuidString.lowercased()).capture.json")
        let markerURL = captures.appendingPathComponent("\(origin.recordingUUID.uuidString.lowercased()).edge-accepted.json")
        let trust = AdoptedTrustTuple(libraryID: .random(), hostAuthorityID: try HostAuthorityID(Data(repeating: 3, count: 32)))
        try first.write(to: sidecarURL)
        #expect(HarcDesktopClientTransferCoordinator.needsProcessingArtifact(origin: origin, clientRoot: root, expectedTrust: trust))
        func writeMarker(_ digest: Data?) throws {
            let marker = HarcDesktopProcessingMarker(exactSignedMetadataSHA256: Data(repeating: 4, count: 32),
                disposition: 1, sidecarSHA256: digest, acceptedAt: now, hostBinding: HarcDesktopHostEvidenceBinding(trust: trust))
            try JSONEncoder().encode(marker).write(to: markerURL)
        }
        try writeMarker(firstDigest)
        #expect(!HarcDesktopClientTransferCoordinator.needsProcessingArtifact(origin: origin, clientRoot: root, expectedTrust: trust))
        try changed.write(to: sidecarURL)
        #expect(HarcDesktopClientTransferCoordinator.needsProcessingArtifact(origin: origin, clientRoot: root, expectedTrust: trust))
        try writeMarker(nil)
        #expect(HarcDesktopClientTransferCoordinator.needsProcessingArtifact(origin: origin, clientRoot: root, expectedTrust: trust))
        try writeMarker(changedDigest)
        #expect(!HarcDesktopClientTransferCoordinator.needsProcessingArtifact(origin: origin, clientRoot: root, expectedTrust: trust))
        #expect(HarcDesktopClientTransferCoordinator.needsProcessingArtifact(origin: origin, clientRoot: root, expectedTrust: nil))
        let grant = GrantID.random()
        let oldURL = HarcDesktopClientTransferCoordinator.processingSubmissionURL(origin: origin, grantID: grant,
            grantEpoch: 1, sidecarSHA256: firstDigest, clientRoot: root)
        let newURL = HarcDesktopClientTransferCoordinator.processingSubmissionURL(origin: origin, grantID: grant,
            grantEpoch: 1, sidecarSHA256: changedDigest, clientRoot: root)
        #expect(oldURL != newURL)
        #expect(oldURL == HarcDesktopClientTransferCoordinator.processingSubmissionURL(origin: origin, grantID: grant,
            grantEpoch: 1, sidecarSHA256: firstDigest, clientRoot: root))
        let old = HarcDesktopProcessingSubmission(exactSignedMetadata: Data("signed".utf8), exactBundle: Data("bundle".utf8), sidecarSHA256: firstDigest)
        let encoded = try JSONEncoder().encode(old)
        try encoded.write(to: oldURL)
        let reopened = try JSONDecoder().decode(HarcDesktopProcessingSubmission.self, from: Data(contentsOf: oldURL))
        #expect(reopened.matchesSidecar(firstDigest))
        #expect(!reopened.matchesSidecar(changedDigest))
        #expect(try Data(contentsOf: oldURL) == encoded)
        let legacy = try JSONDecoder().decode(HarcDesktopProcessingSubmission.self,
            from: JSONEncoder().encode(HarcDesktopProcessingSubmission(exactSignedMetadata: Data(), exactBundle: Data())))
        #expect(!legacy.matchesSidecar(firstDigest))
        #expect(!legacy.matchesSidecar(Data()))
    }

    @Test func overlapPayloadRetainsAssessmentAndBoundsEOFRounding() throws {
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "mixed", words: [], speakers: [], chunks: [])
        for overlap: [SpeechOverlapRange]? in [nil, [], [try SpeechOverlapRange(startMs: 1, endMs: 3)]] {
            transcript.overlapRanges = overlap
            let payload = try HarcDesktopProcessingArtifactBuilder.transcriptPayload(transcript, totalFrames: 40)
            #expect(payload.hasOverlapAssessment == (overlap != nil))
            #expect(payload.protocol.requirements.criticalFieldNumbers == (overlap == nil ? [] : [4]))
            if overlap?.isEmpty == false {
                #expect(payload.overlapAssessment.ranges[0].startFrame == 16)
                #expect(payload.overlapAssessment.ranges[0].endFrameExclusive == 40)
            }
        }
        transcript.overlapRanges = [try SpeechOverlapRange(startMs: 1, endMs: 4)]
        #expect(throws: (any Error).self) {
            try HarcDesktopProcessingArtifactBuilder.transcriptPayload(transcript, totalFrames: 40)
        }
    }

    @Test func completeProducerBundleRetainsExclusiveTurnsAndRequiredEntries() throws {
        var transcript = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "mixed", words: [], speakers: [
                .init(speaker: 0, startMs: 0, endMs: 1000),
                .init(speaker: 1, startMs: 500, endMs: 1500)
            ], chunks: [])
        transcript.overlapRanges = [try SpeechOverlapRange(startMs: 200, endMs: 300)]
        let bundle = try HarcDesktopProcessingArtifactBuilder.processingBundle(transcript: transcript,
            totalFrames: 24000, coverage: HarcDesktopProcessingArtifactBuilder.makeCoverage(totalFrames: 24000, evidence: .complete),
            artifactID: UUID(), origin: OriginRecordingID(deviceID: DeviceID(Data(repeating: 1, count: 32)), recordingUUID: UUID()),
            audioHash: Data(repeating: 2, count: 32))
        #expect(bundle.entries.count == 3)
        guard case .diarization(_, let value) = bundle.entries[1] else {
            Issue.record("Missing required diarization entry"); return
        }
        #expect(value.turns.map(\.startFrame) == [0,4800,16000])
        #expect(value.turns.map(\.endFrameExclusive) == [3200,8000,24000])
        #expect(value.turns.map(\.localClusterID) == ["speaker-0","speaker-0","speaker-1"])
        #expect(try HarcProcessingBundleV1.decode(bundle.exactBytes, totalCanonicalFrames: 24000).exactBytes == bundle.exactBytes)
    }

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
