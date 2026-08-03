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
    let permanentLifecycle: HostPermanentTLSKeyLifecycle?

    init(_ makeKey: @escaping @Sendable () throws -> HostProtectedP256SigningKey) {
        self.makeKey = makeKey
        self.permanentLifecycle = nil
    }

    init(
        makeKey: @escaping @Sendable () throws -> HostProtectedP256SigningKey,
        permanentLifecycle: HostPermanentTLSKeyLifecycle
    ) {
        self.makeKey = makeKey
        self.permanentLifecycle = permanentLifecycle
    }

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
        Self(
            makeKey: {
                .securityFramework(
                    try HostSecurityP256SigningKey.createPreferred(
                        applicationTag: Data(
                            "\(applicationTagPrefix).legacy.\(UUID().uuidString.lowercased())".utf8
                        )
                    )
                )
            },
            permanentLifecycle: HostPermanentTLSKeyLifecycle(
                applicationTag: { tuple, generation in
                    Data(
                        "\(applicationTagPrefix).\(tuple.hostStateID.rawValue.uuidString.lowercased()).g\(generation)"
                            .utf8
                    )
                },
                loadIfPresent: { tag in
                    try HostSecurityP256SigningKey.loadIfPresent(applicationTag: tag)
                        .map { .securityFramework($0) }
                },
                loadOrCreate: { tag in
                    .securityFramework(
                        try HostSecurityP256SigningKey.loadOrCreatePreferred(
                            applicationTag: tag
                        )
                    )
                },
                deleteAndConfirmAbsent: { tag, protection, publicKey in
                    try HostSecurityP256SigningKey.deleteAndConfirmAbsent(
                        applicationTag: tag,
                        protection: protection,
                        expectedPublicKey: publicKey
                    )
                }
            )
        )
    }

    static func permanentLegacyTLSForTesting(applicationTagPrefix: String) -> Self {
        Self(
            makeKey: {
                .securityFramework(
                    try HostSecurityP256SigningKey.createLegacyKeychainTestFixture(
                        applicationTag: Data(
                            "\(applicationTagPrefix).legacy.\(UUID().uuidString.lowercased())".utf8
                        )
                    )
                )
            },
            permanentLifecycle: HostPermanentTLSKeyLifecycle(
                applicationTag: { tuple, generation in
                    Data(
                        "\(applicationTagPrefix).\(tuple.hostStateID.rawValue.uuidString.lowercased()).g\(generation)"
                            .utf8
                    )
                },
                loadIfPresent: { tag in
                    try HostSecurityP256SigningKey.loadLegacyKeychainTestFixtureIfPresent(
                        applicationTag: tag
                    ).map { .securityFramework($0) }
                },
                loadOrCreate: { tag in
                    .securityFramework(
                        try HostSecurityP256SigningKey.loadOrCreateLegacyKeychainTestFixture(
                            applicationTag: tag
                        )
                    )
                },
                deleteAndConfirmAbsent: { tag, protection, publicKey in
                    try HostSecurityP256SigningKey.deleteLegacyKeychainTestFixtureAndConfirmAbsent(
                        applicationTag: tag,
                        protection: protection,
                        expectedPublicKey: publicKey
                    )
                }
            )
        )
    }
}

struct HostPermanentTLSKeyLifecycle: Sendable {
    let applicationTag:
        @Sendable (HostCryptographicStateTuple, UInt64) -> Data
    let loadIfPresent:
        @Sendable (Data) throws -> HostProtectedP256SigningKey?
    let loadOrCreate:
        @Sendable (Data) throws -> HostProtectedP256SigningKey
    let deleteAndConfirmAbsent:
        @Sendable (Data, InstallationKeyProtection, P256X963PublicKey) throws -> Void
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

private struct PersistedHostCryptographicStateV1: Codable, Sendable {
    static let magic = "harc-host-cryptographic-state"
    static let formatVersion: UInt16 = 1

    let magic: String
    let formatVersion: UInt16
    let libraryID: LibraryID
    let hostAuthorityID: HostAuthorityID
    let hostStateID: HostStateID
    let authorityKey: PersistedHostP256Key
    let tlsKey: PersistedHostP256Key
    var securityRegistryRevision: UInt64
    var highestIssuedTransportSetEpoch: UInt64
}

private struct PersistedHostCryptographicStateV2: Codable, Sendable {
    static let magic = PersistedHostCryptographicStateV1.magic
    static let formatVersion: UInt16 = 2

    let magic: String
    let formatVersion: UInt16
    let libraryID: LibraryID
    let hostAuthorityID: HostAuthorityID
    let hostStateID: HostStateID
    let authorityKey: PersistedHostP256Key
    var activeTLSKey: PersistedHostP256Key
    var stagedTLSKey: PersistedHostP256Key?
    var retiringTLSKey: PersistedHostP256Key?
    var securityRegistryRevision: UInt64
    var highestIssuedTransportSetEpoch: UInt64

    init(
        libraryID: LibraryID,
        hostStateID: HostStateID,
        authorityKey: HostProtectedP256SigningKey,
        activeTLSKey: HostProtectedP256SigningKey
    ) {
        self.magic = Self.magic
        self.formatVersion = Self.formatVersion
        self.libraryID = libraryID
        self.hostAuthorityID = authorityKey.publicKey.hostAuthorityID
        self.hostStateID = hostStateID
        self.authorityKey = PersistedHostP256Key(authorityKey)
        self.activeTLSKey = PersistedHostP256Key(activeTLSKey)
        self.stagedTLSKey = nil
        self.retiringTLSKey = nil
        self.securityRegistryRevision = 0
        self.highestIssuedTransportSetEpoch = 0
    }

    init(migrating legacy: PersistedHostCryptographicStateV1) {
        magic = legacy.magic
        formatVersion = Self.formatVersion
        libraryID = legacy.libraryID
        hostAuthorityID = legacy.hostAuthorityID
        hostStateID = legacy.hostStateID
        authorityKey = legacy.authorityKey
        activeTLSKey = legacy.tlsKey
        stagedTLSKey = nil
        retiringTLSKey = nil
        securityRegistryRevision = legacy.securityRegistryRevision
        highestIssuedTransportSetEpoch = legacy.highestIssuedTransportSetEpoch
    }
}

private struct PersistedTLSKeyCreationIntent: Codable, Equatable, Sendable {
    let targetRole: HostCryptographicKeyRole
    let generation: UInt64
    let applicationTag: Data
}

private struct PersistedTLSKeyDeletionIntent: Codable, Sendable {
    let formerRole: HostCryptographicKeyRole
    let key: PersistedHostP256Key
}

private struct PersistedHostCryptographicState: Codable, Sendable {
    static let magic = PersistedHostCryptographicStateV1.magic
    static let currentVersion: UInt16 = 3

    let magic: String
    let formatVersion: UInt16
    let libraryID: LibraryID
    let hostAuthorityID: HostAuthorityID
    let hostStateID: HostStateID
    let authorityKey: PersistedHostP256Key
    var activeTLSKey: PersistedHostP256Key?
    var stagedTLSKey: PersistedHostP256Key?
    var retiringTLSKey: PersistedHostP256Key?
    var securityRegistryRevision: UInt64
    var highestIssuedTransportSetEpoch: UInt64
    var nextTLSKeyGeneration: UInt64
    var pendingTLSKeyCreation: PersistedTLSKeyCreationIntent?
    var pendingTLSKeyDeletions: [PersistedTLSKeyDeletionIntent]

    init(
        libraryID: LibraryID,
        hostStateID: HostStateID,
        authorityKey: HostProtectedP256SigningKey,
        activeTLSKey: HostProtectedP256SigningKey
    ) {
        magic = Self.magic
        formatVersion = Self.currentVersion
        self.libraryID = libraryID
        hostAuthorityID = authorityKey.publicKey.hostAuthorityID
        self.hostStateID = hostStateID
        self.authorityKey = PersistedHostP256Key(authorityKey)
        self.activeTLSKey = PersistedHostP256Key(activeTLSKey)
        stagedTLSKey = nil
        retiringTLSKey = nil
        securityRegistryRevision = 0
        highestIssuedTransportSetEpoch = 0
        nextTLSKeyGeneration = 1
        pendingTLSKeyCreation = nil
        pendingTLSKeyDeletions = []
    }

    init(
        libraryID: LibraryID,
        hostStateID: HostStateID,
        authorityKey: HostProtectedP256SigningKey,
        initialCreationIntent: PersistedTLSKeyCreationIntent
    ) {
        magic = Self.magic
        formatVersion = Self.currentVersion
        self.libraryID = libraryID
        hostAuthorityID = authorityKey.publicKey.hostAuthorityID
        self.hostStateID = hostStateID
        self.authorityKey = PersistedHostP256Key(authorityKey)
        activeTLSKey = nil
        stagedTLSKey = nil
        retiringTLSKey = nil
        securityRegistryRevision = 0
        highestIssuedTransportSetEpoch = 0
        nextTLSKeyGeneration = initialCreationIntent.generation + 1
        pendingTLSKeyCreation = initialCreationIntent
        pendingTLSKeyDeletions = []
    }

    init(migrating legacy: PersistedHostCryptographicStateV1) {
        magic = legacy.magic
        formatVersion = Self.currentVersion
        libraryID = legacy.libraryID
        hostAuthorityID = legacy.hostAuthorityID
        hostStateID = legacy.hostStateID
        authorityKey = legacy.authorityKey
        activeTLSKey = legacy.tlsKey
        stagedTLSKey = nil
        retiringTLSKey = nil
        securityRegistryRevision = legacy.securityRegistryRevision
        highestIssuedTransportSetEpoch = legacy.highestIssuedTransportSetEpoch
        nextTLSKeyGeneration = 1
        pendingTLSKeyCreation = nil
        pendingTLSKeyDeletions = []
    }

    init(migrating legacy: PersistedHostCryptographicStateV2) {
        magic = legacy.magic
        formatVersion = Self.currentVersion
        libraryID = legacy.libraryID
        hostAuthorityID = legacy.hostAuthorityID
        hostStateID = legacy.hostStateID
        authorityKey = legacy.authorityKey
        activeTLSKey = legacy.activeTLSKey
        stagedTLSKey = legacy.stagedTLSKey
        retiringTLSKey = legacy.retiringTLSKey
        securityRegistryRevision = legacy.securityRegistryRevision
        highestIssuedTransportSetEpoch = legacy.highestIssuedTransportSetEpoch
        nextTLSKeyGeneration = 1
        pendingTLSKeyCreation = nil
        pendingTLSKeyDeletions = []
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
            let hostStateID = hostStateIDFactory()
            let candidate: PersistedHostCryptographicState
            let uncommittedTLSKey: HostProtectedP256SigningKey?
            if let lifecycle = tlsKeyFactory.permanentLifecycle {
                uncommittedTLSKey = nil
                let tuple = HostCryptographicStateTuple(
                    libraryID: libraryID,
                    hostAuthorityID: authorityKey.publicKey.hostAuthorityID,
                    hostStateID: hostStateID
                )
                let intent = PersistedTLSKeyCreationIntent(
                    targetRole: .tlsServer,
                    generation: 0,
                    applicationTag: lifecycle.applicationTag(tuple, 0)
                )
                candidate = PersistedHostCryptographicState(
                    libraryID: libraryID,
                    hostStateID: hostStateID,
                    authorityKey: authorityKey,
                    initialCreationIntent: intent
                )
            } else {
                let tlsKey = try tlsKeyFactory.makeKey()
                uncommittedTLSKey = tlsKey
                guard authorityKey.publicKey != tlsKey.publicKey else {
                    throw HostCryptographicStateError.keyRoleCollision
                }
                candidate = PersistedHostCryptographicState(
                    libraryID: libraryID,
                    hostStateID: hostStateID,
                    authorityKey: authorityKey,
                    activeTLSKey: tlsKey
                )
            }
            let candidateBytes: Data
            do {
                candidateBytes = try Self.encode(candidate)
            } catch {
                uncommittedTLSKey?.deleteUncommittedPersistentKeyBestEffort()
                throw error
            }
            let inserted: Bool
            do {
                inserted = try await backend.insertRecordIfAbsent(candidateBytes)
            } catch {
                uncommittedTLSKey?.deleteUncommittedPersistentKeyBestEffort()
                throw error
            }
            if inserted, let loaded = try await loadValidatedRecord() {
                return loaded.state
            }
            uncommittedTLSKey?.deleteUncommittedPersistentKeyBestEffort()

            // Another resolver won the atomic insert. Reload its exact record
            // rather than creating any key for the losing intent.
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

    func inspect(
        requiredTuple: HostCryptographicStateTuple
    ) async throws -> HostCryptographicStateInspection {
        guard let bytes = try await backend.loadRecord() else {
            throw HostCryptographicStateError.keyRecordMissing(expected: requiredTuple)
        }
        let record: PersistedHostCryptographicState
        switch try Self.decodeVersioned(bytes) {
        case .legacyV1(let legacy):
            record = PersistedHostCryptographicState(migrating: legacy)
        case .legacyV2(let legacy):
            record = PersistedHostCryptographicState(migrating: legacy)
        case .current(let current):
            record = current
        }
        let inspection = try inspectRecord(record)
        guard inspection.tuple == requiredTuple else {
            throw HostCryptographicStateError.tupleMismatch(
                expected: requiredTuple,
                actual: inspection.tuple
            )
        }
        return inspection
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

    func stageReplacementTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedActivePublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        let loaded = try await requireLoadedRecord(tuple: tuple)
        guard loaded.state.activeTLSIdentity.publicKey == expectedActivePublicKey else {
            throw HostCryptographicStateError.tlsKeyExpectationMismatch(role: .tlsServer)
        }
        guard loaded.record.stagedTLSKey == nil,
              loaded.record.retiringTLSKey == nil,
              loaded.record.pendingTLSKeyCreation == nil,
              loaded.record.pendingTLSKeyDeletions.isEmpty else {
            throw HostCryptographicStateError.tlsKeyTransitionInProgress
        }

        if let lifecycle = tlsKeyFactory.permanentLifecycle {
            let generation = loaded.record.nextTLSKeyGeneration
            guard generation < UInt64.max else {
                throw HostCryptographicStateError.corruptRecord
            }
            var replacement = loaded.record
            replacement.nextTLSKeyGeneration = generation + 1
            replacement.pendingTLSKeyCreation = PersistedTLSKeyCreationIntent(
                targetRole: .tlsServerStaged,
                generation: generation,
                applicationTag: lifecycle.applicationTag(tuple, generation)
            )
            let replacementBytes = try Self.encode(replacement)
            guard try await backend.replaceRecord(
                expected: loaded.bytes,
                with: replacementBytes
            ) else {
                throw HostCryptographicStateError.concurrentModification
            }
            guard let recovered = try await loadValidatedRecord() else {
                throw HostCryptographicStateError.concurrentModification
            }
            return recovered.state
        }

        let candidate = try tlsKeyFactory.makeKey()
        let occupied = [
            loaded.state.authorityIdentity.publicKey,
            loaded.state.activeTLSIdentity.publicKey,
        ]
        guard !occupied.contains(candidate.publicKey) else {
            candidate.deleteUncommittedPersistentKeyBestEffort()
            throw HostCryptographicStateError.keyRoleCollision
        }

        var replacement = loaded.record
        replacement.stagedTLSKey = PersistedHostP256Key(candidate)
        let replacementBytes: Data
        do {
            replacementBytes = try Self.encode(replacement)
        } catch {
            candidate.deleteUncommittedPersistentKeyBestEffort()
            throw error
        }
        let replaced: Bool
        do {
            replaced = try await backend.replaceRecord(
                expected: loaded.bytes,
                with: replacementBytes
            )
        } catch {
            candidate.deleteUncommittedPersistentKeyBestEffort()
            throw error
        }
        guard replaced else {
            candidate.deleteUncommittedPersistentKeyBestEffort()
            throw HostCryptographicStateError.concurrentModification
        }
        return try validate(replacement)
    }

    func promoteStagedTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedActivePublicKey: P256X963PublicKey,
        expectedStagedPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        let loaded = try await requireLoadedRecord(tuple: tuple)
        guard loaded.state.activeTLSIdentity.publicKey == expectedActivePublicKey else {
            throw HostCryptographicStateError.tlsKeyExpectationMismatch(role: .tlsServer)
        }
        guard let staged = loaded.state.stagedTLSIdentity,
              let stagedRecord = loaded.record.stagedTLSKey else {
            throw HostCryptographicStateError.stagedTLSKeyMissing
        }
        guard staged.publicKey == expectedStagedPublicKey else {
            throw HostCryptographicStateError.tlsKeyExpectationMismatch(role: .tlsServerStaged)
        }
        guard loaded.record.retiringTLSKey == nil else {
            throw HostCryptographicStateError.unexpectedTLSKey(role: .tlsServerRetiring)
        }

        var replacement = loaded.record
        replacement.activeTLSKey = stagedRecord
        replacement.stagedTLSKey = nil
        replacement.retiringTLSKey = loaded.record.activeTLSKey
        return try await replace(loaded: loaded, with: replacement)
    }

    func discardStagedTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedStagedPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        let loaded = try await requireLoadedRecord(tuple: tuple)
        guard let staged = loaded.state.stagedTLSIdentity else {
            throw HostCryptographicStateError.stagedTLSKeyMissing
        }
        guard staged.publicKey == expectedStagedPublicKey else {
            throw HostCryptographicStateError.tlsKeyExpectationMismatch(role: .tlsServerStaged)
        }
        guard loaded.record.retiringTLSKey == nil else {
            throw HostCryptographicStateError.unexpectedTLSKey(role: .tlsServerRetiring)
        }

        var replacement = loaded.record
        replacement.stagedTLSKey = nil
        if staged.key.storageKind == .permanentSecurityKey {
            guard let persisted = loaded.record.stagedTLSKey else {
                throw HostCryptographicStateError.stagedTLSKeyMissing
            }
            replacement.pendingTLSKeyDeletions.append(
                PersistedTLSKeyDeletionIntent(
                    formerRole: .tlsServerStaged,
                    key: persisted
                )
            )
            let bytes = try Self.encode(replacement)
            guard try await backend.replaceRecord(expected: loaded.bytes, with: bytes) else {
                throw HostCryptographicStateError.concurrentModification
            }
            guard let recovered = try await loadValidatedRecord() else {
                throw HostCryptographicStateError.concurrentModification
            }
            return recovered.state
        }
        return try await replace(loaded: loaded, with: replacement)
    }

    func finalizeRetiringTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedRetiringPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        let loaded = try await requireLoadedRecord(tuple: tuple)
        guard let retiring = loaded.state.retiringTLSIdentity else {
            throw HostCryptographicStateError.retiringTLSKeyMissing
        }
        guard retiring.publicKey == expectedRetiringPublicKey else {
            throw HostCryptographicStateError.tlsKeyExpectationMismatch(role: .tlsServerRetiring)
        }
        guard loaded.record.stagedTLSKey == nil else {
            throw HostCryptographicStateError.unexpectedTLSKey(role: .tlsServerStaged)
        }

        var replacement = loaded.record
        replacement.retiringTLSKey = nil
        if retiring.key.storageKind == .permanentSecurityKey {
            guard let persisted = loaded.record.retiringTLSKey else {
                throw HostCryptographicStateError.retiringTLSKeyMissing
            }
            replacement.pendingTLSKeyDeletions.append(
                PersistedTLSKeyDeletionIntent(
                    formerRole: .tlsServerRetiring,
                    key: persisted
                )
            )
            let bytes = try Self.encode(replacement)
            guard try await backend.replaceRecord(expected: loaded.bytes, with: bytes) else {
                throw HostCryptographicStateError.concurrentModification
            }
            guard let recovered = try await loadValidatedRecord() else {
                throw HostCryptographicStateError.concurrentModification
            }
            return recovered.state
        }
        return try await replace(loaded: loaded, with: replacement)
    }

    private func requireLoadedRecord(
        tuple: HostCryptographicStateTuple
    ) async throws -> (
        bytes: Data,
        record: PersistedHostCryptographicState,
        state: HostCryptographicState
    ) {
        guard let loaded = try await loadValidatedRecord() else {
            throw HostCryptographicStateError.keyRecordMissing(expected: tuple)
        }
        guard loaded.state.tuple == tuple else {
            throw HostCryptographicStateError.tupleMismatch(
                expected: tuple,
                actual: loaded.state.tuple
            )
        }
        return loaded
    }

    private func replace(
        loaded: (
            bytes: Data,
            record: PersistedHostCryptographicState,
            state: HostCryptographicState
        ),
        with replacement: PersistedHostCryptographicState
    ) async throws -> HostCryptographicState {
        let replacementBytes = try Self.encode(replacement)
        guard try await backend.replaceRecord(
            expected: loaded.bytes,
            with: replacementBytes
        ) else {
            throw HostCryptographicStateError.concurrentModification
        }
        return try validate(replacement)
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
        for _ in 0..<16 {
            guard let bytes = try await backend.loadRecord() else { return nil }
            switch try Self.decodeVersioned(bytes) {
            case .current(let record):
                _ = try inspectRecord(record)
                if record.pendingTLSKeyCreation != nil {
                    try await recoverPendingCreation(record: record, bytes: bytes)
                    continue
                }
                if !record.pendingTLSKeyDeletions.isEmpty {
                    try await recoverPendingDeletion(record: record, bytes: bytes)
                    continue
                }
                return (bytes, record, try validate(record))
            case .legacyV1(let legacy):
                let migrated = PersistedHostCryptographicState(migrating: legacy)
                _ = try inspectRecord(migrated)
                let migratedBytes = try Self.encode(migrated)
                _ = try await backend.replaceRecord(expected: bytes, with: migratedBytes)
                continue
            case .legacyV2(let legacy):
                let migrated = PersistedHostCryptographicState(migrating: legacy)
                _ = try inspectRecord(migrated)
                let migratedBytes = try Self.encode(migrated)
                _ = try await backend.replaceRecord(expected: bytes, with: migratedBytes)
                continue
            }
        }
        throw HostCryptographicStateError.concurrentModification
    }

    private func recoverPendingCreation(
        record: PersistedHostCryptographicState,
        bytes: Data
    ) async throws {
        guard let intent = record.pendingTLSKeyCreation,
              let lifecycle = tlsKeyFactory.permanentLifecycle else {
            throw HostCryptographicStateError.corruptRecord
        }
        let tuple = Self.tuple(for: record)
        guard intent.applicationTag == lifecycle.applicationTag(tuple, intent.generation) else {
            throw HostCryptographicStateError.corruptRecord
        }
        let key = try lifecycle.loadOrCreate(intent.applicationTag)
        guard key.storageKind == .permanentSecurityKey,
              key.persistedMaterial == intent.applicationTag else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: intent.targetRole)
        }
        let occupied = try restoredRoleKeys(record)
        guard !occupied.contains(where: { $0.publicKey == key.publicKey }) else {
            throw HostCryptographicStateError.keyRoleCollision
        }

        var replacement = record
        switch intent.targetRole {
        case .tlsServer:
            guard replacement.activeTLSKey == nil else {
                throw HostCryptographicStateError.corruptRecord
            }
            replacement.activeTLSKey = PersistedHostP256Key(key)
        case .tlsServerStaged:
            guard replacement.activeTLSKey != nil,
                  replacement.stagedTLSKey == nil,
                  replacement.retiringTLSKey == nil else {
                throw HostCryptographicStateError.corruptRecord
            }
            replacement.stagedTLSKey = PersistedHostP256Key(key)
        default:
            throw HostCryptographicStateError.corruptRecord
        }
        replacement.pendingTLSKeyCreation = nil
        let replacementBytes = try Self.encode(replacement)
        _ = try await backend.replaceRecord(expected: bytes, with: replacementBytes)
    }

    private func recoverPendingDeletion(
        record: PersistedHostCryptographicState,
        bytes: Data
    ) async throws {
        guard let intent = record.pendingTLSKeyDeletions.first,
              let lifecycle = tlsKeyFactory.permanentLifecycle else {
            throw HostCryptographicStateError.corruptRecord
        }
        let publicKey = try recordedPublicKey(intent.key, role: intent.formerRole)
        do {
            try lifecycle.deleteAndConfirmAbsent(
                intent.key.material,
                intent.key.protection,
                publicKey
            )
        } catch let error as HostCryptographicStateError {
            if case .persistentKeyDeletionIncomplete = error {
                throw HostCryptographicStateError.persistentKeyDeletionIncomplete(
                    role: intent.formerRole
                )
            }
            throw error
        } catch {
            throw HostCryptographicStateError.persistentKeyDeletionIncomplete(
                role: intent.formerRole
            )
        }
        var replacement = record
        replacement.pendingTLSKeyDeletions.removeFirst()
        let replacementBytes = try Self.encode(replacement)
        _ = try await backend.replaceRecord(expected: bytes, with: replacementBytes)
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

    private enum DecodedRecord {
        case legacyV1(PersistedHostCryptographicStateV1)
        case legacyV2(PersistedHostCryptographicStateV2)
        case current(PersistedHostCryptographicState)
    }

    private struct RecordHeader: Decodable {
        let magic: String
        let formatVersion: UInt16
    }

    private static func decodeVersioned(_ bytes: Data) throws -> DecodedRecord {
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(RecordHeader.self, from: bytes)
            guard header.magic == PersistedHostCryptographicState.magic else {
                throw HostCryptographicStateError.corruptRecord
            }
            switch header.formatVersion {
            case PersistedHostCryptographicStateV1.formatVersion:
                return .legacyV1(
                    try decoder.decode(PersistedHostCryptographicStateV1.self, from: bytes)
                )
            case PersistedHostCryptographicStateV2.formatVersion:
                return .legacyV2(
                    try decoder.decode(PersistedHostCryptographicStateV2.self, from: bytes)
                )
            case PersistedHostCryptographicState.currentVersion:
                return .current(
                    try decoder.decode(PersistedHostCryptographicState.self, from: bytes)
                )
            default:
                throw HostCryptographicStateError.unsupportedRecordVersion(
                    header.formatVersion
                )
            }
        } catch let error as HostCryptographicStateError {
            throw error
        } catch {
            throw HostCryptographicStateError.corruptRecord
        }
    }

    private func validate(
        _ record: PersistedHostCryptographicState
    ) throws -> HostCryptographicState {
        _ = try inspectRecord(record)
        guard record.pendingTLSKeyCreation == nil,
              record.pendingTLSKeyDeletions.isEmpty,
              let activeRecord = record.activeTLSKey else {
            throw HostCryptographicStateError.corruptRecord
        }
        let authorityKey = try restore(record.authorityKey, role: .authoritySigning)
        let activeTLSKey = try restore(activeRecord, role: .tlsServer)
        let stagedTLSKey = try record.stagedTLSKey.map {
            try restore($0, role: .tlsServerStaged)
        }
        let retiringTLSKey = try record.retiringTLSKey.map {
            try restore($0, role: .tlsServerRetiring)
        }
        return HostCryptographicState(
            tuple: Self.tuple(for: record),
            authorityKey: authorityKey,
            activeTLSKey: activeTLSKey,
            stagedTLSKey: stagedTLSKey,
            retiringTLSKey: retiringTLSKey,
            securityRegistryRevision: record.securityRegistryRevision,
            highestIssuedTransportSetEpoch: record.highestIssuedTransportSetEpoch
        )
    }

    private func inspectRecord(
        _ record: PersistedHostCryptographicState
    ) throws -> HostCryptographicStateInspection {
        guard record.magic == PersistedHostCryptographicState.magic else {
            throw HostCryptographicStateError.corruptRecord
        }
        guard record.formatVersion == PersistedHostCryptographicState.currentVersion else {
            throw HostCryptographicStateError.unsupportedRecordVersion(record.formatVersion)
        }
        guard record.pendingTLSKeyDeletions.count <= 1 else {
            throw HostCryptographicStateError.corruptRecord
        }
        guard record.pendingTLSKeyCreation == nil
                || record.pendingTLSKeyDeletions.isEmpty else {
            throw HostCryptographicStateError.corruptRecord
        }

        let tuple = Self.tuple(for: record)
        let authorityKey = try restore(record.authorityKey, role: .authoritySigning)
        let activeTLSKey = try record.activeTLSKey.map {
            try restore($0, role: .tlsServer)
        }
        let stagedTLSKey = try record.stagedTLSKey.map {
            try restore($0, role: .tlsServerStaged)
        }
        let retiringTLSKey = try record.retiringTLSKey.map {
            try restore($0, role: .tlsServerRetiring)
        }
        guard authorityKey.publicKey.hostAuthorityID == record.hostAuthorityID else {
            throw HostCryptographicStateError.authorityIdentityMismatch
        }
        if stagedTLSKey != nil, retiringTLSKey != nil {
            throw HostCryptographicStateError.tlsKeyTransitionInProgress
        }

        var liveKeys = [authorityKey]
        if let activeTLSKey { liveKeys.append(activeTLSKey) }
        if let stagedTLSKey { liveKeys.append(stagedTLSKey) }
        if let retiringTLSKey { liveKeys.append(retiringTLSKey) }
        try Self.requireDistinct(liveKeys.map(\.publicKey))

        let creationInspection: HostCryptographicPendingTLSKeyCreation?
        if let intent = record.pendingTLSKeyCreation {
            guard let lifecycle = tlsKeyFactory.permanentLifecycle,
                  intent.applicationTag
                    == lifecycle.applicationTag(tuple, intent.generation),
                  intent.generation < record.nextTLSKeyGeneration else {
                throw HostCryptographicStateError.corruptRecord
            }
            switch intent.targetRole {
            case .tlsServer:
                guard activeTLSKey == nil,
                      stagedTLSKey == nil,
                      retiringTLSKey == nil else {
                    throw HostCryptographicStateError.corruptRecord
                }
            case .tlsServerStaged:
                guard activeTLSKey != nil,
                      stagedTLSKey == nil,
                      retiringTLSKey == nil else {
                    throw HostCryptographicStateError.corruptRecord
                }
            default:
                throw HostCryptographicStateError.corruptRecord
            }
            let existing = try lifecycle.loadIfPresent(intent.applicationTag)
            if let existing {
                guard existing.storageKind == .permanentSecurityKey,
                      existing.persistedMaterial == intent.applicationTag,
                      !liveKeys.contains(where: { $0.publicKey == existing.publicKey }) else {
                    throw HostCryptographicStateError.keyRoleCollision
                }
            }
            creationInspection = HostCryptographicPendingTLSKeyCreation(
                targetRole: intent.targetRole,
                keyExists: existing != nil,
                publicKey: existing?.publicKey
            )
        } else {
            guard activeTLSKey != nil else {
                throw HostCryptographicStateError.corruptRecord
            }
            creationInspection = nil
        }

        var deletionInspections: [HostCryptographicPendingTLSKeyDeletion] = []
        for intent in record.pendingTLSKeyDeletions {
            guard let lifecycle = tlsKeyFactory.permanentLifecycle,
                  intent.key.storageKind == .permanentSecurityKey else {
                throw HostCryptographicStateError.corruptRecord
            }
            switch intent.formerRole {
            case .tlsServerStaged:
                guard stagedTLSKey == nil else {
                    throw HostCryptographicStateError.corruptRecord
                }
            case .tlsServerRetiring:
                guard retiringTLSKey == nil else {
                    throw HostCryptographicStateError.corruptRecord
                }
            default:
                throw HostCryptographicStateError.corruptRecord
            }
            let recorded = try recordedPublicKey(intent.key, role: intent.formerRole)
            guard !liveKeys.contains(where: { $0.publicKey == recorded }) else {
                throw HostCryptographicStateError.keyRoleCollision
            }
            let existing = try lifecycle.loadIfPresent(intent.key.material)
            if let existing {
                guard existing.protection == intent.key.protection,
                      existing.publicKey == recorded,
                      existing.persistedMaterial == intent.key.material else {
                    throw HostCryptographicStateError.publicKeyMismatch(
                        role: intent.formerRole
                    )
                }
            }
            deletionInspections.append(
                HostCryptographicPendingTLSKeyDeletion(
                    formerRole: intent.formerRole,
                    publicKey: recorded,
                    keyExists: existing != nil
                )
            )
        }

        return HostCryptographicStateInspection(
            tuple: tuple,
            authorityKey: authorityKey,
            activeTLSKey: activeTLSKey,
            stagedTLSKey: stagedTLSKey,
            retiringTLSKey: retiringTLSKey,
            securityRegistryRevision: record.securityRegistryRevision,
            highestIssuedTransportSetEpoch: record.highestIssuedTransportSetEpoch,
            pendingTLSKeyCreation: creationInspection,
            pendingTLSKeyDeletions: deletionInspections
        )
    }

    private func restoredRoleKeys(
        _ record: PersistedHostCryptographicState
    ) throws -> [HostProtectedP256SigningKey] {
        var keys = [try restore(record.authorityKey, role: .authoritySigning)]
        if let active = record.activeTLSKey {
            keys.append(try restore(active, role: .tlsServer))
        }
        if let staged = record.stagedTLSKey {
            keys.append(try restore(staged, role: .tlsServerStaged))
        }
        if let retiring = record.retiringTLSKey {
            keys.append(try restore(retiring, role: .tlsServerRetiring))
        }
        return keys
    }

    private static func tuple(
        for record: PersistedHostCryptographicState
    ) -> HostCryptographicStateTuple {
        HostCryptographicStateTuple(
            libraryID: record.libraryID,
            hostAuthorityID: record.hostAuthorityID,
            hostStateID: record.hostStateID
        )
    }

    private static func requireDistinct(_ keys: [P256X963PublicKey]) throws {
        for firstIndex in keys.indices {
            for secondIndex in keys.indices where secondIndex > firstIndex {
                guard keys[firstIndex] != keys[secondIndex] else {
                    throw HostCryptographicStateError.keyRoleCollision
                }
            }
        }
    }

    private func recordedPublicKey(
        _ persisted: PersistedHostP256Key,
        role: HostCryptographicKeyRole
    ) throws -> P256X963PublicKey {
        do {
            return try P256X963PublicKey(persisted.publicKeyX963)
        } catch {
            throw HostCryptographicStateError.publicKeyMismatch(role: role)
        }
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

    public func inspect(
        requiredTuple: HostCryptographicStateTuple
    ) async throws -> HostCryptographicStateInspection {
        try await repository.inspect(requiredTuple: requiredTuple)
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

    public func stageReplacementTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedActivePublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        try await repository.stageReplacementTLSIdentity(
            for: tuple,
            expectedActivePublicKey: expectedActivePublicKey
        )
    }

    public func promoteStagedTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedActivePublicKey: P256X963PublicKey,
        expectedStagedPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        try await repository.promoteStagedTLSIdentity(
            for: tuple,
            expectedActivePublicKey: expectedActivePublicKey,
            expectedStagedPublicKey: expectedStagedPublicKey
        )
    }

    public func discardStagedTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedStagedPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        try await repository.discardStagedTLSIdentity(
            for: tuple,
            expectedStagedPublicKey: expectedStagedPublicKey
        )
    }

    public func finalizeRetiringTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedRetiringPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState {
        try await repository.finalizeRetiringTLSIdentity(
            for: tuple,
            expectedRetiringPublicKey: expectedRetiringPublicKey
        )
    }
}
