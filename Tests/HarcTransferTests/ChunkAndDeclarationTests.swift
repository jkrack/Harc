import Foundation
import HarcDomain
import Testing
@testable import HarcTransfer

@Suite("HarcTransfer immutable chunks and declarations")
struct ChunkAndDeclarationTests {
    @Test("Logical chunks enforce V1 frame, byte, format, and arithmetic ceilings")
    func logicalChunkLimits() throws {
        let origin = TransferFixtures.origin()
        let encoded = try EncodedChunkSHA256(TransferFixtures.bytes(1))
        let decoded = try CanonicalPCMHash(TransferFixtures.bytes(2))

        #expect(throws: TransferValidationError.self) {
            try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: .random(),
                chunkIndex: 0,
                canonicalStartFrame: 0,
                canonicalFrameCount: TransferLimits.ordinaryChunkFrames + 1,
                encoding: .cafALAC,
                encodedByteLength: 1,
                encodedSHA256: encoded,
                canonicalDecodedByteLength: (TransferLimits.ordinaryChunkFrames + 1) * 2,
                canonicalDecodedSHA256: decoded
            )
        }
        #expect(throws: TransferValidationError.self) {
            try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: .random(),
                chunkIndex: 0,
                canonicalStartFrame: 0,
                canonicalFrameCount: 1,
                encoding: .cafALAC,
                encodedByteLength: TransferLimits.encodedChunkBytes + 1,
                encodedSHA256: encoded,
                canonicalDecodedByteLength: 2,
                canonicalDecodedSHA256: decoded
            )
        }
        #expect(throws: TransferValidationError.self) {
            try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: .random(),
                chunkIndex: 0,
                canonicalStartFrame: UInt64.max,
                canonicalFrameCount: 1,
                encoding: .cafALAC,
                encodedByteLength: 1,
                encodedSHA256: encoded,
                canonicalDecodedByteLength: 2,
                canonicalDecodedSHA256: decoded
            )
        }
        #expect(throws: TransferValidationError.self) {
            try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: .random(),
                chunkIndex: 0,
                canonicalStartFrame: 0,
                canonicalFrameCount: 10,
                encoding: .cafALAC,
                encodedByteLength: 10,
                encodedSHA256: encoded,
                canonicalDecodedByteLength: 19,
                canonicalDecodedSHA256: decoded
            )
        }

        let nonV1 = try CanonicalPCMFormat(
            sampleRateHz: 48_000,
            channelCount: 1,
            encoding: .signedInt16LittleEndian
        )
        #expect(throws: TransferValidationError.self) {
            try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: .random(),
                chunkIndex: 0,
                canonicalStartFrame: 0,
                canonicalFrameCount: 10,
                canonicalFormat: nonV1,
                encoding: .cafALAC,
                encodedByteLength: 10,
                encodedSHA256: encoded,
                canonicalDecodedByteLength: 20,
                canonicalDecodedSHA256: decoded
            )
        }
    }

    @Test("Raw fixture descriptors require exact canonical bytes and hash")
    func rawFixtureEquality() throws {
        let origin = TransferFixtures.origin()
        let decoded = try CanonicalPCMHash(TransferFixtures.bytes(5))
        #expect(throws: TransferValidationError.self) {
            try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: .random(),
                chunkIndex: 0,
                canonicalStartFrame: 0,
                canonicalFrameCount: 10,
                encoding: .rawPCMFixture,
                encodedByteLength: 20,
                encodedSHA256: EncodedChunkSHA256(TransferFixtures.bytes(6)),
                canonicalDecodedByteLength: 20,
                canonicalDecodedSHA256: decoded
            )
        }
        let valid = TransferFixtures.chunk(
            origin: origin,
            index: 0,
            startFrame: 0,
            frameCount: 10,
            encoding: .rawPCMFixture
        )
        #expect(valid.encodedSHA256.rawBytes == valid.canonicalDecodedSHA256.rawBytes)
        #expect(valid.encodedByteLength == valid.canonicalDecodedByteLength)
    }

    @Test("Complete chunk sets require exact zero-based contiguous coverage and one encoding")
    func completeCoverage() throws {
        let origin = TransferFixtures.origin()
        let capture = TransferFixtures.capture(origin: origin)
        let chunks = TransferFixtures.chunkedCapture(origin: origin).chunks
        let complete = try ChunkedFinalizedCapture(capture: capture, chunks: chunks)
        #expect(complete.chunks.count == 2)

        let gap = TransferFixtures.chunk(
            origin: origin,
            index: 1,
            startFrame: 960_001,
            frameCount: 239_999
        )
        #expect(throws: TransferValidationError.self) {
            try ChunkedFinalizedCapture(capture: capture, chunks: [chunks[0], gap])
        }

        let duplicateID = TransferFixtures.chunk(
            origin: origin,
            index: 1,
            startFrame: 960_000,
            frameCount: 240_000,
            id: chunks[0].chunkID.rawValue == TransferFixtures.uuid(100) ? 100 : 999
        )
        #expect(throws: TransferValidationError.self) {
            try ChunkedFinalizedCapture(capture: capture, chunks: [chunks[0], duplicateID])
        }

        let flac = try LosslessEncodingConfiguration.flac(compressionLevel: 5)
        let changedEncoding = TransferFixtures.chunk(
            origin: origin,
            index: 1,
            startFrame: 960_000,
            frameCount: 240_000,
            encoding: flac
        )
        #expect(throws: TransferValidationError.self) {
            try ChunkedFinalizedCapture(capture: capture, chunks: [chunks[0], changedEncoding])
        }
    }

    @Test("Declarations append contiguously and accept exact subset or mixed replay")
    func declarationsAndReplay() throws {
        let origin = TransferFixtures.origin()
        let profile = TransferFixtures.profile()
        let chunks = TransferFixtures.chunkedCapture(origin: origin).chunks
        let third = TransferFixtures.chunk(
            origin: origin,
            index: 2,
            startFrame: 1_200_000,
            frameCount: 10
        )
        var ledger = ChunkDeclarationLedger(originRecordingID: origin, frozenProfile: profile)
        #expect(try ledger.declare([chunks[0]]) == .appended(firstIndex: 0, count: 1))
        #expect(try ledger.declare([chunks[0]]) == .exactReplay)
        #expect(try ledger.declare([chunks[0], chunks[1]]) == .appended(firstIndex: 1, count: 1))
        #expect(try ledger.declare([chunks[1], third]) == .appended(firstIndex: 2, count: 1))
        #expect(ledger.descriptors == [chunks[0], chunks[1], third])
        #expect(ledger.status == .open)
    }

    @Test("A gap or reorder is rejected atomically without conflict blocking")
    func orderingRejectsWithoutBlock() throws {
        let origin = TransferFixtures.origin()
        let profile = TransferFixtures.profile()
        let first = TransferFixtures.chunk(origin: origin, index: 0, startFrame: 0, frameCount: 10)
        let gap = TransferFixtures.chunk(origin: origin, index: 2, startFrame: 20, frameCount: 10)
        var ledger = ChunkDeclarationLedger(originRecordingID: origin, frozenProfile: profile)

        #expect(throws: TransferValidationError.self) { try ledger.declare([gap]) }
        #expect(ledger.descriptors.isEmpty)
        #expect(ledger.status == .open)

        #expect(throws: TransferValidationError.self) { try ledger.declare([gap, first]) }
        #expect(ledger.descriptors.isEmpty)
        #expect(ledger.status == .open)
    }

    @Test("Index and identifier conflicts block all later data, including exact replay")
    func conflictsBlock() throws {
        let origin = TransferFixtures.origin()
        let profile = TransferFixtures.profile()
        let first = TransferFixtures.chunk(origin: origin, index: 0, startFrame: 0, frameCount: 10)
        var ledger = ChunkDeclarationLedger(originRecordingID: origin, frozenProfile: profile)
        _ = try ledger.declare([first])

        let indexConflict = TransferFixtures.chunk(
            origin: origin,
            index: 0,
            startFrame: 0,
            frameCount: 9,
            id: 999
        )
        #expect(throws: TransferValidationError.self) { try ledger.declare([indexConflict]) }
        #expect(ledger.status == .conflictBlocked)
        #expect(ledger.conflict?.kind == .indexReused)
        #expect(ledger.descriptors == [first])
        #expect(throws: TransferValidationError.self) { try ledger.declare([first]) }

        var identifierLedger = ChunkDeclarationLedger(originRecordingID: origin, frozenProfile: profile)
        _ = try identifierLedger.declare([first])
        let identifierConflict = TransferFixtures.chunk(
            origin: origin,
            index: 1,
            startFrame: 10,
            frameCount: 10,
            id: 100
        )
        #expect(throws: TransferValidationError.self) { try identifierLedger.declare([identifierConflict]) }
        #expect(identifierLedger.conflict?.kind == .identifierReused)

        var profileConflictLedger = ChunkDeclarationLedger(originRecordingID: origin, frozenProfile: profile)
        _ = try profileConflictLedger.declare([first])
        let changedCodec = TransferFixtures.chunk(
            origin: origin,
            index: 0,
            startFrame: 0,
            frameCount: 10,
            id: 100,
            encoding: try LosslessEncodingConfiguration.flac(compressionLevel: 5)
        )
        #expect(throws: TransferValidationError.self) { try profileConflictLedger.declare([changedCodec]) }
        #expect(profileConflictLedger.status == .conflictBlocked)
        #expect(profileConflictLedger.conflict?.kind == .indexAndIdentifierReused)
    }

    @Test("Closing requires the exact complete descriptor list and remains replay-idempotent")
    func closeDeclarations() throws {
        let finalized = TransferFixtures.chunkedCapture()
        var ledger = ChunkDeclarationLedger(
            originRecordingID: finalized.capture.originRecordingID,
            frozenProfile: TransferFixtures.profile()
        )
        _ = try ledger.declare(finalized.chunks)
        #expect(try ledger.close(for: finalized) == .closed)
        #expect(try ledger.close(for: finalized) == .exactReplay)
        #expect(ledger.closedTotalFrames == finalized.capture.totalCanonicalFrames)

        let extra = TransferFixtures.chunk(
            index: 2,
            startFrame: finalized.capture.totalCanonicalFrames,
            frameCount: 1
        )
        #expect(throws: TransferValidationError.self) { try ledger.declare([extra]) }
        #expect(try ledger.declare(finalized.chunks) == .exactReplay)

        let encoded = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(ChunkDeclarationLedger.self, from: encoded) == ledger)
    }
}
