import Foundation
import HarcDomain
import HarcIdentity
import HarcStore

/// Filesystem locations and the durable listener binding for one resident Host.
public struct HarcResidentHostStorageConfiguration: Sendable {
    public let canonicalDatabaseURL: URL
    public let hostDatabaseURL: URL
    public let stagingRoot: URL
    public let listenerPorts: HarcHostListenerPorts

    public init(
        canonicalDatabaseURL: URL = RecordingStore.defaultURL(),
        hostDatabaseURL: URL = HarcHostStore.defaultDatabaseURL(),
        stagingRoot: URL = HarcHostStore.defaultStagingRoot(),
        listenerPorts: HarcHostListenerPorts
    ) {
        self.canonicalDatabaseURL = canonicalDatabaseURL
        self.hostDatabaseURL = hostDatabaseURL
        self.stagingRoot = stagingRoot
        self.listenerPorts = listenerPorts
    }
}

/// Owns the canonical Host writer lease and the tuple-matched HostDB.
///
/// This layer intentionally starts no listener. The transport composition must
/// finish its dual-journal preflight through `HostTransportResidentRuntime`
/// before exposing either network port.
public actor HarcResidentHostStorageRuntime {
    public nonisolated let recordingStore: RecordingStore
    public nonisolated let hostStore: HarcHostStore
    public nonisolated let tuple: HostCryptographicStateTuple
    public nonisolated let authorityPublicKey: P256X963PublicKey
    public nonisolated let listenerPorts: HarcHostListenerPorts

    package nonisolated let cryptographicStateStore:
        any HostCryptographicStateStore
    package nonisolated let writerLease: HostWriterLease

    private var hostModeDisabled = false

    /// Opens a fresh, dormant, or crash-interrupted Host without ever replacing
    /// an already recorded authority. A new authority may be created only when
    /// canonical metadata has no dormant Host tuple.
    public static func start(
        configuration: HarcResidentHostStorageConfiguration,
        cryptographicStateStore: any HostCryptographicStateStore =
            KeychainHostCryptographicStateStore()
    ) async throws -> HarcResidentHostStorageRuntime {
        try validateConfiguration(configuration)

        let canonicalExists = FileManager.default.fileExists(
            atPath: configuration.canonicalDatabaseURL.path
        )
        if !canonicalExists {
            _ = try await RecordingStore.onDisk(
                url: configuration.canonicalDatabaseURL
            )
        }
        let canonicalMetadata = try RecordingStore.inspectLibraryMetadata(
            onDiskAt: configuration.canonicalDatabaseURL
        )
        let cryptographicState = try await resolveCryptographicState(
            for: canonicalMetadata,
            using: cryptographicStateStore
        )
        let tuple = cryptographicState.tuple

        let recordingStore: RecordingStore
        let lease: HostWriterLease
        let enabledDuringThisStart: Bool
        switch canonicalMetadata.writerMode {
        case .standalone:
            let opened = try await RecordingStore.onDisk(
                url: configuration.canonicalDatabaseURL
            )
            lease = try await opened.enableHostMode(
                expectedLibraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID,
                hostStateID: tuple.hostStateID
            )
            recordingStore = opened
            enabledDuringThisStart = true
        case .host:
            let recovered = try await RecordingStore.recoverHostMode(
                onDiskAt: configuration.canonicalDatabaseURL,
                expectedLibraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID,
                hostStateID: tuple.hostStateID
            )
            recordingStore = recovered.store
            lease = recovered.lease
            enabledDuringThisStart = false
        }

        do {
            let metadata = HarcHostMetadata(
                libraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID,
                hostStateID: tuple.hostStateID,
                controlPort: configuration.listenerPorts.controlPort,
                uploadPort: configuration.listenerPorts.uploadPort
            )
            let highWater = KeychainSecurityRegistryHighWaterMarkStore(
                cryptographicStateStore: cryptographicStateStore,
                tuple: tuple
            )
            let hostDatabaseAlreadyExists = FileManager.default.fileExists(
                atPath: configuration.hostDatabaseURL.path
            )
            let hostStore: HarcHostStore
            if hostDatabaseAlreadyExists {
                hostStore = try await HarcHostStore.onDiskDeferredForServing(
                    databaseURL: configuration.hostDatabaseURL,
                    stagingRoot: configuration.stagingRoot,
                    metadata: metadata,
                    highWaterMarkStore: highWater
                )
            } else {
                hostStore = try await HarcHostStore.onDisk(
                    databaseURL: configuration.hostDatabaseURL,
                    stagingRoot: configuration.stagingRoot,
                    metadata: metadata,
                    highWaterMarkStore: highWater
                )
            }
            try await hostStore.persistListenerPorts(
                configuration.listenerPorts
            )
            return HarcResidentHostStorageRuntime(
                recordingStore: recordingStore,
                hostStore: hostStore,
                tuple: tuple,
                authorityPublicKey: cryptographicState.authorityIdentity.publicKey,
                listenerPorts: configuration.listenerPorts,
                cryptographicStateStore: cryptographicStateStore,
                writerLease: lease
            )
        } catch {
            guard enabledDuringThisStart else { throw error }
            do {
                try await recordingStore.disableHostMode(lease)
            } catch let rollbackError {
                throw HarcResidentHostStorageError.startupRollbackFailed(
                    startup: String(describing: error),
                    rollback: String(describing: rollbackError)
                )
            }
            throw error
        }
    }

    private init(
        recordingStore: RecordingStore,
        hostStore: HarcHostStore,
        tuple: HostCryptographicStateTuple,
        authorityPublicKey: P256X963PublicKey,
        listenerPorts: HarcHostListenerPorts,
        cryptographicStateStore: any HostCryptographicStateStore,
        writerLease: HostWriterLease
    ) {
        self.recordingStore = recordingStore
        self.hostStore = hostStore
        self.tuple = tuple
        self.authorityPublicKey = authorityPublicKey
        self.listenerPorts = listenerPorts
        self.cryptographicStateStore = cryptographicStateStore
        self.writerLease = writerLease
    }

    /// Called only by the full resident runtime after advertisement is gone and
    /// both listeners and ingest work have drained.
    package func disableHostMode() async throws {
        guard !hostModeDisabled else { return }
        try await recordingStore.disableHostMode(writerLease)
        hostModeDisabled = true
    }

    private static func resolveCryptographicState(
        for metadata: LibraryMetadata,
        using store: any HostCryptographicStateStore
    ) async throws -> HostCryptographicState {
        switch (metadata.hostAuthorityID, metadata.hostStateID) {
        case (nil, nil):
            guard metadata.writerMode == .standalone else {
                throw HarcResidentHostStorageError.invalidCanonicalHostTuple
            }
            return try await store.loadOrCreate(libraryID: metadata.libraryID)
        case let (.some(authorityID), .some(stateID)):
            return try await store.load(
                requiredTuple: HostCryptographicStateTuple(
                    libraryID: metadata.libraryID,
                    hostAuthorityID: authorityID,
                    hostStateID: stateID
                )
            )
        default:
            throw HarcResidentHostStorageError.invalidCanonicalHostTuple
        }
    }

    private static func validateConfiguration(
        _ configuration: HarcResidentHostStorageConfiguration
    ) throws {
        let urls = [
            configuration.canonicalDatabaseURL,
            configuration.hostDatabaseURL,
            configuration.stagingRoot,
        ]
        guard urls.allSatisfy({
            $0.isFileURL && $0.standardizedFileURL.path == $0.path
        }), configuration.canonicalDatabaseURL.path
            != configuration.hostDatabaseURL.path else {
            throw HarcResidentHostStorageError.invalidConfiguration
        }
    }
}

public enum HarcResidentHostStorageError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidCanonicalHostTuple
    case startupRollbackFailed(startup: String, rollback: String)
}

extension HarcResidentHostStorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Resident Host storage locations must be distinct standardized file URLs."
        case .invalidCanonicalHostTuple:
            "Canonical Host metadata does not contain one complete recoverable identity tuple."
        case .startupRollbackFailed(let startup, let rollback):
            "Resident Host startup failed (\(startup)) and Standalone rollback also failed (\(rollback))."
        }
    }
}
