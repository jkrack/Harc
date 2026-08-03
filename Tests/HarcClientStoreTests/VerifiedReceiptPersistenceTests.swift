import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer
import Testing
@testable import HarcClientStore
@testable import HarcProtocol

@Suite("HarcTransferStore verified receipt deletion gate")
struct VerifiedReceiptPersistenceTests {
    @Test("validated receipt atomically commits durable state and cleanup eligibility")
    func atomicCommitAndExactReplay() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try ClientStoreValidatedEvidenceFixture()
        let masterURL = root.appendingPathComponent("master.wav")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data([0x10, 0x20, 0x30]).write(to: masterURL)
        let store = try preparedReceiptStore(
            root: root,
            evidence: evidence,
            masterURL: masterURL
        )
        let pendingCleanup = try store.requestCleanup(
            for: evidence.origin,
            requestedAt: ClientStoreFixtures.baseDate
        )
        #expect(!pendingCleanup.isEligible)

        let first = try store.persistVerifiedRecordingReceipt(
            authenticated(evidence.receiptEvidence),
            verifiedAt: ClientStoreFixtures.baseDate.addingTimeInterval(20)
        )
        #expect(first.hostTrust == evidence.receiptEvidence.hostTrust)
        #expect(first.exactReceiptObject == evidence.receiptEvidence.exactReceiptObject)
        #expect(first.exactManifestObject == evidence.receiptEvidence.exactManifestObject)
        #expect(first.canonicalPCMSHA256 == evidence.capture.canonicalPCMSHA256)
        #expect(first.totalCanonicalFrames == evidence.capture.totalCanonicalFrames)
        #expect(first.canonicalFormat == evidence.capture.canonicalFormat)
        #expect(first.verifiedAt == ClientStoreFixtures.baseDate.addingTimeInterval(20))

        let committedOutbox = try #require(
            try store.recordingOutbox(for: evidence.origin)
        )
        #expect(committedOutbox.stateMachine.state == .committed)
        #expect(
            committedOutbox.stateMachine.exactReceipt
                == evidence.receiptEvidence.exactReceiptObject
        )
        let committedAttempt = try #require(
            try store.uploadAttempt(id: evidence.attempt.uploadID)
        )
        #expect(committedAttempt.attempt.status == .committed)
        #expect(
            committedAttempt.attempt.exactReceipt
                == evidence.receiptEvidence.exactReceiptObject
        )
        let eligibleCleanup = try #require(
            try store.cleanupIntent(for: evidence.origin)
        )
        #expect(eligibleCleanup.isEligible)
        #expect(
            eligibleCleanup.verifiedReceiptSHA256
                == evidence.receiptEvidence.exactReceiptObject.objectSHA256
        )
        #expect(try Data(contentsOf: masterURL) == Data([0x10, 0x20, 0x30]))

        // A later delivery of the identical validated receipt is a read-only
        // replay: the first verification time and exact bytes remain stable.
        let replay = try store.persistVerifiedRecordingReceipt(
            authenticated(evidence.receiptEvidence),
            verifiedAt: ClientStoreFixtures.baseDate.addingTimeInterval(30)
        )
        #expect(replay == first)

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: evidence.origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        #expect(try reopened.verifiedRecordingReceipt(for: evidence.origin) == first)
        #expect(try reopened.cleanupIntent(for: evidence.origin)?.isEligible == true)
        #expect(try Data(contentsOf: masterURL) == Data([0x10, 0x20, 0x30]))
    }

    @Test("cleanup requested after commit is immediately backed by the verified receipt")
    func cleanupRequestedAfterCommit() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try ClientStoreValidatedEvidenceFixture()
        let store = try preparedReceiptStore(root: root, evidence: evidence)

        _ = try store.persistVerifiedRecordingReceipt(
            authenticated(evidence.receiptEvidence)
        )
        #expect(try store.cleanupIntent(for: evidence.origin) == nil)

        let cleanup = try store.requestCleanup(for: evidence.origin)
        #expect(cleanup.isEligible)
        #expect(
            cleanup.verifiedReceiptSHA256
                == evidence.receiptEvidence.exactReceiptObject.objectSHA256
        )
    }

    @Test("conflicting prior receipt fails closed and retains local bytes")
    func conflictingReceiptFailsClosed() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try ClientStoreValidatedEvidenceFixture()
        let masterURL = root.appendingPathComponent("master.wav")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data([0xAA, 0xBB]).write(to: masterURL)
        let store = try preparedReceiptStore(
            root: root,
            evidence: evidence,
            masterURL: masterURL
        )
        _ = try store.requestCleanup(for: evidence.origin)
        let accepted = try store.persistVerifiedRecordingReceipt(
            authenticated(evidence.receiptEvidence)
        )
        let conflict = try ValidatedRecordingReceiptEvidence(
            hostTrust: evidence.receiptEvidence.hostTrust,
            exactReceiptObject: ClientStoreFixtures.exactObject(
                kind: .recordingReceiptV1,
                byte: 91
            ),
            validatedManifest: evidence.manifestEvidence,
            uploadID: evidence.attempt.uploadID,
            originRecordingID: evidence.origin,
            signedManifestObjectSHA256:
                evidence.manifestEvidence.exactManifestObject.objectSHA256,
            canonicalPCMSHA256: evidence.capture.canonicalPCMSHA256,
            totalCanonicalFrames: evidence.capture.totalCanonicalFrames,
            canonicalFormat: evidence.capture.canonicalFormat,
            canonicalRecordingID: CanonicalRecordingID(
                ClientStoreFixtures.uuid(790)
            ),
            canonicalRevision: .initial,
            changeCursor: ChangeCursor(2),
            receiptID: ClientStoreFixtures.uuid(791),
            durableCommitTime: ClientStoreFixtures.baseDate.addingTimeInterval(11),
            processingState: .pending
        )

        #expect(throws: ClientStoreError.conflictingVerifiedReceipt(
            origin: evidence.origin
        )) {
            try store.persistVerifiedRecordingReceipt(authenticated(conflict))
        }
        #expect(try store.verifiedRecordingReceipt(for: evidence.origin) == accepted)
        #expect(
            try store.exactObject(
                sha256: conflict.exactReceiptObject.objectSHA256
            ) == nil
        )
        #expect(try Data(contentsOf: masterURL) == Data([0xAA, 0xBB]))
        #expect(try store.cleanupIntent(for: evidence.origin)?.isEligible == true)
    }

    @Test("a receipt cannot commit against a different durable capture")
    func canonicalCaptureMismatchRollsBack() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try ClientStoreValidatedEvidenceFixture()
        let store = try preparedReceiptStore(root: root, evidence: evidence)
        _ = try store.requestCleanup(for: evidence.origin)

        let driftedCapture = try FinalizedCapture(
            producingDeviceID: evidence.capture.producingDeviceID,
            originRecordingID: evidence.capture.originRecordingID,
            captureStartedAt: evidence.capture.captureStartedAt,
            captureEndedAt: evidence.capture.captureEndedAt,
            captureStartedMonotonicNanoseconds:
                evidence.capture.captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds:
                evidence.capture.captureEndedMonotonicNanoseconds,
            finalizationReason: evidence.capture.finalizationReason,
            canonicalFormat: evidence.capture.canonicalFormat,
            totalCanonicalFrames: evidence.capture.totalCanonicalFrames,
            totalCanonicalBytes: evidence.capture.totalCanonicalBytes,
            canonicalPCMSHA256: CanonicalPCMHash(
                ClientStoreFixtures.bytes(88)
            ),
            discontinuities: evidence.capture.discontinuities
        )
        try store.database.queue.write { db in
            try db.execute(
                sql: """
                    UPDATE finalized_captures
                    SET finalized_capture_json = ?
                    WHERE origin_device_id = ? AND origin_recording_uuid = ?
                    """,
                arguments: [
                    try ClientStoreCoding.encode(driftedCapture),
                    evidence.origin.deviceID.rawBytes,
                    evidence.origin.recordingUUID.uuidString.lowercased(),
                ]
            )
        }

        #expect(throws: ClientStoreError.verifiedReceiptBindingMismatch(
            field: "canonical audio"
        )) {
            try store.persistVerifiedRecordingReceipt(
                authenticated(evidence.receiptEvidence)
            )
        }
        #expect(try store.verifiedRecordingReceipt(for: evidence.origin) == nil)
        #expect(
            try store.recordingOutbox(for: evidence.origin)?.stateMachine.state
                == .hostCommitPending
        )
        #expect(try store.cleanupIntent(for: evidence.origin)?.isEligible == false)
    }

    @Test("receipt requires a currently authorizing adopted grant")
    func inactiveGrantFailsClosed() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try ClientStoreValidatedEvidenceFixture()
        let store = try preparedReceiptStore(root: root, evidence: evidence)
        let currentGrant = try #require(try store.activeAdoption()?.grant)
        let revokedClaims = try DeviceGrantClaims(
            libraryID: evidence.tuple.libraryID,
            hostAuthorityID: evidence.tuple.hostAuthorityID,
            grantID: currentGrant.grantID,
            devicePublicKey: evidence.producingDevicePublicKey,
            scopes: [.recordingUploadOwn],
            grantEpoch: GrantEpoch(2),
            issuedAt: ClientStoreFixtures.baseDate.addingTimeInterval(1),
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        _ = try store.persistNextVerifiedGrant(
            ValidatedDeviceGrantEvidence(
                hostTrust: evidence.receiptEvidence.hostTrust,
                claims: revokedClaims,
                status: .revoked,
                exactSignedBytes: Data([0x90, 0x91])
            )
        )

        #expect(throws: ClientStoreError.nonauthorizingGrantStatus("revoked")) {
            try store.persistVerifiedRecordingReceipt(
                authenticated(evidence.receiptEvidence)
            )
        }
        #expect(try store.verifiedRecordingReceipt(for: evidence.origin) == nil)
    }

    @Test("cleanup persistence API accepts only sealed protocol evidence")
    func persistenceAPISignatureIsSealed() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try ClientStoreValidatedEvidenceFixture()
        let store = try preparedReceiptStore(root: root, evidence: evidence)

        let persistence: (
            HarcAuthenticatedRecordingReceiptV1,
            Date?
        ) throws -> StoredVerifiedRecordingReceipt =
            store.persistVerifiedRecordingReceipt
        _ = persistence
    }

    private func preparedReceiptStore(
        root: URL,
        evidence: ClientStoreValidatedEvidenceFixture,
        masterURL: URL? = nil
    ) throws -> HarcTransferStore {
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: evidence.origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        _ = try store.adopt(evidence.adoption)
        _ = try store.persistFinalizedCapture(
            evidence.capture,
            masterFileURL: masterURL ?? root.appendingPathComponent("master.wav")
        )
        _ = try store.updateRecordingOutbox(for: evidence.origin) { machine in
            try machine.queue()
            try machine.beginAuthorization()
            try machine.beginActiveUpload()
            try machine.awaitHostCommit()
        }
        var attempt = evidence.attempt
        _ = try attempt.bindFinalManifest(
            using: evidence.manifestEvidence,
            generation: attempt.generation,
            at: attempt.generationBeganAt
        )
        try store.persistUploadAttempt(attempt, for: evidence.tuple)
        return store
    }

    /// Test-only construction is available through `@testable HarcProtocol`;
    /// the initializer is inaccessible to every other production module.
    private func authenticated(
        _ evidence: ValidatedRecordingReceiptEvidence
    ) -> HarcAuthenticatedRecordingReceiptV1 {
        HarcAuthenticatedRecordingReceiptV1(evidence: evidence)
    }
}
