import CryptoKit
import Foundation
import HarcClient
import HarcClientStore
import HarcCore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

struct HarcDesktopProcessingSubmission: Codable, Sendable {
    let exactSignedMetadata: Data
    let exactBundle: Data
}

enum HarcDesktopProcessingArtifactBuilder {
    static func makeSubmission(
        origin: OriginRecordingID,
        clientRoot: URL,
        adoption: ValidatedClientAdoptionEvidence,
        identity: InstallationSigningIdentity,
        now: Date = Date()
    ) throws -> HarcDesktopProcessingSubmission? {
        guard adoption.grant.deviceID == identity.deviceID,
              adoption.grant.scopes.contains(.processingSubmitOwn),
              adoption.grant.libraryID == adoption.hostTrust.libraryID,
              adoption.grant.hostAuthorityID
                == adoption.hostTrust.hostAuthorityID else {
            return nil
        }
        let sidecarURL = clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
            )
        let sidecar = try JSONDecoder().decode(
            HarcDesktopClientCaptureSidecar.self,
            from: Data(contentsOf: sidecarURL, options: .mappedIfSafe)
        )
        guard sidecar.capture.originRecordingID == origin,
              sidecar.capture.producingDeviceID == identity.deviceID,
              let transcript = sidecar.transcript,
              let processingCoverage = transcript.processingCoverage,
              !transcript.joinedText.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            return nil
        }

        let totalFrames = sidecar.capture.totalCanonicalFrames
        let artifactID = UUID()
        let operationID = OperationID(UUID())
        let coverage = try makeCoverage(
            totalFrames: totalFrames,
            evidence: processingCoverage
        )
        let transcriptPayload = try transcriptPayload(
            transcript,
            totalFrames: totalFrames
        ).serializedData()
        var coverageArtifact = Harc_V1_CoverageArtifactV1()
        coverageArtifact.protocol = HarcProtocolVersion.v1.protobufV1()
        coverageArtifact.coverage = coverage
        let coveragePayload = try coverageArtifact.serializedData()
        let payloads = [transcriptPayload, coveragePayload]
        let types: [Harc_V1_ProcessingBundleEntryTypeV1] = [
            .processingBundleEntryTypeTranscript,
            .processingBundleEntryTypeCoverage,
        ]

        var bundleHeader = Harc_V1_ProcessingBundleHeaderV1()
        bundleHeader.protocol = HarcProtocolVersion.v1.protobufV1()
        bundleHeader.artifactID.value = uuidBytes(artifactID)
        bundleHeader.originRecordingID = Harc_V1_OriginRecordingIDV1(origin)
        bundleHeader.canonicalAudioSha256.value =
            sidecar.capture.canonicalPCMSHA256.rawBytes
        bundleHeader.entries = zip(types, payloads).map { type, payload in
            var descriptor = Harc_V1_ProcessingBundleEntryDescriptorV1()
            descriptor.entryType = type
            descriptor.schemaVersion = 1
            descriptor.payloadByteLength = UInt64(payload.count)
            descriptor.payloadSha256.value = Data(SHA256.hash(data: payload))
            return descriptor
        }
        let bundle = try HarcProcessingBundleV1.create(
            header: bundleHeader,
            exactEntryPayloads: payloads,
            totalCanonicalFrames: totalFrames
        )

        let issuedAt = try unixMilliseconds(now)
        let expiry = issuedAt.addingReportingOverflow(
            HarcProtocolLimits.initialCommandLifetimeMilliseconds
        )
        guard !expiry.overflow else {
            throw HarcDesktopProcessingArtifactError.invalidTime
        }
        var metadata = Harc_V1_ProcessingArtifactV1()
        metadata.protocol = HarcProtocolVersion.v1.protobufV1()
        metadata.libraryID = Harc_V1_LibraryIDV1(adoption.grant.libraryID)
        metadata.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            adoption.grant.hostAuthorityID
        )
        metadata.artifactID.value = uuidBytes(artifactID)
        metadata.originRecordingID = Harc_V1_OriginRecordingIDV1(origin)
        metadata.canonicalAudioSha256.value =
            sidecar.capture.canonicalPCMSHA256.rawBytes
        metadata.producingDeviceID = Harc_V1_DeviceIDV1(identity.deviceID)
        metadata.grantID = Harc_V1_GrantIDV1(adoption.grant.grantID)
        metadata.grantEpoch = adoption.grant.registryEpoch
        metadata.operationID = Harc_V1_OperationIDV1(operationID)
        metadata.issuedAtUnixMs = issuedAt
        metadata.submissionExpiresAtUnixMs = expiry.partialValue
        metadata.engineRevision = transcript.manualEditAt == nil
            ? "harc-stt.\(HarcVersion.sttEngineVersion)"
            : "harc-user-edited.v1"
        metadata.buildRevision = "harc-macos-client.v1"
        if sidecar.speakerProcessingNeedsRetry {
            metadata.diarizationRevision = "harc-diarization.retry-needed.v1"
        } else if (sidecar.speakerEmbeddings ?? []).isEmpty {
            metadata.diarizationRevision = "harc-diarization.no-observations.v1"
        } else {
            metadata.diarizationRevision = "harc-diarization.local.v1"
        }
        metadata.vadRevision = "harc-vad.local.v1"
        metadata.vocabularyRevision = "harc-vocabulary.default.v1"
        metadata.promptRevision = "harc-transcript.none.v1"
        metadata.wordTimingSchemaID = transcript.manualEditAt == nil
            ? "harc.word-timing.v1"
            : "harc.word-timing.approximate.v1"
        metadata.coverage = coverage
        metadata.exactBundleByteLength = UInt64(bundle.exactBytes.count)
        metadata.exactBundleSha256.value = bundle.exactSHA256

        let exactPayload = try metadata.serializedData()
        let envelope = try HarcSignedEnvelopeV1(
            messageType: .processingArtifact,
            protocolVersion: .v1,
            libraryID: adoption.grant.libraryID,
            hostAuthorityID: adoption.grant.hostAuthorityID,
            signerDeviceID: identity.deviceID,
            grantID: adoption.grant.grantID.rawValue,
            grantEpoch: adoption.grant.registryEpoch,
            operationID: operationID.rawValue,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: expiry.partialValue,
            payloadType: .processingArtifact,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(exactPayload)
        )
        let signed = try HarcSignedObjectV1.sign(
            header: envelope,
            exactPayloadBytes: exactPayload,
            using: identity
        )
        _ = try signed.authenticateRegisteredPayload(
            using: identity.publicKey,
            purpose: .historicalEvidence
        )
        return HarcDesktopProcessingSubmission(
            exactSignedMetadata: signed.exactFramedBytes,
            exactBundle: bundle.exactBytes
        )
    }

    static func requests(
        for submission: HarcDesktopProcessingSubmission
    ) -> [Harc_V1_SubmitOwnArtifactRequestV1] {
        var begin = Harc_V1_SubmitOwnArtifactRequestV1()
        begin.protocol = HarcProtocolVersion.v1.protobufV1()
        begin.begin.exactSignedProcessingArtifact.framedBytes =
            submission.exactSignedMetadata
        var requests = [begin]
        var offset = 0
        var index: UInt32 = 0
        while offset < submission.exactBundle.count {
            let end = min(
                offset + HarcProcessingBundleV1.maximumHeaderBytes,
                submission.exactBundle.count
            )
            var request = Harc_V1_SubmitOwnArtifactRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.frame.frameIndex = index
            request.frame.byteOffset = UInt64(offset)
            request.frame.data = submission.exactBundle[offset ..< end]
            requests.append(request)
            offset = end
            index &+= 1
        }
        return requests
    }

    private static func transcriptPayload(
        _ transcript: SessionTranscript,
        totalFrames: UInt64
    ) throws -> Harc_V1_TranscriptArtifactV1 {
        var value = Harc_V1_TranscriptArtifactV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.locale = "en-US"
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = transcript.joinedText
        utterance.startFrame = 0
        utterance.endFrameExclusive = totalFrames
        var priorEnd: UInt64 = 0
        utterance.words = transcript.words.compactMap { word in
            let start = min(totalFrames, frames(milliseconds: word.startMs))
            let end = min(totalFrames, frames(milliseconds: word.endMs))
            guard end > start, start >= priorEnd else { return nil }
            priorEnd = end
            var wire = Harc_V1_TranscriptWordV1()
            wire.text = word.text
            wire.startFrame = start
            wire.endFrameExclusive = end
            return wire
        }
        value.utterances = [utterance]
        return value
    }

    static func makeCoverage(
        totalFrames: UInt64,
        evidence: TranscriptProcessingCoverage
    ) throws -> Harc_V1_ArtifactCoverageV1 {
        guard totalFrames > 0 else {
            throw HarcDesktopProcessingArtifactError.invalidCoverage
        }
        let degraded = try normalize(
            evidence.degradedRanges,
            totalFrames: totalFrames,
            combinedReason: "stt.multiple_degradations"
        )
        let failed = try normalize(
            evidence.failedRanges,
            totalFrames: totalFrames,
            combinedReason: "stt.multiple_failures"
        )
        let categorized = (
            degraded.map { (start: $0.start, end: $0.end) }
                + failed.map { (start: $0.start, end: $0.end) }
        ).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var priorEnd: UInt64 = 0
        for range in categorized {
            guard range.start >= priorEnd else {
                throw HarcDesktopProcessingArtifactError.invalidCoverage
            }
            priorEnd = range.end
        }

        var coverage = Harc_V1_ArtifactCoverageV1()
        coverage.degradedRanges = degraded.map { value in
            var range = Harc_V1_ExplainedFrameRangeV1()
            range.frames.startFrame = value.start
            range.frames.endFrameExclusive = value.end
            range.reasonCode = value.reasonCode
            return range
        }
        coverage.failedRanges = failed.map { value in
            var range = Harc_V1_ExplainedFrameRangeV1()
            range.frames.startFrame = value.start
            range.frames.endFrameExclusive = value.end
            range.reasonCode = value.reasonCode
            return range
        }

        var cursor: UInt64 = 0
        for issue in categorized {
            if cursor < issue.start {
                var covered = Harc_V1_CanonicalFrameRangeV1()
                covered.startFrame = cursor
                covered.endFrameExclusive = issue.start
                coverage.coveredRanges.append(covered)
            }
            cursor = issue.end
        }
        if cursor < totalFrames {
            var covered = Harc_V1_CanonicalFrameRangeV1()
            covered.startFrame = cursor
            covered.endFrameExclusive = totalFrames
            coverage.coveredRanges.append(covered)
        }
        return coverage
    }

    private struct NormalizedCoverageIssue {
        var start: UInt64
        var end: UInt64
        var reasonCode: String
    }

    private static func normalize(
        _ issues: [TranscriptCoverageIssue],
        totalFrames: UInt64,
        combinedReason: String
    ) throws -> [NormalizedCoverageIssue] {
        let normalized = try issues.map { issue -> NormalizedCoverageIssue in
            guard issue.startMs >= 0,
                  issue.endMs > issue.startMs,
                  isProtocolIdentifier(issue.reasonCode) else {
                throw HarcDesktopProcessingArtifactError.invalidCoverage
            }
            let start = min(totalFrames, frames(milliseconds: issue.startMs))
            let end = min(totalFrames, frames(milliseconds: issue.endMs))
            guard end > start else {
                throw HarcDesktopProcessingArtifactError.invalidCoverage
            }
            return NormalizedCoverageIssue(
                start: start,
                end: end,
                reasonCode: issue.reasonCode
            )
        }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var merged: [NormalizedCoverageIssue] = []
        for issue in normalized {
            guard var last = merged.last else {
                merged.append(issue)
                continue
            }
            if issue.start <= last.end {
                last.end = max(last.end, issue.end)
                if last.reasonCode != issue.reasonCode {
                    last.reasonCode = combinedReason
                }
                merged[merged.count - 1] = last
            } else {
                merged.append(issue)
            }
        }
        return merged
    }

    private static func isProtocolIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7a)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2d || byte == 0x2e || byte == 0x5f
        }
    }

    private static func frames(milliseconds: Int) -> UInt64 {
        guard milliseconds > 0 else { return 0 }
        let product = UInt64(milliseconds).multipliedReportingOverflow(by: 16)
        return product.overflow ? UInt64.max : product.partialValue
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else {
            throw HarcDesktopProcessingArtifactError.invalidTime
        }
        return UInt64(milliseconds.rounded(.down))
    }
}

private enum HarcDesktopProcessingArtifactError: Error {
    case invalidTime
    case invalidCoverage
}
