import Darwin
import Foundation
import GRDB
import HarcDomain

/// The exact canonical-library identity guarded by one lifetime writer lease.
public struct HostWriterIdentity: Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let hostStateID: HostStateID

    public init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostStateID: HostStateID
    ) {
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.hostStateID = hostStateID
    }
}

/// A canonical store reopened after process death with its exact Host writer
/// lease already installed. Callers must retain the lease for the full Host
/// service lifetime and disable it only during an intentional shutdown.
public struct RecoveredHostMode: Sendable {
    public let store: RecordingStore
    public let lease: HostWriterLease

    fileprivate init(store: RecordingStore, lease: HostWriterLease) {
        self.store = store
        self.lease = lease
    }
}

/// A process-lifetime proof that this `RecordingStore` owns the canonical
/// library's exclusive POSIX writer lease. The initializer is intentionally
/// unavailable to callers; only a successful Host-mode transition or exact
/// Host-mode recovery can mint one.
public final class HostWriterLease: @unchecked Sendable {
    public let identity: HostWriterIdentity
    public let lockFileURL: URL

    fileprivate let storeIdentifier: UUID
    fileprivate let token = UUID()
    fileprivate let fileLock: AdvisoryFileLock
    private let stateLock = NSLock()
    private var active = true

    fileprivate init(
        identity: HostWriterIdentity,
        storeIdentifier: UUID,
        fileLock: AdvisoryFileLock
    ) {
        self.identity = identity
        self.storeIdentifier = storeIdentifier
        self.fileLock = fileLock
        self.lockFileURL = fileLock.url
    }

    public var canonicalCommitCapability: HostCanonicalCommitCapability {
        HostCanonicalCommitCapability(lease: self)
    }

    fileprivate var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active && fileLock.isHeld
    }

    fileprivate func invalidate() {
        stateLock.lock()
        guard active else {
            stateLock.unlock()
            return
        }
        active = false
        stateLock.unlock()
        fileLock.release()
    }

    deinit {
        // Normal Host shutdown calls `disableHostMode(_:)`, which first writes
        // Standalone while this lock remains held. A dropped process/lease only
        // releases the OS lock; its Host marker deliberately survives.
        invalidate()
    }
}

/// Non-forgeable authority for the narrow remote canonical-commit API.
/// Retaining this value does not make an explicitly disabled lease valid.
public final class HostCanonicalCommitCapability: @unchecked Sendable {
    let lease: HostWriterLease

    /// Read-only tuple for application-service composition checks. This does
    /// not expose the lease token or make a retained, invalidated capability
    /// usable by the canonical commit API.
    public var identity: HostWriterIdentity { lease.identity }

    fileprivate init(lease: HostWriterLease) {
        self.lease = lease
    }
}

enum StoreWriteMode: Sendable {
    case inMemory
    case standalone(AdvisoryFileLock)
    case host(HostWriterLease)
}

final class StoreWriteAccess: @unchecked Sendable {
    let mode: StoreWriteMode

    init(mode: StoreWriteMode) {
        self.mode = mode
    }

    func validate(in database: Database) throws {
        switch mode {
        case .inMemory:
            return
        case .standalone:
            let metadata = try RecordingStore.readLibraryMetadata(in: database)
            guard metadata.writerMode == .standalone else {
                throw StoreError.staleHostWriterMarker
            }
        case .host(let lease):
            guard lease.isActive else {
                throw StoreError.hostWriterCapabilityRequired
            }
            let metadata = try RecordingStore.readLibraryMetadata(in: database)
            guard metadata.writerMode == .host,
                  metadata.libraryID == lease.identity.libraryID,
                  metadata.hostAuthorityID == lease.identity.hostAuthorityID,
                  metadata.hostStateID == lease.identity.hostStateID
            else {
                throw StoreError.hostWriterTupleMismatch
            }
        }
    }
}

struct StoreDatabaseAccess {
    let queue: DatabaseQueue
    let writerCoordinator: StoreWriterCoordinator
    let waitForLock: Bool

    func read<T>(
        _ value: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        let access = try writerCoordinator.beginReadAccess(
            waitForLock: waitForLock
        )
        return try await queue.read { database in
            try access.validate(in: database)
            return try value(database)
        }
    }

    func write<T>(
        _ updates: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        let access = try writerCoordinator.beginWriteAccess(
            waitForLock: waitForLock
        )
        return try await queue.write { database in
            try access.validate(in: database)
            return try updates(database)
        }
    }
}

final class StoreWriterCoordinator: @unchecked Sendable {
    let storeIdentifier: UUID
    let databaseURL: URL?
    let lockFileURL: URL?

    private let stateLock = NSLock()
    private var activeHostLease: HostWriterLease?

    init(inMemoryIdentifier: UUID) {
        self.storeIdentifier = inMemoryIdentifier
        self.databaseURL = nil
        self.lockFileURL = nil
    }

    init(databaseURL: URL) throws {
        self.storeIdentifier = UUID()
        let paths = try AdvisoryFileLock.validatedPaths(for: databaseURL)
        self.databaseURL = paths.databaseURL
        self.lockFileURL = paths.lockFileURL
    }

    func beginReadAccess(waitForLock: Bool) throws -> StoreWriteAccess {
        stateLock.lock()
        let lease = activeHostLease
        stateLock.unlock()

        if let lease {
            guard lease.isActive else {
                throw StoreError.hostWriterCapabilityRequired
            }
            return StoreWriteAccess(mode: .host(lease))
        }
        guard let lockFileURL else {
            return StoreWriteAccess(mode: .inMemory)
        }
        return StoreWriteAccess(
            mode: .standalone(
                try AdvisoryFileLock.acquireShared(
                    at: lockFileURL,
                    wait: waitForLock
                )
            )
        )
    }

    func beginWriteAccess(waitForLock: Bool) throws -> StoreWriteAccess {
        stateLock.lock()
        let lease = activeHostLease
        stateLock.unlock()

        if let lease {
            guard lease.isActive else {
                throw StoreError.hostWriterCapabilityRequired
            }
            return StoreWriteAccess(mode: .host(lease))
        }
        guard let lockFileURL else {
            return StoreWriteAccess(mode: .inMemory)
        }
        return StoreWriteAccess(
            mode: .standalone(
                try AdvisoryFileLock.acquireExclusive(
                    at: lockFileURL,
                    wait: waitForLock
                )
            )
        )
    }

    func acquireHostFileLock(waitForLock: Bool) throws -> AdvisoryFileLock {
        stateLock.lock()
        let alreadyActive = activeHostLease != nil
        stateLock.unlock()
        guard !alreadyActive else { throw StoreError.writerLeaseUnavailable }
        guard let lockFileURL else {
            throw StoreError.invalidData("Host mode requires an on-disk canonical library")
        }
        return try AdvisoryFileLock.acquireExclusive(at: lockFileURL, wait: waitForLock)
    }

    func install(_ lease: HostWriterLease) throws {
        guard lease.storeIdentifier == storeIdentifier, lease.isActive else {
            throw StoreError.hostWriterCapabilityRequired
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeHostLease == nil else { throw StoreError.writerLeaseUnavailable }
        activeHostLease = lease
    }

    func requireInstalled(_ lease: HostWriterLease) throws {
        stateLock.lock()
        let installed = activeHostLease
        stateLock.unlock()
        guard installed === lease,
              lease.storeIdentifier == storeIdentifier,
              lease.isActive
        else {
            throw StoreError.hostWriterCapabilityRequired
        }
    }

    func remove(_ lease: HostWriterLease) throws {
        try requireInstalled(lease)
        stateLock.lock()
        activeHostLease = nil
        stateLock.unlock()
    }

    /// Models abrupt process termination for focused lease recovery tests: the
    /// file descriptor is closed but canonical metadata is intentionally not
    /// rewritten. This has the same persistent-state result as OS process death.
    func abandonHostLeaseForTesting(_ lease: HostWriterLease) throws {
        try remove(lease)
        lease.invalidate()
    }
}

final class AdvisoryFileLock: @unchecked Sendable {
    let url: URL

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    var isHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return descriptor >= 0
    }

    static func validatedPaths(for requestedDatabaseURL: URL) throws -> (
        databaseURL: URL,
        lockFileURL: URL
    ) {
        guard requestedDatabaseURL.isFileURL else {
            throw StoreError.unsafeWriterLeasePath("database URL is not a file URL")
        }

        let standardized = requestedDatabaseURL.standardizedFileURL
        let requestedParent = standardized.deletingLastPathComponent()
        try rejectSymlink(at: requestedParent, label: "database parent")

        let resolvedParent = requestedParent.resolvingSymlinksInPath()
        var parentInfo = stat()
        guard lstat(resolvedParent.path, &parentInfo) == 0 else {
            throw unsafePOSIX("cannot inspect database parent")
        }
        guard fileType(parentInfo.st_mode) == mode_t(S_IFDIR) else {
            throw StoreError.unsafeWriterLeasePath("database parent is not a directory")
        }
        guard parentInfo.st_uid == geteuid() else {
            throw StoreError.unsafeWriterLeasePath("database parent is not owned by the current user")
        }
        guard (parentInfo.st_mode & mode_t(0o022)) == 0 else {
            throw StoreError.unsafeWriterLeasePath("database parent is group- or world-writable")
        }

        let resolvedDatabaseURL = resolvedParent
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: false)
        try validateExistingRegularFile(
            at: resolvedDatabaseURL,
            label: "database",
            requireSingleLink: true
        )
        return (
            resolvedDatabaseURL,
            URL(fileURLWithPath: resolvedDatabaseURL.path + ".writer.lock")
        )
    }

    static func acquireExclusive(at url: URL, wait: Bool) throws -> AdvisoryFileLock {
        try acquire(at: url, operation: LOCK_EX, wait: wait)
    }

    static func acquireShared(at url: URL, wait: Bool) throws -> AdvisoryFileLock {
        try acquire(at: url, operation: LOCK_SH, wait: wait)
    }

    private static func acquire(
        at url: URL,
        operation: Int32,
        wait: Bool
    ) throws -> AdvisoryFileLock {
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let descriptor = url.path.withCString { path in
            Darwin.open(path, flags, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw unsafePOSIX("cannot open writer lock")
        }

        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw unsafePOSIX("cannot inspect writer lock")
            }
            guard fileType(info.st_mode) == mode_t(S_IFREG),
                  info.st_uid == geteuid(),
                  info.st_nlink == 1
            else {
                throw StoreError.unsafeWriterLeasePath(
                    "writer lock must be a current-user-owned regular file with one link"
                )
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw unsafePOSIX("cannot restrict writer lock permissions")
            }
            guard flock(descriptor, operation | (wait ? 0 : LOCK_NB)) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw StoreError.writerLeaseUnavailable
                }
                throw unsafePOSIX("cannot acquire writer lock")
            }
            return AdvisoryFileLock(url: url, descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func release() {
        stateLock.lock()
        let oldDescriptor = descriptor
        descriptor = -1
        stateLock.unlock()
        guard oldDescriptor >= 0 else { return }
        _ = flock(oldDescriptor, LOCK_UN)
        Darwin.close(oldDescriptor)
    }

    deinit { release() }

    private static func rejectSymlink(at url: URL, label: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw unsafePOSIX("cannot inspect \(label)")
        }
        guard fileType(info.st_mode) != mode_t(S_IFLNK) else {
            throw StoreError.unsafeWriterLeasePath("\(label) is a symbolic link")
        }
    }

    private static func validateExistingRegularFile(
        at url: URL,
        label: String,
        requireSingleLink: Bool
    ) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw unsafePOSIX("cannot inspect \(label)") }
            return
        }
        guard fileType(info.st_mode) != mode_t(S_IFLNK) else {
            throw StoreError.unsafeWriterLeasePath("\(label) is a symbolic link")
        }
        guard fileType(info.st_mode) == mode_t(S_IFREG) else {
            throw StoreError.unsafeWriterLeasePath("\(label) is not a regular file")
        }
        guard info.st_uid == geteuid() else {
            throw StoreError.unsafeWriterLeasePath("\(label) is not owned by the current user")
        }
        if requireSingleLink, info.st_nlink != 1 {
            throw StoreError.unsafeWriterLeasePath("\(label) has multiple hard links")
        }
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & mode_t(S_IFMT)
    }

    private static func unsafePOSIX(_ context: String) -> StoreError {
        StoreError.unsafeWriterLeasePath("\(context): \(String(cString: strerror(errno)))")
    }
}

public extension RecordingStore {
    /// Reopen a canonical database left in Host mode by process death. The
    /// independently validated identity is installed as the lifetime writer
    /// lease before the database is opened or any pending schema migration can
    /// run. Failure releases only the OS lock; it never clears the Host marker.
    static func recoverHostMode(
        onDiskAt url: URL = defaultURL(),
        expectedLibraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostStateID: HostStateID,
        waitForLock: Bool = true
    ) async throws -> RecoveredHostMode {
        try recoverHostMode(
            onDiskAt: url,
            expectedLibraryID: expectedLibraryID,
            hostAuthorityID: hostAuthorityID,
            hostStateID: hostStateID,
            waitForLock: waitForLock,
            migrator: DatabaseMigrator.harcMigrator()
        )
    }

    /// `@testable` seam for exercising a migration that does not yet ship in
    /// the production migrator.
    static func recoverHostModeForTesting(
        onDiskAt url: URL,
        expectedLibraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostStateID: HostStateID,
        waitForLock: Bool,
        migrator: DatabaseMigrator
    ) throws -> RecoveredHostMode {
        try recoverHostMode(
            onDiskAt: url,
            expectedLibraryID: expectedLibraryID,
            hostAuthorityID: hostAuthorityID,
            hostStateID: hostStateID,
            waitForLock: waitForLock,
            migrator: migrator
        )
    }

    private static func recoverHostMode(
        onDiskAt url: URL,
        expectedLibraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostStateID: HostStateID,
        waitForLock: Bool,
        migrator: DatabaseMigrator
    ) throws -> RecoveredHostMode {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let writerCoordinator = try StoreWriterCoordinator(databaseURL: url)
        guard let databaseURL = writerCoordinator.databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path)
        else {
            throw StoreError.databaseOpenFailed(
                "Host recovery requires an existing canonical database"
            )
        }

        let identity = HostWriterIdentity(
            libraryID: expectedLibraryID,
            hostAuthorityID: hostAuthorityID,
            hostStateID: hostStateID
        )
        let fileLock = try writerCoordinator.acquireHostFileLock(waitForLock: waitForLock)
        let lease = HostWriterLease(
            identity: identity,
            storeIdentifier: writerCoordinator.storeIdentifier,
            fileLock: fileLock
        )
        do {
            try writerCoordinator.install(lease)
        } catch {
            lease.invalidate()
            throw error
        }

        let dbQueue: DatabaseQueue
        do {
            var configuration = Configuration()
            configuration.busyMode = .timeout(5)
            dbQueue = try DatabaseQueue(
                path: databaseURL.path,
                configuration: configuration
            )
        } catch {
            try? writerCoordinator.remove(lease)
            lease.invalidate()
            throw StoreError.databaseOpenFailed(error.localizedDescription)
        }

        do {
            let beforeMigration = try dbQueue.unsafeRead { database in
                try Self.readLibraryMetadata(in: database)
            }
            guard beforeMigration.writerMode == .host,
                  beforeMigration.libraryID == expectedLibraryID,
                  beforeMigration.hostAuthorityID == hostAuthorityID,
                  beforeMigration.hostStateID == hostStateID
            else { throw StoreError.hostWriterTupleMismatch }

            try migrator.migrate(dbQueue)

            let afterMigration = try dbQueue.unsafeRead { database in
                try Self.readLibraryMetadata(in: database)
            }
            guard afterMigration.writerMode == .host,
                  afterMigration.libraryID == expectedLibraryID,
                  afterMigration.hostAuthorityID == hostAuthorityID,
                  afterMigration.hostStateID == hostStateID
            else { throw StoreError.hostWriterTupleMismatch }

            return RecoveredHostMode(
                store: RecordingStore(
                    dbQueue: dbQueue,
                    writerCoordinator: writerCoordinator
                ),
                lease: lease
            )
        } catch {
            try? writerCoordinator.remove(lease)
            lease.invalidate()
            if let storeError = error as? StoreError { throw storeError }
            throw StoreError.migrationFailed(error.localizedDescription)
        }
    }

    /// Wait for the canonical writer lock, atomically switch a Standalone
    /// library to the exact Host tuple, then retain the same lock for the Host
    /// lifetime. Existing dormant identity markers must either be absent or
    /// match exactly; this method never silently replaces an authority.
    func enableHostMode(
        expectedLibraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostStateID: HostStateID,
        waitForLock: Bool = true
    ) async throws -> HostWriterLease {
        let identity = HostWriterIdentity(
            libraryID: expectedLibraryID,
            hostAuthorityID: hostAuthorityID,
            hostStateID: hostStateID
        )
        let fileLock = try writerCoordinator.acquireHostFileLock(waitForLock: waitForLock)
        let lease = HostWriterLease(
            identity: identity,
            storeIdentifier: writerCoordinator.storeIdentifier,
            fileLock: fileLock
        )

        do {
            // Install before the first suspension. Reentrant actor calls then
            // fail against the not-yet-transitioned marker instead of taking a
            // Standalone access path that blocks on this lifetime flock.
            try writerCoordinator.install(lease)
            try await uncoordinatedDB.write { database in
                let metadata = try Self.readLibraryMetadata(in: database)
                guard metadata.libraryID == expectedLibraryID else {
                    throw StoreError.hostWriterTupleMismatch
                }
                guard metadata.writerMode == .standalone else {
                    throw StoreError.staleHostWriterMarker
                }
                let dormantPairIsEmpty = metadata.hostAuthorityID == nil
                    && metadata.hostStateID == nil
                let dormantPairMatches = metadata.hostAuthorityID == hostAuthorityID
                    && metadata.hostStateID == hostStateID
                guard dormantPairIsEmpty || dormantPairMatches else {
                    throw StoreError.hostWriterTupleMismatch
                }

                let now = Date()
                try database.execute(
                    sql: """
                        UPDATE library_metadata
                        SET writer_mode = 'host', host_authority_id = ?,
                            host_state_uuid = ?, updated_at = ?
                        WHERE id = 1 AND library_uuid = ? AND writer_mode = 'standalone'
                        """,
                    arguments: [
                        hostAuthorityID.rawBytes,
                        hostStateID.description,
                        now,
                        expectedLibraryID.description,
                    ]
                )
                guard database.changesCount == 1 else {
                    throw StoreError.hostWriterTupleMismatch
                }
            }
            return lease
        } catch {
            try? writerCoordinator.remove(lease)
            lease.invalidate()
            throw error
        }
    }

    /// Recover a process-death Host marker only when the caller already has the
    /// exact independently validated tuple from Host state and key storage.
    /// This method never resets or invents identity.
    func resumeHostMode(
        expectedLibraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostStateID: HostStateID,
        waitForLock: Bool = true
    ) async throws -> HostWriterLease {
        let identity = HostWriterIdentity(
            libraryID: expectedLibraryID,
            hostAuthorityID: hostAuthorityID,
            hostStateID: hostStateID
        )
        let fileLock = try writerCoordinator.acquireHostFileLock(waitForLock: waitForLock)
        let lease = HostWriterLease(
            identity: identity,
            storeIdentifier: writerCoordinator.storeIdentifier,
            fileLock: fileLock
        )
        do {
            // As in enable, publish the held lease before awaiting GRDB so no
            // reentrant writer can choose a Standalone access path and block.
            try writerCoordinator.install(lease)
            let metadata = try await uncoordinatedDB.read { database in
                try Self.readLibraryMetadata(in: database)
            }
            guard metadata.writerMode == .host,
                  metadata.libraryID == expectedLibraryID,
                  metadata.hostAuthorityID == hostAuthorityID,
                  metadata.hostStateID == hostStateID
            else {
                throw StoreError.hostWriterTupleMismatch
            }
            return lease
        } catch {
            try? writerCoordinator.remove(lease)
            lease.invalidate()
            throw error
        }
    }

    /// Disable Host mode while its lifetime lock is still held. Authority and
    /// state remain as dormant consistency markers for the next exact enable.
    func disableHostMode(_ lease: HostWriterLease) async throws {
        try writerCoordinator.requireInstalled(lease)
        try await uncoordinatedDB.write { database in
            let metadata = try Self.readLibraryMetadata(in: database)
            guard metadata.writerMode == .host,
                  metadata.libraryID == lease.identity.libraryID,
                  metadata.hostAuthorityID == lease.identity.hostAuthorityID,
                  metadata.hostStateID == lease.identity.hostStateID
            else {
                throw StoreError.hostWriterTupleMismatch
            }
            try database.execute(
                sql: """
                    UPDATE library_metadata
                    SET writer_mode = 'standalone', updated_at = ?
                    WHERE id = 1 AND library_uuid = ? AND writer_mode = 'host'
                      AND host_authority_id = ? AND host_state_uuid = ?
                    """,
                arguments: [
                    Date(),
                    lease.identity.libraryID.description,
                    lease.identity.hostAuthorityID.rawBytes,
                    lease.identity.hostStateID.description,
                ]
            )
            guard database.changesCount == 1 else {
                throw StoreError.hostWriterTupleMismatch
            }
        }
        try writerCoordinator.remove(lease)
        lease.invalidate()
    }

    internal func abandonHostLeaseForTesting(_ lease: HostWriterLease) throws {
        try writerCoordinator.abandonHostLeaseForTesting(lease)
    }
}
