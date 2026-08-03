import Foundation
import HarcDomain

public enum ChunkDeclarationConflictKind: String, Codable, CaseIterable, Sendable {
    case indexReused
    case identifierReused
    case indexAndIdentifierReused
}

public struct ChunkDeclarationConflict: Codable, Equatable, Hashable, Sendable {
    public let kind: ChunkDeclarationConflictKind
    public let existing: LogicalChunkDescriptor
    public let attempted: LogicalChunkDescriptor

    public init(existing: LogicalChunkDescriptor, attempted: LogicalChunkDescriptor) throws {
        guard existing != attempted else {
            throw TransferValidationError.invalidUploadAttempt(
                reason: "An exact descriptor replay is not a conflict."
            )
        }
        guard existing.originRecordingID == attempted.originRecordingID else {
            throw TransferValidationError.invalidUploadAttempt(
                reason: "A declaration conflict must remain within one origin recording."
            )
        }

        let sameIndex = existing.chunkIndex == attempted.chunkIndex
        let sameIdentifier = existing.chunkID == attempted.chunkID
        switch (sameIndex, sameIdentifier) {
        case (true, true): self.kind = .indexAndIdentifierReused
        case (true, false): self.kind = .indexReused
        case (false, true): self.kind = .identifierReused
        case (false, false):
            throw TransferValidationError.invalidUploadAttempt(
                reason: "A conflict must reuse a chunk index or chunk identifier."
            )
        }
        self.existing = existing
        self.attempted = attempted
    }

    private enum CodingKeys: String, CodingKey { case existing, attempted }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                existing: container.decode(LogicalChunkDescriptor.self, forKey: .existing),
                attempted: container.decode(LogicalChunkDescriptor.self, forKey: .attempted)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid chunk declaration conflict.")
        }
    }
}

public enum ChunkDeclarationStatus: String, Codable, CaseIterable, Sendable {
    case open
    case closed
    case conflictBlocked
}

public enum ChunkDeclarationDisposition: Equatable, Hashable, Sendable {
    case appended(firstIndex: UInt32, count: Int)
    case exactReplay
    case closed
    case conflictBlocked(ChunkDeclarationConflict)
}

/// Ordered, transaction-friendly declaration state. A conflicting reuse
/// permanently blocks this upload ledger; a mere gap/reorder rejects the call
/// without changing prior declarations.
public struct ChunkDeclarationLedger: Codable, Equatable, Hashable, Sendable {
    public let originRecordingID: OriginRecordingID
    public let frozenProfile: FrozenUploadProfile
    public private(set) var descriptors: [LogicalChunkDescriptor]
    public private(set) var status: ChunkDeclarationStatus
    public private(set) var conflict: ChunkDeclarationConflict?
    public private(set) var closedTotalFrames: UInt64?

    public init(originRecordingID: OriginRecordingID, frozenProfile: FrozenUploadProfile) {
        self.originRecordingID = originRecordingID
        self.frozenProfile = frozenProfile
        self.descriptors = []
        self.status = .open
        self.conflict = nil
        self.closedTotalFrames = nil
    }

    @discardableResult
    public mutating func declare(
        _ incoming: [LogicalChunkDescriptor]
    ) throws -> ChunkDeclarationDisposition {
        guard status != .conflictBlocked else {
            throw TransferValidationError.declarationBlocked
        }
        guard !incoming.isEmpty else {
            throw TransferValidationError.invalidLength(field: "DeclareChunks.descriptors", value: 0)
        }
        try validateIncomingStructuralOrder(incoming)

        let byIndex = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.chunkIndex, $0) })
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.chunkID, $0) })

        // Detect immutable-identity conflicts before accepting any prefix. This
        // models the host transaction: the call either appends completely or
        // records one blocking conflict without partial declarations.
        for descriptor in incoming {
            if let existing = byIndex[descriptor.chunkIndex], existing != descriptor {
                let found = try ChunkDeclarationConflict(existing: existing, attempted: descriptor)
                status = .conflictBlocked
                conflict = found
                throw TransferValidationError.chunkConflict(found)
            }
            if let existing = byID[descriptor.chunkID], existing != descriptor {
                let found = try ChunkDeclarationConflict(existing: existing, attempted: descriptor)
                status = .conflictBlocked
                conflict = found
                throw TransferValidationError.chunkConflict(found)
            }
        }
        try validateIncomingProfile(incoming)

        let allReplay = incoming.allSatisfy { byIndex[$0.chunkIndex] == $0 }
        if allReplay { return .exactReplay }
        guard status == .open else {
            throw TransferValidationError.declarationClosed
        }

        var candidate = descriptors
        var firstAppended: UInt32?
        for descriptor in incoming where byIndex[descriptor.chunkIndex] == nil {
            guard let expectedIndex = UInt32(exactly: candidate.count) else {
                throw TransferValidationError.numericOverflow(field: "ChunkDeclarationLedger.descriptors.count")
            }
            let expectedStart = candidate.last?.canonicalEndFrameExclusive ?? 0
            guard descriptor.chunkIndex == expectedIndex,
                  descriptor.canonicalStartFrame == expectedStart else {
                throw TransferValidationError.nonContiguousDeclaration(
                    expectedIndex: expectedIndex,
                    expectedStartFrame: expectedStart
                )
            }
            firstAppended = firstAppended ?? descriptor.chunkIndex
            candidate.append(descriptor)
        }

        guard let firstAppended else { return .exactReplay }
        guard candidate.count <= TransferLimits.declaredChunksPerUpload else {
            throw TransferValidationError.exceedsLimit(
                field: "ChunkDeclarationLedger.descriptors",
                limit: UInt64(TransferLimits.declaredChunksPerUpload),
                actual: UInt64(candidate.count)
            )
        }
        let appendedCount = candidate.count - descriptors.count
        descriptors = candidate
        return .appended(firstIndex: firstAppended, count: appendedCount)
    }

    @discardableResult
    public mutating func close(
        for finalizedCapture: ChunkedFinalizedCapture
    ) throws -> ChunkDeclarationDisposition {
        guard status != .conflictBlocked else {
            throw TransferValidationError.declarationBlocked
        }
        try finalizedCapture.validate(against: frozenProfile)
        guard finalizedCapture.capture.originRecordingID == originRecordingID else {
            throw TransferValidationError.profileMismatch(field: "originRecordingID")
        }
        guard descriptors == finalizedCapture.chunks else {
            throw TransferValidationError.profileMismatch(field: "complete descriptor list")
        }
        if status == .closed {
            guard closedTotalFrames == finalizedCapture.capture.totalCanonicalFrames else {
                throw TransferValidationError.profileMismatch(field: "closedTotalFrames")
            }
            return .exactReplay
        }
        status = .closed
        closedTotalFrames = finalizedCapture.capture.totalCanonicalFrames
        return .closed
    }

    private func validateIncomingStructuralOrder(_ incoming: [LogicalChunkDescriptor]) throws {
        var seen = Set<ChunkID>()
        var prior: LogicalChunkDescriptor?
        for descriptor in incoming {
            guard descriptor.originRecordingID == originRecordingID else {
                throw TransferValidationError.profileMismatch(field: "originRecordingID")
            }
            guard seen.insert(descriptor.chunkID).inserted else {
                throw TransferValidationError.duplicateIdentifier(field: "DeclareChunks chunk IDs")
            }
            if let prior {
                let nextIndex = try TransferValidation.next(prior.chunkIndex, field: "DeclareChunks.chunkIndex")
                guard descriptor.chunkIndex == nextIndex,
                      descriptor.canonicalStartFrame == prior.canonicalEndFrameExclusive else {
                    throw TransferValidationError.invalidOrdering(field: "DeclareChunks descriptors")
                }
            }
            prior = descriptor
        }
    }

    private func validateIncomingProfile(_ incoming: [LogicalChunkDescriptor]) throws {
        for descriptor in incoming {
            guard descriptor.canonicalFormat == frozenProfile.canonicalFormat else {
                throw TransferValidationError.profileMismatch(field: "canonicalFormat")
            }
            guard descriptor.encoding == frozenProfile.encoding else {
                throw TransferValidationError.profileMismatch(field: "encoding")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case originRecordingID
        case frozenProfile
        case descriptors
        case status
        case conflict
        case closedTotalFrames
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let origin = try container.decode(OriginRecordingID.self, forKey: .originRecordingID)
            let profile = try container.decode(FrozenUploadProfile.self, forKey: .frozenProfile)
            let descriptors = try container.decode([LogicalChunkDescriptor].self, forKey: .descriptors)
            let status = try container.decode(ChunkDeclarationStatus.self, forKey: .status)
            let conflict = try container.decodeIfPresent(ChunkDeclarationConflict.self, forKey: .conflict)
            let closedTotalFrames = try container.decodeIfPresent(UInt64.self, forKey: .closedTotalFrames)

            var rebuilt = Self(originRecordingID: origin, frozenProfile: profile)
            if !descriptors.isEmpty {
                _ = try rebuilt.declare(descriptors)
            }
            switch status {
            case .open:
                guard conflict == nil, closedTotalFrames == nil else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Open declarations cannot carry terminal detail.")
                }
            case .closed:
                guard conflict == nil, let closedTotalFrames,
                      descriptors.last?.canonicalEndFrameExclusive == closedTotalFrames else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Closed declarations require exact frame coverage.")
                }
                rebuilt.status = .closed
                rebuilt.closedTotalFrames = closedTotalFrames
            case .conflictBlocked:
                guard let conflict, closedTotalFrames == nil,
                      descriptors.contains(conflict.existing),
                      conflict.existing.originRecordingID == origin,
                      conflict.attempted.originRecordingID == origin else {
                    throw TransferValidationError.invalidUploadAttempt(reason: "Blocked declarations require their persisted conflict.")
                }
                rebuilt.status = .conflictBlocked
                rebuilt.conflict = conflict
            }
            self = rebuilt
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid chunk declaration ledger.")
        }
    }
}
