import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity
import HarcStore

public enum HarcHostLibraryError: Error, Equatable, Sendable {
    case invalidSnapshotToken
    case snapshotExpired
    case snapshotBindingMismatch
    case invalidPageToken
    case invalidPageLimit
    case snapshotCapacityExceeded
    case cursorAheadOfHost
    case recordingNotFound
    case invalidSearchQuery
    case recordingRevisionConflict
    case canonicalAudioUnavailable
    case invalidResumeOffset
    case canonicalAudioChanged
    case metadataMutationUnavailable
    case metadataMutationRateLimited
}

public enum HarcHostMetadataMutation: Codable, Equatable, Sendable {
    case setTitle(String?)
    case replaceTags([String])
    case setSpeakerLabel(index: UInt32, displayName: String?)
    case setNotesMarkdown(String?)
    case setPinned(Bool)
}

public enum HarcHostMetadataFieldValue: Codable, Equatable, Sendable {
    case title(String?)
    case tags([String])
    case speakerLabel(index: UInt32, displayName: String?)
    case notesMarkdown(String?)
    case pinned(Bool)
}

public enum HarcHostMetadataMutationResult: Codable, Equatable, Sendable {
    case applied(newRevision: EntityRevision, changeCursor: ChangeCursor)
    case conflict(currentRevision: EntityRevision, currentValue: HarcHostMetadataFieldValue)
}

public struct HarcHostMetadataMutationCommand: Sendable {
    public let operationID: OperationID
    public let issuedAt: Date
    public let expiresAt: Date
    public let canonicalID: CanonicalRecordingID
    public let expectedRevision: EntityRevision
    public let mutation: HarcHostMetadataMutation
    public let exactSignedRequestBytes: Data

    public init(
        operationID: OperationID,
        issuedAt: Date,
        expiresAt: Date,
        canonicalID: CanonicalRecordingID,
        expectedRevision: EntityRevision,
        mutation: HarcHostMetadataMutation,
        exactSignedRequestBytes: Data
    ) {
        self.operationID = operationID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.canonicalID = canonicalID
        self.expectedRevision = expectedRevision
        self.mutation = mutation
        self.exactSignedRequestBytes = exactSignedRequestBytes
    }
}

public enum HarcHostLibrarySnapshotItem: Equatable, Sendable {
    case recording(LibraryRecordingSummary)
    case tombstone(RecordingTombstone)

    public var canonicalID: CanonicalRecordingID {
        switch self {
        case .recording(let value): value.canonicalID
        case .tombstone(let value): value.canonicalID
        }
    }
}

public struct HarcHostLibrarySnapshotStart: Equatable, Sendable {
    public let anchor: ChangeCursor
    public let snapshotToken: Data
    public let expiresAt: Date
    public let recordingCount: UInt64
    public let tombstoneCount: UInt64
}

public struct HarcHostLibrarySnapshotPage: Equatable, Sendable {
    public let anchor: ChangeCursor
    public let items: [HarcHostLibrarySnapshotItem]
    public let nextPageToken: Data?
    public let complete: Bool
}

public enum HarcHostLibraryChangesResult: Equatable, Sendable {
    case page(
        changes: [MaterializedLibraryChange],
        nextCursor: ChangeCursor
    )
    case fullResyncRequired(currentCursor: ChangeCursor)
}

public struct HarcHostMetadataSearchFilter: Equatable, Sendable {
    public let titleContains: String?
    public let tagsAll: Set<String>
    public let tagsAny: Set<String>
    public let startedAtStart: Date?
    public let startedAtEnd: Date?
    public let speakerDisplayNames: Set<String>
    public let pinned: Bool?
    public let processingStates: [RecordingProcessingState]

    public init(
        titleContains: String? = nil,
        tagsAll: Set<String> = [],
        tagsAny: Set<String> = [],
        startedAtStart: Date? = nil,
        startedAtEnd: Date? = nil,
        speakerDisplayNames: Set<String> = [],
        pinned: Bool? = nil,
        processingStates: [RecordingProcessingState] = []
    ) {
        self.titleContains = titleContains
        self.tagsAll = tagsAll
        self.tagsAny = tagsAny
        self.startedAtStart = startedAtStart
        self.startedAtEnd = startedAtEnd
        self.speakerDisplayNames = speakerDisplayNames
        self.pinned = pinned
        self.processingStates = processingStates
    }
}

public enum HarcHostMetadataSearchSort: Equatable, Sendable {
    case startedAtDescending
    case startedAtAscending
    case titleAscending
}

public struct HarcHostTranscriptSearchFilter: Equatable, Sendable {
    public let canonicalRecordingIDs: Set<CanonicalRecordingID>
    public let tags: Set<String>
    public let startedAtStart: Date?
    public let startedAtEnd: Date?
    public let speakerIndices: Set<UInt32>

    public init(
        canonicalRecordingIDs: Set<CanonicalRecordingID> = [],
        tags: Set<String> = [],
        startedAtStart: Date? = nil,
        startedAtEnd: Date? = nil,
        speakerIndices: Set<UInt32> = []
    ) {
        self.canonicalRecordingIDs = canonicalRecordingIDs
        self.tags = tags
        self.startedAtStart = startedAtStart
        self.startedAtEnd = startedAtEnd
        self.speakerIndices = speakerIndices
    }
}

public enum HarcHostTranscriptSearchMode: Equatable, Sendable {
    case lexical
    case semantic
    case hybrid
}

public struct HarcHostMetadataSearchPage: Equatable, Sendable {
    public let recordings: [LibraryRecordingSummary]
    public let nextPageToken: Data?
}

public struct HarcHostTranscriptSearchSnippet: Equatable, Sendable {
    public let text: String
    public let frames: CanonicalFrameRange
    public let speakerIndex: UInt32?

    public init(
        text: String,
        frames: CanonicalFrameRange,
        speakerIndex: UInt32?
    ) {
        self.text = text
        self.frames = frames
        self.speakerIndex = speakerIndex
    }
}

public struct HarcHostTranscriptSearchHit: Equatable, Sendable {
    public let recording: LibraryRecordingSummary
    public let score: Double
    public let snippets: [HarcHostTranscriptSearchSnippet]

    public init(
        recording: LibraryRecordingSummary,
        score: Double,
        snippets: [HarcHostTranscriptSearchSnippet]
    ) {
        self.recording = recording
        self.score = score
        self.snippets = snippets
    }
}

public struct HarcHostTranscriptSearchPage: Equatable, Sendable {
    public let hits: [HarcHostTranscriptSearchHit]
    public let nextPageToken: Data?
}

/// Canonical library read application for authenticated host clients.
///
/// Snapshot materialization is held only in this resident process, is bound to
/// the live session's device/grant/epoch/scope set, and expires after thirty
/// minutes. Beginning another snapshot invalidates the prior one for that
/// device. The transport layer chooses a smaller item limit when necessary to
/// enforce its exact decoded protobuf byte ceiling.
public actor HarcHostLibraryService {
    public static let snapshotLifetime: TimeInterval = 30 * 60
    public static let searchLifetime: TimeInterval = 5 * 60
    public static let maximumSnapshotItems = 100_000
    public static let maximumPageItems = 1_000
    public static let maximumSearchPageItems = 200
    public static let maximumSearchContinuations = 128
    public static let metadataMutationRatePerMinute = 10.0
    public static let metadataMutationBurst = 20.0

    private struct SnapshotBinding: Equatable, Sendable {
        let context: AuthenticatedDeviceContext
        let scopes: [AuthorizationScope]
    }

    private struct Snapshot: Sendable {
        let binding: SnapshotBinding
        let anchor: ChangeCursor
        let token: Data
        let expiresAt: Date
        let recordingCount: UInt64
        let tombstoneCount: UInt64
        let preferredPageSize: Int
        let items: [HarcHostLibrarySnapshotItem]
        var pageTokensByOffset: [Int: Data]
        var offsetsByPageToken: [Data: Int]
    }

    private struct MetadataSearchRequest: Equatable, Sendable {
        let filter: HarcHostMetadataSearchFilter
        let sort: HarcHostMetadataSearchSort
        let limit: Int
    }

    private struct TranscriptSearchRequest: Equatable, Sendable {
        let query: String
        let mode: HarcHostTranscriptSearchMode
        let filter: HarcHostTranscriptSearchFilter
        let limit: Int
    }

    private enum SearchResultSet: Sendable {
        case metadata([LibraryRecordingSummary])
        case transcripts([HarcHostTranscriptSearchHit])
    }

    private enum SearchRequest: Equatable, Sendable {
        case metadata(MetadataSearchRequest)
        case transcripts(TranscriptSearchRequest)
    }

    private struct SearchContinuation: Sendable {
        let binding: SnapshotBinding
        let request: SearchRequest
        let results: SearchResultSet
        let offset: Int
        let expiresAt: Date
    }

    private struct MutationRateBucket: Sendable {
        var tokens: Double
        var updatedAt: Date
    }

    private let store: RecordingStore
    private let hostStore: HarcHostStore?
    private let randomness: any HostAuthenticationRandomness
    private let now: @Sendable () -> Date
    private let searchEmbedder: any TextEmbedder
    private var snapshotsByDevice: [DeviceID: Snapshot] = [:]
    private var searchContinuations: [Data: SearchContinuation] = [:]
    private var mutationRateBuckets: [DeviceID: MutationRateBucket] = [:]

    public init(
        store: RecordingStore,
        hostStore: HarcHostStore? = nil,
        randomness: any HostAuthenticationRandomness =
            SystemHostAuthenticationRandomness(),
        searchEmbedder: any TextEmbedder = HashedLexicalEmbedder(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.hostStore = hostStore
        self.randomness = randomness
        self.searchEmbedder = searchEmbedder
        self.now = now
    }

    public func applyMetadataMutation(
        session: HostAuthenticatedSession,
        command: HarcHostMetadataMutationCommand
    ) async throws -> HarcHostMetadataMutationResult {
        guard let hostStore else {
            throw HarcHostLibraryError.metadataMutationUnavailable
        }
        guard session.context.libraryID
                == (try await store.libraryMetadata()).libraryID else {
            throw HarcHostLibraryError.snapshotBindingMismatch
        }
        guard !command.exactSignedRequestBytes.isEmpty else {
            throw HarcHostLibraryError.metadataMutationUnavailable
        }
        try consumeMetadataMutationRateLimit(
            for: session.context.authenticatedDeviceID
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let effect = MetadataMutationPreparedEffect(
            canonicalID: command.canonicalID,
            expectedRevision: command.expectedRevision,
            mutation: command.mutation,
            exactRequestSHA256: Data(SHA256.hash(
                data: command.exactSignedRequestBytes
            ))
        )
        let preparedEffect = try encoder.encode(effect)
        let disposition = try await hostStore.prepareExternalOperationEffect(
            context: session.context,
            requiredScope: .libraryMetadataWrite,
            messageType: "library.metadata-mutation.v1",
            operationID: command.operationID,
            issuedAt: command.issuedAt,
            expiresAt: command.expiresAt,
            exactRequestBytes: command.exactSignedRequestBytes,
            preparedEffect: preparedEffect
        )
        if case .alreadyApplied(let originalResult) = disposition {
            return try decoder.decode(
                HarcHostMetadataMutationResult.self,
                from: originalResult
            )
        }

        let canonicalResult = try await store.applyCanonicalMetadataMutation(
            operationID: command.operationID,
            exactRequestSHA256: effect.exactRequestSHA256,
            canonicalID: command.canonicalID,
            expectedRevision: command.expectedRevision,
            mutation: command.mutation.canonicalStoreValue,
            at: hostStore.now()
        )
        let result = HarcHostMetadataMutationResult(canonicalResult)
        let resultBytes = try encoder.encode(result)
        let key = try HostOperationReplayKey(
            libraryID: session.context.libraryID,
            hostAuthorityID: session.context.hostAuthorityID,
            messageType: "library.metadata-mutation.v1",
            signer: .device(session.context.authenticatedDeviceID),
            operationID: command.operationID
        )
        _ = try await hostStore.markPreparedOperationApplied(
            key: key,
            exactRequestBytes: command.exactSignedRequestBytes,
            preparedEffect: preparedEffect,
            originalResult: resultBytes
        )
        return result
    }

    private func consumeMetadataMutationRateLimit(
        for deviceID: DeviceID
    ) throws {
        let current = now()
        guard current.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostLibraryError.metadataMutationUnavailable
        }
        var bucket = mutationRateBuckets[deviceID] ?? MutationRateBucket(
            tokens: Self.metadataMutationBurst,
            updatedAt: current
        )
        let elapsed = max(0, current.timeIntervalSince(bucket.updatedAt))
        bucket.tokens = min(
            Self.metadataMutationBurst,
            bucket.tokens
                + elapsed * Self.metadataMutationRatePerMinute / 60
        )
        bucket.updatedAt = current
        guard bucket.tokens >= 1 else {
            mutationRateBuckets[deviceID] = bucket
            throw HarcHostLibraryError.metadataMutationRateLimited
        }
        bucket.tokens -= 1
        mutationRateBuckets[deviceID] = bucket
    }

    public func beginSnapshot(
        session: HostAuthenticatedSession,
        preferredPageSize: Int
    ) async throws -> HarcHostLibrarySnapshotStart {
        guard (1 ... Self.maximumPageItems).contains(preferredPageSize) else {
            throw HarcHostLibraryError.invalidPageLimit
        }
        try pruneExpiredSnapshots()
        let anchored = try await store.anchoredLibrarySnapshot()
        guard anchored.libraryID == session.context.libraryID else {
            throw HarcHostLibraryError.snapshotBindingMismatch
        }
        let itemCount = anchored.recordings.count + anchored.tombstones.count
        guard itemCount <= Self.maximumSnapshotItems else {
            throw HarcHostLibraryError.snapshotCapacityExceeded
        }

        var items = anchored.recordings.map(
            HarcHostLibrarySnapshotItem.recording
        )
        items.append(contentsOf: anchored.tombstones.map(
            HarcHostLibrarySnapshotItem.tombstone
        ))
        items.sort { $0.canonicalID < $1.canonicalID }

        let token = try uniqueToken()
        let expiry = now().addingTimeInterval(Self.snapshotLifetime)
        let recordingCount = UInt64(anchored.recordings.count)
        let tombstoneCount = UInt64(anchored.tombstones.count)
        snapshotsByDevice[session.context.authenticatedDeviceID] = Snapshot(
            binding: SnapshotBinding(
                context: session.context,
                scopes: session.scopes
            ),
            anchor: anchored.anchor,
            token: token,
            expiresAt: expiry,
            recordingCount: recordingCount,
            tombstoneCount: tombstoneCount,
            preferredPageSize: preferredPageSize,
            items: items,
            pageTokensByOffset: [:],
            offsetsByPageToken: [:]
        )
        return HarcHostLibrarySnapshotStart(
            anchor: anchored.anchor,
            snapshotToken: token,
            expiresAt: expiry,
            recordingCount: recordingCount,
            tombstoneCount: tombstoneCount
        )
    }

    public func listSnapshotPage(
        session: HostAuthenticatedSession,
        snapshotToken: Data,
        pageToken: Data?,
        maximumItems: Int
    ) throws -> HarcHostLibrarySnapshotPage {
        guard (1 ... Self.maximumPageItems).contains(maximumItems) else {
            throw HarcHostLibraryError.invalidPageLimit
        }
        try pruneExpiredSnapshots()
        let deviceID = session.context.authenticatedDeviceID
        guard var snapshot = snapshotsByDevice[deviceID],
              snapshot.token == snapshotToken else {
            throw HarcHostLibraryError.invalidSnapshotToken
        }
        guard snapshot.binding == SnapshotBinding(
            context: session.context,
            scopes: session.scopes
        ) else {
            throw HarcHostLibraryError.snapshotBindingMismatch
        }

        let offset: Int
        if let pageToken {
            guard let storedOffset = snapshot.offsetsByPageToken[pageToken]
            else { throw HarcHostLibraryError.invalidPageToken }
            offset = storedOffset
        } else {
            offset = 0
        }
        guard offset <= snapshot.items.count else {
            throw HarcHostLibraryError.invalidPageToken
        }
        let pageItemLimit = min(maximumItems, snapshot.preferredPageSize)
        let end = min(offset + pageItemLimit, snapshot.items.count)
        let complete = end == snapshot.items.count
        let nextPageToken: Data?
        if complete {
            nextPageToken = nil
        } else if let existing = snapshot.pageTokensByOffset[end] {
            nextPageToken = existing
        } else {
            let created = try uniquePageToken(in: snapshot)
            snapshot.pageTokensByOffset[end] = created
            snapshot.offsetsByPageToken[created] = end
            nextPageToken = created
        }
        snapshotsByDevice[deviceID] = snapshot
        return HarcHostLibrarySnapshotPage(
            anchor: snapshot.anchor,
            items: Array(snapshot.items[offset ..< end]),
            nextPageToken: nextPageToken,
            complete: complete
        )
    }

    public func listChanges(
        session: HostAuthenticatedSession,
        after cursor: ChangeCursor,
        limit: Int
    ) async throws -> HarcHostLibraryChangesResult {
        guard (1 ... Self.maximumPageItems).contains(limit) else {
            throw HarcHostLibraryError.invalidPageLimit
        }
        let page: AnchoredLibraryChangePage
        do {
            page = try await store.anchoredMaterializedLibraryChanges(
                after: cursor,
                limit: limit
            )
        } catch {
            let metadata = try await store.libraryMetadata()
            if cursor > metadata.currentChangeCursor {
                throw HarcHostLibraryError.cursorAheadOfHost
            }
            throw error
        }
        guard page.libraryID == session.context.libraryID else {
            throw HarcHostLibraryError.snapshotBindingMismatch
        }
        guard cursor <= page.currentCursor else {
            throw HarcHostLibraryError.cursorAheadOfHost
        }
        if cursor < page.currentCursor {
            let expectedNext = cursor.rawValue.addingReportingOverflow(1)
            if expectedNext.overflow
                || page.firstStoredCursor.map({
                    $0.rawValue > expectedNext.partialValue
                }) ?? true
                || page.selectedDescriptorCount == 0 {
                return .fullResyncRequired(
                    currentCursor: page.currentCursor
                )
            }
        }
        return .page(
            changes: page.changes,
            nextCursor: page.throughCursor
        )
    }

    public func recording(
        session: HostAuthenticatedSession,
        canonicalID: CanonicalRecordingID
    ) async throws -> LibraryRecordingDetail {
        guard let detail = try await store.recordingDetail(
            canonicalID: canonicalID
        ) else {
            throw HarcHostLibraryError.recordingNotFound
        }
        return detail
    }

    public func prepareAudioDownload(
        session: HostAuthenticatedSession,
        canonicalID: CanonicalRecordingID,
        expectedRevision: EntityRevision
    ) async throws -> HarcHostPreparedAudioDownload {
        guard try await store.libraryMetadata().libraryID
                == session.context.libraryID else {
            throw HarcHostLibraryError.snapshotBindingMismatch
        }
        guard let recording = try await store.fetch(canonicalID: canonicalID),
              recording.deletedAt == nil else {
            throw HarcHostLibraryError.recordingNotFound
        }
        guard recording.revision == expectedRevision else {
            throw HarcHostLibraryError.recordingRevisionConflict
        }
        guard let pcmHash = recording.canonicalPCMHash,
              let totalFrames = recording.canonicalPCMFrames else {
            throw HarcHostLibraryError.canonicalAudioUnavailable
        }
        let fileURL = URL(fileURLWithPath: recording.wavPath)
        let reader = try await Task.detached(priority: .userInitiated) {
            try HarcHostCanonicalAudioReader(
                canonicalID: canonicalID,
                revision: expectedRevision,
                fileURL: fileURL,
                canonicalPCMSHA256: pcmHash,
                totalCanonicalFrames: totalFrames
            )
        }.value
        return HarcHostPreparedAudioDownload(
            descriptor: reader.descriptor,
            reader: reader
        )
    }

    public func searchMetadata(
        session: HostAuthenticatedSession,
        filter: HarcHostMetadataSearchFilter,
        sort: HarcHostMetadataSearchSort,
        limit: Int,
        pageToken: Data?
    ) async throws -> HarcHostMetadataSearchPage {
        try validateSearchLimit(limit)
        try validateDateRange(
            start: filter.startedAtStart,
            end: filter.startedAtEnd
        )
        let request = MetadataSearchRequest(
            filter: filter,
            sort: sort,
            limit: limit
        )
        if let pageToken {
            let (results, next) = try consumeMetadataContinuation(
                token: pageToken,
                session: session,
                request: request
            )
            return HarcHostMetadataSearchPage(
                recordings: results,
                nextPageToken: next
            )
        }

        let rows = try await store.libraryMetadataSearchRecords()
        var matches = rows.filter { Self.matches($0, filter: filter) }
        matches.sort { Self.metadataOrder($0, $1, sort: sort) }
        let values = matches.map(\.summary)
        let (page, next) = try firstSearchPage(
            values,
            limit: limit,
            session: session,
            request: .metadata(request),
            wrap: SearchResultSet.metadata
        )
        return HarcHostMetadataSearchPage(
            recordings: page,
            nextPageToken: next
        )
    }

    public func searchTranscripts(
        session: HostAuthenticatedSession,
        query: String,
        mode: HarcHostTranscriptSearchMode,
        filter: HarcHostTranscriptSearchFilter,
        limit: Int,
        pageToken: Data?
    ) async throws -> HarcHostTranscriptSearchPage {
        try validateSearchLimit(limit)
        try validateDateRange(
            start: filter.startedAtStart,
            end: filter.startedAtEnd
        )
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty,
              normalizedQuery.utf8.count <= 1_024 else {
            throw HarcHostLibraryError.invalidSearchQuery
        }
        let request = TranscriptSearchRequest(
            query: normalizedQuery,
            mode: mode,
            filter: filter,
            limit: limit
        )
        if let pageToken {
            let (results, next) = try consumeTranscriptContinuation(
                token: pageToken,
                session: session,
                request: request
            )
            return HarcHostTranscriptSearchPage(
                hits: results,
                nextPageToken: next
            )
        }

        let candidates: [LibraryTranscriptSearchRecord]
        switch mode {
        case .lexical:
            candidates = try await store.libraryLexicalTranscriptSearch(
                query: normalizedQuery
            )
        case .semantic:
            candidates = try await store.librarySemanticTranscriptSearch(
                query: normalizedQuery,
                embedder: searchEmbedder
            )
        case .hybrid:
            async let lexical = store.libraryLexicalTranscriptSearch(
                query: normalizedQuery
            )
            async let semantic = store.librarySemanticTranscriptSearch(
                query: normalizedQuery,
                embedder: searchEmbedder
            )
            candidates = Self.fuse(
                lexical: try await lexical,
                semantic: try await semantic
            )
        }
        let matches = candidates.filter {
            Self.matches($0, filter: filter)
        }
        let projected = matches.map(Self.hostTranscriptHit)
        let (page, next) = try firstSearchPage(
            projected,
            limit: limit,
            session: session,
            request: .transcripts(request),
            wrap: SearchResultSet.transcripts
        )
        return HarcHostTranscriptSearchPage(
            hits: page,
            nextPageToken: next
        )
    }

    private func pruneExpiredSnapshots() throws {
        let current = now()
        guard current.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostLibraryError.snapshotExpired
        }
        snapshotsByDevice = snapshotsByDevice.filter {
            current < $0.value.expiresAt
        }
        searchContinuations = searchContinuations.filter {
            current < $0.value.expiresAt
        }
    }

    private func uniqueToken() throws -> Data {
        for _ in 0 ..< 8 {
            let candidate = try randomness.randomBytes(count: 32)
            guard !snapshotsByDevice.values.contains(where: {
                $0.token == candidate
            }) else { continue }
            return candidate
        }
        throw HarcHostLibraryError.snapshotCapacityExceeded
    }

    private func uniquePageToken(in snapshot: Snapshot) throws -> Data {
        for _ in 0 ..< 8 {
            let candidate = try randomness.randomBytes(count: 24)
            guard snapshot.offsetsByPageToken[candidate] == nil else { continue }
            return candidate
        }
        throw HarcHostLibraryError.snapshotCapacityExceeded
    }

    private func validateSearchLimit(_ limit: Int) throws {
        guard (1 ... Self.maximumSearchPageItems).contains(limit) else {
            throw HarcHostLibraryError.invalidPageLimit
        }
    }

    private func validateDateRange(start: Date?, end: Date?) throws {
        guard start.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              end.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              start == nil || end == nil || start! <= end! else {
            throw HarcHostLibraryError.invalidSearchQuery
        }
    }

    private static func matches(
        _ row: LibraryMetadataSearchRecord,
        filter: HarcHostMetadataSearchFilter
    ) -> Bool {
        let summary = row.summary
        if let title = filter.titleContains,
           !(summary.title ?? summary.suggestedTitle ?? "")
            .localizedCaseInsensitiveContains(title) { return false }
        let tags = Set(summary.tags.map { $0.lowercased() })
        if !Set(filter.tagsAll.map({ $0.lowercased() })).isSubset(of: tags) {
            return false
        }
        let any = Set(filter.tagsAny.map { $0.lowercased() })
        if !any.isEmpty, tags.isDisjoint(with: any) { return false }
        if let start = filter.startedAtStart, summary.startedAt < start {
            return false
        }
        if let end = filter.startedAtEnd, summary.startedAt >= end {
            return false
        }
        if let pinned = filter.pinned, summary.pinned != pinned { return false }
        if !filter.processingStates.isEmpty,
           !filter.processingStates.contains(summary.processing.state) {
            return false
        }
        let labels = Set(row.speakerLabels.map {
            $0.displayName.lowercased()
        })
        return Set(filter.speakerDisplayNames.map { $0.lowercased() })
            .isSubset(of: labels)
    }

    private static func matches(
        _ row: LibraryTranscriptSearchRecord,
        filter: HarcHostTranscriptSearchFilter
    ) -> Bool {
        let summary = row.summary
        if !filter.canonicalRecordingIDs.isEmpty,
           !filter.canonicalRecordingIDs.contains(summary.canonicalID) {
            return false
        }
        let tags = Set(summary.tags.map { $0.lowercased() })
        if !Set(filter.tags.map({ $0.lowercased() })).isSubset(of: tags) {
            return false
        }
        if let start = filter.startedAtStart, summary.startedAt < start {
            return false
        }
        if let end = filter.startedAtEnd, summary.startedAt >= end {
            return false
        }
        return filter.speakerIndices.isSubset(of: row.speakerIndices)
    }

    private static func metadataOrder(
        _ lhs: LibraryMetadataSearchRecord,
        _ rhs: LibraryMetadataSearchRecord,
        sort: HarcHostMetadataSearchSort
    ) -> Bool {
        switch sort {
        case .startedAtDescending:
            if lhs.summary.startedAt != rhs.summary.startedAt {
                return lhs.summary.startedAt > rhs.summary.startedAt
            }
        case .startedAtAscending:
            if lhs.summary.startedAt != rhs.summary.startedAt {
                return lhs.summary.startedAt < rhs.summary.startedAt
            }
        case .titleAscending:
            let left = (lhs.summary.title ?? lhs.summary.suggestedTitle ?? "")
                .lowercased()
            let right = (rhs.summary.title ?? rhs.summary.suggestedTitle ?? "")
                .lowercased()
            if left != right { return left < right }
        }
        return lhs.summary.canonicalID < rhs.summary.canonicalID
    }

    private static func fuse(
        lexical: [LibraryTranscriptSearchRecord],
        semantic: [LibraryTranscriptSearchRecord],
        rrfK: Double = 60
    ) -> [LibraryTranscriptSearchRecord] {
        var scoreByID: [CanonicalRecordingID: Double] = [:]
        var resultByID: [CanonicalRecordingID: LibraryTranscriptSearchRecord]
            = [:]
        for (rank, result) in lexical.enumerated() {
            let id = result.summary.canonicalID
            scoreByID[id, default: 0] += 1 / (rrfK + Double(rank + 1))
            resultByID[id] = result
        }
        for (rank, result) in semantic.enumerated() {
            let id = result.summary.canonicalID
            scoreByID[id, default: 0] += 1 / (rrfK + Double(rank + 1))
            if resultByID[id] == nil { resultByID[id] = result }
        }
        return scoreByID.compactMap { id, score in
            guard let result = resultByID[id] else { return nil }
            return LibraryTranscriptSearchRecord(
                summary: result.summary,
                speakerIndices: result.speakerIndices,
                score: score,
                snippets: result.snippets
            )
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.summary.canonicalID < $1.summary.canonicalID
        }
    }

    private static func hostTranscriptHit(
        _ value: LibraryTranscriptSearchRecord
    ) -> HarcHostTranscriptSearchHit {
        HarcHostTranscriptSearchHit(
            recording: value.summary,
            score: value.score,
            snippets: value.snippets.map {
                HarcHostTranscriptSearchSnippet(
                    text: $0.text,
                    frames: $0.frames,
                    speakerIndex: $0.speakerIndex
                )
            }
        )
    }

    private func firstSearchPage<Value: Sendable>(
        _ values: [Value],
        limit: Int,
        session: HostAuthenticatedSession,
        request: SearchRequest,
        wrap: ([Value]) -> SearchResultSet
    ) throws -> ([Value], Data?) {
        try pruneExpiredSnapshots()
        let end = min(limit, values.count)
        guard end < values.count else {
            return (Array(values[..<end]), nil)
        }
        let token = try storeSearchContinuation(
            binding: SnapshotBinding(
                context: session.context,
                scopes: session.scopes
            ),
            request: request,
            results: wrap(values),
            offset: end
        )
        return (Array(values[..<end]), token)
    }

    private func consumeMetadataContinuation(
        token: Data,
        session: HostAuthenticatedSession,
        request: MetadataSearchRequest
    ) throws -> ([LibraryRecordingSummary], Data?) {
        let continuation = try consumeSearchContinuation(
            token: token,
            session: session,
            request: .metadata(request)
        )
        guard case .metadata(let values) = continuation.results else {
            throw HarcHostLibraryError.invalidPageToken
        }
        let end = min(continuation.offset + request.limit, values.count)
        let next = try nextSearchToken(
            after: end,
            continuation: continuation,
            count: values.count
        )
        return (Array(values[continuation.offset ..< end]), next)
    }

    private func consumeTranscriptContinuation(
        token: Data,
        session: HostAuthenticatedSession,
        request: TranscriptSearchRequest
    ) throws -> ([HarcHostTranscriptSearchHit], Data?) {
        let continuation = try consumeSearchContinuation(
            token: token,
            session: session,
            request: .transcripts(request)
        )
        guard case .transcripts(let values) = continuation.results else {
            throw HarcHostLibraryError.invalidPageToken
        }
        let end = min(continuation.offset + request.limit, values.count)
        let next = try nextSearchToken(
            after: end,
            continuation: continuation,
            count: values.count
        )
        return (Array(values[continuation.offset ..< end]), next)
    }

    private func consumeSearchContinuation(
        token: Data,
        session: HostAuthenticatedSession,
        request: SearchRequest
    ) throws -> SearchContinuation {
        try pruneExpiredSnapshots()
        guard token.count == 24,
              let continuation = searchContinuations.removeValue(forKey: token),
              continuation.binding == SnapshotBinding(
                context: session.context,
                scopes: session.scopes
              ),
              continuation.request == request else {
            throw HarcHostLibraryError.invalidPageToken
        }
        return continuation
    }

    private func nextSearchToken(
        after offset: Int,
        continuation: SearchContinuation,
        count: Int
    ) throws -> Data? {
        guard offset < count else { return nil }
        return try storeSearchContinuation(
            binding: continuation.binding,
            request: continuation.request,
            results: continuation.results,
            offset: offset
        )
    }

    private func storeSearchContinuation(
        binding: SnapshotBinding,
        request: SearchRequest,
        results: SearchResultSet,
        offset: Int
    ) throws -> Data {
        guard searchContinuations.count < Self.maximumSearchContinuations else {
            throw HarcHostLibraryError.snapshotCapacityExceeded
        }
        for _ in 0 ..< 8 {
            let token = try randomness.randomBytes(count: 24)
            guard searchContinuations[token] == nil else { continue }
            searchContinuations[token] = SearchContinuation(
                binding: binding,
                request: request,
                results: results,
                offset: offset,
                expiresAt: now().addingTimeInterval(Self.searchLifetime)
            )
            return token
        }
        throw HarcHostLibraryError.snapshotCapacityExceeded
    }
}

private struct MetadataMutationPreparedEffect: Codable, Equatable, Sendable {
    let canonicalID: CanonicalRecordingID
    let expectedRevision: EntityRevision
    let mutation: HarcHostMetadataMutation
    let exactRequestSHA256: Data
}

private extension HarcHostMetadataMutation {
    var canonicalStoreValue: CanonicalMetadataMutation {
        switch self {
        case .setTitle(let value): .setTitle(value)
        case .replaceTags(let value): .replaceTags(value)
        case .setSpeakerLabel(let index, let displayName):
            .setSpeakerLabel(index: index, displayName: displayName)
        case .setNotesMarkdown(let value): .setNotesMarkdown(value)
        case .setPinned(let value): .setPinned(value)
        }
    }
}

private extension HarcHostMetadataFieldValue {
    init(_ value: CanonicalMetadataFieldValue) {
        switch value {
        case .title(let value): self = .title(value)
        case .tags(let value): self = .tags(value)
        case .speakerLabel(let index, let displayName):
            self = .speakerLabel(index: index, displayName: displayName)
        case .notesMarkdown(let value): self = .notesMarkdown(value)
        case .pinned(let value): self = .pinned(value)
        }
    }
}

private extension HarcHostMetadataMutationResult {
    init(_ value: CanonicalMetadataMutationResult) {
        switch value {
        case .applied(let newRevision, let changeCursor):
            self = .applied(
                newRevision: newRevision,
                changeCursor: changeCursor
            )
        case .conflict(let currentRevision, let currentValue):
            self = .conflict(
                currentRevision: currentRevision,
                currentValue: HarcHostMetadataFieldValue(currentValue)
            )
        }
    }
}
