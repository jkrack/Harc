import Foundation

/// Path-free metadata used by anchored snapshots and compact library lists.
public struct LibraryRecordingSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: CanonicalRecordingID { canonicalID }

    public let canonicalID: CanonicalRecordingID
    public let originID: OriginRecordingID?
    public let revision: EntityRevision
    public let startedAt: Date
    public let endedAt: Date?
    public let title: String?
    public let suggestedTitle: String?
    public let tags: [String]
    public let pinned: Bool
    public let canonicalAudio: CanonicalAudioDescriptor
    public let processing: ProcessingDescriptor
    public let projection: ProjectionDescriptor

    public init(
        canonicalID: CanonicalRecordingID,
        originID: OriginRecordingID? = nil,
        revision: EntityRevision,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        suggestedTitle: String? = nil,
        tags: [String] = [],
        pinned: Bool = false,
        canonicalAudio: CanonicalAudioDescriptor = .unavailablePendingHash,
        processing: ProcessingDescriptor = .pending,
        projection: ProjectionDescriptor = .unknownLegacy
    ) throws {
        try DomainValidation.requireFinite(startedAt, field: "LibraryRecordingSummary.startedAt")
        if let endedAt {
            try DomainValidation.requireFinite(endedAt, field: "LibraryRecordingSummary.endedAt")
            guard endedAt >= startedAt else {
                throw DomainValidationError.invalidState(reason: "A recording cannot end before it starts.")
            }
        }

        self.canonicalID = canonicalID
        self.originID = originID
        self.revision = revision
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.suggestedTitle = suggestedTitle
        self.tags = tags
        self.pinned = pinned
        self.canonicalAudio = canonicalAudio
        self.processing = processing
        self.projection = projection
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalID
        case originID
        case revision
        case startedAt
        case endedAt
        case title
        case suggestedTitle
        case tags
        case pinned
        case canonicalAudio
        case processing
        case projection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                canonicalID: container.decode(CanonicalRecordingID.self, forKey: .canonicalID),
                originID: container.decodeIfPresent(OriginRecordingID.self, forKey: .originID),
                revision: container.decode(EntityRevision.self, forKey: .revision),
                startedAt: container.decode(Date.self, forKey: .startedAt),
                endedAt: container.decodeIfPresent(Date.self, forKey: .endedAt),
                title: container.decodeIfPresent(String.self, forKey: .title),
                suggestedTitle: container.decodeIfPresent(String.self, forKey: .suggestedTitle),
                tags: container.decode([String].self, forKey: .tags),
                pinned: container.decode(Bool.self, forKey: .pinned),
                canonicalAudio: container.decode(CanonicalAudioDescriptor.self, forKey: .canonicalAudio),
                processing: container.decode(ProcessingDescriptor.self, forKey: .processing),
                projection: container.decode(ProjectionDescriptor.self, forKey: .projection)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid path-free recording summary.",
                    underlyingError: error
                )
            )
        }
    }
}

public struct SpeakerLabel: Codable, Equatable, Hashable, Sendable {
    public let speakerIndex: UInt32
    public let displayName: String

    public init(speakerIndex: UInt32, displayName: String) throws {
        self.speakerIndex = speakerIndex
        self.displayName = try DomainValidation.nonemptyTrimmed(
            displayName,
            field: "SpeakerLabel.displayName",
            maximum: 256
        )
    }

    private enum CodingKeys: String, CodingKey {
        case speakerIndex
        case displayName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                speakerIndex: container.decode(UInt32.self, forKey: .speakerIndex),
                displayName: container.decode(String.self, forKey: .displayName)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid speaker label.",
                    underlyingError: error
                )
            )
        }
    }
}

/// Path-free recording detail. Content is included only after authorization by
/// a higher application layer.
public struct LibraryRecordingDetail: Codable, Equatable, Hashable, Sendable {
    public let summary: LibraryRecordingSummary
    public let transcriptText: String?
    public let speakerLabels: [SpeakerLabel]
    public let summaryMarkdown: String?
    public let actionItemsMarkdown: String?
    public let notesMarkdown: String?
    public let discontinuities: [CaptureDiscontinuity]

    public init(
        summary: LibraryRecordingSummary,
        transcriptText: String? = nil,
        speakerLabels: [SpeakerLabel] = [],
        summaryMarkdown: String? = nil,
        actionItemsMarkdown: String? = nil,
        notesMarkdown: String? = nil,
        discontinuities: [CaptureDiscontinuity] = []
    ) throws {
        let labelIndices = speakerLabels.map(\.speakerIndex)
        guard labelIndices == labelIndices.sorted() else {
            throw DomainValidationError.invalidOrdering(field: "LibraryRecordingDetail.speakerLabels")
        }
        guard Set(labelIndices).count == labelIndices.count else {
            throw DomainValidationError.duplicateIdentifier(field: "LibraryRecordingDetail.speakerLabels")
        }

        if !discontinuities.isEmpty {
            guard let originID = summary.originID else {
                throw DomainValidationError.invalidState(
                    reason: "Discontinuities require an origin recording identity."
                )
            }
            guard discontinuities.allSatisfy({ $0.recordingID == originID }) else {
                throw DomainValidationError.invalidState(
                    reason: "Every discontinuity must refer to the detail's origin recording."
                )
            }
            let monotonicTimes = discontinuities.map(\.monotonicTimeNanoseconds)
            guard monotonicTimes == monotonicTimes.sorted() else {
                throw DomainValidationError.invalidOrdering(
                    field: "LibraryRecordingDetail.discontinuities"
                )
            }
        }

        self.summary = summary
        self.transcriptText = transcriptText
        self.speakerLabels = speakerLabels
        self.summaryMarkdown = summaryMarkdown
        self.actionItemsMarkdown = actionItemsMarkdown
        self.notesMarkdown = notesMarkdown
        self.discontinuities = discontinuities
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case transcriptText
        case speakerLabels
        case summaryMarkdown
        case actionItemsMarkdown
        case notesMarkdown
        case discontinuities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                summary: container.decode(LibraryRecordingSummary.self, forKey: .summary),
                transcriptText: container.decodeIfPresent(String.self, forKey: .transcriptText),
                speakerLabels: container.decode([SpeakerLabel].self, forKey: .speakerLabels),
                summaryMarkdown: container.decodeIfPresent(String.self, forKey: .summaryMarkdown),
                actionItemsMarkdown: container.decodeIfPresent(String.self, forKey: .actionItemsMarkdown),
                notesMarkdown: container.decodeIfPresent(String.self, forKey: .notesMarkdown),
                discontinuities: container.decode([CaptureDiscontinuity].self, forKey: .discontinuities)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid path-free recording detail.",
                    underlyingError: error
                )
            )
        }
    }
}

public struct RecordingTombstone: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: CanonicalRecordingID { canonicalID }

    public let canonicalID: CanonicalRecordingID
    public let revision: EntityRevision
    public let deletedAt: Date

    public init(
        canonicalID: CanonicalRecordingID,
        revision: EntityRevision,
        deletedAt: Date
    ) throws {
        try DomainValidation.requireFinite(deletedAt, field: "RecordingTombstone.deletedAt")
        self.canonicalID = canonicalID
        self.revision = revision
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalID
        case revision
        case deletedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                canonicalID: container.decode(CanonicalRecordingID.self, forKey: .canonicalID),
                revision: container.decode(EntityRevision.self, forKey: .revision),
                deletedAt: container.decode(Date.self, forKey: .deletedAt)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid recording tombstone.",
                    underlyingError: error
                )
            )
        }
    }
}

public struct AnchoredLibrarySnapshot: Codable, Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let anchor: ChangeCursor
    public let recordings: [LibraryRecordingSummary]
    public let tombstones: [RecordingTombstone]

    public init(
        libraryID: LibraryID,
        anchor: ChangeCursor,
        recordings: [LibraryRecordingSummary],
        tombstones: [RecordingTombstone]
    ) throws {
        guard recordings.map(\.canonicalID) == recordings.map(\.canonicalID).sorted() else {
            throw DomainValidationError.invalidOrdering(field: "AnchoredLibrarySnapshot.recordings")
        }
        guard tombstones.map(\.canonicalID) == tombstones.map(\.canonicalID).sorted() else {
            throw DomainValidationError.invalidOrdering(field: "AnchoredLibrarySnapshot.tombstones")
        }

        var seen = Set<CanonicalRecordingID>()
        for identifier in recordings.map(\.canonicalID) + tombstones.map(\.canonicalID) {
            guard seen.insert(identifier).inserted else {
                throw DomainValidationError.duplicateIdentifier(
                    field: "AnchoredLibrarySnapshot canonical recording IDs"
                )
            }
        }

        self.libraryID = libraryID
        self.anchor = anchor
        self.recordings = recordings
        self.tombstones = tombstones
    }

    private enum CodingKeys: String, CodingKey {
        case libraryID
        case anchor
        case recordings
        case tombstones
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                libraryID: container.decode(LibraryID.self, forKey: .libraryID),
                anchor: container.decode(ChangeCursor.self, forKey: .anchor),
                recordings: container.decode([LibraryRecordingSummary].self, forKey: .recordings),
                tombstones: container.decode([RecordingTombstone].self, forKey: .tombstones)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid anchored library snapshot.",
                    underlyingError: error
                )
            )
        }
    }
}

public enum LibraryChangeOperation: String, Codable, CaseIterable, Sendable {
    case upsert
    case tombstone
}

public struct LibraryChangeDescriptor: Codable, Equatable, Hashable, Sendable {
    public let cursor: ChangeCursor
    public let canonicalID: CanonicalRecordingID
    public let revision: EntityRevision
    public let operation: LibraryChangeOperation
    public let changedAt: Date

    public init(
        cursor: ChangeCursor,
        canonicalID: CanonicalRecordingID,
        revision: EntityRevision,
        operation: LibraryChangeOperation,
        changedAt: Date
    ) throws {
        guard cursor != .zero else {
            throw DomainValidationError.invalidState(reason: "A library change cursor must be nonzero.")
        }
        try DomainValidation.requireFinite(changedAt, field: "LibraryChangeDescriptor.changedAt")
        self.cursor = cursor
        self.canonicalID = canonicalID
        self.revision = revision
        self.operation = operation
        self.changedAt = changedAt
    }

    public var isTombstone: Bool { operation == .tombstone }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case canonicalID
        case revision
        case operation
        case changedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                cursor: container.decode(ChangeCursor.self, forKey: .cursor),
                canonicalID: container.decode(CanonicalRecordingID.self, forKey: .canonicalID),
                revision: container.decode(EntityRevision.self, forKey: .revision),
                operation: container.decode(LibraryChangeOperation.self, forKey: .operation),
                changedAt: container.decode(Date.self, forKey: .changedAt)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid library change descriptor.",
                    underlyingError: error
                )
            )
        }
    }
}

/// The path-free value carried by a materialized library change page.
public enum LibraryChangeValue: Equatable, Hashable, Sendable {
    case upsert(LibraryRecordingSummary)
    case tombstone(RecordingTombstone)
}

/// A change-log cursor paired with the exact current value materialized in the
/// same canonical-store read transaction. The descriptor revision always
/// matches the projected value, even when several log rows for one recording
/// are collapsed into a single page result.
public struct MaterializedLibraryChange: Equatable, Hashable, Sendable {
    public let descriptor: LibraryChangeDescriptor
    public let value: LibraryChangeValue

    public init(
        descriptor: LibraryChangeDescriptor,
        value: LibraryChangeValue
    ) throws {
        switch value {
        case .upsert(let summary):
            guard descriptor.operation == .upsert,
                  descriptor.canonicalID == summary.canonicalID,
                  descriptor.revision == summary.revision else {
                throw DomainValidationError.invalidState(
                    reason: "A materialized upsert must match its descriptor."
                )
            }
        case .tombstone(let tombstone):
            guard descriptor.operation == .tombstone,
                  descriptor.canonicalID == tombstone.canonicalID,
                  descriptor.revision == tombstone.revision else {
                throw DomainValidationError.invalidState(
                    reason: "A materialized tombstone must match its descriptor."
                )
            }
        }
        self.descriptor = descriptor
        self.value = value
    }
}

/// One transactionally anchored change-log read. `currentCursor` is the
/// canonical high-water mark observed by the same SQLite snapshot as `changes`.
public struct AnchoredLibraryChangePage: Equatable, Sendable {
    public let libraryID: LibraryID
    public let requestedAfter: ChangeCursor
    public let currentCursor: ChangeCursor
    public let throughCursor: ChangeCursor
    public let firstStoredCursor: ChangeCursor?
    public let selectedDescriptorCount: Int
    public let changes: [MaterializedLibraryChange]

    public init(
        libraryID: LibraryID,
        requestedAfter: ChangeCursor,
        currentCursor: ChangeCursor,
        throughCursor: ChangeCursor,
        firstStoredCursor: ChangeCursor?,
        selectedDescriptorCount: Int,
        changes: [MaterializedLibraryChange]
    ) throws {
        guard requestedAfter <= currentCursor,
              requestedAfter <= throughCursor,
              throughCursor <= currentCursor,
              selectedDescriptorCount >= changes.count else {
            throw DomainValidationError.invalidState(
                reason: "An anchored library change page has invalid cursor bounds."
            )
        }
        let cursors = changes.map(\.descriptor.cursor)
        guard cursors == cursors.sorted(),
              Set(cursors).count == cursors.count else {
            throw DomainValidationError.invalidOrdering(
                field: "AnchoredLibraryChangePage.changes"
            )
        }
        self.libraryID = libraryID
        self.requestedAfter = requestedAfter
        self.currentCursor = currentCursor
        self.throughCursor = throughCursor
        self.firstStoredCursor = firstStoredCursor
        self.selectedDescriptorCount = selectedDescriptorCount
        self.changes = changes
    }
}
