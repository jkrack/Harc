import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcProtocol
import HarcTransfer
import Testing
@testable import HarcClientStore

@Suite("Background ACK transaction recovery")
struct BackgroundACKAtomicityTests {
    enum FailurePoint: CaseIterable, Sendable {
        case secondChunk, batchCompletion, taskCompletion

        var triggerSQL: String {
            let target: String
            let condition: String
            switch self {
            case .secondChunk:
                target = "upload_chunks"
                condition = "NEW.chunk_index = 1 AND NEW.outbox_state = 'durableAtHost'"
            case .batchCompletion:
                target = "upload_batches"
                condition = "NEW.state = 'completed'"
            case .taskCompletion:
                target = "background_task_mappings"
                condition = "NEW.state = 'completed'"
            }
            return """
                CREATE TRIGGER inject_background_ack_failure
                BEFORE UPDATE ON \(target) WHEN \(condition)
                BEGIN SELECT RAISE(ABORT, 'injected background ACK write failure'); END
                """
        }
    }

    @Test("late ACK writes roll back completely across reopen and remain retryable",
          arguments: FailurePoint.allCases)
    func lateACKFailureRollsBack(point: FailurePoint) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.openStore()
        try fixture.prepare(in: store)
        let batchBefore = try #require(try store.backgroundBatch(id: fixture.batch.batchID))
        let chunksBefore = try store.chunks(uploadID: fixture.attempt.uploadID)
        let mappingsBefore = try store.taskMappings()
        let outboxBefore = try #require(try store.recordingOutbox(for: fixture.origin))
        let cleanupBefore = try #require(try store.cleanupIntent(for: fixture.origin))
        #expect(!cleanupBefore.isEligible)
        try store.database.queue.write { db in try db.execute(sql: point.triggerSQL) }

        do {
            try store.persistVerifiedBatchACK(fixture.acknowledgement)
            Issue.record("Expected the injected late write failure")
        } catch let error as DatabaseError {
            #expect(error.message == "injected background ACK write failure")
        }

        func expectRolledBack(_ reader: HarcTransferStore) throws {
            #expect(try reader.backgroundBatch(id: fixture.batch.batchID) == batchBefore)
            #expect(try reader.chunks(uploadID: fixture.attempt.uploadID) == chunksBefore)
            #expect(try reader.taskMappings() == mappingsBefore)
            #expect(try reader.recordingOutbox(for: fixture.origin) == outboxBefore)
            #expect(try reader.cleanupIntent(for: fixture.origin) == cleanupBefore)
            #expect(try reader.verifiedRecordingReceipt(for: fixture.origin) == nil)
            #expect(try reader.exactObject(sha256: fixture.acknowledgement.exactAcknowledgementObject.objectSHA256) == nil)
            try fixture.expectFilesUnchanged()
        }
        try expectRolledBack(store)
        let reopened = try fixture.openStore()
        try expectRolledBack(reopened)

        // Remove only the test-created failure; never rewrite transfer data.
        try reopened.database.queue.write { db in
            try db.execute(sql: "DROP TRIGGER inject_background_ack_failure")
        }
        try reopened.persistVerifiedBatchACK(fixture.acknowledgement)
        let final = try fixture.openStore()
        #expect(try final.backgroundBatch(id: fixture.batch.batchID)?.durableACK == fixture.acknowledgement.exactAcknowledgementObject)
        #expect(try final.backgroundBatch(id: fixture.batch.batchID)?.state == .completed)
        #expect(try final.chunks(uploadID: fixture.attempt.uploadID).allSatisfy {
            $0.stateMachine.state == .durableAtHost && $0.durableACK == fixture.acknowledgement.exactAcknowledgementObject
        })
        #expect(try final.taskMappings().map(\.state) == [.completed])
        // An authenticated staging ACK is still not a recording safety receipt.
        #expect(try final.recordingOutbox(for: fixture.origin) == outboxBefore)
        #expect(try final.cleanupIntent(for: fixture.origin) == cleanupBefore)
        #expect(try final.verifiedRecordingReceipt(for: fixture.origin) == nil)
        try fixture.expectFilesUnchanged()
        let completedBatch = try final.backgroundBatch(id: fixture.batch.batchID)
        let completedChunks = try final.chunks(uploadID: fixture.attempt.uploadID)
        let completedMappings = try final.taskMappings()
        try final.persistVerifiedBatchACK(fixture.acknowledgement)
        #expect(try final.backgroundBatch(id: fixture.batch.batchID) == completedBatch)
        #expect(try final.chunks(uploadID: fixture.attempt.uploadID) == completedChunks)
        #expect(try final.taskMappings() == completedMappings)
    }

    private struct Fixture {
        let root = temporaryClientStoreDirectory()
        let origin = ClientStoreFixtures.origin()
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let chunks: [LogicalChunkDescriptor]
        let attempt: UploadAttempt
        let batch: ImmutableAudioBatchDescriptor
        let acknowledgement: ValidatedBatchAcknowledgementEvidence
        let masterBytes = Data(repeating: 0x21, count: 4_000)
        let encodedBytes = [Data(repeating: 0x31, count: 1_000), Data(repeating: 0x32, count: 1_000)]
        let bodyBytes = Data(repeating: 0x42, count: 2_400)

        init() throws {
            let chunkOrigin = origin
            let encoded = encodedBytes
            chunks = try (0..<2).map { index in
                try LogicalChunkDescriptor(
                    originRecordingID: chunkOrigin, chunkID: ChunkID(ClientStoreFixtures.uuid(200 + UInt32(index))),
                    chunkIndex: UInt32(index), canonicalStartFrame: UInt64(index * 1_000), canonicalFrameCount: 1_000,
                    encoding: .cafALAC, encodedByteLength: 1_000,
                    encodedSHA256: EncodedChunkSHA256(Data(SHA256.hash(data: encoded[index]))),
                    canonicalDecodedByteLength: 2_000, canonicalDecodedSHA256: CanonicalPCMHash(ClientStoreFixtures.bytes(13))
                )
            }
            var pending = try UploadAttempt(
                uploadID: UploadID(ClientStoreFixtures.uuid(300)), ownerDeviceID: origin.deviceID,
                originRecordingID: origin, frozenProfile: ClientStoreFixtures.profile(), beganAt: ClientStoreFixtures.baseDate
            )
            try pending.declare(chunks, generation: .initial, at: ClientStoreFixtures.baseDate)
            attempt = pending
            batch = try ImmutableAudioBatchDescriptor(
                batchID: AudioBatchID(ClientStoreFixtures.uuid(400)), uploadID: pending.uploadID,
                generation: .initial, uploadProfileSHA256: pending.frozenProfile.profileSHA256,
                originRecordingID: origin, ownerDeviceID: origin.deviceID, chunks: chunks,
                exactBodyByteLength: UInt64(bodyBytes.count), exactBodySHA256: ImmutableBatchSHA256(Data(SHA256.hash(data: bodyBytes)))
            )
            let trust = ClientStoreFixtures.hostTrust(tuple: tuple, keyByte: 1)
            let codec = HarcBatchAcknowledgementCodecV1()
            let issued = try codec.issueBatchAcknowledgement(
                claims: BatchAcknowledgementClaims(hostTrust: trust, batch: batch,
                    acknowledgementID: ClientStoreFixtures.uuid(401), durableAt: ClientStoreFixtures.baseDate),
                hostAuthoritySigner: ClientStoreFixtures.signingKey(1)
            )
            acknowledgement = try codec.validateBatchAcknowledgement(
                exactSignedAcknowledgementBytes: issued.exactAcknowledgementObject.exactBytes,
                batch: batch, hostTrust: trust
            )
        }

        func openStore() throws -> HarcTransferStore {
            try HarcTransferStore(rootDirectory: root, installationDeviceID: origin.deviceID,
                storageAttributes: RecordingStorageAttributes(), now: { ClientStoreFixtures.baseDate })
        }
        func chunkURL(_ index: Int) -> URL { root.appendingPathComponent("chunk-\(index).caf") }
        func prepare(in store: HarcTransferStore) throws {
            _ = try store.adopt(ClientStoreFixtures.adoption(tuple: tuple, keyByte: 1,
                transportEpoch: 1, transportByte: 1, grantEpoch: 1, grantByte: 1))
            try masterBytes.write(to: root.appendingPathComponent("master.wav"))
            try bodyBytes.write(to: root.appendingPathComponent("batch.bin"))
            _ = try store.persistFinalizedCapture(ClientStoreFixtures.capture(origin: origin, frames: 2_000),
                masterFileURL: root.appendingPathComponent("master.wav"))
            _ = try store.updateRecordingOutbox(for: origin) {
                try $0.queue(); try $0.beginAuthorization(); try $0.beginActiveUpload()
            }
            try store.persistUploadAttempt(attempt, for: tuple)
            for (index, chunk) in chunks.enumerated() {
                try encodedBytes[index].write(to: chunkURL(index))
                var machine = ChunkOutboxStateMachine()
                try machine.beginEncoding(); try machine.markReady(); try machine.schedule()
                try store.persistEncodedChunk(uploadID: attempt.uploadID, descriptor: chunk,
                    encodedFileURL: chunkURL(index), stateMachine: machine)
            }
            try store.persistBackgroundBatch(batch, bodyFileURL: root.appendingPathComponent("batch.bin"),
                capability: OpaqueBackgroundCapability(credential: Data([1]), capabilityBindings: Data([2]),
                    expiresAt: ClientStoreFixtures.baseDate.addingTimeInterval(300)))
            try store.persistTaskMappingBeforeResume(SystemBackgroundTaskIdentity(taskIdentifier: 50), batchID: batch.batchID)
            _ = try store.requestCleanup(for: origin, requestedAt: ClientStoreFixtures.baseDate)
        }
        func expectFilesUnchanged() throws {
            #expect(try Data(contentsOf: root.appendingPathComponent("master.wav")) == masterBytes)
            #expect(try Data(contentsOf: root.appendingPathComponent("batch.bin")) == bodyBytes)
            for index in encodedBytes.indices { #expect(try Data(contentsOf: chunkURL(index)) == encodedBytes[index]) }
        }
    }
}
