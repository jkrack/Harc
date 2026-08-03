import Foundation
import GRDB
import HarcDomain
import HarcTransfer

public enum ClientStoreDatabaseKind: String, Sendable {
    case transfer
    case libraryCache

    public var fileName: String {
        switch self {
        case .transfer: "HarcTransferStore.sqlite"
        case .libraryCache: "HarcLibraryCache.sqlite"
        }
    }
}

public enum ClientStoreProtection: String, Hashable, Sendable {
    case completeUntilFirstUserAuthentication
    case complete

    var foundationValue: FileProtectionType {
        switch self {
        case .completeUntilFirstUserAuthentication:
            .completeUntilFirstUserAuthentication
        case .complete:
            .complete
        }
    }
}

public struct ClientStoreStoragePolicy: Equatable, Hashable, Sendable {
    public let protection: ClientStoreProtection
    public let excludesFromBackup: Bool

    public init(protection: ClientStoreProtection, excludesFromBackup: Bool = true) {
        self.protection = protection
        self.excludesFromBackup = excludesFromBackup
    }

    public static let transfer = Self(protection: .completeUntilFirstUserAuthentication)
    public static let libraryCache = Self(protection: .complete)
}

public struct ClientStoreLocations: Equatable, Sendable {
    public let rootDirectory: URL
    public let transferDirectory: URL
    public let libraryCacheDirectory: URL
    public let transferDatabase: URL
    public let libraryCacheDatabase: URL

    public init(rootDirectory: URL) throws {
        guard rootDirectory.isFileURL else {
            throw ClientStoreError.nonFileURL(rootDirectory.absoluteString)
        }
        let standardizedRoot = rootDirectory.standardizedFileURL
        self.rootDirectory = standardizedRoot
        transferDirectory = standardizedRoot.appendingPathComponent(
            "Transfer",
            isDirectory: true
        )
        libraryCacheDirectory = standardizedRoot.appendingPathComponent(
            "LibraryCache",
            isDirectory: true
        )
        transferDatabase = transferDirectory.appendingPathComponent(
            ClientStoreDatabaseKind.transfer.fileName,
            isDirectory: false
        )
        libraryCacheDatabase = libraryCacheDirectory.appendingPathComponent(
            ClientStoreDatabaseKind.libraryCache.fileName,
            isDirectory: false
        )
    }
}

public enum ClientStoreStorageArtifact: Equatable, Sendable {
    case directory(URL)
    case database(URL)
    case sidecar(URL)

    var url: URL {
        switch self {
        case .directory(let url), .database(let url), .sidecar(let url): url
        }
    }
}

/// Injectable seam for iOS protected-data state and filesystem attributes.
/// Implementations must not create, delete, or mutate an artifact from
/// `applyAndVerify` when `isProtectedDataAvailable` is false.
public protocol ClientStoreStorageAttributeApplying: Sendable {
    func isProtectedDataAvailable(for policy: ClientStoreStoragePolicy) -> Bool
    func applyAndVerify(
        _ policy: ClientStoreStoragePolicy,
        to artifact: ClientStoreStorageArtifact
    ) throws
}

public enum ClientStoreStorageAttributeError: Error, Equatable, Sendable {
    case backupExclusionNotApplied(path: String)
    case protectionNotApplied(
        path: String,
        expected: ClientStoreProtection,
        actual: String
    )
}

/// Foundation implementation used by application composition. The app may
/// inject its protected-data availability probe (for example, UIKit's
/// `isProtectedDataAvailable`) without making this persistence target depend on
/// UIKit. File protection is applied and verified on iOS-family platforms;
/// macOS does not provide the same data-protection contract, so only backup
/// exclusion is enforced there.
public struct FoundationClientStoreStorageAttributes: ClientStoreStorageAttributeApplying {
    private let availability: @Sendable (ClientStoreStoragePolicy) -> Bool

    public init(
        protectedDataAvailability: @escaping @Sendable (ClientStoreStoragePolicy) -> Bool = { _ in true }
    ) {
        availability = protectedDataAvailability
    }

    /// Compatibility adapter for callers whose platform probe cannot
    /// distinguish complete protection from after-first-unlock protection.
    public init(
        protectedDataAvailability: @escaping @Sendable () -> Bool
    ) {
        availability = { _ in protectedDataAvailability() }
    }

    public func isProtectedDataAvailable(for policy: ClientStoreStoragePolicy) -> Bool {
        availability(policy)
    }

    public func applyAndVerify(
        _ policy: ClientStoreStoragePolicy,
        to artifact: ClientStoreStorageArtifact
    ) throws {
        guard availability(policy) else { throw ClientStoreError.protectedDataUnavailable }

        let url = artifact.url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        if policy.excludesFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            let verified = try mutableURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup
            guard verified == true else {
                throw ClientStoreStorageAttributeError.backupExclusionNotApplied(
                    path: url.path
                )
            }
        }

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try FileManager.default.setAttributes(
            [.protectionKey: policy.protection.foundationValue],
            ofItemAtPath: url.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actual = attributes[.protectionKey] as? FileProtectionType
        guard actual == policy.protection.foundationValue else {
            throw ClientStoreStorageAttributeError.protectionNotApplied(
                path: url.path,
                expected: policy.protection,
                actual: String(describing: actual)
            )
        }
        #endif
    }
}

public enum ClientStoreFaultPoint: Equatable, Sendable {
    case afterDeactivatingPriorAdoption
    case afterWritingTrustNamespace
}

public protocol ClientStoreFaultInjecting: Sendable {
    func trigger(_ point: ClientStoreFaultPoint) throws
}

public struct NoClientStoreFaults: ClientStoreFaultInjecting {
    public init() {}
    public func trigger(_: ClientStoreFaultPoint) throws {}
}

/// Exact authority transition shown by the client's foreground replacement
/// surface. The injected boundary receives this immutable request so its local
/// user choice and OS-authentication prompt authorize the same LibraryID and
/// old/new authority IDs that the store commits afterward.
public struct ClientAuthorityReplacementRequest: Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let replacingHostAuthorityID: HostAuthorityID
    public let replacementHostAuthorityID: HostAuthorityID

    init(
        libraryID: LibraryID,
        replacingHostAuthorityID: HostAuthorityID,
        replacementHostAuthorityID: HostAuthorityID
    ) {
        self.libraryID = libraryID
        self.replacingHostAuthorityID = replacingHostAuthorityID
        self.replacementHostAuthorityID = replacementHostAuthorityID
    }
}

/// Application-composition seam for the explicit local authority-replacement
/// choice plus OS user authentication. Success is represented by returning;
/// callers cannot pass a Boolean that the persistence layer might mistake for
/// authentication. Implementations must throw when the choice is cancelled or
/// LocalAuthentication does not succeed.
public protocol ClientAuthorityReplacementAuthorizationBoundary: Sendable {
    func authorizeAuthorityReplacement(
        _ request: ClientAuthorityReplacementRequest
    ) async throws
}

/// Fail-closed default used until a foreground app surface injects the real
/// local-choice and LocalAuthentication implementation.
public struct RejectingClientAuthorityReplacementAuthorizationBoundary:
    ClientAuthorityReplacementAuthorizationBoundary {
    public init() {}

    public func authorizeAuthorityReplacement(
        _: ClientAuthorityReplacementRequest
    ) async throws {
        throw ClientStoreError.authorityReplacementOSAuthenticationRequired
    }
}

public enum ClientStoreError: Error, Equatable, Sendable {
    case protectedDataUnavailable
    case nonFileURL(String)
    case unexpectedDatabaseFileName(expected: String, actual: String)
    case invalidAuthorityPublicKey
    case emptyOpaqueBytes(field: String)
    case integerOutOfRange(field: String, value: UInt64)
    case corruptStoredValue(field: String)
    case noActiveAdoption
    case inactiveTrustTuple(libraryID: LibraryID, hostAuthorityID: HostAuthorityID)
    case trustEvidenceBindingMismatch(field: String)
    case hostAuthorityIdentityMismatch
    case authorityKeyEquivocation
    case grantDeviceMismatch(expected: DeviceID, presented: DeviceID)
    case nonauthorizingGrantStatus(String)
    case transportEpochRollback(stored: UInt64, presented: UInt64)
    case transportEpochEquivocation(epoch: UInt64)
    case grantEpochNotNext(expected: UInt64, presented: UInt64)
    case grantEpochEquivocation(epoch: UInt64)
    case grantIdentityEquivocation(epoch: UInt64)
    case grantRevivalRequiresExplicitReadoption
    case readoptionRequiresRevokedGrant
    case authorityReplacementRequiresExplicitAuthorization(
        libraryID: LibraryID,
        remembered: HostAuthorityID,
        presented: HostAuthorityID
    )
    case authorityReplacementSelectionMismatch
    case authorityReplacementOSAuthenticationRequired
    case grantExpired
    case grantMissingRequiredScope(ClientAuthorizationScope)
    case grantProtocolIncompatible(
        clientMinor: UInt16,
        minimum: UInt16,
        maximum: UInt16
    )
    case captureDeviceMismatch(expected: DeviceID, presented: DeviceID)
    case captureAlreadyExistsWithDifferentFacts
    case uploadAlreadyExistsWithDifferentFacts
    case uploadGenerationRollback(stored: UInt64, presented: UInt64)
    case uploadGenerationGap(expected: UInt64, presented: UInt64)
    case uploadRebindNotAllowed(current: UploadID, presented: UploadID)
    case uploadAttemptSuperseded(uploadID: UploadID, replacement: UploadID)
    case chunkAlreadyExistsWithDifferentFacts
    case exactObjectEquivocation
    case cursorRollback(stored: ChangeCursor, presented: ChangeCursor)
    case cursorMismatch(expected: ChangeCursor, presented: ChangeCursor)
    case snapshotEquivocation(cursor: ChangeCursor)
    case revisionRollback(stored: EntityRevision, presented: EntityRevision)
    case revisionEquivocation(revision: EntityRevision)
    case wrongLibrary(expected: LibraryID, presented: LibraryID)
    case missingRow(entity: String)
    case invalidLocalArtifactURL(String)
    case localArtifactIntegrityBlocked(origin: OriginRecordingID)
    case verifiedReceiptBindingMismatch(field: String)
    case conflictingVerifiedReceipt(origin: OriginRecordingID)
    case cleanupRequiresFutureVerifiedReceiptTransaction
}

extension ClientStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .protectedDataUnavailable:
            "Protected data is unavailable; client-store reconciliation was not started."
        case .nonFileURL(let value):
            "Client store requires a file URL: \(value)"
        case .unexpectedDatabaseFileName(let expected, let actual):
            "Client database must be named \(expected), not \(actual)."
        case .invalidAuthorityPublicKey:
            "The authority public key must be an uncompressed 65-byte P-256 X9.63 key."
        case .emptyOpaqueBytes(let field):
            "\(field) cannot be empty."
        case .integerOutOfRange(let field, let value):
            "\(field) value \(value) cannot be represented by SQLite."
        case .corruptStoredValue(let field):
            "The persisted \(field) value is corrupt."
        case .noActiveAdoption:
            "No host trust tuple is currently adopted."
        case .inactiveTrustTuple:
            "Historical trust tuples are nonauthorizing."
        case .trustEvidenceBindingMismatch(let field):
            "Validated trust evidence is bound to a different \(field)."
        case .hostAuthorityIdentityMismatch:
            "The authority public key does not derive the presented host authority ID."
        case .authorityKeyEquivocation:
            "The same host authority ID was presented with different public-key bytes."
        case .grantDeviceMismatch:
            "The signed grant is not bound to this installation device."
        case .nonauthorizingGrantStatus(let status):
            "The selected grant status \(status) is nonauthorizing."
        case .transportEpochRollback(let stored, let presented):
            "Transport-set epoch \(presented) is below stored high-water epoch \(stored)."
        case .transportEpochEquivocation(let epoch):
            "Transport-set epoch \(epoch) was reused with different exact bytes."
        case .grantEpochNotNext(let expected, let presented):
            "Grant epoch \(presented) is invalid; the next accepted epoch is \(expected)."
        case .grantEpochEquivocation(let epoch):
            "Grant epoch \(epoch) was reused with different exact bytes."
        case .grantIdentityEquivocation(let epoch):
            "Grant epoch \(epoch) was reused with different grant identity facts."
        case .grantRevivalRequiresExplicitReadoption:
            "A revoked grant can be replaced only by explicit same-key re-adoption."
        case .readoptionRequiresRevokedGrant:
            "Explicit revoked-grant re-adoption requires a currently revoked grant."
        case .authorityReplacementRequiresExplicitAuthorization:
            "A remembered library can change host authority only through explicit local replacement authorization."
        case .authorityReplacementSelectionMismatch:
            "Authority-replacement evidence no longer matches the active local choice."
        case .authorityReplacementOSAuthenticationRequired:
            "Authority replacement requires an explicit local choice and successful OS user authentication."
        case .grantExpired:
            "The selected device grant has expired."
        case .grantMissingRequiredScope(let scope):
            "The selected device grant does not authorize \(scope.rawValue)."
        case .grantProtocolIncompatible(let clientMinor, let minimum, let maximum):
            "Client protocol minor \(clientMinor) is outside the grant compatibility range \(minimum)...\(maximum)."
        case .captureDeviceMismatch:
            "The capture and upload attempt must belong to this installation identity."
        case .captureAlreadyExistsWithDifferentFacts:
            "The finalized capture identity is already bound to different facts."
        case .uploadAlreadyExistsWithDifferentFacts:
            "The upload ID is already bound to different facts."
        case .uploadGenerationRollback(let stored, let presented):
            "Upload generation \(presented) is below persisted generation \(stored)."
        case .uploadGenerationGap(let expected, let presented):
            "Upload generation \(presented) skipped the next generation \(expected)."
        case .uploadRebindNotAllowed:
            "A recording cannot bind a new upload ID until its prior attempt is explicitly abandoned or expired."
        case .uploadAttemptSuperseded:
            "The upload attempt was permanently superseded by a newer attempt."
        case .chunkAlreadyExistsWithDifferentFacts:
            "The chunk identity is already bound to different facts."
        case .exactObjectEquivocation:
            "An exact object hash is already bound to different bytes or a different kind."
        case .cursorRollback(let stored, let presented):
            "Change cursor \(presented.rawValue) is below cached cursor \(stored.rawValue)."
        case .cursorMismatch(let expected, let presented):
            "The delta starts at cursor \(presented.rawValue); expected \(expected.rawValue)."
        case .snapshotEquivocation(let cursor):
            "Library snapshot cursor \(cursor.rawValue) was reused with different path-free content."
        case .revisionRollback(let stored, let presented):
            "Entity revision \(presented.rawValue) is below cached revision \(stored.rawValue)."
        case .revisionEquivocation(let revision):
            "Entity revision \(revision.rawValue) was reused with different path-free content."
        case .wrongLibrary(let expected, let presented):
            "The cache belongs to library \(expected); received \(presented)."
        case .missingRow(let entity):
            "No persisted \(entity) row exists."
        case .invalidLocalArtifactURL(let value):
            "Transfer artifacts require a local file URL: \(value)"
        case .localArtifactIntegrityBlocked:
            "Immutable local upload bytes are missing or changed; restore them exactly or abandon the attempt."
        case .verifiedReceiptBindingMismatch(let field):
            "Validated recording receipt does not match the durable local \(field)."
        case .conflictingVerifiedReceipt(let origin):
            "Recording \(origin.recordingUUID.uuidString.lowercased()) already has conflicting verified receipt evidence."
        case .cleanupRequiresFutureVerifiedReceiptTransaction:
            "Cleanup eligibility can be granted only by the atomic verified-receipt transaction."
        }
    }
}

enum ClientStoreCoding {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        field: String
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ClientStoreError.corruptStoredValue(field: field)
        }
    }

    static func sqliteInteger(_ value: UInt64, field: String) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw ClientStoreError.integerOutOfRange(field: field, value: value)
        }
        return result
    }

    static func unsigned(_ value: Int64, field: String) throws -> UInt64 {
        guard value >= 0 else { throw ClientStoreError.corruptStoredValue(field: field) }
        return UInt64(value)
    }

    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else {
            throw ClientStoreError.corruptStoredValue(field: "date")
        }
        return Int64(value.rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

final class ClientStoreDatabase: @unchecked Sendable {
    let queue: DatabaseQueue
    let databaseURL: URL
    let policy: ClientStoreStoragePolicy
    let attributes: any ClientStoreStorageAttributeApplying

    init(
        databaseURL: URL,
        policy: ClientStoreStoragePolicy,
        attributes: any ClientStoreStorageAttributeApplying,
        migrator: DatabaseMigrator
    ) throws {
        guard databaseURL.isFileURL else {
            throw ClientStoreError.nonFileURL(databaseURL.absoluteString)
        }
        guard attributes.isProtectedDataAvailable(for: policy) else {
            throw ClientStoreError.protectedDataUnavailable
        }

        self.databaseURL = databaseURL.standardizedFileURL
        self.policy = policy
        self.attributes = attributes

        let directory = self.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try attributes.applyAndVerify(policy, to: .directory(directory))

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        queue = try DatabaseQueue(path: self.databaseURL.path, configuration: configuration)
        // GRDB deliberately lowers WAL connections to NORMAL unless the
        // application restores its durability policy. Transfer acknowledgments,
        // task mappings, and trust mutations are power-loss boundaries, so both
        // client databases keep SQLite's strongest synchronous setting for the
        // lifetime of every opened connection.
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        try migrator.migrate(queue)
        try refreshStorageAttributes()
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try ensureProtectedDataAvailable()
        return try queue.read(body)
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        try ensureProtectedDataAvailable()
        let value = try queue.write(body)
        try refreshStorageAttributes()
        return value
    }

    func checkpoint() throws {
        try ensureProtectedDataAvailable()
        try queue.writeWithoutTransaction { db in
            _ = try db.checkpoint(.passive)
        }
        try refreshStorageAttributes()
    }

    func ensureProtectedDataAvailable() throws {
        guard attributes.isProtectedDataAvailable(for: policy) else {
            throw ClientStoreError.protectedDataUnavailable
        }
    }

    func refreshStorageAttributes() throws {
        try ensureProtectedDataAvailable()
        let directory = databaseURL.deletingLastPathComponent()
        try attributes.applyAndVerify(policy, to: .directory(directory))
        try attributes.applyAndVerify(policy, to: .database(databaseURL))
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try attributes.applyAndVerify(policy, to: .sidecar(sidecar))
            }
        }
    }
}
