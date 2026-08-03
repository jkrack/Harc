import Foundation
import HarcDomain
import Testing
@testable import HarcTransfer

@Suite("HarcTransfer reconciliation and immutable batches")
struct ReconciliationAndBatchTests {
    @Test("Reconciliation returns only exact declarations and matching durable/rejected values")
    func reconciliationValidation() throws {
        let origin = TransferFixtures.origin()
        let chunks = TransferFixtures.chunkedCapture(origin: origin).chunks
        let durable = DurableChunkStatus(
            chunkIndex: chunks[0].chunkIndex,
            chunkID: chunks[0].chunkID,
            encodedSHA256: chunks[0].encodedSHA256
        )
        let rejected = RejectedChunkStatus(
            chunkIndex: chunks[1].chunkIndex,
            chunkID: chunks[1].chunkID,
            reason: .missingBytes
        )
        let value = try UploadReconciliation(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
            generation: .initial,
            generationExpiresAt: TransferFixtures.baseDate.addingTimeInterval(60),
            declarations: chunks,
            boundManifestObjectSHA256: nil,
            durableChunks: [durable],
            rejectedChunks: [rejected],
            terminalReason: nil,
            existingReceipt: nil
        )
        #expect(value.durableChunks == [durable])
        #expect(value.rejectedChunks == [rejected])
        #expect(try JSONDecoder().decode(UploadReconciliation.self, from: JSONEncoder().encode(value)) == value)

        let wrongHash = DurableChunkStatus(
            chunkIndex: chunks[0].chunkIndex,
            chunkID: chunks[0].chunkID,
            encodedSHA256: try EncodedChunkSHA256(TransferFixtures.bytes(99))
        )
        #expect(throws: TransferValidationError.self) {
            try UploadReconciliation(
                uploadID: .random(),
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                generation: .initial,
                generationExpiresAt: TransferFixtures.baseDate,
                declarations: chunks,
                boundManifestObjectSHA256: nil,
                durableChunks: [wrongHash],
                rejectedChunks: [],
                terminalReason: nil,
                existingReceipt: nil
            )
        }
        #expect(throws: TransferValidationError.self) {
            try UploadReconciliation(
                uploadID: .random(),
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                generation: .initial,
                generationExpiresAt: TransferFixtures.baseDate,
                declarations: chunks,
                boundManifestObjectSHA256: nil,
                durableChunks: [durable],
                rejectedChunks: [
                    RejectedChunkStatus(
                        chunkIndex: chunks[0].chunkIndex,
                        chunkID: chunks[0].chunkID,
                        reason: .corruptContainer
                    ),
                ],
                terminalReason: nil,
                existingReceipt: nil
            )
        }
    }

    @Test("Committed reconciliation requires exact receipt and bound manifest identities")
    func committedReconciliation() throws {
        let origin = TransferFixtures.origin()
        let chunks = TransferFixtures.chunkedCapture(origin: origin).chunks
        let receipt = TransferFixtures.exactObject(.recordingReceiptV1, byte: 10)
        let manifestID = try ExactObjectSHA256(TransferFixtures.bytes(11))

        #expect(throws: TransferValidationError.self) {
            try UploadReconciliation(
                uploadID: .random(),
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                generation: .initial,
                generationExpiresAt: TransferFixtures.baseDate,
                declarations: chunks,
                boundManifestObjectSHA256: manifestID,
                durableChunks: [],
                rejectedChunks: [],
                terminalReason: .committed,
                existingReceipt: nil
            )
        }
        #expect(throws: TransferValidationError.self) {
            try UploadReconciliation(
                uploadID: .random(),
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                generation: .initial,
                generationExpiresAt: TransferFixtures.baseDate,
                declarations: chunks,
                boundManifestObjectSHA256: manifestID,
                durableChunks: [],
                rejectedChunks: [],
                terminalReason: nil,
                existingReceipt: receipt
            )
        }

        let committed = try UploadReconciliation(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
            generation: .initial,
            generationExpiresAt: TransferFixtures.baseDate,
            declarations: chunks,
            boundManifestObjectSHA256: manifestID,
            durableChunks: chunks.map {
                DurableChunkStatus(
                    chunkIndex: $0.chunkIndex,
                    chunkID: $0.chunkID,
                    encodedSHA256: $0.encodedSHA256
                )
            },
            rejectedChunks: [],
            terminalReason: .committed,
            existingReceipt: receipt
        )
        #expect(committed.existingReceipt == receipt)
    }

    @Test("Exact-object slots are opaque, nonempty, typed, and Codable")
    func exactObjectSlots() throws {
        #expect(throws: TransferValidationError.self) {
            try OpaqueExactObjectSlot(
                kind: .recordingManifestV1,
                exactBytes: Data(),
                objectSHA256: ExactObjectSHA256(TransferFixtures.bytes(1))
            )
        }
        let slot = TransferFixtures.exactObject(.audioBatchAckV1, byte: 3)
        #expect(try JSONDecoder().decode(OpaqueExactObjectSlot.self, from: JSONEncoder().encode(slot)) == slot)
        #expect(slot.exactBytes == Data([3, 4, 5]))
    }

    @Test("Immutable batch descriptor enforces 64 entries, 64 MiB, order, and framing lower bound")
    func immutableBatchLimits() throws {
        let origin = TransferFixtures.origin()
        let chunks = TransferFixtures.chunkedCapture(origin: origin).chunks
        let batch = try ImmutableAudioBatchDescriptor(
            batchID: .random(),
            uploadID: .random(),
            generation: .initial,
            uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
            originRecordingID: origin,
            ownerDeviceID: origin.deviceID,
            chunks: chunks,
            exactBodyByteLength: 2_000_000,
            exactBodySHA256: ImmutableBatchSHA256(TransferFixtures.bytes(4))
        )
        #expect(batch.chunks == chunks)
        #expect(try JSONDecoder().decode(ImmutableAudioBatchDescriptor.self, from: JSONEncoder().encode(batch)) == batch)

        #expect(throws: TransferValidationError.self) {
            try ImmutableAudioBatchDescriptor(
                batchID: .random(),
                uploadID: .random(),
                generation: .initial,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                originRecordingID: origin,
                ownerDeviceID: origin.deviceID,
                chunks: chunks,
                exactBodyByteLength: 10,
                exactBodySHA256: ImmutableBatchSHA256(TransferFixtures.bytes(4))
            )
        }
        #expect(throws: TransferValidationError.self) {
            try ImmutableAudioBatchDescriptor(
                batchID: .random(),
                uploadID: .random(),
                generation: .initial,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                originRecordingID: origin,
                ownerDeviceID: origin.deviceID,
                chunks: chunks,
                exactBodyByteLength: TransferLimits.backgroundBatchBytes + 1,
                exactBodySHA256: ImmutableBatchSHA256(TransferFixtures.bytes(4))
            )
        }
        #expect(throws: TransferValidationError.self) {
            try ImmutableAudioBatchDescriptor(
                batchID: .random(),
                uploadID: .random(),
                generation: .initial,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                originRecordingID: origin,
                ownerDeviceID: origin.deviceID,
                chunks: chunks.reversed(),
                exactBodyByteLength: 2_000_000,
                exactBodySHA256: ImmutableBatchSHA256(TransferFixtures.bytes(4))
            )
        }

        let tooMany = (0...TransferLimits.backgroundBatchEntries).map { index in
            TransferFixtures.chunk(
                origin: origin,
                index: UInt32(index),
                startFrame: UInt64(index),
                frameCount: 1,
                id: UInt32(index + 1_000)
            )
        }
        #expect(throws: TransferValidationError.self) {
            try ImmutableAudioBatchDescriptor(
                batchID: .random(),
                uploadID: .random(),
                generation: .initial,
                uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
                originRecordingID: origin,
                ownerDeviceID: origin.deviceID,
                chunks: tooMany,
                exactBodyByteLength: 1_000,
                exactBodySHA256: ImmutableBatchSHA256(TransferFixtures.bytes(4))
            )
        }
    }

    @Test("Transfer public JSON values contain no URL or host filesystem fields")
    func noPublicPaths() throws {
        let origin = TransferFixtures.origin()
        let batch = try ImmutableAudioBatchDescriptor(
            batchID: .random(),
            uploadID: .random(),
            generation: .initial,
            uploadProfileSHA256: TransferFixtures.profile().profileSHA256,
            originRecordingID: origin,
            ownerDeviceID: origin.deviceID,
            chunks: [TransferFixtures.chunk(origin: origin, index: 0, startFrame: 0, frameCount: 10)],
            exactBodyByteLength: 1_000,
            exactBodySHA256: ImmutableBatchSHA256(TransferFixtures.bytes(4))
        )
        let json = try #require(String(data: JSONEncoder().encode(batch), encoding: .utf8))
        #expect(!json.localizedCaseInsensitiveContains("url"))
        #expect(!json.localizedCaseInsensitiveContains("path"))
        #expect(!json.localizedCaseInsensitiveContains("filename"))
    }
}
