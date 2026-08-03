import Foundation
import GRDB
import HarcDomain

/// Immutable, host-generated values needed to bind an already durable
/// canonical WAV to one producing-device origin.
public struct HostCanonicalRecordingCommitRequest: Equatable, Sendable {
    public let canonicalID: CanonicalRecordingID
    public let originID: OriginRecordingID
    public let canonicalPCMHash: CanonicalPCMHash
    public let canonicalPCMFrames: UInt64
    public let canonicalWAVURL: URL
    public let artifactIdentity: HostCanonicalArtifactIdentity
    public let startedAt: Date
    public let endedAt: Date?

    public init(
        canonicalID: CanonicalRecordingID,
        originID: OriginRecordingID,
        canonicalPCMHash: CanonicalPCMHash,
        canonicalPCMFrames: UInt64,
        canonicalWAVURL: URL,
        artifactIdentity: HostCanonicalArtifactIdentity,
        startedAt: Date,
        endedAt: Date?
    ) throws {
        guard canonicalID.rawValue != Self.zeroUUID,
              originID.recordingUUID != Self.zeroUUID
        else {
            throw StoreError.invalidData("Canonical and origin recording IDs must be nonzero")
        }
        guard canonicalPCMFrames > 0,
              Int64(exactly: canonicalPCMFrames) != nil
        else {
            throw StoreError.invalidData(
                "Canonical PCM frame count must fit SQLite and be positive"
            )
        }
        guard canonicalWAVURL.isFileURL,
              canonicalWAVURL.path.hasPrefix("/"),
              !canonicalWAVURL.path.contains("\0"),
              canonicalWAVURL.standardizedFileURL.path == canonicalWAVURL.path
        else {
            throw StoreError.invalidData("Canonical WAV path must be absolute and normalized")
        }
        guard startedAt.timeIntervalSince1970.isFinite,
              endedAt?.timeIntervalSince1970.isFinite != false,
              endedAt.map({ $0 >= startedAt }) ?? true
        else {
            throw StoreError.invalidData("Canonical recording timestamps are invalid")
        }

        try artifactIdentity.validatePathBinding(at: canonicalWAVURL)

        self.canonicalID = canonicalID
        self.originID = originID
        self.canonicalPCMHash = canonicalPCMHash
        self.canonicalPCMFrames = canonicalPCMFrames
        self.canonicalWAVURL = canonicalWAVURL
        self.artifactIdentity = artifactIdentity
        self.startedAt = try Self.exactMillisecondDate(startedAt, field: "startedAt")
        self.endedAt = try endedAt.map {
            try Self.exactMillisecondDate($0, field: "endedAt")
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private static func exactMillisecondDate(_ value: Date, field: String) throws -> Date {
        let milliseconds = value.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= 9_007_199_254_740_991,
              let exact = UInt64(exactly: milliseconds.rounded(.towardZero))
        else {
            throw StoreError.invalidData("\(field) is outside the Unix-millisecond range")
        }
        return Date(timeIntervalSince1970: Double(exact) / 1_000)
    }
}

/// Receipt claims sourced from the one durable canonical-library transaction.
/// The local SQLite primary key and filesystem path remain intentionally absent.
public struct HostCanonicalRecordingCommitResult: Equatable, Sendable {
    public let canonicalID: CanonicalRecordingID
    public let revision: EntityRevision
    public let changeCursor: ChangeCursor
    public let durableCommitTime: Date
    public let durableCommitUnixMilliseconds: UInt64
    public let replayed: Bool

    public init(
        canonicalID: CanonicalRecordingID,
        revision: EntityRevision,
        changeCursor: ChangeCursor,
        durableCommitTime: Date,
        durableCommitUnixMilliseconds: UInt64,
        replayed: Bool
    ) {
        self.canonicalID = canonicalID
        self.revision = revision
        self.changeCursor = changeCursor
        self.durableCommitTime = durableCommitTime
        self.durableCommitUnixMilliseconds = durableCommitUnixMilliseconds
        self.replayed = replayed
    }
}

public extension RecordingStore {
    /// Atomically inserts the pending-processing row and its sole revision-one
    /// change-log entry, or returns the exact original commit evidence for an
    /// identical replay. Only a capability tied to this store's live Host
    /// writer lease can enter this path.
    func commitCanonicalRemoteRecording(
        _ request: HostCanonicalRecordingCommitRequest,
        using capability: HostCanonicalCommitCapability
    ) async throws -> HostCanonicalRecordingCommitResult {
        let lease = capability.lease
        try writerCoordinator.requireInstalled(lease)

        do {
            let result = try await uncoordinatedDB.write { database in
                let metadata = try Self.readLibraryMetadata(in: database)
                guard metadata.writerMode == .host,
                      metadata.libraryID == lease.identity.libraryID,
                      metadata.hostAuthorityID == lease.identity.hostAuthorityID,
                      metadata.hostStateID == lease.identity.hostStateID
                else {
                    throw StoreError.hostWriterTupleMismatch
                }

                if let existing = try Recording
                    .filter(
                        Recording.Columns.originDeviceID
                            == request.originID.deviceID.rawBytes
                    )
                    .filter(
                        Recording.Columns.originRecordingUUID
                            == request.originID.recordingUUID.uuidString.lowercased()
                    )
                    .fetchOne(database)
                {
                    // GRDB's millisecond datetime text round-trip can differ
                    // from the original Foundation `Date` by a fraction of a
                    // microsecond. Canonical capture time is defined at Unix-
                    // millisecond precision, so compare that exact identity
                    // instead of the two floating-point representations.
                    let existingStartedAtMilliseconds = try Self.exactUnixMilliseconds(
                        existing.startedAt,
                        field: "existing.startedAt"
                    )
                    let requestStartedAtMilliseconds = try Self.exactUnixMilliseconds(
                        request.startedAt,
                        field: "request.startedAt"
                    )
                    let existingEndedAtMilliseconds = try existing.endedAt.map {
                        try Self.exactUnixMilliseconds($0, field: "existing.endedAt")
                    }
                    let requestEndedAtMilliseconds = try request.endedAt.map {
                        try Self.exactUnixMilliseconds($0, field: "request.endedAt")
                    }
                    guard existing.canonicalID == request.canonicalID,
                          existing.canonicalPCMHash == request.canonicalPCMHash,
                          existing.canonicalPCMFrames == request.canonicalPCMFrames,
                          existing.wavPath == request.canonicalWAVURL.path,
                          existingStartedAtMilliseconds == requestStartedAtMilliseconds,
                          existingEndedAtMilliseconds == requestEndedAtMilliseconds
                    else {
                        throw StoreError.originIdentityConflict
                    }
                    try request.artifactIdentity.validatePathBinding(
                        at: request.canonicalWAVURL
                    )
                    let result = try Self.originalHostCommitResult(
                        in: database,
                        canonicalID: existing.canonicalID,
                        replayed: true
                    )
                    try request.artifactIdentity.validatePathBinding(
                        at: request.canonicalWAVURL
                    )
                    return result
                }

                if try Recording
                    .filter(Recording.Columns.canonicalID == request.canonicalID.description)
                    .fetchCount(database) != 0
                {
                    throw StoreError.canonicalRecordingIdentityConflict
                }
                if try Recording
                    .filter(Recording.Columns.wavPath == request.canonicalWAVURL.path)
                    .fetchCount(database) != 0
                {
                    throw StoreError.canonicalRecordingPathConflict
                }
                let maximumStoredCursor = try Int64.fetchOne(
                    database,
                    sql: "SELECT COALESCE(MAX(cursor), 0) FROM library_changes"
                ) ?? 0
                guard metadata.currentChangeCursor.rawValue < UInt64(Int64.max),
                      maximumStoredCursor < Int64.max
                else {
                    throw StoreError.changeCursorOverflow
                }

                try request.artifactIdentity.validatePathBinding(
                    at: request.canonicalWAVURL
                )
                let committedAt = try Self.currentExactCommitClock().date
                var inserted = Recording(
                    wavPath: request.canonicalWAVURL.path,
                    startedAt: request.startedAt,
                    endedAt: request.endedAt,
                    createdAt: committedAt,
                    updatedAt: committedAt,
                    canonicalID: request.canonicalID,
                    originID: request.originID,
                    canonicalPCMHash: request.canonicalPCMHash,
                    canonicalPCMFrames: request.canonicalPCMFrames,
                    revision: .initial,
                    processing: .pending,
                    projection: .pending
                )
                try inserted.insert(database)
                inserted.id = database.lastInsertedRowID
                guard let recordingID = inserted.id, recordingID > 0 else {
                    throw StoreError.invalidData("Canonical recording row ID is invalid")
                }
                let storedCursor = try Self.appendLibraryChange(
                    in: database,
                    recordingID: recordingID,
                    operation: .upsert,
                    changedAt: committedAt
                )
                guard storedCursor > 0 else {
                    throw StoreError.invalidData("Canonical commit cursor is invalid")
                }

                let result = try Self.originalHostCommitResult(
                    in: database,
                    canonicalID: request.canonicalID,
                    replayed: false
                )
                try request.artifactIdentity.validatePathBinding(
                    at: request.canonicalWAVURL
                )
                return result
            }
            // GRDB commits after its transaction closure returns. Revalidate
            // once more after `write` itself completes so no caller can treat
            // the commit as successful after a post-closure path replacement.
            try request.artifactIdentity.validatePathBinding(
                at: request.canonicalWAVURL
            )
            return result
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}

extension RecordingStore {
    static func originalHostCommitResult(
        in database: Database,
        canonicalID: CanonicalRecordingID,
        replayed: Bool
    ) throws -> HostCanonicalRecordingCommitResult {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT cursor, revision, changed_at
                FROM library_changes
                WHERE entity_type = 'recording' AND entity_uuid = ?
                  AND revision = 1 AND operation = 'upsert' AND is_tombstone = 0
                """,
            arguments: [canonicalID.description]
        )
        guard rows.count == 1 else {
            throw StoreError.invalidData(
                "Canonical recording does not have exactly one durable initial change"
            )
        }
        let storedCursor: Int64 = rows[0]["cursor"]
        let storedRevision: Int64 = rows[0]["revision"]
        let changedAt: Date = rows[0]["changed_at"]
        guard storedCursor > 0,
              storedRevision == 1,
              changedAt.timeIntervalSince1970.isFinite
        else {
            throw StoreError.invalidData("Canonical commit evidence is invalid")
        }
        let durableMilliseconds = try exactUnixMilliseconds(
            changedAt,
            field: "durableCommitTime"
        )
        let durableCommitTime = Date(
            timeIntervalSince1970: Double(durableMilliseconds) / 1_000
        )
        return HostCanonicalRecordingCommitResult(
            canonicalID: canonicalID,
            revision: try EntityRevision(signedValue: storedRevision),
            changeCursor: try ChangeCursor(signedValue: storedCursor),
            durableCommitTime: durableCommitTime,
            durableCommitUnixMilliseconds: durableMilliseconds,
            replayed: replayed
        )
    }

    static func currentExactCommitClock() throws -> (milliseconds: UInt64, date: Date) {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > 0,
              milliseconds <= 9_007_199_254_740_991,
              let exact = UInt64(exactly: milliseconds.rounded(.towardZero))
        else {
            throw StoreError.invalidData("Current time is outside the Unix-millisecond range")
        }
        return (exact, Date(timeIntervalSince1970: Double(exact) / 1_000))
    }

    static func exactUnixMilliseconds(_ date: Date, field: String) throws -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= 9_007_199_254_740_991
        else {
            throw StoreError.invalidData("\(field) is outside the Unix-millisecond range")
        }
        let rounded = milliseconds.rounded()
        guard let exact = UInt64(exactly: rounded),
              abs(milliseconds - Double(exact)) <= 0.000_5
        else {
            throw StoreError.invalidData("\(field) is not exact to Unix milliseconds")
        }
        return exact
    }
}
