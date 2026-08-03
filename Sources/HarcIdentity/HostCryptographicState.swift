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
            "The host authority and TLS server roles must use distinct P-256 keys."
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
public struct HostTLSSigningIdentity: P256DigestSigner, Sendable {
    let key: HostProtectedP256SigningKey

    init(key: HostProtectedP256SigningKey) {
        self.key = key
    }

    public var publicKey: P256X963PublicKey { key.publicKey }
    public var keyProtection: InstallationKeyProtection { key.protection }

    public func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        try key.sign(digest: digest)
    }
}

/// A validated snapshot of the single protected host record.
public struct HostCryptographicState: Sendable {
    public let tuple: HostCryptographicStateTuple
    public let authorityIdentity: HostAuthoritySigningIdentity
    public let tlsIdentity: HostTLSSigningIdentity
    public let securityRegistryRevision: UInt64
    public let highestIssuedTransportSetEpoch: UInt64

    init(
        tuple: HostCryptographicStateTuple,
        authorityKey: HostProtectedP256SigningKey,
        tlsKey: HostProtectedP256SigningKey,
        securityRegistryRevision: UInt64,
        highestIssuedTransportSetEpoch: UInt64
    ) {
        self.tuple = tuple
        self.authorityIdentity = HostAuthoritySigningIdentity(key: authorityKey)
        self.tlsIdentity = HostTLSSigningIdentity(key: tlsKey)
        self.securityRegistryRevision = securityRegistryRevision
        self.highestIssuedTransportSetEpoch = highestIssuedTransportSetEpoch
    }
}

/// Persistence boundary for the authority/TLS keys, exact host tuple, and the
/// two Keychain anti-rollback marks.
public protocol HostCryptographicStateStore: Sendable {
    func resolve(
        _ requirement: HostCryptographicStateRequirement
    ) async throws -> HostCryptographicState

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
