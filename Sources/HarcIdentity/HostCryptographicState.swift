import Foundation
import HarcDomain

/// The exact public host identity that must agree across canonical metadata,
/// `HarcHost.db`, and the protected host key record.
public struct HostCryptographicStateTuple: Codable, Equatable, Hashable, Sendable {
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

/// A caller either enables a genuinely new host for a known canonical library,
/// or proves the complete tuple of an already-enabled host. The second form
/// never creates replacement keys when the protected record is missing.
public enum HostCryptographicStateRequirement: Equatable, Sendable {
    case loadOrCreate(libraryID: LibraryID)
    case requireExisting(HostCryptographicStateTuple)
}

public enum HostCryptographicKeyRole: String, Codable, Equatable, Sendable {
    case authoritySigning
    case tlsServer
    case tlsServerStaged
    case tlsServerRetiring
}

public enum HostCryptographicMark: String, Codable, Equatable, Sendable {
    case securityRegistryRevision
    case highestIssuedTransportSetEpoch
}

public enum HostCryptographicStateError: Error, Equatable, Sendable {
    case keyRecordMissing(expected: HostCryptographicStateTuple)
    case libraryMismatch(expected: LibraryID, actual: LibraryID)
    case tupleMismatch(
        expected: HostCryptographicStateTuple,
        actual: HostCryptographicStateTuple
    )
    case corruptKeychainItem
    case corruptRecord
    case unsupportedRecordVersion(UInt16)
    case privateKeyUnavailable(role: HostCryptographicKeyRole)
    case publicKeyMismatch(role: HostCryptographicKeyRole)
    case authorityIdentityMismatch
    case keyRoleCollision
    case tlsKeyTransitionInProgress
    case stagedTLSKeyMissing
    case retiringTLSKeyMissing
    case unexpectedTLSKey(role: HostCryptographicKeyRole)
    case tlsKeyExpectationMismatch(role: HostCryptographicKeyRole)
    case invalidCertificateValidity
    case transportSetExtensionEmpty
    case transportSetExtensionTooLarge(actual: Int)
    case invalidServerCertificate
    case serverCertificateKeyMismatch
    case serverIdentityUnavailable
    case certificateProfileMismatch(field: String)
    case secureRandomFailure(Int32)
    case monotonicityViolation(
        mark: HostCryptographicMark,
        current: UInt64,
        expected: UInt64,
        proposed: UInt64
    )
    case concurrentModification
    case unexpectedKeychainStatus(Int32)
    case persistentKeyDeletionIncomplete(role: HostCryptographicKeyRole)
}

extension HostCryptographicStateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keyRecordMissing:
            "The known host key record is missing. Harc will not mint a replacement authority implicitly."
        case .libraryMismatch:
            "The protected host key record belongs to a different canonical library."
        case .tupleMismatch:
            "The protected host identity does not match canonical and host database metadata."
        case .corruptKeychainItem:
            "The host Keychain item is malformed or fails its stored integrity binding."
        case .corruptRecord:
            "The protected host key record is malformed."
        case .unsupportedRecordVersion(let version):
            "The protected host key record uses unsupported version \(version)."
        case .privateKeyUnavailable(let role):
            "The protected \(role.rawValue) private key is unavailable or invalid."
        case .publicKeyMismatch(let role):
            "The protected \(role.rawValue) private key does not match its recorded public key."
        case .authorityIdentityMismatch:
            "The recorded host authority ID does not derive from the authority public key."
        case .keyRoleCollision:
            "The host authority and every TLS server role must use distinct P-256 keys."
        case .tlsKeyTransitionInProgress:
            "A TLS key transition is already in progress."
        case .stagedTLSKeyMissing:
            "No staged TLS server key is available to promote or discard."
        case .retiringTLSKeyMissing:
            "No retiring TLS server key is available to finalize."
        case .unexpectedTLSKey(let role):
            "The protected record contains an unexpected \(role.rawValue) key for its lifecycle state."
        case .tlsKeyExpectationMismatch(let role):
            "The protected \(role.rawValue) key changed before the requested transition."
        case .invalidCertificateValidity:
            "The TLS certificate validity must be finite, positive, no longer than 90 days, and contained by its transport-set entry."
        case .transportSetExtensionEmpty:
            "The TLS certificate requires one framed signed transport-set object."
        case .transportSetExtensionTooLarge(let actual):
            "The framed signed transport-set extension exceeds 4096 bytes (received \(actual))."
        case .invalidServerCertificate:
            "The TLS server certificate is not valid DER."
        case .serverCertificateKeyMismatch:
            "The TLS server certificate does not contain the protected TLS public key."
        case .serverIdentityUnavailable:
            "The matching permanent TLS private key and certificate could not form a server identity."
        case .certificateProfileMismatch(let field):
            "The TLS server certificate violates the required Harc profile at \(field)."
        case .secureRandomFailure(let status):
            "Secure random generation failed with status \(status)."
        case .monotonicityViolation(let mark, let current, let expected, let proposed):
            "Invalid \(mark.rawValue) transition: stored \(current), expected \(expected), proposed \(proposed)."
        case .concurrentModification:
            "The protected host key record changed concurrently; the operation failed closed."
        case .unexpectedKeychainStatus(let status):
            "The Keychain returned unexpected status \(status)."
        case .persistentKeyDeletionIncomplete(let role):
            "The retired \(role.rawValue) private key could not be proven absent from the Keychain."
        }
    }
}

/// Stable host-authority signing capability. Only the public key and signing
/// operation cross the module boundary; private or opaque key bytes do not.
public struct HostAuthoritySigningIdentity: P256DigestSigner, Sendable {
    private let key: HostProtectedP256SigningKey

    init(key: HostProtectedP256SigningKey) {
        self.key = key
    }

    public var publicKey: P256X963PublicKey { key.publicKey }
    public var hostAuthorityID: HostAuthorityID { publicKey.hostAuthorityID }
    public var keyProtection: InstallationKeyProtection { key.protection }

    public func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        try key.sign(digest: digest)
    }
}

/// The distinct P-256 TLS server key capability. Its narrow X.509 issuance API
/// returns only an installed `SecIdentity` plus public certificate facts; the
/// permanent private `SecKey` remains module-internal.
public struct HostTLSSigningIdentity: Sendable {
    let key: HostProtectedP256SigningKey

    init(key: HostProtectedP256SigningKey) {
        self.key = key
    }

    package var publicKey: P256X963PublicKey { key.publicKey }
    package var keyProtection: InstallationKeyProtection { key.protection }
}

/// A validated snapshot of the single protected host record.
public struct HostCryptographicState: Sendable {
    public let tuple: HostCryptographicStateTuple
    public let authorityIdentity: HostAuthoritySigningIdentity
    public let activeTLSIdentity: HostTLSSigningIdentity
    public let stagedTLSIdentity: HostTLSSigningIdentity?
    public let retiringTLSIdentity: HostTLSSigningIdentity?
    /// Compatibility spelling. The sole serving identity is always the active
    /// slot; staged and retiring keys are never selected implicitly.
    public let tlsIdentity: HostTLSSigningIdentity
    public let securityRegistryRevision: UInt64
    public let highestIssuedTransportSetEpoch: UInt64

    init(
        tuple: HostCryptographicStateTuple,
        authorityKey: HostProtectedP256SigningKey,
        activeTLSKey: HostProtectedP256SigningKey,
        stagedTLSKey: HostProtectedP256SigningKey?,
        retiringTLSKey: HostProtectedP256SigningKey?,
        securityRegistryRevision: UInt64,
        highestIssuedTransportSetEpoch: UInt64
    ) {
        self.tuple = tuple
        self.authorityIdentity = HostAuthoritySigningIdentity(key: authorityKey)
        self.activeTLSIdentity = HostTLSSigningIdentity(key: activeTLSKey)
        self.stagedTLSIdentity = stagedTLSKey.map(HostTLSSigningIdentity.init(key:))
        self.retiringTLSIdentity = retiringTLSKey.map(HostTLSSigningIdentity.init(key:))
        self.tlsIdentity = self.activeTLSIdentity
        self.securityRegistryRevision = securityRegistryRevision
        self.highestIssuedTransportSetEpoch = highestIssuedTransportSetEpoch
    }
}

/// Read-only facts about a crash-interrupted permanent TLS-key creation. The
/// application tag and other private storage descriptors never leave this
/// module.
public struct HostCryptographicPendingTLSKeyCreation: Sendable {
    public let targetRole: HostCryptographicKeyRole
    public let keyExists: Bool
    public let publicKey: P256X963PublicKey?

    init(
        targetRole: HostCryptographicKeyRole,
        keyExists: Bool,
        publicKey: P256X963PublicKey?
    ) {
        self.targetRole = targetRole
        self.keyExists = keyExists
        self.publicKey = publicKey
    }
}

/// Read-only facts about a permanent TLS key whose role was removed but whose
/// checked Keychain deletion has not yet been durably acknowledged.
public struct HostCryptographicPendingTLSKeyDeletion: Sendable {
    public let formerRole: HostCryptographicKeyRole
    public let publicKey: P256X963PublicKey
    public let keyExists: Bool

    init(
        formerRole: HostCryptographicKeyRole,
        publicKey: P256X963PublicKey,
        keyExists: Bool
    ) {
        self.formerRole = formerRole
        self.publicKey = publicKey
        self.keyExists = keyExists
    }
}

/// A non-mutating view used to cross-check HostDB and transport journals before
/// ordinary resolution is allowed to repair a protected-record journal.
public struct HostCryptographicStateInspection: Sendable {
    public let tuple: HostCryptographicStateTuple
    public let authorityPublicKey: P256X963PublicKey
    public let activeTLSPublicKey: P256X963PublicKey?
    public let stagedTLSPublicKey: P256X963PublicKey?
    public let retiringTLSPublicKey: P256X963PublicKey?
    public let securityRegistryRevision: UInt64
    public let highestIssuedTransportSetEpoch: UInt64
    public let pendingTLSKeyCreation: HostCryptographicPendingTLSKeyCreation?
    public let pendingTLSKeyDeletions: [HostCryptographicPendingTLSKeyDeletion]

    init(
        tuple: HostCryptographicStateTuple,
        authorityKey: HostProtectedP256SigningKey,
        activeTLSKey: HostProtectedP256SigningKey?,
        stagedTLSKey: HostProtectedP256SigningKey?,
        retiringTLSKey: HostProtectedP256SigningKey?,
        securityRegistryRevision: UInt64,
        highestIssuedTransportSetEpoch: UInt64,
        pendingTLSKeyCreation: HostCryptographicPendingTLSKeyCreation?,
        pendingTLSKeyDeletions: [HostCryptographicPendingTLSKeyDeletion]
    ) {
        self.tuple = tuple
        authorityPublicKey = authorityKey.publicKey
        activeTLSPublicKey = activeTLSKey?.publicKey
        stagedTLSPublicKey = stagedTLSKey?.publicKey
        retiringTLSPublicKey = retiringTLSKey?.publicKey
        self.securityRegistryRevision = securityRegistryRevision
        self.highestIssuedTransportSetEpoch = highestIssuedTransportSetEpoch
        self.pendingTLSKeyCreation = pendingTLSKeyCreation
        self.pendingTLSKeyDeletions = pendingTLSKeyDeletions
    }
}

/// Persistence boundary for the authority/TLS keys, exact host tuple, and the
/// two Keychain anti-rollback marks.
public protocol HostCryptographicStateStore: Sendable {
    func resolve(
        _ requirement: HostCryptographicStateRequirement
    ) async throws -> HostCryptographicState

    /// Parses and validates the protected record without migration, journal
    /// recovery, key creation/deletion, record CAS, or mark changes.
    func inspect(
        requiredTuple: HostCryptographicStateTuple
    ) async throws -> HostCryptographicStateInspection

    @discardableResult
    func advanceSecurityRegistryRevision(
        for tuple: HostCryptographicStateTuple,
        from expectedRevision: UInt64,
        to newRevision: UInt64
    ) async throws -> HostCryptographicState

    @discardableResult
    func advanceHighestIssuedTransportSetEpoch(
        for tuple: HostCryptographicStateTuple,
        from expectedEpoch: UInt64,
        to newEpoch: UInt64
    ) async throws -> HostCryptographicState

    /// Durably records a creation intent, creates or recovers its exact
    /// permanent key, and atomically publishes it into the staged slot.
    @discardableResult
    func stageReplacementTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedActivePublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState

    /// Atomically promotes staged -> active and active -> retiring. Promotion
    /// is only legal after the overlap transport set has been durably
    /// published and its retirement floor has elapsed.
    @discardableResult
    func promoteStagedTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedActivePublicKey: P256X963PublicKey,
        expectedStagedPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState

    /// Removes an unpublished staged key through the durable deletion journal.
    @discardableResult
    func discardStagedTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedStagedPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState

    /// Removes the old key after a one-key transport set and matching active
    /// leaf are durable, through the durable deletion journal.
    @discardableResult
    func finalizeRetiringTLSIdentity(
        for tuple: HostCryptographicStateTuple,
        expectedRetiringPublicKey: P256X963PublicKey
    ) async throws -> HostCryptographicState
}

extension HostCryptographicStateStore {
    public func load(
        requiredTuple: HostCryptographicStateTuple
    ) async throws -> HostCryptographicState {
        try await resolve(.requireExisting(requiredTuple))
    }

    public func loadOrCreate(
        libraryID: LibraryID
    ) async throws -> HostCryptographicState {
        try await resolve(.loadOrCreate(libraryID: libraryID))
    }
}

enum HostProtectedP256SigningKey: Sendable {
    case secureEnclave(SecureEnclaveP256SigningKey)
    case keychainSoftware(SoftwareP256SigningKey)
    case securityFramework(HostSecurityP256SigningKey)

    var protection: InstallationKeyProtection {
        switch self {
        case .secureEnclave: .secureEnclave
        case .keychainSoftware: .keychainSoftware
        case .securityFramework(let key): key.protection
        }
    }

    var publicKey: P256X963PublicKey {
        switch self {
        case .secureEnclave(let key): key.publicKey
        case .keychainSoftware(let key): key.publicKey
        case .securityFramework(let key): key.publicKey
        }
    }

    func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        switch self {
        case .secureEnclave(let key): try key.sign(digest: digest)
        case .keychainSoftware(let key): try key.sign(digest: digest)
        case .securityFramework(let key): try key.sign(digest: digest)
        }
    }

    var persistedMaterial: Data {
        switch self {
        case .secureEnclave(let key): key.persistedOpaqueDataRepresentation
        case .keychainSoftware(let key): key.persistedRawRepresentation
        case .securityFramework(let key): key.applicationTag
        }
    }

    func deleteUncommittedPersistentKeyBestEffort() {
        guard case .securityFramework(let key) = self else { return }
        key.deletePersistentKeyBestEffort()
    }

    var storageKind: HostPersistedKeyStorageKind {
        switch self {
        case .secureEnclave, .keychainSoftware: .embeddedMaterial
        case .securityFramework: .permanentSecurityKey
        }
    }
}

enum HostPersistedKeyStorageKind: String, Codable, Sendable {
    case embeddedMaterial
    case permanentSecurityKey
}
