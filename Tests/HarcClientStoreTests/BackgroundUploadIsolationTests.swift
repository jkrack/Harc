import Foundation
import GRDB
import HarcDomain
import HarcTransfer
import Testing
@testable import HarcClientStore

@Suite("Background upload task isolation")
struct BackgroundUploadIsolationTests {
    @Test("late old-task failure cannot security-block replacement work", arguments: [false, true])
    func staleFailureAfterCapabilityRefresh(refreshCredential: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let batch = try fixture.stage(seed: 1)
        let old = try SystemBackgroundTaskIdentity(taskIdentifier: 801)
        try fixture.store.persistTaskMappingBeforeResume(old, batchID: batch.batchID)
        try fixture.store.persistBackgroundTaskFailure(old, batchID: batch.batchID, disposition: .failedRecoverable)
        let replacement = try fixture.capability(seed: refreshCredential ? 2 : 1)
        try fixture.store.persistBackgroundBatchForScheduling(
            batch, bodyFileURL: fixture.bodyURL(batch), capability: replacement
        )
        _ = try fixture.store.updateRecordingOutbox(for: batch.originRecordingID) {
            try $0.retryRecoverable(); try $0.beginAuthorization(); try $0.beginActiveUpload()
        }
        let current = try SystemBackgroundTaskIdentity(taskIdentifier: 802)
        try fixture.store.persistTaskMappingBeforeResume(current, batchID: batch.batchID)
        try fixture.store.persistBackgroundTaskFailure(old, batchID: batch.batchID, disposition: .securityBlocked)
        #expect(try fixture.store.backgroundBatch(id: batch.batchID)?.state == .scheduled)
        #expect(try fixture.store.backgroundBatch(id: batch.batchID)?.capability == replacement)
        #expect(try fixture.store.recordingOutbox(for: batch.originRecordingID)?.stateMachine.state == .activeUpload)
        #expect(try fixture.store.taskMappings().first { $0.identity == current }?.state == .persistedBeforeResume)
        let reconciled = try fixture.store.reconcileBackgroundTasks(observedSystemTasks: [current])
        #expect(reconciled.matchedTasks == [current])
        #expect(reconciled.batchesToReschedule.isEmpty)
        #expect(try fixture.store.recordingOutbox(for: batch.originRecordingID)?.stateMachine.state == .activeUpload)
        #expect(try Data(contentsOf: fixture.masterURL(batch.originRecordingID)) == fixture.masterBytes)
        #expect(try fixture.store.cleanupIntent(for: batch.originRecordingID) == nil)
    }

    @Test("forgotten Host work cannot abort reconciliation for the newly adopted Host")
    func forgottenHostDoesNotAbortCurrentHostReconciliation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldBatch = try fixture.stage(seed: 1)
        let old = try SystemBackgroundTaskIdentity(taskIdentifier: 811)
        try fixture.store.persistTaskMappingBeforeResume(old, batchID: oldBatch.batchID)
        #expect(try fixture.store.forgetActiveHost())
        try fixture.adopt(library: 2, key: 2)
        let currentBatch = try fixture.stage(seed: 2, library: 2, key: 2)
        let current = try SystemBackgroundTaskIdentity(taskIdentifier: 812)
        try fixture.store.persistTaskMappingBeforeResume(current, batchID: currentBatch.batchID)
        let snapshot = try fixture.store.backgroundTaskMappingsForTransport()
        #expect(snapshot.first { $0.identity == old }?.state == .retired)
        #expect(snapshot.first { $0.identity == current }?.state.isActive == true)
        let result = try fixture.store.reconcileBackgroundTasks(observedSystemTasks: [old, current])
        #expect(result.matchedTasks == [current])
        #expect(result.orphanedSystemTasks == [old])
        #expect(result.batchesToReschedule.isEmpty)
        #expect(try fixture.store.activeAdoption()?.tuple == ClientStoreFixtures.tuple(library: 2, authorityByte: 2))
        #expect(try fixture.store.taskMappings().first { $0.identity == old }?.state.rawValue == "retired")
        #expect(try fixture.store.reconcileBackgroundTasks(observedSystemTasks: []).batchesToReschedule == [currentBatch.batchID])
        #expect(try Data(contentsOf: fixture.masterURL(oldBatch.originRecordingID)) == fixture.masterBytes)
        #expect(try fixture.store.cleanupIntent(for: oldBatch.originRecordingID) == nil)
    }

    @Test("revoked-grant tasks are quarantined without reviving authorization")
    func revokedGrantRemainsRevoked() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let batch = try fixture.stage(seed: 1)
        let task = try SystemBackgroundTaskIdentity(taskIdentifier: 821)
        try fixture.store.persistTaskMappingBeforeResume(task, batchID: batch.batchID)
        let adoption = try #require(try fixture.store.activeAdoption())
        _ = try fixture.store.persistNextVerifiedGrant(ClientStoreFixtures.grantEvidence(
            tuple: adoption.tuple, keyByte: 1, grantID: adoption.grant.grantID,
            registryEpoch: 2, status: .revoked, exactSignedBytes: Data([7, 8])
        ))
        let result = try fixture.store.reconcileBackgroundTasks(observedSystemTasks: [task])
        #expect(result.matchedTasks.isEmpty)
        #expect(result.batchesToReschedule.isEmpty)
        #expect(result.orphanedSystemTasks == [task])
        #expect(try fixture.store.activeAdoption()?.grant.status == .revoked)
        #expect(throws: ClientStoreError.self) {
            try fixture.store.persistTaskMappingBeforeResume(
                SystemBackgroundTaskIdentity(taskIdentifier: 822), batchID: batch.batchID
            )
        }
        #expect(try Data(contentsOf: fixture.masterURL(batch.originRecordingID)) == fixture.masterBytes)
        #expect(try fixture.store.cleanupIntent(for: batch.originRecordingID) == nil)
    }

    @Test("corrupt database facts still surface and roll back reconciliation")
    func corruptBatchStillFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let batch = try fixture.stage(seed: 1)
        let task = try SystemBackgroundTaskIdentity(taskIdentifier: 831)
        try fixture.store.persistTaskMappingBeforeResume(task, batchID: batch.batchID)
        try fixture.store.database.queue.write { db in
            try db.execute(sql: "UPDATE upload_batches SET descriptor_json = ? WHERE batch_id = ?",
                           arguments: [Data([0]), batch.batchID.description])
        }
        #expect(throws: (any Error).self) {
            try fixture.store.reconcileBackgroundTasks(observedSystemTasks: [task])
        }
        #expect(try fixture.store.taskMappings().first?.state == .persistedBeforeResume)
        #expect(try Data(contentsOf: fixture.masterURL(batch.originRecordingID)) == fixture.masterBytes)
    }

    private struct Fixture {
        let root: URL
        let store: HarcTransferStore
        let masterBytes = Data("synthetic-local-master".utf8)
        init() throws {
            root = temporaryClientStoreDirectory()
            store = try HarcTransferStore(
                rootDirectory: root, installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: RecordingStorageAttributes()
            )
            try adopt(library: 1, key: 1)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func adopt(library: UInt32, key: UInt8) throws {
            _ = try store.adopt(ClientStoreFixtures.adoption(
                tuple: ClientStoreFixtures.tuple(library: library, authorityByte: key),
                keyByte: key, transportEpoch: 1, transportByte: key, grantEpoch: 1, grantByte: key
            ))
        }
        func capability(seed: UInt8) throws -> OpaqueBackgroundCapability {
            try OpaqueBackgroundCapability(
                credential: Data([seed]), capabilityBindings: Data([seed, 9]),
                expiresAt: ClientStoreFixtures.baseDate.addingTimeInterval(600)
            )
        }
        func masterURL(_ origin: OriginRecordingID) -> URL {
            root.appendingPathComponent("\(origin.recordingUUID).wav")
        }
        func bodyURL(_ batch: ImmutableAudioBatchDescriptor) -> URL {
            root.appendingPathComponent("\(batch.batchID).harcab1")
        }
        func stage(seed: UInt32, library: UInt32 = 1, key: UInt8 = 1) throws -> ImmutableAudioBatchDescriptor {
            let origin = ClientStoreFixtures.origin(recording: seed)
            try masterBytes.write(to: masterURL(origin))
            _ = try store.persistFinalizedCapture(ClientStoreFixtures.capture(origin: origin), masterFileURL: masterURL(origin))
            _ = try store.updateRecordingOutbox(for: origin) {
                try $0.queue(); try $0.beginAuthorization(); try $0.beginActiveUpload()
            }
            let prototype = ClientStoreFixtures.chunk(origin: origin)
            let chunk = try LogicalChunkDescriptor(
                originRecordingID: origin, chunkID: ChunkID(ClientStoreFixtures.uuid(9000 + seed)),
                chunkIndex: 0, canonicalStartFrame: 0, canonicalFrameCount: prototype.canonicalFrameCount,
                encoding: prototype.encoding, encodedByteLength: prototype.encodedByteLength,
                encodedSHA256: prototype.encodedSHA256, canonicalDecodedByteLength: prototype.canonicalDecodedByteLength,
                canonicalDecodedSHA256: prototype.canonicalDecodedSHA256
            )
            var attempt = try UploadAttempt(
                uploadID: UploadID(ClientStoreFixtures.uuid(8000 + seed)), ownerDeviceID: origin.deviceID,
                originRecordingID: origin, frozenProfile: ClientStoreFixtures.profile(), beganAt: ClientStoreFixtures.baseDate
            )
            try attempt.declare([chunk], generation: .initial, at: ClientStoreFixtures.baseDate)
            try store.persistUploadAttempt(attempt, for: ClientStoreFixtures.tuple(library: library, authorityByte: key))
            let batch = try ImmutableAudioBatchDescriptor(
                batchID: AudioBatchID(ClientStoreFixtures.uuid(7000 + seed)), uploadID: attempt.uploadID,
                generation: .initial, uploadProfileSHA256: attempt.frozenProfile.profileSHA256,
                originRecordingID: origin, ownerDeviceID: origin.deviceID, chunks: [chunk],
                exactBodyByteLength: 1200, exactBodySHA256: ImmutableBatchSHA256(ClientStoreFixtures.bytes(14))
            )
            try store.persistBackgroundBatch(batch, bodyFileURL: bodyURL(batch), capability: capability(seed: 1))
            return batch
        }
    }
}
