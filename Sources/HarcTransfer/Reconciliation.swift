import Foundation
import HarcDomain

public struct DurableChunkStatus: Codable, Equatable, Hashable, Sendable {
    public let chunkIndex: UInt32
    public let chunkID: ChunkID
    public let encodedSHA256: EncodedChunkSHA256

    public init(chunkIndex: UInt32, chunkID: ChunkID, encodedSHA256: EncodedChunkSHA256) {
        self.chunkIndex = chunkIndex
        self.chunkID = chunkID
        self.encodedSHA256 = encodedSHA256
    }
}

public enum RejectedChunkReason: String, Codable, CaseIterable, Sendable {
    case missingBytes
    case lengthMismatch
    case encodedHashMismatch
    case decodedHashMismatch
    case corruptContainer
    case unsupportedEncoding
    case quotaExhausted
}

public struct RejectedChunkStatus: Codable, Equatable, Hashable, Sendable {
    public let chunkIndex: UInt32
    public let chunkID: ChunkID
    public let reason: RejectedChunkReason

    public init(chunkIndex: UInt32, chunkID: ChunkID, reason: RejectedChunkReason) {
        self.chunkIndex = chunkIndex
        self.chunkID = chunkID
        self.reason = reason
    }
}

public enum UploadReconciliationTerminalReason: String, Codable, CaseIterable, Sendable {
    case expired
    case abandoned
    case declarationConflict
    case committed
}

/// Path-free, transport-neutral value returned by upload reconciliation.
public struct UploadReconciliation: Codable, Equatable, Hashable, Sendable {
    public let uploadID: UploadID
    public let ownerDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let uploadProfileSHA256: UploadProfileSHA256
    public let generation: UploadGeneration
    public let generationExpiresAt: Date
    public let declarations: [LogicalChunkDescriptor]
    public let boundManifestObjectSHA256: ExactObjectSHA256?
    public let durableChunks: [DurableChunkStatus]
    public let rejectedChunks: [RejectedChunkStatus]
    public let terminalReason: UploadReconciliationTerminalReason?
    public let existingReceipt: OpaqueExactObjectSlot?

    public init(
        uploadID: UploadID,
        ownerDeviceID: DeviceID,
        originRecordingID: OriginRecordingID,
        uploadProfileSHA256: UploadProfileSHA256,
        generation: UploadGeneration,
        generationExpiresAt: Date,
        declarations: [LogicalChunkDescriptor],
        boundManifestObjectSHA256: ExactObjectSHA256?,
        durableChunks: [DurableChunkStatus],
        rejectedChunks: [RejectedChunkStatus],
        terminalReason: UploadReconciliationTerminalReason?,
        existingReceipt: OpaqueExactObjectSlot?
    ) throws {
        guard originRecordingID.deviceID == ownerDeviceID else {
            throw TransferValidationError.originDeviceMismatch
        }
        try TransferValidation.requireFinite(generationExpiresAt, field: "UploadReconciliation.generationExpiresAt")

        var descriptorByIndex: [UInt32: LogicalChunkDescriptor] = [:]
        var expectedIndex: UInt32 = 0
        var expectedStart: UInt64 = 0
        var chunkIDs = Set<ChunkID>()
        var encoding: LosslessEncodingConfiguration?
        for descriptor in declarations {
            guard descriptor.originRecordingID == originRecordingID else {
                throw TransferValidationError.reconciliationMismatch(reason: "Declaration origin mismatch.")
            }
            guard descriptor.chunkIndex == expectedIndex,
                  descriptor.canonicalStartFrame == expectedStart else {
                throw TransferValidationError.nonContiguousDeclaration(
                    expectedIndex: expectedIndex,
                    expectedStartFrame: expectedStart
                )
            }
            if let encoding {
                guard encoding == descriptor.encoding else {
                    throw TransferValidationError.reconciliationMismatch(reason: "Declaration encoding changed.")
                }
            } else {
                encoding = descriptor.encoding
            }
            guard chunkIDs.insert(descriptor.chunkID).inserted else {
                throw TransferValidationError.duplicateIdentifier(field: "UploadReconciliation declarations")
            }
            descriptorByIndex[descriptor.chunkIndex] = descriptor
            expectedStart = descriptor.canonicalEndFrameExclusive
            expectedIndex = try TransferValidation.next(expectedIndex, field: "UploadReconciliation.declarationIndex")
        }

        guard durableChunks.map(\.chunkIndex) == durableChunks.map(\.chunkIndex).sorted() else {
            throw TransferValidationError.invalidOrdering(field: "UploadReconciliation.durableChunks")
        }
        guard Set(durableChunks.map(\.chunkIndex)).count == durableChunks.count,
              Set(durableChunks.map(\.chunkID)).count == durableChunks.count else {
            throw TransferValidationError.duplicateIdentifier(field: "UploadReconciliation.durableChunks")
        }
        for durable in durableChunks {
            guard let descriptor = descriptorByIndex[durable.chunkIndex],
                  descriptor.chunkID == durable.chunkID,
                  descriptor.encodedSHA256 == durable.encodedSHA256 else {
                throw TransferValidationError.reconciliationMismatch(reason: "Durable chunk does not match its immutable declaration.")
            }
        }

        guard rejectedChunks.map(\.chunkIndex) == rejectedChunks.map(\.chunkIndex).sorted() else {
            throw TransferValidationError.invalidOrdering(field: "UploadReconciliation.rejectedChunks")
        }
        guard Set(rejectedChunks.map(\.chunkIndex)).count == rejectedChunks.count,
              Set(rejectedChunks.map(\.chunkID)).count == rejectedChunks.count else {
            throw TransferValidationError.duplicateIdentifier(field: "UploadReconciliation.rejectedChunks")
        }
        let durableIndexes = Set(durableChunks.map(\.chunkIndex))
        for rejected in rejectedChunks {
            guard let descriptor = descriptorByIndex[rejected.chunkIndex],
                  descriptor.chunkID == rejected.chunkID else {
                throw TransferValidationError.reconciliationMismatch(reason: "Rejected chunk does not match a declaration.")
            }
            guard !durableIndexes.contains(rejected.chunkIndex) else {
                throw TransferValidationError.reconciliationMismatch(reason: "A chunk cannot be both durable and rejected.")
            }
        }

        if terminalReason == .committed {
            guard let existingReceipt,
                  existingReceipt.kind == .recordingReceiptV1,
                  boundManifestObjectSHA256 != nil else {
                throw TransferValidationError.receiptEvidenceRequired
            }
        } else if existingReceipt != nil {
            throw TransferValidationError.reconciliationMismatch(
                reason: "A receipt is valid only for a committed reconciliation."
            )
        }

        self.uploadID = uploadID
        self.ownerDeviceID = ownerDeviceID
        self.originRecordingID = originRecordingID
        self.uploadProfileSHA256 = uploadProfileSHA256
        self.generation = generation
        self.generationExpiresAt = generationExpiresAt
        self.declarations = declarations
        self.boundManifestObjectSHA256 = boundManifestObjectSHA256
        self.durableChunks = durableChunks
        self.rejectedChunks = rejectedChunks
        self.terminalReason = terminalReason
        self.existingReceipt = existingReceipt
    }

    private enum CodingKeys: String, CodingKey {
        case uploadID
        case ownerDeviceID
        case originRecordingID
        case uploadProfileSHA256
        case generation
        case generationExpiresAt
        case declarations
        case boundManifestObjectSHA256
        case durableChunks
        case rejectedChunks
        case terminalReason
        case existingReceipt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                uploadID: container.decode(UploadID.self, forKey: .uploadID),
                ownerDeviceID: container.decode(DeviceID.self, forKey: .ownerDeviceID),
                originRecordingID: container.decode(OriginRecordingID.self, forKey: .originRecordingID),
                uploadProfileSHA256: container.decode(UploadProfileSHA256.self, forKey: .uploadProfileSHA256),
                generation: container.decode(UploadGeneration.self, forKey: .generation),
                generationExpiresAt: container.decode(Date.self, forKey: .generationExpiresAt),
                declarations: container.decode([LogicalChunkDescriptor].self, forKey: .declarations),
                boundManifestObjectSHA256: container.decodeIfPresent(ExactObjectSHA256.self, forKey: .boundManifestObjectSHA256),
                durableChunks: container.decode([DurableChunkStatus].self, forKey: .durableChunks),
                rejectedChunks: container.decode([RejectedChunkStatus].self, forKey: .rejectedChunks),
                terminalReason: container.decodeIfPresent(UploadReconciliationTerminalReason.self, forKey: .terminalReason),
                existingReceipt: container.decodeIfPresent(OpaqueExactObjectSlot.self, forKey: .existingReceipt)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid upload reconciliation.")
        }
    }
}
