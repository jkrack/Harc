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
    let sidecarSHA256: Data?

    init(exactSignedMetadata: Data, exactBundle: Data, sidecarSHA256: Data? = nil) {
        self.exactSignedMetadata = exactSignedMetadata
        self.exactBundle = exactBundle
        self.sidecarSHA256 = sidecarSHA256
    }

    func matchesSidecar(_ digest: Data) -> Bool {
        digest.count == 32 && sidecarSHA256 == digest
    }
}

struct HarcDesktopBoundSpeakerBatch: Codable, Sendable {
    let observations: [BoundSpeakerEmbeddingObservation]
    let hostBinding: HarcDesktopHostEvidenceBinding
    let sidecarSHA256: Data
    let createdAt: Date
    var completedAt: Date?

    func matches(_ proposed: [BoundSpeakerEmbeddingObservation], host: HarcDesktopHostEvidenceBinding,
        sidecar: Data) -> Bool {
        hostBinding == host && sidecarSHA256 == sidecar && sidecar.count == 32
            && observations.count == proposed.count
            && zip(observations, proposed).allSatisfy {
                $0.evidence == $1.evidence && $0.observation.speakerIndex == $1.observation.speakerIndex
            }
    }

    func persist(to url: URL, synchronize: (URL) throws -> Void = DurableFileIO.synchronizeFileAndParent) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try HarcDesktopClientFiles.writeProtectedData(encoder.encode(self), to: url,
            replacingExistingRegularFile: true)
        try synchronize(url)
    }
}

enum HarcDesktopProcessingArtifactBuilder {
    static func durableSpeakerBatch(at url: URL, proposed: [BoundSpeakerEmbeddingObservation],
        host: HarcDesktopHostEvidenceBinding, sidecarSHA256: Data, now: Date = Date(),
        synchronize: (URL) throws -> Void = DurableFileIO.synchronizeFileAndParent) throws -> HarcDesktopBoundSpeakerBatch {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw HarcDesktopProcessingArtifactError.invalidSpeakerEvidence
            }
            let batch = try JSONDecoder().decode(HarcDesktopBoundSpeakerBatch.self, from: Data(contentsOf: url))
            guard batch.matches(proposed, host: host, sidecar: sidecarSHA256) else {
                throw HarcDesktopProcessingArtifactError.invalidSpeakerEvidence
            }
            // An unfinished batch has no retry expiry. A completed batch remains
            // replayable through its review interval if its completion marker is lost.
            if batch.completedAt.map({ now < $0.addingTimeInterval(6 * 60 * 60) }) ?? true {
                try synchronize(url)
                return batch
            }
        }
        let batch = HarcDesktopBoundSpeakerBatch(observations: proposed, hostBinding: host,
            sidecarSHA256: sidecarSHA256, createdAt: now, completedAt: nil)
        try batch.persist(to: url, synchronize: synchronize)
        return batch
    }

    static func validateSelectedArtifactStatus(_ status: Harc_V1_ProcessingStatusV1,
        submission: HarcDesktopProcessingSubmission, origin: OriginRecordingID,
        canonicalID: CanonicalRecordingID, canonicalPCMHash: CanonicalPCMHash) throws {
        guard status.hasCanonicalRecordingID, status.hasOriginRecordingID,
              try status.canonicalRecordingID.domainValue() == canonicalID,
              try status.originRecordingID.domainValue() == origin,
              status.hasCanonicalAudioSha256,
              status.canonicalAudioSha256.value == canonicalPCMHash.rawBytes,
              status.hasSelectedEdgeBundleSha256,
              status.selectedEdgeBundleSha256.value == Data(SHA256.hash(data: submission.exactBundle)) else {
            throw HarcDesktopProcessingArtifactError.artifactNotSelected
        }
    }

    /// Reuse live commands byte-for-byte. Expired commands are archived before
    /// their generation slot can be replaced by a newly signed artifact.
    static func reusableSubmission(at url: URL, sidecarSHA256: Data,
        producerPublicKey: P256X963PublicKey, now: Date = Date()) throws -> HarcDesktopProcessingSubmission? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HarcDesktopProcessingArtifactError.invalidPersistedSubmission
        }
        let bytes = try Data(contentsOf: url)
        let submission = try JSONDecoder().decode(HarcDesktopProcessingSubmission.self, from: bytes)
        guard submission.matchesSidecar(sidecarSHA256),
              !submission.exactSignedMetadata.isEmpty,
              submission.exactSignedMetadata.count <= HarcProtocolLimits.signedObjectBytes,
              !submission.exactBundle.isEmpty,
              submission.exactBundle.count <= HarcProcessingBundleV1.maximumExactBytes else {
            throw HarcDesktopProcessingArtifactError.invalidPersistedSubmission
        }
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            submission.exactSignedMetadata, using: producerPublicKey, purpose: .historicalEvidence)
        guard case .processingArtifact(let payload) = authenticated.payload,
              payload.message.exactBundleByteLength == UInt64(submission.exactBundle.count),
              payload.message.exactBundleSha256.value == Data(SHA256.hash(data: submission.exactBundle)) else {
            throw HarcDesktopProcessingArtifactError.invalidPersistedSubmission
        }
        guard try unixMilliseconds(now) >= payload.message.submissionExpiresAtUnixMs else {
            try DurableFileIO.synchronizeFileAndParent(at: url)
            return submission
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let archive = url.appendingPathExtension("expired-" + digest)
        if FileManager.default.fileExists(atPath: archive.path) {
            let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  try Data(contentsOf: archive) == bytes else {
                throw HarcDesktopProcessingArtifactError.invalidPersistedSubmission
            }
        } else {
            try HarcDesktopClientFiles.writeProtectedData(bytes, to: archive)
        }
        // Also repeat these barriers after a previous archive publication whose
        // final synchronization failed. Existence alone does not authorize replacement.
        try DurableFileIO.synchronizeFileAndParent(at: archive)
        return nil
    }

    /// Builds the complete batch before transport. Duration/cluster mismatches
    /// remain errors; never relabel or truncate a stored embedding to make it fit.
    static func boundSpeakerObservations(submission: HarcDesktopProcessingSubmission,
        sidecarData: Data, origin: OriginRecordingID, canonicalID: CanonicalRecordingID,
        producerPublicKey: P256X963PublicKey, hostTrust: AdoptedTrustTuple,
        pack: SpeakerRecognitionPack?) throws -> [BoundSpeakerEmbeddingObservation] {
        let sidecarDigest = Data(SHA256.hash(data: sidecarData))
        guard submission.matchesSidecar(sidecarDigest),
              submission.exactSignedMetadata.count <= HarcProtocolLimits.signedObjectBytes,
              submission.exactBundle.count <= HarcProcessingBundleV1.maximumExactBytes else {
            throw HarcDesktopProcessingArtifactError.invalidSpeakerEvidence
        }
        let sidecar = try JSONDecoder().decode(HarcDesktopClientCaptureSidecar.self, from: sidecarData)
        guard sidecar.capture.originRecordingID == origin,
              sidecar.capture.producingDeviceID == producerPublicKey.deviceID,
              !sidecar.speakerProcessingNeedsRetry else {
            throw HarcDesktopProcessingArtifactError.invalidSpeakerEvidence
        }
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            submission.exactSignedMetadata, using: producerPublicKey, purpose: .historicalEvidence)
        let artifact = try HarcValidatedRetainedProcessingArtifactV1(authenticatedMetadata: authenticated,
            exactBundleBytes: submission.exactBundle,
            selectedSignedMetadataSHA256: Data(SHA256.hash(data: submission.exactSignedMetadata)),
            selectedBundleSHA256: Data(SHA256.hash(data: submission.exactBundle)),
            totalCanonicalFrames: sidecar.capture.totalCanonicalFrames)
        guard try artifact.metadata.message.libraryID.domainValue() == hostTrust.libraryID,
              try artifact.metadata.message.hostAuthorityID.domainValue() == hostTrust.hostAuthorityID,
              try artifact.metadata.message.originRecordingID.domainValue() == origin,
              try artifact.metadata.message.producingDeviceID.domainValue() == producerPublicKey.deviceID,
              artifact.metadata.message.canonicalAudioSha256.value == sidecar.capture.canonicalPCMSHA256.rawBytes else {
            throw HarcDesktopProcessingArtifactError.invalidSpeakerEvidence
        }
        let observations = try HarcDesktopClientTransferCoordinator.prepareSpeakerObservations(
            sidecar.speakerEmbeddings ?? [], origin: origin, canonicalID: canonicalID, pack: pack, sidecarSHA256: sidecarDigest)
        return try observations.map { candidate in
            let observation = try HarcDesktopClientTransferCoordinator.bindSpeakerObservation(candidate,
                sidecarSHA256: sidecarDigest, processingArtifactSHA256: artifact.bundle.exactSHA256)
            let evidence = try SpeakerEvidenceSnapshot(canonicalRecordingID: canonicalID,
                canonicalPCMHash: sidecar.capture.canonicalPCMSHA256, producerDeviceID: producerPublicKey.deviceID,
                processingArtifactSHA256: artifact.bundle.exactSHA256,
                localClusterID: "speaker-\(observation.speakerIndex)", embedding: observation.embedding,
                modelID: observation.modelID, speechDurationMs: observation.speechDurationMs,
                segmentCount: observation.segmentCount)
            let bound = try BoundSpeakerEmbeddingObservation(observation: observation, evidence: evidence)
            return try HarcValidatedSpeakerEvidenceV1(bound, retainedArtifact: artifact,
                canonicalRecordingID: canonicalID, originRecordingID: origin,
                canonicalPCMHash: sidecar.capture.canonicalPCMSHA256,
                currentArtifactSHA256: artifact.bundle.exactSHA256).value
        }
    }

    static func makeSubmission(
        origin: OriginRecordingID,
        clientRoot: URL,
        adoption: ValidatedClientAdoptionEvidence,
        identity: InstallationSigningIdentity,
        sidecarData: Data? = nil, now: Date = Date()
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
        let exactSidecar = try sidecarData ?? Data(contentsOf: sidecarURL, options: .mappedIfSafe)
        let sidecar = try JSONDecoder().decode(HarcDesktopClientCaptureSidecar.self, from: exactSidecar)
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
        let bundle = try processingBundle(transcript: transcript, totalFrames: totalFrames,
            coverage: coverage, artifactID: artifactID, origin: origin,
            audioHash: sidecar.capture.canonicalPCMSHA256.rawBytes)

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
            exactBundle: bundle.exactBytes,
            sidecarSHA256: Data(SHA256.hash(data: exactSidecar))
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

    static func processingBundle(
        transcript: SessionTranscript, totalFrames: UInt64, coverage: Harc_V1_ArtifactCoverageV1,
        artifactID: UUID, origin: OriginRecordingID, audioHash: Data
    ) throws -> HarcProcessingBundleV1 {
        let transcriptPayload = try transcriptPayload(
            transcript,
            totalFrames: totalFrames
        ).serializedData()
        var coverageArtifact = Harc_V1_CoverageArtifactV1()
        coverageArtifact.protocol = HarcProtocolVersion.v1.protobufV1()
        coverageArtifact.coverage = coverage
        let coveragePayload = try coverageArtifact.serializedData()
        let diarizationPayload = try Self.diarizationPayload(transcript, totalFrames: totalFrames).serializedData()
        let payloads = [transcriptPayload, diarizationPayload, coveragePayload]
        let types: [Harc_V1_ProcessingBundleEntryTypeV1] = [
            .processingBundleEntryTypeTranscript,
            .processingBundleEntryTypeDiarization,
            .processingBundleEntryTypeCoverage,
        ]

        var bundleHeader = Harc_V1_ProcessingBundleHeaderV1()
        bundleHeader.protocol = HarcProtocolVersion.v1.protobufV1()
        bundleHeader.artifactID.value = uuidBytes(artifactID)
        bundleHeader.originRecordingID = Harc_V1_OriginRecordingIDV1(origin)
        bundleHeader.canonicalAudioSha256.value =
            audioHash
        bundleHeader.entries = zip(types, payloads).map { type, payload in
            var descriptor = Harc_V1_ProcessingBundleEntryDescriptorV1()
            descriptor.entryType = type
            descriptor.schemaVersion = 1
            descriptor.payloadByteLength = UInt64(payload.count)
            descriptor.payloadSha256.value = Data(SHA256.hash(data: payload))
            return descriptor
        }
        return try HarcProcessingBundleV1.create(
            header: bundleHeader,
            exactEntryPayloads: payloads,
            totalCanonicalFrames: totalFrames
        )

    }

    /// V1 diarization turns are disjoint exclusive assignments. Preserve raw
    /// overlap separately in the transcript assessment; never choose one voice
    /// when raw overlap or multiple tracked speakers cover the same interval.
    static func diarizationPayload(
        _ transcript: SessionTranscript, totalFrames: UInt64
    ) throws -> Harc_V1_DiarizationArtifactV1 {
        struct Event { let frame: UInt64; let speaker: Int?; let delta: Int }
        var events: [Event] = []
        func append(startMs: Int, endMs: Int, speaker: Int?) throws {
            guard startMs >= 0, endMs > startMs else {
                throw HarcProtocolCodecError.invalidTimeRange(field: "diarization.turn")
            }
            let start = frames(milliseconds: startMs), roundedEnd = frames(milliseconds: endMs)
            guard roundedEnd <= totalFrames || roundedEnd - totalFrames < 16 else {
                throw HarcProtocolCodecError.invalidTimeRange(field: "diarization.turn")
            }
            let end = min(totalFrames, roundedEnd)
            guard end > start else { throw HarcProtocolCodecError.invalidTimeRange(field: "diarization.turn") }
            events.append(Event(frame: start, speaker: speaker, delta: 1))
            events.append(Event(frame: end, speaker: speaker, delta: -1))
        }
        for segment in transcript.speakers {
            guard segment.speaker >= 0 else { throw HarcProtocolCodecError.invalidText(field: "diarization.speaker") }
            try append(startMs: segment.startMs, endMs: segment.endMs, speaker: segment.speaker)
        }
        for range in transcript.overlapRanges ?? [] {
            try append(startMs: range.startMs, endMs: range.endMs, speaker: nil)
        }
        events.sort { $0.frame < $1.frame }
        var value = Harc_V1_DiarizationArtifactV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        var counts: [Int: Int] = [:], overlapDepth = 0, index = 0
        while index < events.count {
            let start = events[index].frame
            while index < events.count, events[index].frame == start {
                let event = events[index]
                if let speaker = event.speaker {
                    let count = (counts[speaker] ?? 0) + event.delta
                    if count == 0 { counts.removeValue(forKey: speaker) } else { counts[speaker] = count }
                } else { overlapDepth += event.delta }
                index += 1
            }
            guard index < events.count, overlapDepth == 0, counts.count == 1,
                  let speaker = counts.keys.first else { continue }
            let end = events[index].frame, cluster = "speaker-\(speaker)"
            if let last = value.turns.last, last.localClusterID == cluster, last.endFrameExclusive == start {
                value.turns[value.turns.count - 1].endFrameExclusive = end
            } else {
                var turn = Harc_V1_SpeakerTurnV1()
                turn.startFrame = start; turn.endFrameExclusive = end; turn.localClusterID = cluster
                value.turns.append(turn)
            }
        }
        return value
    }

    static func transcriptPayload(
        _ transcript: SessionTranscript,
        totalFrames: UInt64
    ) throws -> Harc_V1_TranscriptArtifactV1 {
        var value = Harc_V1_TranscriptArtifactV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.locale = "en-US"
        if let overlaps = transcript.overlapRanges {
            value.protocol.requirements.criticalFieldNumbers = [4]
            var assessment = Harc_V1_SpeechOverlapAssessmentV1()
            assessment.ranges = try overlaps.map { range in
                let start = frames(milliseconds: range.startMs)
                let roundedEnd = frames(milliseconds: range.endMs)
                // Local overlap ranges round outward to milliseconds. Permit
                // only that sub-millisecond rounding at the canonical EOF.
                guard roundedEnd <= totalFrames || roundedEnd - totalFrames < 16 else {
                    throw HarcProtocolCodecError.invalidTimeRange(field: "transcript.overlapAssessment")
                }
                let end = min(totalFrames, roundedEnd)
                guard end > start else {
                    throw HarcProtocolCodecError.invalidTimeRange(field: "transcript.overlapAssessment")
                }
                var wire = Harc_V1_CanonicalFrameRangeV1()
                wire.startFrame = start
                wire.endFrameExclusive = end
                return wire
            }
            value.overlapAssessment = assessment
        }
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

private enum HarcDesktopProcessingArtifactError: Error, LocalizedError {
    case invalidTime
    case invalidCoverage
    case invalidSpeakerEvidence
    case invalidPersistedSubmission
    case artifactNotSelected

    var errorDescription: String? {
        switch self {
        case .invalidTime: "The processing submission has an invalid timestamp."
        case .invalidCoverage: "The transcript's audio coverage is inconsistent. Reprocess this recording."
        case .artifactNotSelected: "Speaker delivery is waiting for the Host to select the matching processing artifact."
        case .invalidPersistedSubmission: "The saved processing submission is invalid. Its evidence has been preserved."
        case .invalidSpeakerEvidence: "The voice evidence does not match the submitted transcript. Reprocess this recording."
        }
    }
}
