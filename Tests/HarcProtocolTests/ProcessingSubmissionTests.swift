import CryptoKit
import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
import Testing

@Suite("Authenticated processing submission binding")
struct ProcessingSubmissionTests {
    @Test("signed metadata and exact HARCPB1 body validate only as one bound value")
    func boundSubmission() throws {
        let fixture = try makeFixture()
        let submission = try HarcValidatedProcessingSubmissionV1(
            authenticatedMetadata: fixture.authenticated,
            exactBundleBytes: fixture.bundle.exactBytes,
            totalCanonicalFrames: 4
        )
        #expect(submission.bundle.exactBytes == fixture.bundle.exactBytes)
        #expect(submission.metadata.exactBytes == fixture.authenticated.signedObject.exactPayloadBytes)
        #expect(submission.totalCanonicalFrames == 4)
    }

    @Test("historical authentication cannot be promoted to a live processing command")
    func historicalEvidenceCannotBecomeLiveSubmission() throws {
        let fixture = try makeFixture()
        let historical = try authenticateMetadata(
            fixture: fixture.context,
            artifactID: fixture.artifactID,
            audioSHA256: fixture.audioSHA256,
            coverage: coveredRange(),
            exactBundleBytes: fixture.bundle.exactBytes,
            purpose: .historicalEvidence
        )
        #expect(historical.authenticationPurpose == .historicalEvidence)
        #expect(throws: HarcProtocolCodecError.currentGrantRequired) {
            try HarcValidatedProcessingSubmissionV1(
                authenticatedMetadata: historical,
                exactBundleBytes: fixture.bundle.exactBytes,
                totalCanonicalFrames: 4
            )
        }
    }

    @Test("valid objects cannot be swapped across artifact, audio, coverage, or length bindings")
    func bindingRejections() throws {
        let fixture = try makeFixture()
        let otherArtifactID = uuidBytes(9_001)
        let otherBundle = try makeBundle(
            artifactID: otherArtifactID,
            origin: fixture.origin,
            audioSHA256: fixture.audioSHA256,
            coverage: coveredRange()
        )
        let metadataForOtherBytes = try authenticateMetadata(
            fixture: fixture.context,
            artifactID: fixture.artifactID,
            audioSHA256: fixture.audioSHA256,
            coverage: coveredRange(),
            exactBundleBytes: otherBundle.exactBytes
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "processingSubmission.artifactID"
        )) {
            try HarcValidatedProcessingSubmissionV1(
                authenticatedMetadata: metadataForOtherBytes,
                exactBundleBytes: otherBundle.exactBytes,
                totalCanonicalFrames: 4
            )
        }

        let otherAudio = Data(repeating: 0x99, count: 32)
        let otherAudioBundle = try makeBundle(
            artifactID: fixture.artifactID,
            origin: fixture.origin,
            audioSHA256: otherAudio,
            coverage: coveredRange()
        )
        let metadataForOtherAudioBytes = try authenticateMetadata(
            fixture: fixture.context,
            artifactID: fixture.artifactID,
            audioSHA256: fixture.audioSHA256,
            coverage: coveredRange(),
            exactBundleBytes: otherAudioBundle.exactBytes
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "processingSubmission.canonicalAudioSHA256"
        )) {
            try HarcValidatedProcessingSubmissionV1(
                authenticatedMetadata: metadataForOtherAudioBytes,
                exactBundleBytes: otherAudioBundle.exactBytes,
                totalCanonicalFrames: 4
            )
        }

        let degraded = degradedRange()
        let degradedMetadata = try authenticateMetadata(
            fixture: fixture.context,
            artifactID: fixture.artifactID,
            audioSHA256: fixture.audioSHA256,
            coverage: degraded,
            exactBundleBytes: fixture.bundle.exactBytes
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "processingSubmission.coverage"
        )) {
            try HarcValidatedProcessingSubmissionV1(
                authenticatedMetadata: degradedMetadata,
                exactBundleBytes: fixture.bundle.exactBytes,
                totalCanonicalFrames: 4
            )
        }

        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "processingSubmission.bundleByteLength"
        )) {
            try HarcValidatedProcessingSubmissionV1(
                authenticatedMetadata: fixture.authenticated,
                exactBundleBytes: fixture.bundle.exactBytes + Data([0]),
                totalCanonicalFrames: 4
            )
        }
    }

    private struct FixtureContext {
        let hostKey: SoftwareP256SigningKey
        let deviceKey: SoftwareP256SigningKey
        let libraryID: LibraryID
        let grantID: UUID
        let operationID: UUID
        let artifactID: Data
        let origin: Harc_V1_OriginRecordingIDV1
        let audioSHA256: Data
    }

    private struct Fixture {
        let context: FixtureContext
        let bundle: HarcProcessingBundleV1
        let authenticated: HarcAuthenticatedSignedObjectV1

        var artifactID: Data { context.artifactID }
        var origin: Harc_V1_OriginRecordingIDV1 { context.origin }
        var audioSHA256: Data { context.audioSHA256 }
    }

    private func makeFixture() throws -> Fixture {
        let hostKey = ProtocolCodecFixtures.key(80)
        let deviceKey = ProtocolCodecFixtures.key(81)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(8_000))
        let grantID = ProtocolCodecFixtures.uuid(8_001)
        let operationID = ProtocolCodecFixtures.uuid(8_002)
        let artifactID = uuidBytes(8_003)
        var origin = Harc_V1_OriginRecordingIDV1()
        origin.deviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        origin.recordingUuid = uuidBytes(8_004)
        let audioSHA256 = Data(repeating: 0x88, count: 32)
        let bundle = try makeBundle(
            artifactID: artifactID,
            origin: origin,
            audioSHA256: audioSHA256,
            coverage: coveredRange()
        )

        let context = FixtureContext(
            hostKey: hostKey,
            deviceKey: deviceKey,
            libraryID: libraryID,
            grantID: grantID,
            operationID: operationID,
            artifactID: artifactID,
            origin: origin,
            audioSHA256: audioSHA256
        )
        let authenticated = try authenticateMetadata(
            fixture: context,
            artifactID: artifactID,
            audioSHA256: audioSHA256,
            coverage: coveredRange(),
            exactBundleBytes: bundle.exactBytes
        )
        return Fixture(
            context: context,
            bundle: bundle,
            authenticated: authenticated
        )
    }

    private func authenticateMetadata(
        fixture: FixtureContext,
        artifactID: Data,
        audioSHA256: Data,
        coverage: Harc_V1_ArtifactCoverageV1,
        exactBundleBytes: Data,
        purpose explicitPurpose: HarcSignedObjectAuthenticationPurposeV1? = nil
    ) throws -> HarcAuthenticatedSignedObjectV1 {
        let issuedAt = ProtocolCodecFixtures.issuedAt
        var value = Harc_V1_ProcessingArtifactV1()
        value.protocol = protocolVersion()
        value.libraryID = Harc_V1_LibraryIDV1(fixture.libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(fixture.hostKey.publicKey.hostAuthorityID)
        value.artifactID.value = artifactID
        value.originRecordingID = fixture.origin
        value.canonicalAudioSha256.value = audioSHA256
        value.producingDeviceID = Harc_V1_DeviceIDV1(fixture.deviceKey.publicKey.deviceID)
        value.grantID.value = uuidBytes(fixture.grantID)
        value.grantEpoch = 1
        value.operationID.value = uuidBytes(fixture.operationID)
        value.issuedAtUnixMs = issuedAt
        value.submissionExpiresAtUnixMs = issuedAt + 60_000
        value.engineRevision = "engine.v1"
        value.buildRevision = "build.v1"
        value.diarizationRevision = "diarization.v1"
        value.vadRevision = "vad.v1"
        value.vocabularyRevision = "vocabulary.v1"
        value.promptRevision = "prompt.v1"
        value.wordTimingSchemaID = "harc.word-timing.v1"
        value.coverage = coverage
        value.exactBundleByteLength = UInt64(exactBundleBytes.count)
        value.exactBundleSha256.value = Data(SHA256.hash(data: exactBundleBytes))
        let payload = try value.serializedData()
        let header = try HarcSignedEnvelopeV1(
            messageType: .processingArtifact,
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            signerDeviceID: fixture.deviceKey.publicKey.deviceID,
            grantID: fixture.grantID,
            grantEpoch: 1,
            operationID: fixture.operationID,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: issuedAt + 60_000,
            payloadType: .processingArtifact,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        let object = try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: payload,
            using: fixture.deviceKey
        )
        let purpose: HarcSignedObjectAuthenticationPurposeV1
        if let explicitPurpose {
            purpose = explicitPurpose
        } else {
            purpose = .initialCommandAcceptance(
                acceptedAtUnixMilliseconds: issuedAt + 1,
                currentGrant: try ProtocolCodecFixtures.currentGrantBinding(
                    libraryID: fixture.libraryID,
                    hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
                    deviceKey: fixture.deviceKey,
                    grantID: fixture.grantID,
                    grantEpoch: 1,
                    scopes: [.processingSubmitOwn]
                )
            )
        }
        return try object.authenticateRegisteredPayload(
            using: fixture.deviceKey.publicKey,
            purpose: purpose
        )
    }

    private func makeBundle(
        artifactID: Data,
        origin: Harc_V1_OriginRecordingIDV1,
        audioSHA256: Data,
        coverage: Harc_V1_ArtifactCoverageV1
    ) throws -> HarcProcessingBundleV1 {
        var transcript = Harc_V1_TranscriptArtifactV1()
        transcript.protocol = protocolVersion()
        transcript.locale = "en-US"
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = "test"
        utterance.startFrame = 0
        utterance.endFrameExclusive = 4
        transcript.utterances = [utterance]

        var diarization = Harc_V1_DiarizationArtifactV1()
        diarization.protocol = protocolVersion()
        var turn = Harc_V1_SpeakerTurnV1()
        turn.startFrame = 0
        turn.endFrameExclusive = 4
        turn.localClusterID = "speaker-1"
        diarization.turns = [turn]

        var coverageArtifact = Harc_V1_CoverageArtifactV1()
        coverageArtifact.protocol = protocolVersion()
        coverageArtifact.coverage = coverage
        let payloads = try [
            transcript.serializedData(),
            diarization.serializedData(),
            coverageArtifact.serializedData(),
        ]
        let types: [Harc_V1_ProcessingBundleEntryTypeV1] = [
            .processingBundleEntryTypeTranscript,
            .processingBundleEntryTypeDiarization,
            .processingBundleEntryTypeCoverage,
        ]
        var header = Harc_V1_ProcessingBundleHeaderV1()
        header.protocol = protocolVersion()
        header.artifactID.value = artifactID
        header.originRecordingID = origin
        header.canonicalAudioSha256.value = audioSHA256
        header.entries = zip(types, payloads).map { type, payload in
            var descriptor = Harc_V1_ProcessingBundleEntryDescriptorV1()
            descriptor.entryType = type
            descriptor.schemaVersion = 1
            descriptor.payloadByteLength = UInt64(payload.count)
            descriptor.payloadSha256.value = Data(SHA256.hash(data: payload))
            return descriptor
        }
        return try HarcProcessingBundleV1.create(
            header: header,
            exactEntryPayloads: payloads,
            totalCanonicalFrames: 4
        )
    }

    private func coveredRange() -> Harc_V1_ArtifactCoverageV1 {
        var coverage = Harc_V1_ArtifactCoverageV1()
        var range = Harc_V1_CanonicalFrameRangeV1()
        range.startFrame = 0
        range.endFrameExclusive = 4
        coverage.coveredRanges = [range]
        return coverage
    }

    private func degradedRange() -> Harc_V1_ArtifactCoverageV1 {
        var coverage = Harc_V1_ArtifactCoverageV1()
        var range = Harc_V1_ExplainedFrameRangeV1()
        range.frames.startFrame = 0
        range.frames.endFrameExclusive = 4
        range.reasonCode = "quality.degraded"
        coverage.degradedRanges = [range]
        return coverage
    }

    private func protocolVersion() -> Harc_V1_ProtocolVersionV1 {
        var value = Harc_V1_ProtocolVersionV1()
        value.major = 1
        value.minor = 0
        return value
    }

    private func uuidBytes(_ value: UInt32) -> Data {
        uuidBytes(ProtocolCodecFixtures.uuid(value))
    }

    private func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }

}
