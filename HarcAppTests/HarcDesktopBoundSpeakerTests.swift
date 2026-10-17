import CryptoKit
import Foundation
import HarcClient
import HarcClientStore
import HarcCore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Testing
@testable import Harc

@Suite("Desktop exact bound speaker batch")
struct HarcDesktopBoundSpeakerTests {
    @Test func signedBundleAndSidecarMustAgreeBeforeAnyBoundBatchIsReturned() throws {
        let producer = SoftwareP256SigningKey(), host = SoftwareP256SigningKey()
        let trust = AdoptedTrustTuple(libraryID: .random(), hostAuthorityID: host.publicKey.hostAuthorityID)
        let origin = OriginRecordingID(deviceID: producer.publicKey.deviceID, recordingUUID: UUID())
        let canonical = CanonicalRecordingID.random()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let capture = try FinalizedCapture(producingDeviceID: origin.deviceID, originRecordingID: origin,
            captureStartedAt: now, captureEndedAt: now.addingTimeInterval(1), captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: 1_000_000_000, finalizationReason: .userStopped,
            totalCanonicalFrames: 16_000, totalCanonicalBytes: 32_000,
            canonicalPCMSHA256: CanonicalPCMHash(Data(repeating: 1, count: 32)), discontinuities: [])
        let transcript = SessionTranscript(startedAt: now, endedAt: now.addingTimeInterval(1), audioPath: "/tmp/fixture.wav",
            joinedText: "voice", words: [], speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)], chunks: [])
        func sidecar(_ rows: [SpeakerEmbeddingRow]) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(HarcDesktopClientCaptureSidecar(capture: capture, transcript: transcript,
                speakerEmbeddings: rows, persistedAt: now))
        }
        let row = SpeakerEmbeddingRow(speakerIndex: 0, vector: [1,0], totalMs: 1000, segmentCount: 1)
        let data = try sidecar([row])
        func submission(_ bytes: Data) throws -> HarcDesktopProcessingSubmission {
            try signedSubmission(sidecar: bytes, transcript: transcript, capture: capture, producer: producer, trust: trust)
        }
        func build(_ submission: HarcDesktopProcessingSubmission, _ bytes: Data,
                   key: P256X963PublicKey? = nil, expectedTrust: AdoptedTrustTuple? = nil) throws -> [BoundSpeakerEmbeddingObservation] {
            try HarcDesktopProcessingArtifactBuilder.boundSpeakerObservations(submission: submission,
                sidecarData: bytes, origin: origin, canonicalID: canonical,
                producerPublicKey: key ?? producer.publicKey, hostTrust: expectedTrust ?? trust, pack: nil)
        }
        let selected = try submission(data)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let cachedURL = root.appendingPathComponent("submission.json")
        let cachedBytes = try JSONEncoder().encode(selected)
        try cachedBytes.write(to: cachedURL)
        let expiry = Date(timeIntervalSince1970: 1_800_000_005)
        func reusable(_ at: Date, key: P256X963PublicKey? = nil) throws -> HarcDesktopProcessingSubmission? {
            try HarcDesktopProcessingArtifactBuilder.reusableSubmission(at: cachedURL,
                sidecarSHA256: Data(SHA256.hash(data: data)), producerPublicKey: key ?? producer.publicKey, now: at)
        }
        #expect(try reusable(expiry.addingTimeInterval(-0.001))?.exactSignedMetadata == selected.exactSignedMetadata)
        #expect(throws: (any Error).self) { try reusable(expiry, key: host.publicKey) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        #expect(try reusable(expiry) == nil)
        let archived = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("submission.json.expired-") }
        #expect(archived.count == 1)
        #expect(try Data(contentsOf: archived[0]) == cachedBytes)
        #expect(try Data(contentsOf: cachedURL) == cachedBytes)
        // Interrupted after archiving but before replacement: retry preserves both
        // exact copies, repeats synchronization and still requires a new command.
        #expect(try reusable(expiry.addingTimeInterval(60)) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
        try Data([0]).write(to: archived[0])
        #expect(throws: (any Error).self) { try reusable(expiry) }
        #expect(try Data(contentsOf: cachedURL) == cachedBytes)
        try cachedBytes.write(to: archived[0])
        let corrupt = HarcDesktopProcessingSubmission(exactSignedMetadata: selected.exactSignedMetadata,
            exactBundle: selected.exactBundle + Data([0]), sidecarSHA256: selected.sidecarSHA256)
        try JSONEncoder().encode(corrupt).write(to: cachedURL)
        #expect(throws: (any Error).self) { try reusable(expiry) }
        try cachedBytes.write(to: cachedURL)
        var status = Harc_V1_ProcessingStatusV1()
        status.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(canonical)
        status.originRecordingID = Harc_V1_OriginRecordingIDV1(origin)
        status.canonicalAudioSha256.value = capture.canonicalPCMSHA256.rawBytes
        status.selectedEdgeBundleSha256.value = Data(SHA256.hash(data: selected.exactBundle))
        func validateStatus(_ value: Harc_V1_ProcessingStatusV1) throws {
            try HarcDesktopProcessingArtifactBuilder.validateSelectedArtifactStatus(value,
                submission: selected, origin: origin, canonicalID: canonical,
                canonicalPCMHash: capture.canonicalPCMSHA256)
        }
        try validateStatus(status)
        var absent = status; absent.clearSelectedEdgeBundleSha256()
        #expect(throws: (any Error).self) { try validateStatus(absent) }
        var changedSelection = status; changedSelection.selectedEdgeBundleSha256.value = Data(repeating: 8, count: 32)
        #expect(throws: (any Error).self) { try validateStatus(changedSelection) }
        var wrongRecording = status; wrongRecording.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(.random())
        #expect(throws: (any Error).self) { try validateStatus(wrongRecording) }
        var wrongAudio = status; wrongAudio.canonicalAudioSha256.value = Data(repeating: 8, count: 32)
        #expect(throws: (any Error).self) { try validateStatus(wrongAudio) }
        let marker = HarcDesktopSpeakerObservationMarker(canonicalRecordingID: canonical,
            sourcePackRevision: nil, decisions: nil, acceptedAt: now,
            processingArtifactSHA256: status.selectedEdgeBundleSha256.value)
        #expect(marker.matchesSelectedArtifact(status.selectedEdgeBundleSha256.value))
        #expect(!marker.matchesSelectedArtifact(nil))
        #expect(!marker.matchesSelectedArtifact(Data([1])))
        #expect(!marker.matchesSelectedArtifact(changedSelection.selectedEdgeBundleSha256.value))
        let reopenedMarker = try JSONDecoder().decode(HarcDesktopSpeakerObservationMarker.self,
            from: JSONEncoder().encode(marker))
        #expect(reopenedMarker.matchesSelectedArtifact(status.selectedEdgeBundleSha256.value))
        let first = try build(selected, data)
        #expect(first.count == 1)
        let faultURL = root.appendingPathComponent("speaker-batch-barrier.json")
        let faultHost = HarcDesktopHostEvidenceBinding(trust: trust)
        let faultDigest = Data(SHA256.hash(data: data))
        var failedBarriers = 0
        func failBarrier(_ url: URL) throws {
            #expect(url == faultURL)
            failedBarriers += 1
            throw CocoaError(.fileWriteUnknown)
        }
        // First publication may leave exact bytes, but no usable batch escapes
        // until all barriers succeed. Existence must not bypass a repeated failure.
        for _ in 0..<2 {
            #expect(throws: (any Error).self) {
                try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: faultURL,
                    proposed: first, host: faultHost, sidecarSHA256: faultDigest, now: now,
                    synchronize: failBarrier)
            }
        }
        #expect(failedBarriers == 2)
        let pendingBytes = try Data(contentsOf: faultURL)
        var faultBatch = try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: faultURL,
            proposed: first, host: faultHost, sidecarSHA256: faultDigest, now: now)
        #expect(faultBatch.observations == first)
        #expect(faultBatch.completedAt == nil)
        #expect(try Data(contentsOf: faultURL) == pendingBytes)
        faultBatch.completedAt = now
        #expect(throws: (any Error).self) { try faultBatch.persist(to: faultURL, synchronize: failBarrier) }
        let completedBytes = try Data(contentsOf: faultURL)
        #expect(throws: (any Error).self) {
            try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: faultURL,
                proposed: first, host: faultHost, sidecarSHA256: faultDigest, now: now,
                synchronize: failBarrier)
        }
        #expect(failedBarriers == 4)
        let completedAfterBarrierRetry = try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: faultURL,
            proposed: first, host: faultHost, sidecarSHA256: faultDigest, now: now)
        #expect(completedAfterBarrierRetry.completedAt == now)
        #expect(completedAfterBarrierRetry.observations == first)
        #expect(try Data(contentsOf: faultURL) == completedBytes)
        let journalURL = root.appendingPathComponent("speaker-batch.json")
        let journalHost = HarcDesktopHostEvidenceBinding(trust: trust)
        let sidecarDigest = Data(SHA256.hash(data: data))
        var journal = try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: journalURL,
            proposed: first, host: journalHost, sidecarSHA256: sidecarDigest, now: now)
        let changedPackObservation = try SpeakerEmbeddingObservation(operationID: .random(),
            canonicalRecordingID: canonical, speakerIndex: first[0].observation.speakerIndex,
            embedding: first[0].evidence.embedding, modelID: first[0].evidence.modelID,
            speechDurationMs: first[0].evidence.speechDurationMs, segmentCount: first[0].evidence.segmentCount,
            sourcePackRevision: EntityRevision(2))
        let changedPack = [try BoundSpeakerEmbeddingObservation(observation: changedPackObservation, evidence: first[0].evidence)]
        let late = now.addingTimeInterval(7 * 60 * 60)
        let pendingRetry = try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: journalURL,
            proposed: changedPack, host: journalHost, sidecarSHA256: sidecarDigest, now: late)
        #expect(pendingRetry.observations == first)
        #expect(pendingRetry.completedAt == nil)
        journal.completedAt = late
        try journal.persist(to: journalURL)
        let completedReplay = try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: journalURL,
            proposed: changedPack, host: journalHost, sidecarSHA256: sidecarDigest, now: late.addingTimeInterval(1))
        #expect(completedReplay.observations == first)
        let reviewed = try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: journalURL,
            proposed: changedPack, host: journalHost, sidecarSHA256: sidecarDigest, now: late.addingTimeInterval(6 * 60 * 60))
        #expect(reviewed.observations == changedPack)
        #expect(reviewed.completedAt == nil)
        #expect(throws: (any Error).self) {
            try HarcDesktopProcessingArtifactBuilder.durableSpeakerBatch(at: journalURL,
                proposed: changedPack, host: journalHost, sidecarSHA256: Data(repeating: 9, count: 32), now: late)
        }
        #expect(first[0].evidence.localClusterID == "speaker-0")
        #expect(first[0].evidence.speechDurationMs == 1000)
        #expect(first[0].evidence.processingArtifactSHA256 == Data(SHA256.hash(data: selected.exactBundle)))
        #expect(try build(selected, data) == first)
        let replacement = try build(submission(data), data)
        #expect(replacement[0].observation.operationID != first[0].observation.operationID)
        #expect(throws: (any Error).self) { try build(selected, data + Data(" ".utf8)) }
        #expect(throws: (any Error).self) { try build(selected, data, key: host.publicKey) }
        #expect(throws: (any Error).self) {
            try build(selected, data, expectedTrust: AdoptedTrustTuple(libraryID: .random(), hostAuthorityID: trust.hostAuthorityID))
        }
        let changed = HarcDesktopProcessingSubmission(exactSignedMetadata: selected.exactSignedMetadata,
            exactBundle: selected.exactBundle + Data([0]), sidecarSHA256: selected.sidecarSHA256)
        #expect(throws: (any Error).self) { try build(changed, data) }
        let legacy = HarcDesktopProcessingSubmission(exactSignedMetadata: selected.exactSignedMetadata, exactBundle: selected.exactBundle)
        #expect(throws: (any Error).self) { try build(legacy, data) }
        for invalid in [
            SpeakerEmbeddingRow(speakerIndex: 1, vector: [1,0], totalMs: 1000, segmentCount: 1),
            SpeakerEmbeddingRow(speakerIndex: 0, vector: [1,0], totalMs: 1001, segmentCount: 1),
            SpeakerEmbeddingRow(speakerIndex: 0, vector: [0,0], totalMs: 1000, segmentCount: 1)
        ] {
            let invalidData = try sidecar([invalid])
            #expect(throws: (any Error).self) { try build(submission(invalidData), invalidData) }
        }
        var overlapTranscript = transcript
        overlapTranscript.overlapRanges = [try SpeechOverlapRange(startMs: 200, endMs: 400)]
        let overlapData = try JSONEncoder().encode(HarcDesktopClientCaptureSidecar(capture: capture,
            transcript: overlapTranscript, speakerEmbeddings: [row], persistedAt: now))
        let overlapSubmission = try signedSubmission(sidecar: overlapData, transcript: overlapTranscript,
            capture: capture, producer: producer, trust: trust)
        #expect(throws: (any Error).self) { try build(overlapSubmission, overlapData) }
        let wrongCapture = try FinalizedCapture(producingDeviceID: origin.deviceID, originRecordingID: origin,
            captureStartedAt: now, captureEndedAt: now.addingTimeInterval(1), captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: 1_000_000_000, finalizationReason: .userStopped,
            totalCanonicalFrames: 16_000, totalCanonicalBytes: 32_000,
            canonicalPCMSHA256: CanonicalPCMHash(Data(repeating: 9, count: 32)), discontinuities: [])
        let emptyWrongAudio = try JSONEncoder().encode(HarcDesktopClientCaptureSidecar(capture: wrongCapture,
            transcript: transcript, speakerEmbeddings: [], persistedAt: now))
        #expect(throws: (any Error).self) { try build(submission(emptyWrongAudio), emptyWrongAudio) }
        let mixed = try sidecar([row, SpeakerEmbeddingRow(speakerIndex: 1, vector: [1,0], totalMs: 1000, segmentCount: 1)])
        #expect(throws: (any Error).self) { try build(submission(mixed), mixed) }
    }

    private func signedSubmission(sidecar: Data, transcript: SessionTranscript, capture: FinalizedCapture,
        producer: SoftwareP256SigningKey, trust: AdoptedTrustTuple) throws -> HarcDesktopProcessingSubmission {
        let artifactID = UUID(), operationID = UUID(), grantID = UUID()
        var coverage = Harc_V1_ArtifactCoverageV1()
        var range = Harc_V1_CanonicalFrameRangeV1(); range.endFrameExclusive = capture.totalCanonicalFrames
        coverage.coveredRanges = [range]
        let bundle = try HarcDesktopProcessingArtifactBuilder.processingBundle(transcript: transcript,
            totalFrames: capture.totalCanonicalFrames, coverage: coverage, artifactID: artifactID,
            origin: capture.originRecordingID, audioHash: capture.canonicalPCMSHA256.rawBytes)
        let issued: UInt64 = 1_800_000_000_000
        var metadata = Harc_V1_ProcessingArtifactV1()
        metadata.protocol = HarcProtocolVersion.v1.protobufV1()
        metadata.libraryID = Harc_V1_LibraryIDV1(trust.libraryID)
        metadata.hostAuthorityID = Harc_V1_HostAuthorityIDV1(trust.hostAuthorityID)
        metadata.artifactID.value = uuidBytes(artifactID)
        metadata.originRecordingID = Harc_V1_OriginRecordingIDV1(capture.originRecordingID)
        metadata.canonicalAudioSha256.value = capture.canonicalPCMSHA256.rawBytes
        metadata.producingDeviceID = Harc_V1_DeviceIDV1(producer.publicKey.deviceID)
        metadata.grantID.value = uuidBytes(grantID); metadata.grantEpoch = 1
        metadata.operationID.value = uuidBytes(operationID)
        metadata.issuedAtUnixMs = issued; metadata.submissionExpiresAtUnixMs = issued + 5000
        metadata.engineRevision = "engine.v1"; metadata.buildRevision = "build.v1"
        metadata.diarizationRevision = "diarization.v1"; metadata.vadRevision = "vad.v1"
        metadata.vocabularyRevision = "vocabulary.v1"; metadata.promptRevision = "prompt.v1"
        metadata.wordTimingSchemaID = "harc.word-timing.v1"; metadata.coverage = coverage
        metadata.exactBundleByteLength = UInt64(bundle.exactBytes.count); metadata.exactBundleSha256.value = bundle.exactSHA256
        let payload = try metadata.serializedData()
        let header = try HarcSignedEnvelopeV1(messageType: .processingArtifact, libraryID: trust.libraryID,
            hostAuthorityID: trust.hostAuthorityID, signerDeviceID: producer.publicKey.deviceID,
            grantID: grantID, grantEpoch: 1, operationID: operationID, issuedAtUnixMilliseconds: issued,
            expiresAtUnixMilliseconds: issued + 5000, payloadType: .processingArtifact,
            expectedRevision: nil, payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload))
        let signed = try HarcSignedObjectV1.sign(header: header, exactPayloadBytes: payload, using: producer)
        return HarcDesktopProcessingSubmission(exactSignedMetadata: signed.exactFramedBytes,
            exactBundle: bundle.exactBytes, sidecarSHA256: Data(SHA256.hash(data: sidecar)))
    }
    private func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
}
