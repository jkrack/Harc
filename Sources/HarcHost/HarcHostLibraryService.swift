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

/// Canonical library read application for authenticated host clients.
///
/// Snapshot materialization is held only in this resident process, is bound to
/// the live session's device/grant/epoch/scope set, and expires after thirty
/// minutes. Beginning another snapshot invalidates the prior one for that
/// device. The transport layer chooses a smaller item limit when necessary to
/// enforce its exact decoded protobuf byte ceiling.
public actor HarcHostLibraryService {
    public static let snapshotLifetime: TimeInterval = 30 * 60
    public static let maximumSnapshotItems = 100_000
    public static let maximumPageItems = 1_000

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

    private let store: RecordingStore
    private let randomness: any HostAuthenticationRandomness
    private let now: @Sendable () -> Date
    private var snapshotsByDevice: [DeviceID: Snapshot] = [:]

    public init(
        store: RecordingStore,
        randomness: any HostAuthenticationRandomness =
            SystemHostAuthenticationRandomness(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.randomness = randomness
        self.now = now
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

    private func pruneExpiredSnapshots() throws {
        let current = now()
        guard current.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostLibraryError.snapshotExpired
        }
        snapshotsByDevice = snapshotsByDevice.filter {
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
}
