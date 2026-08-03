import Foundation
import HarcDomain

protocol HostCryptographicStateRecordBackend: Sendable {
    func loadRecord() async throws -> Data?
    func insertRecordIfAbsent(_ record: Data) async throws -> Bool
    func replaceRecord(expected: Data, with replacement: Data) async throws -> Bool
}

actor InMemoryHostCryptographicStateRecordBackend: HostCryptographicStateRecordBackend {
    private var record: Data?

    init(record: Data? = nil) {
        self.record = record
    }

    func loadRecord() -> Data? { record }

    func insertRecordIfAbsent(_ record: Data) -> Bool {
        guard self.record == nil else { return false }
        self.record = record
        return true
    }

    func replaceRecord(expected: Data, with replacement: Data) -> Bool {
        guard record == expected else { return false }
        record = replacement
        return true
    }

    func replaceForTesting(_ replacement: Data?) {
        record = replacement
    }
}

struct HostProtectedP256SigningKeyFactory: Sendable {
    let makeKey: @Sendable () throws -> HostProtectedP256SigningKey

    static let preferred = Self {
        if SecureEnclaveP256SigningKey.isAvailable {
            return .secureEnclave(try SecureEnclaveP256SigningKey())
        }
        return .keychainSoftware(SoftwareP256SigningKey())
    }

    static let software = Self {
        .keychainSoftware(SoftwareP256SigningKey())
    }

    static func permanentTLS(applicationTagPrefix: String) -> Self {
        Self {
            .securityFramework(
                try HostSecurityP256SigningKey.createPreferred(
                    applicationTag: Data(
                        "\(applicationTagPrefix).\(UUID().uuidString.lowercased())".utf8
                    )
                )
            )
        }
    }
}

private struct PersistedHostP256Key: Codable, Sendable {
    let protection: InstallationKeyProtection
    let storageKind: HostPersistedKeyStorageKind
    let material: Data
    let publicKeyX963: Data

    init(_ key: HostProtectedP256SigningKey) {
        protection = key.protection
        storageKind = key.storageKind
        material = key.persistedMaterial
        publicKeyX963 = key.publicKey.rawBytes
    }
}

private struct PersistedHostCryptographicState: Codable, Sendable {
    static let magic = "harc-host-cryptographic-state"
    static let currentVersion: UInt16 = 1

    let magic: String
    let formatVersion: UInt16
    let libraryID: LibraryID
    let hostAuthorityID: HostAuthorityID
    let hostStateID: HostStateID
    let authorityKey: PersistedHostP256Key
    let tlsKey: PersistedHostP256Key
    var securityRegistryRevision: UInt64
    var highestIssuedTransportSetEpoch: UInt64

    init(
        libraryID: LibraryID,
        hostStateID: HostStateID,
        authorityKey: HostProtectedP256SigningKey,
        tlsKey: HostProtectedP256SigningKey
    ) {
        self.magic = Self.magic
        self.formatVersion = Self.currentVersion
        self.libraryID = libraryID
        self.hostAuthorityID = authorityKey.publicKey.hostAuthorityID
        self.hostStateID = hostStateID
        self.authorityKey = PersistedHostP256Key(authorityKey)
        self.tlsKey = PersistedHostP256Key(tlsKey)
        self.securityRegistryRevision = 0
        self.highestIssuedTransportSetEpoch = 0
    }
}

actor HostCryptographicStateRepository: HostCryptographicStateStore {
    private let backend: any HostCryptographicStateRecordBackend
    private let authorityKeyFactory: HostProtectedP256SigningKeyFactory
    private let tlsKeyFactory: HostProtectedP256SigningKeyFactory
    private let hostStateIDFactory: @Sendable () -> HostStateID
    private let persistentSecurityKeyLoader:
        @Sendable (Data, InstallationKeyProtection) throws -> HostProtectedP256SigningKey

    init(
        backend: any HostCryptographicStateRecordBackend,
        authorityKeyFactory: HostProtectedP256SigningKeyFactory,
        tlsKeyFactory: HostProtectedP256SigningKeyFactory,
        hostStateIDFactory: @escaping @Sendable () -> HostStateID = HostStateID.random,
        persistentSecurityKeyLoader: @escaping @Sendable (
            Data,
            InstallationKeyProtection
        ) throws -> HostProtectedP256SigningKey = { applicationTag, protection in
            .securityFramework(
                try HostSecurityP256SigningKey.load(
                    applicationTag: applicationTag,
                    protection: protection
                )
            )
        }
    ) {
        self.backend = backend
        self.authorityKeyFactory = authorityKeyFactory
        self.tlsKeyFactory = tlsKeyFactory
        self.hostStateIDFactory = hostStateIDFactory
        self.persistentSecurityKeyLoader = persistentSecurityKeyLoader
    }

    func resolve(
        _ requirement: HostCryptographicStateRequirement
    ) async throws -> HostCryptographicState {
        switch requirement {
        case .loadOrCreate(let libraryID):
            if let loaded = try await loadValidatedRecord() {
                guard loaded.state.tuple.libraryID == libraryID else {
                    throw HostCryptographicStateError.libraryMismatch(
                        expected: libraryID,
                        actual: loaded.state.tuple.libraryID
                    )
                }
                return loaded.state
            }

            let authorityKey = try authorityKeyFactory.makeKey()
            let tlsKey = try tlsKeyFactory.makeKey()
            guard authorityKey.publicKey != tlsKey.publicKey else {
                throw HostCryptographicStateError.keyRoleCollision
            }
            let candidate = PersistedHostCryptographicState(
                libraryID: libraryID,
                hostStateID: hostStateIDFactory(),
                authorityKey: authorityKey,
                tlsKey: tlsKey
            )
            let candidateBytes: Data
            do {
                candidateBytes = try Self.encode(candidate)
            } catch {
                tlsKey.deleteUncommittedPersistentKeyBestEffort()
                throw error
            }
            let inserted: Bool
            do {
                inserted = try await backend.insertRecordIfAbsent(candidateBytes)
            } catch {
                tlsKey.deleteUncommittedPersistentKeyBestEffort()
                throw error
            }
            if inserted {
                return try validate(candidate)
            }

            // Permanent TLS SecKeys are created before the record CAS. A
            // losing candidate has its own random application tag, so it is
            // safe to remove without touching the winner referenced by the
            // stored record.
            tlsKey.deleteUncommittedPersistentKeyBestEffort()

            // Another resolver won the atomic insert. Reload its exact record
            // rather than returning either locally generated candidate key.
            guard let winner = try await loadValidatedRecord() else {
                throw HostCryptographicStateError.concurrentModification
            }
            guard winner.state.tuple.libraryID == libraryID else {
                throw HostCryptographicStateError.libraryMismatch(
                    expected: libraryID,
                    actual: winner.state.tuple.libraryID
                )
            }
            return winner.state

        case .requireExisting(let expectedTuple):
            guard let loaded = try await loadValidatedRecord() else {
                throw HostCryptographicStateError.keyRecordMissing(expected: expectedTuple)
            }
            guard loaded.state.tuple == expectedTuple else {
                throw HostCryptographicStateError.tupleMismatch(
                    expected: expectedTuple,
                    actual: loaded.state.tuple
                )
            }
            return loaded.state
        }
    }

    func advanceSecurityRegistryRevision(
        for tuple: HostCryptographicStateTuple,
        from expectedRevision: UInt64,
        to newRevision: UInt64
    ) async throws -> HostCryptographicState {
        try await advance(
            .securityRegistryRevision,
            tuple: tuple,
            expected: expectedRevision,
            proposed: newRevision
        )
    }

    func advanceHighestIssuedTransportSetEpoch(
        for tuple: HostCryptographicStateTuple,
        from expectedEpoch: UInt64,
        to newEpoch: UInt64
    ) async throws -> HostCryptographicState {
        try await advance(
            .highestIssuedTransportSetEpoch,
            tuple: tuple,
            expected: expectedEpoch,
            proposed: newEpoch
        )
    }

    private func advance(
        _ mark: HostCryptographicMark,
        tuple: HostCryptographicStateTuple,
        expected: UInt64,
        proposed: UInt64
    ) async throws -> HostCryptographicState {
        guard let loaded = try await loadValidatedRecord() else {
            throw HostCryptographicStateError.keyRecordMissing(expected: tuple)
        }
        guard loaded.state.tuple == tuple else {
            throw HostCryptographicStateError.tupleMismatch(
                expected: tuple,
                actual: loaded.state.tuple
            )
        }

        let current: UInt64
        switch mark {
        case .securityRegistryRevision:
            current = loaded.record.securityRegistryRevision
        case .highestIssuedTransportSetEpoch:
            current = loaded.record.highestIssuedTransportSetEpoch
        }
        guard expected < UInt64.max,
              current == expected,
              proposed == expected + 1 else {
            throw HostCryptographicStateError.monotonicityViolation(
                mark: mark,
                current: current,
                expected: expected,
                proposed: proposed
            )
        }

        var replacement = loaded.record
        switch mark {
        case .securityRegistryRevision:
            replacement.securityRegistryRevision = proposed
        case .highestIssuedTransportSetEpoch:
            replacement.highestIssuedTransportSetEpoch = proposed
        }
        let replacementBytes = try Self.encode(replacement)
        guard try await backend.replaceRecord(
            expected: loaded.bytes,
            with: replacementBytes
        ) else {
            throw HostCryptographicStateError.concurrentModification
        }
        return try validate(replacement)
    }

    private func loadValidatedRecord() async throws -> (
        bytes: Data,
        record: PersistedHostCryptographicState,
        state: HostCryptographicState
    )? {
        guard let bytes = try await backend.loadRecord() else { return nil }
        let record = try Self.decode(bytes)
        return (bytes, record, try validate(record))
    }

    private static func encode(_ record: PersistedHostCryptographicState) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(record)
        } catch {
            throw HostCryptographicStateError.corruptRecord
        }
    }

    private static func decode(_ bytes: Data) throws -> PersistedHostCryptographicState {
        do {
            return try JSONDecoder().decode(PersistedHostCryptographicState.self, from: bytes)
        } catch let error as HostCryptographicStateError {
            throw error
        } catch {
            throw HostCryptographicStateError.corruptRecord
        }
    }

    private func validate(
        _ record: PersistedHostCryptographicState
    ) throws -> HostCryptographicState {
        guard record.magic == PersistedHostCryptographicState.magic else {
            throw HostCryptographicStateError.corruptRecord
        }
        guard record.formatVersion == PersistedHostCryptographicState.currentVersion else {
            throw HostCryptographicStateError.unsupportedRecordVersion(record.formatVersion)
        }
        let authorityKey = try restore(
            record.authorityKey,
            role: .authoritySigning
        )
        let tlsKey = try restore(record.tlsKey, role: .tlsServer)
        guard authorityKey.publicKey.hostAuthorityID == record.hostAuthorityID else {
            throw HostCryptographicStateError.authorityIdentityMismatch
        }
        guard authorityKey.publicKey != tlsKey.publicKey else {
            throw HostCryptographicStateError.keyRoleCollision
        }
        let tuple = HostCryptographicStateTuple(
            libraryID: record.libraryID,
            hostAuthorityID: record.hostAuthorityID,
            hostStateID: record.hostStateID
        )
        return HostCryptographicState(
            tuple: tuple,
            authorityKey: authorityKey,
            tlsKey: tlsKey,
            securityRegistryRevision: record.securityRegistryRevision,
            highestIssuedTransportSetEpoch: record.highestIssuedTransportSetEpoch
        )
    }

    private func restore(
        _ persisted: PersistedHostP256Key,
        role: HostCryptographicKeyRole
    ) throws -> HostProtectedP256SigningKey {
        let key: HostProtectedP256SigningKey
        do {
            switch persisted.storageKind {
            case .embeddedMaterial:
                switch persisted.protection {
                case .secureEnclave:
                    key = .secureEnclave(
                        try SecureEnclaveP256SigningKey(
                            opaqueDataRepresentation: persisted.material
                        )
                    )
                case .keychainSoftware:
                    key = .keychainSoftware(
                        try SoftwareP256SigningKey(rawRepresentation: persisted.material)
                    )
                }
            case .permanentSecurityKey:
                key = try persistentSecurityKeyLoader(
                    persisted.material,
                    persisted.protection
                )
            }
        } catch {
            throw HostCryptographicStateError.privateKeyUnavailable(role: role)
        }
        let recordedPublicKey: P256X963PublicKey
        do {
            recordedPublicKey = try P256X963PublicKey(persisted.publicKeyX963)
        } catch {
            throw HostCryptographicStateError.publicKeyMismatch(role: role)
        }
        guard key.publicKey == recordedPublicKey else {
            throw HostCryptographicStateError.publicKeyMismatch(role: role)
        }
        return key
    }
}

/// Memory-only fixture with the exact production validation and monotonic
/// transition behavior. It deliberately generates software keys so tests do
/// not depend on Secure Enclave availability or a developer Keychain.
public struct InMemoryHostCryptographicStateStore: HostCryptographicStateStore, Sendable {
    private let repository: HostCryptographicStateRepository

    public init() {
        repository = HostCryptographicStateRepository(
            backend: InMemoryHostCryptographicStateRecordBackend(),
            authorityKeyFactory: .software,
            tlsKeyFactory: .software
        )
    }

    init(
        backend: any HostCryptographicStateRecordBackend,
        hostStateIDFactory: @escaping @Sendable () -> HostStateID = HostStateID.random
    ) {
        repository = HostCryptographicStateRepository(
            backend: backend,
            authorityKeyFactory: .software,
            tlsKeyFactory: .software,
            hostStateIDFactory: hostStateIDFactory
        )
    }

    public func resolve(
        _ requirement: HostCryptographicStateRequirement
    ) async throws -> HostCryptographicState {
        try await repository.resolve(requirement)
    }

    public func advanceSecurityRegistryRevision(
        for tuple: HostCryptographicStateTuple,
        from expectedRevision: UInt64,
        to newRevision: UInt64
    ) async throws -> HostCryptographicState {
        try await repository.advanceSecurityRegistryRevision(
            for: tuple,
            from: expectedRevision,
            to: newRevision
        )
    }

    public func advanceHighestIssuedTransportSetEpoch(
        for tuple: HostCryptographicStateTuple,
        from expectedEpoch: UInt64,
        to newEpoch: UInt64
    ) async throws -> HostCryptographicState {
        try await repository.advanceHighestIssuedTransportSetEpoch(
            for: tuple,
            from: expectedEpoch,
            to: newEpoch
        )
    }
}
