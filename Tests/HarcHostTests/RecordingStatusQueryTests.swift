import CryptoKit
import Darwin
import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcStore
import HarcTransfer
import Testing
@testable import HarcHost

@Suite("Authenticated recording status query", .serialized)
struct RecordingStatusQueryTests {
    private struct StartedUpload {
        let fixture: HostTestFixture
        let directory: URL
        let clock: LockedHostClock
        let store: HarcHostStore
        let context: AuthenticatedDeviceContext
        let uploadID: UploadID
        let origin: OriginRecordingID
        let profile: FrozenUploadProfile
        let descriptor: LogicalChunkDescriptor
        let bytes: Data
    }

    private struct PublicationFixture {
        let started: StartedUpload
        let manifestEvidence: ValidatedRecordingManifestEvidence
        let work: HostCanonicalPublicationWork
        let artifactIdentity: HostCanonicalArtifactIdentity
        let commitResult: HostCanonicalRecordingCommitResult
        let receiptEvidence: ValidatedRecordingReceiptEvidence
    }

    @Test("upload and origin keys resolve only for the authenticated owner")
    func lookupAndAuthorization() async throws {
        let started = try await startUpload()
        defer { try? FileManager.default.removeItem(at: started.directory) }
        let queriedAt = started.fixture.beganAt.addingTimeInterval(2)

        let byUpload = try await started.store.recordingStatus(
            for: .uploadID(started.uploadID),
            context: started.context,
            at: queriedAt
        )
        let byOrigin = try await started.store.recordingStatus(
            for: .originRecordingID(started.origin),
            context: started.context,
            at: queriedAt
        )
        #expect(byUpload == byOrigin)
        #expect(byUpload.ingestState == .receiving)
        #expect(byUpload.canonicalRecordingID == nil)
        #expect(byUpload.processing == nil)

        let otherKey = SoftwareP256SigningKey()
        let otherGrant = try DeviceGrantClaims(
            libraryID: started.fixture.libraryID,
            hostAuthorityID: started.fixture.hostKey.publicKey.hostAuthorityID,
            grantID: .random(),
            deviceID: otherKey.publicKey.deviceID,
            devicePublicKey: otherKey.publicKey,
            scopes: [.recordingUploadOwn],
            grantEpoch: .initial,
            issuedAt: started.fixture.beganAt,
            expiresAt: nil,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        try await started.store.seedDeviceGrantForTesting(
            otherGrant,
            exactGrantBytes: Data("other-status-grant".utf8)
        )
        let otherContext = AuthenticatedDeviceContext(
            libraryID: started.fixture.libraryID,
            hostAuthorityID: started.fixture.hostKey.publicKey.hostAuthorityID,
            authenticatedDeviceID: otherKey.publicKey.deviceID,
            grantID: otherGrant.grantID,
            grantEpoch: otherGrant.grantEpoch
        )
        await #expect(throws: HarcHostError.objectOwnershipMismatch) {
            _ = try await started.store.recordingStatus(
                for: .uploadID(started.uploadID),
                context: otherContext,
                at: queriedAt
            )
        }

        let expired = try await started.store.recordingStatus(
            for: .uploadID(started.uploadID),
            context: started.context,
            at: started.fixture.beganAt.addingTimeInterval(
                TransferLimits.uploadGenerationLifetime + 2
            )
        )
        #expect(expired.ingestState == .expired)
    }

    @Test("journal checkpoints expose only their durable canonical evidence")
    func publicationEvidenceProgression() async throws {
        let fixture = try await preparePublication()
        defer { try? FileManager.default.removeItem(at: fixture.started.directory) }
        let store = fixture.started.store
        let context = fixture.started.context
        let uploadID = fixture.started.uploadID

        let assembling = try await store.recordingStatus(
            for: .uploadID(uploadID),
            context: context,
            at: fixture.started.clock.read()
        )
        #expect(assembling.ingestState == .assembling)
        #expect(assembling.canonicalRecordingID == fixture.work.canonicalRecordingID)
        #expect(assembling.canonicalRecordingRevision == nil)
        #expect(assembling.exactRecordingReceipt == nil)

        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(6)
        )
        try await store.markPublicationCheckpoint(
            uploadID: uploadID,
            expected: [.assembling],
            next: .temporarySynchronized,
            at: fixture.started.clock.read()
        )
        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(7)
        )
        try await store.markPublicationCheckpoint(
            uploadID: uploadID,
            expected: [.temporarySynchronized],
            next: .audioRenamed,
            at: fixture.started.clock.read()
        )
        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(8)
        )
        try await store.persistPublishedCanonicalArtifact(
            uploadID: uploadID,
            identity: fixture.artifactIdentity,
            at: fixture.started.clock.read()
        )
        let published = try await store.recordingStatus(
            for: .originRecordingID(fixture.started.origin),
            context: context,
            at: fixture.started.clock.read()
        )
        #expect(published.ingestState == .audioPublished)
        #expect(published.canonicalRecordingID == fixture.work.canonicalRecordingID)
        #expect(published.canonicalRecordingRevision == nil)

        fixture.started.clock.set(fixture.commitResult.durableCommitTime)
        try await store.persistCanonicalCommitLinkage(
            uploadID: uploadID,
            canonicalRecordingID: fixture.work.canonicalRecordingID,
            publicationRelativePath: fixture.work.publicationRelativePath,
            artifactIdentity: fixture.artifactIdentity,
            result: fixture.commitResult,
            at: fixture.started.clock.read()
        )
        let committed = try await store.recordingStatus(
            for: .uploadID(uploadID),
            context: context,
            at: fixture.started.clock.read()
        )
        #expect(committed.ingestState == .recordingCommitted)
        #expect(committed.canonicalRecordingRevision == .initial)
        #expect(committed.exactRecordingReceipt == nil)

        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(10)
        )
        try await store.persistPreparedPublicationReceipt(
            uploadID: uploadID,
            receiptID: fixture.receiptEvidence.receiptID,
            exactReceipt: fixture.receiptEvidence.exactReceiptObject,
            evidence: fixture.receiptEvidence,
            at: fixture.started.clock.read()
        )
        let prepared = try await store.recordingStatus(
            for: .uploadID(uploadID),
            context: context,
            at: fixture.started.clock.read()
        )
        #expect(prepared.ingestState == .recordingCommitted)
        #expect(prepared.exactRecordingReceipt == nil)

        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(11)
        )
        try await store.markPublicationSidecarSynchronized(
            uploadID: uploadID,
            kind: .manifest,
            at: fixture.started.clock.read()
        )
        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(12)
        )
        try await store.markPublicationSidecarSynchronized(
            uploadID: uploadID,
            kind: .receipt,
            at: fixture.started.clock.read()
        )
        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(13)
        )
        try await store.finalizePreparedPublicationReceipt(
            uploadID: uploadID,
            evidence: fixture.receiptEvidence,
            at: fixture.started.clock.read()
        )
        let receipted = try await store.recordingStatus(
            for: .originRecordingID(fixture.started.origin),
            context: context,
            at: fixture.started.clock.read()
        )
        #expect(receipted.ingestState == .receipted)
        #expect(receipted.canonicalRecordingRevision == .initial)
        #expect(
            receipted.exactRecordingReceipt
                == fixture.receiptEvidence.exactReceiptObject
        )
        #expect(receipted.processing == nil)

        try await store.markPublicationProcessingScheduled(
            uploadID: uploadID,
            at: fixture.started.clock.read().addingTimeInterval(1)
        )
        let processing = try await store.recordingStatus(
            for: .uploadID(uploadID),
            context: context,
            at: fixture.started.clock.read().addingTimeInterval(1)
        )
        #expect(processing.ingestState == .processing)
        #expect(processing.processing == nil)
        #expect(processing.exactRecordingReceipt == receipted.exactRecordingReceipt)
    }

    @Test("receipt hash drift fails closed")
    func receiptDriftFailsClosed() async throws {
        let fixture = try await preparePublication()
        defer { try? FileManager.default.removeItem(at: fixture.started.directory) }
        try await advanceToReceipted(fixture)
        try await fixture.started.store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE publication_journal SET receipt_object_sha256 = ?
                    WHERE upload_id = ?
                    """,
                arguments: [
                    Data(repeating: 0xFF, count: 32),
                    fixture.started.uploadID.description,
                ]
            )
        }

        await #expect(throws: HarcHostError.databaseFailure(
            "Durable recording receipt evidence is inconsistent."
        )) {
            _ = try await fixture.started.store.recordingStatus(
                for: .uploadID(fixture.started.uploadID),
                context: fixture.started.context,
                at: fixture.started.clock.read()
            )
        }
    }

    private func startUpload() async throws -> StartedUpload {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        let clock = LockedHostClock(fixture.beganAt)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("recording-status-grant".utf8)
        )
        let context = fixture.context(for: grant)
        let uploadID = UploadID.random()
        let origin = OriginRecordingID(
            deviceID: fixture.deviceID,
            recordingUUID: UUID()
        )
        let profile = try fixture.profile()
        let bytes = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let descriptor = try fixture.descriptor(origin: origin, bytes: bytes)
        clock.set(fixture.beganAt.addingTimeInterval(1))
        _ = try await store.beginUpload(
            context: context,
            sessionCapabilities: try fixture.sessionCapabilities(for: profile),
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: profile,
                beganAt: clock.read()
            )
        )
        return StartedUpload(
            fixture: fixture,
            directory: directory,
            clock: clock,
            store: store,
            context: context,
            uploadID: uploadID,
            origin: origin,
            profile: profile,
            descriptor: descriptor,
            bytes: bytes
        )
    }

    private func preparePublication() async throws -> PublicationFixture {
        let started = try await startUpload()
        started.clock.set(started.fixture.beganAt.addingTimeInterval(2))
        _ = try await started.store.declareChunks(
            context: started.context,
            uploadID: started.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: started.profile.profileSHA256,
            descriptors: [started.descriptor]
        )
        started.clock.set(started.fixture.beganAt.addingTimeInterval(3))
        _ = try await started.store.stageChunk(
            context: started.context,
            uploadID: started.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: started.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: started.descriptor.chunkID,
            declaredEncodedLength: UInt64(started.bytes.count),
            claimedEncodedSHA256: started.descriptor.encodedSHA256,
            bodyFragments: [started.bytes]
        )
        let digest = Data(SHA256.hash(data: started.bytes))
        let capture = try FinalizedCapture(
            producingDeviceID: started.fixture.deviceID,
            originRecordingID: started.origin,
            captureStartedAt: started.fixture.beganAt,
            captureEndedAt: started.fixture.beganAt.addingTimeInterval(1),
            captureStartedMonotonicNanoseconds: 100,
            captureEndedMonotonicNanoseconds: 200,
            finalizationReason: .userStopped,
            totalCanonicalFrames: UInt64(started.bytes.count / 2),
            totalCanonicalBytes: UInt64(started.bytes.count),
            canonicalPCMSHA256: try CanonicalPCMHash(digest),
            discontinuities: []
        )
        let finalized = try ChunkedFinalizedCapture(
            capture: capture,
            chunks: [started.descriptor]
        )
        let manifestBytes = Data("recording-status-manifest".utf8)
        let manifestObject = try OpaqueExactObjectSlot(
            kind: .recordingManifestV1,
            exactBytes: manifestBytes,
            objectSHA256: ExactObjectSHA256(
                Data(SHA256.hash(data: manifestBytes))
            )
        )
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: started.fixture.libraryID,
            hostAuthorityID: started.fixture.hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: started.fixture.hostKey.publicKey
        )
        let manifestEvidence = try ValidatedRecordingManifestEvidence(
            hostTrust: hostTrust,
            exactManifestObject: manifestObject,
            uploadID: started.uploadID,
            producingDevicePublicKey: started.fixture.deviceKey.publicKey,
            originRecordingID: started.origin,
            uploadProfileSHA256: started.profile.profileSHA256,
            finalizedCapture: finalized
        )
        started.clock.set(started.fixture.beganAt.addingTimeInterval(4))
        _ = try await started.store.bindFinalManifestForPrecommit(
            context: started.context,
            uploadID: started.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: started.profile.profileSHA256,
            evidence: manifestEvidence
        )
        started.clock.set(started.fixture.beganAt.addingTimeInterval(5))
        let preparation = try await started.store.prepareCanonicalPublication(
            context: started.context,
            uploadID: started.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: started.profile.profileSHA256
        )
        guard case .work(let work) = preparation else {
            throw HarcHostError.databaseFailure("Expected fresh publication work.")
        }
        let layout = try HostCanonicalWAVLayout(
            totalFrames: finalized.capture.totalCanonicalFrames
        )
        let identity = try HostCanonicalArtifactIdentity(
            deviceNumber: 1,
            inodeNumber: 2,
            ownerUserID: getuid(),
            posixMode: UInt32(S_IFREG) | 0o600,
            linkCount: 1,
            fileByteCount: layout.fileByteCount,
            changeTimeSeconds: 1,
            changeTimeNanoseconds: 2
        )
        let durableCommitTime = started.fixture.beganAt.addingTimeInterval(9)
        let commit = HostCanonicalRecordingCommitResult(
            canonicalID: work.canonicalRecordingID,
            revision: .initial,
            changeCursor: ChangeCursor(1),
            durableCommitTime: durableCommitTime,
            durableCommitUnixMilliseconds: UInt64(
                durableCommitTime.timeIntervalSince1970 * 1_000
            ),
            replayed: false
        )
        let receiptBytes = Data("recording-status-receipt".utf8)
        let receiptObject = try OpaqueExactObjectSlot(
            kind: .recordingReceiptV1,
            exactBytes: receiptBytes,
            objectSHA256: ExactObjectSHA256(
                Data(SHA256.hash(data: receiptBytes))
            )
        )
        let receiptID = UUID()
        let receiptEvidence = try ValidatedRecordingReceiptEvidence(
            hostTrust: hostTrust,
            exactReceiptObject: receiptObject,
            validatedManifest: manifestEvidence,
            uploadID: started.uploadID,
            originRecordingID: started.origin,
            signedManifestObjectSHA256: manifestObject.objectSHA256,
            canonicalPCMSHA256: finalized.capture.canonicalPCMSHA256,
            totalCanonicalFrames: finalized.capture.totalCanonicalFrames,
            canonicalFormat: finalized.capture.canonicalFormat,
            canonicalRecordingID: work.canonicalRecordingID,
            canonicalRevision: .initial,
            changeCursor: ChangeCursor(1),
            receiptID: receiptID,
            durableCommitTime: durableCommitTime,
            processingState: .pending
        )
        return PublicationFixture(
            started: started,
            manifestEvidence: manifestEvidence,
            work: work,
            artifactIdentity: identity,
            commitResult: commit,
            receiptEvidence: receiptEvidence
        )
    }

    private func advanceToReceipted(_ fixture: PublicationFixture) async throws {
        let store = fixture.started.store
        let uploadID = fixture.started.uploadID
        try await store.markPublicationCheckpoint(
            uploadID: uploadID,
            expected: [.assembling],
            next: .temporarySynchronized,
            at: fixture.started.fixture.beganAt.addingTimeInterval(6)
        )
        try await store.markPublicationCheckpoint(
            uploadID: uploadID,
            expected: [.temporarySynchronized],
            next: .audioRenamed,
            at: fixture.started.fixture.beganAt.addingTimeInterval(7)
        )
        try await store.persistPublishedCanonicalArtifact(
            uploadID: uploadID,
            identity: fixture.artifactIdentity,
            at: fixture.started.fixture.beganAt.addingTimeInterval(8)
        )
        try await store.persistCanonicalCommitLinkage(
            uploadID: uploadID,
            canonicalRecordingID: fixture.work.canonicalRecordingID,
            publicationRelativePath: fixture.work.publicationRelativePath,
            artifactIdentity: fixture.artifactIdentity,
            result: fixture.commitResult,
            at: fixture.commitResult.durableCommitTime
        )
        try await store.persistPreparedPublicationReceipt(
            uploadID: uploadID,
            receiptID: fixture.receiptEvidence.receiptID,
            exactReceipt: fixture.receiptEvidence.exactReceiptObject,
            evidence: fixture.receiptEvidence,
            at: fixture.started.fixture.beganAt.addingTimeInterval(10)
        )
        try await store.markPublicationSidecarSynchronized(
            uploadID: uploadID,
            kind: .manifest,
            at: fixture.started.fixture.beganAt.addingTimeInterval(11)
        )
        try await store.markPublicationSidecarSynchronized(
            uploadID: uploadID,
            kind: .receipt,
            at: fixture.started.fixture.beganAt.addingTimeInterval(12)
        )
        fixture.started.clock.set(
            fixture.started.fixture.beganAt.addingTimeInterval(13)
        )
        try await store.finalizePreparedPublicationReceipt(
            uploadID: uploadID,
            evidence: fixture.receiptEvidence,
            at: fixture.started.clock.read()
        )
    }
}
