import CryptoKit
import Foundation
import XCTest
import GRDB
import HarcDomain
import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
@testable import HarcHost
@testable import HarcStore

final class BoundSpeakerServiceTests: XCTestCase {
    func test_selectedSignedArtifactUsesCurrentScopeAndCanonicalCluster() async throws {
        for allowed in [false, true] {
            let fixture = HostTestFixture()
            let root = try fixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let now = fixture.beganAt.addingTimeInterval(10)
            let host = try await HarcHostStore.inMemory(stagingRoot: root.appendingPathComponent("staging"),
                metadata: fixture.metadata, capacityProvider: FixedHostVolumeCapacityProvider(), now: { now })
            let scopes: Set<AuthorizationScope> = allowed ? [.processingSubmitOwn, .speakerObservationWrite, .recordingReadOwn] : [.processingSubmitOwn, .recordingReadOwn]
            let grant = try fixture.grant(scopes: scopes)
            try await host.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("fixture registry grant".utf8))
            let context = fixture.context(for: grant)
            let authority = try await host.currentDeviceCommandAuthority(context, requiredScope: .processingSubmitOwn)
            let session = HostAuthenticatedSession(context: context, scopes: scopes.sorted(),
                exactCapabilitiesBytes: Data([1]), capabilitiesSHA256: Data(repeating: 3, count: 32),
                protocolMinor: 0, selectedCodec: "caf-alac", selectedContainer: "caf", expiresAt: now.addingTimeInterval(60))
            let sessions = HarcSessionService(store: host, protocolBoundary: UnusedSessionBoundary())
            let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("library.sqlite"))
            let queue = await store.uncoordinatedDB
            let origin = OriginRecordingID(deviceID: fixture.deviceID, recordingUUID: UUID())
            let pcm = try CanonicalPCMHash(Data(repeating: 5, count: 32))
            let recording = try await queue.write { db in
                try db.execute(sql: "UPDATE library_metadata SET library_uuid = ? WHERE id = 1",
                    arguments: [fixture.libraryID.description])
                let value = Recording(wavPath: root.appendingPathComponent("audio.wav").path, startedAt: now,
                    canonicalPCMHash: pcm, canonicalPCMFrames: 160_000)
                try value.insert(db)
                let id = db.lastInsertedRowID
                try db.execute(sql: "UPDATE recordings SET origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                    arguments: [fixture.deviceID.rawBytes, origin.recordingUUID.uuidString.lowercased(), id])
                return try XCTUnwrap(Recording.fetchOne(db, key: id))
            }
            let id = try XCTUnwrap(recording.id)
            var wireOrigin = Harc_V1_OriginRecordingIDV1()
            wireOrigin.deviceID = Harc_V1_DeviceIDV1(fixture.deviceID)
            wireOrigin.recordingUuid = uuidBytes(origin.recordingUUID)
            let artifactID = uuidBytes(UUID())
            let coverage = coveredRange(totalFrames: 160_000)
            let bundle = try makeBundle(artifactID: artifactID, origin: wireOrigin, audioSHA256: pcm.rawBytes,
                coverage: coverage, totalFrames: 160_000)
            let issuedAt = UInt64(fixture.beganAt.timeIntervalSince1970 * 1000)
            let operationID = UUID()
            var metadata = Harc_V1_ProcessingArtifactV1()
            metadata.protocol = protocolVersion()
            metadata.libraryID = Harc_V1_LibraryIDV1(fixture.libraryID)
            metadata.hostAuthorityID = Harc_V1_HostAuthorityIDV1(fixture.metadata.hostAuthorityID)
            metadata.artifactID.value = artifactID
            metadata.originRecordingID = wireOrigin
            metadata.canonicalAudioSha256.value = pcm.rawBytes
            metadata.producingDeviceID = Harc_V1_DeviceIDV1(fixture.deviceID)
            metadata.grantID.value = uuidBytes(grant.grantID.rawValue)
            metadata.grantEpoch = 1
            metadata.operationID.value = uuidBytes(operationID)
            metadata.issuedAtUnixMs = issuedAt
            metadata.submissionExpiresAtUnixMs = issuedAt + 5000
            metadata.engineRevision = "engine.v1"; metadata.buildRevision = "build.v1"
            metadata.diarizationRevision = "diarization.v1"; metadata.vadRevision = "vad.v1"
            metadata.vocabularyRevision = "vocabulary.v1"; metadata.promptRevision = "prompt.v1"
            metadata.wordTimingSchemaID = "harc.word-timing.v1"
            metadata.coverage = coverage
            metadata.exactBundleByteLength = UInt64(bundle.exactBytes.count)
            metadata.exactBundleSha256.value = bundle.exactSHA256
            let payload = try metadata.serializedData()
            let header = try HarcSignedEnvelopeV1(messageType: .processingArtifact, libraryID: fixture.libraryID,
                hostAuthorityID: fixture.metadata.hostAuthorityID, signerDeviceID: fixture.deviceID,
                grantID: grant.grantID.rawValue, grantEpoch: 1, operationID: operationID,
                issuedAtUnixMilliseconds: issuedAt, expiresAtUnixMilliseconds: issuedAt + 5000,
                payloadType: .processingArtifact, expectedRevision: nil, payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload))
            let signed = try HarcSignedObjectV1.sign(header: header, exactPayloadBytes: payload, using: fixture.deviceKey)
            let authenticated = try signed.authenticateRegisteredPayload(using: fixture.deviceKey.publicKey,
                purpose: .initialCommandAcceptance(acceptedAtUnixMilliseconds: issuedAt + 1,
                    currentGrant: HarcCurrentGrantBindingV1(registryEntry: authority.registryEntry)))
            let submission = try HarcValidatedProcessingSubmissionV1(authenticatedMetadata: authenticated,
                exactBundleBytes: bundle.exactBytes, totalCanonicalFrames: 160_000)
            let projected = try HarcHostProcessingArtifactService.acceptedTranscriptProjection(submission, recording: recording)
            let metadataURL = root.appendingPathComponent("selected.harcso"), bundleURL = root.appendingPathComponent("selected.harcpb")
            try HarcHostProcessingArtifactService.persistExact(signed.exactFramedBytes, at: metadataURL)
            try HarcHostProcessingArtifactService.persistExact(bundle.exactBytes, at: bundleURL)
            let source = try SelectedEdgeArtifactSource(signedMetadataURL: metadataURL, bundleURL: bundleURL,
                signedMetadataSHA256: Data(SHA256.hash(data: signed.exactFramedBytes)), bundleSHA256: bundle.exactSHA256)
            // Seed the future selected speaker-bearing artifact through the trusted
            // Store seam; production edge acceptance deliberately remains closed.
            let service = HarcHostProcessingArtifactService(hostStore: host, recordingStore: store,
                sessionService: sessions, acceptedEngineRevisions: ["engine.v1"])
            let initialStatus = try await service.status(session: session, originRecordingID: origin)
            XCTAssertNil(initialStatus.selectedEdgeBundleSHA256)
            try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "test", modelID: "engine.v1",
                structuredTranscriptData: projected.data, clusterMap: projected.clusterMap, artifactSource: source)
            let evidence = try SpeakerEvidenceSnapshot(canonicalRecordingID: recording.canonicalID,
                canonicalPCMHash: pcm, producerDeviceID: fixture.deviceID, processingArtifactSHA256: bundle.exactSHA256,
                localClusterID: "speaker-1", embedding: QuantizedSpeakerEmbedding(dimensions: 3,
                    values: Data([127,0,1]), scale: 0.5), modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
            let bound = try BoundSpeakerEmbeddingObservation(observation: SpeakerEmbeddingObservation(operationID: .random(),
                canonicalRecordingID: recording.canonicalID, speakerIndex: 99, embedding: evidence.embedding,
                modelID: evidence.modelID, speechDurationMs: 6000, segmentCount: 1), evidence: evidence)
            let selectedStatus = try await service.status(session: session, originRecordingID: origin)
            XCTAssertEqual(selectedStatus.selectedEdgeBundleSHA256, bundle.exactSHA256)
            let canonicalStatus = try await service.status(session: session, canonicalRecordingID: recording.canonicalID)
            XCTAssertEqual(canonicalStatus.selectedEdgeBundleSHA256, bundle.exactSHA256)
            if allowed {
                let result = try await service.submitBoundSpeakerObservation(session: session, observation: bound)
                XCTAssertEqual(result.disposition, SpeakerObservationDisposition.noMatch)
                let review = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
                XCTAssertEqual(review?.evidence, evidence)
                let replay = try await service.submitBoundSpeakerObservation(session: session, observation: bound)
                XCTAssertEqual(replay, result)
                try Data("changed".utf8).write(to: metadataURL)
                do {
                    _ = try await service.status(session: session, originRecordingID: origin)
                    XCTFail("Changed selected bytes must not be advertised as current evidence")
                } catch {}
                do { _ = try await service.submitBoundSpeakerObservation(session: session, observation: bound)
                    XCTFail("Changed selected signature bytes must reject replay") } catch {}
                let changedSource = try SelectedEdgeArtifactSource(signedMetadataURL: metadataURL, bundleURL: bundleURL,
                    signedMetadataSHA256: Data(SHA256.hash(data: Data("changed".utf8))), bundleSHA256: bundle.exactSHA256)
                try await store.applyAcceptedEdgeTranscript(recordingID: id, text: "test", modelID: "engine.v1",
                    structuredTranscriptData: projected.data, clusterMap: projected.clusterMap, artifactSource: changedSource)
                do {
                    _ = try await store.submitSelectedEdgeSpeakerObservation(bound, validatedClusterMap: projected.clusterMap,
                        selectedArtifactSource: source, from: fixture.deviceID)
                    XCTFail("Same bundle cannot conceal changed selected signed metadata")
                } catch StoreError.invalidData(let message) {
                    XCTAssertEqual(message, "Selected signed processing artifact changed before admission")
                }
                do {
                    _ = try await service.submitBoundSpeakerObservation(session: session, observation: bound)
                    XCTFail("Matching stored hashes cannot turn invalid signed metadata into authority")
                } catch {}
                let missingReview = try await store.currentHostSpeakerReview(recordingID: id, speakerIndex: 0)
                XCTAssertNil(missingReview)
            } else {
                do { _ = try await service.submitBoundSpeakerObservation(session: session, observation: bound)
                    XCTFail("Current grant without speaker-write scope must reject") } catch {}
                let retained = try await store.retainedSpeakerEvidence(sha256: evidence.evidenceSHA256)
                XCTAssertNil(retained)
            }
        }
    }
    private func makeBundle(
        artifactID: Data,
        origin: Harc_V1_OriginRecordingIDV1,
        audioSHA256: Data,
        coverage: Harc_V1_ArtifactCoverageV1,
        totalFrames: UInt64 = 4,
        configureTranscript: (inout Harc_V1_TranscriptArtifactV1) -> Void = { _ in }
    ) throws -> HarcProcessingBundleV1 {
        var transcript = Harc_V1_TranscriptArtifactV1()
        transcript.protocol = protocolVersion()
        transcript.locale = "en-US"
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = "test"
        utterance.startFrame = 0
        utterance.endFrameExclusive = totalFrames
        transcript.utterances = [utterance]
        configureTranscript(&transcript)

        var diarization = Harc_V1_DiarizationArtifactV1()
        diarization.protocol = protocolVersion()
        var turn = Harc_V1_SpeakerTurnV1()
        turn.startFrame = 0
        turn.endFrameExclusive = totalFrames
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
            totalCanonicalFrames: totalFrames
        )
    }

    private func coveredRange(totalFrames: UInt64 = 4) -> Harc_V1_ArtifactCoverageV1 {
        var coverage = Harc_V1_ArtifactCoverageV1()
        var range = Harc_V1_CanonicalFrameRangeV1()
        range.startFrame = 0
        range.endFrameExclusive = totalFrames
        coverage.coveredRanges = [range]
        return coverage
    }


    private func protocolVersion() -> Harc_V1_ProtocolVersionV1 {
        var value = Harc_V1_ProtocolVersionV1(); value.major = 1; value.minor = 0; return value
    }
    private func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
}

// Session establishment is outside this service test; unexpected use fails closed.
private struct UnusedSessionBoundary: HostSessionAuthenticationProtocolBoundary {
    func validateProtocolVersion(major: UInt16, minor: UInt16) throws { throw HarcHostError.sessionAdmissionRejected }
    func validateNegotiatedCapabilities(exactBytes: Data, expectedSHA256: Data,
        protocolMajor: UInt16, protocolMinor: UInt16) throws -> HostNegotiatedSessionCapabilities {
        throw HarcHostError.sessionAdmissionRejected
    }
    func validateSessionProof(_ input: HostSessionProofValidationInput) throws { throw HarcHostError.sessionAdmissionRejected }
}
