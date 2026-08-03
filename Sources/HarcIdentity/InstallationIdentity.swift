import Foundation
import HarcDomain

/// Durable evidence outside the key item that distinguishes a genuinely clean
/// installation from loss of a previously used installation key.
public struct InstallationIdentityEvidence: Equatable, Sendable {
    public let rememberedDeviceID: DeviceID?
    public let hasPriorIdentityState: Bool
    public let hasIdentityBoundCaptures: Bool

    public init(
        rememberedDeviceID: DeviceID? = nil,
        hasPriorIdentityState: Bool = false,
        hasIdentityBoundCaptures: Bool = false
    ) {
        self.rememberedDeviceID = rememberedDeviceID
        self.hasPriorIdentityState = hasPriorIdentityState
        self.hasIdentityBoundCaptures = hasIdentityBoundCaptures
    }

    public static let cleanInstallation = InstallationIdentityEvidence()

    public var requiresExistingIdentity: Bool {
        rememberedDeviceID != nil || hasPriorIdentityState || hasIdentityBoundCaptures
    }
}

public struct InstallationKeyLoss: Equatable, Sendable {
    public let rememberedDeviceID: DeviceID?
    public let hasIdentityBoundCaptures: Bool

    public init(rememberedDeviceID: DeviceID?, hasIdentityBoundCaptures: Bool) {
        self.rememberedDeviceID = rememberedDeviceID
        self.hasIdentityBoundCaptures = hasIdentityBoundCaptures
    }
}

public enum InstallationIdentityOrigin: String, Equatable, Sendable {
    case existingKey
    case newlyCreatedKey
}

public enum InstallationIdentityResolution: Sendable {
    case available(identity: InstallationSigningIdentity, origin: InstallationIdentityOrigin)
    case keyLoss(InstallationKeyLoss)
}

public enum InstallationIdentityError: Error, Equatable, Sendable {
    case rememberedIdentityMismatch(expected: DeviceID, actual: DeviceID)
}

/// Atomic result from installing a candidate key into an empty store.
public enum InstallationKeyProtection: String, Codable, Sendable {
    case secureEnclave
    case keychainSoftware
}

/// Type-erased installation signer that retains its protection class without
/// exposing private or opaque key material.
public struct InstallationSigningKey: P256DigestSigner, Sendable {
    private let signer: any P256DigestSigner
    public let protection: InstallationKeyProtection

    public init(secureEnclave key: SecureEnclaveP256SigningKey) {
        self.init(signer: key, protection: .secureEnclave)
    }

    public init(keychainSoftware key: SoftwareP256SigningKey) {
        self.init(signer: key, protection: .keychainSoftware)
    }

    init(signer: any P256DigestSigner, protection: InstallationKeyProtection) {
        self.signer = signer
        self.protection = protection
    }

    public var publicKey: P256X963PublicKey { signer.publicKey }

    public func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        try signer.sign(digest: digest)
    }
}

public struct InstallationSigningKeyInsertResult: Sendable {
    public let key: InstallationSigningKey
    public let inserted: Bool

    public init(key: InstallationSigningKey, inserted: Bool) {
        self.key = key
        self.inserted = inserted
    }
}

/// Storage and capability-selection seam for the installation key.
public protocol InstallationSigningKeyStore: Sendable {
    func load() async throws -> InstallationSigningKey?
    func createPreferredIfAbsent() async throws -> InstallationSigningKeyInsertResult
}

/// In-memory implementation used by transport-free services and focused tests.
public actor InMemorySoftwareInstallationKeyStore: InstallationSigningKeyStore {
    private var key: InstallationSigningKey?
    private let keyFactory: @Sendable () throws -> InstallationSigningKey

    public init(initialKey: SoftwareP256SigningKey? = nil) {
        self.key = initialKey.map(InstallationSigningKey.init(keychainSoftware:))
        self.keyFactory = {
            InstallationSigningKey(keychainSoftware: SoftwareP256SigningKey())
        }
    }

    init(
        initialKey: InstallationSigningKey? = nil,
        keyFactory: @escaping @Sendable () throws -> InstallationSigningKey
    ) {
        self.key = initialKey
        self.keyFactory = keyFactory
    }

    public func load() -> InstallationSigningKey? { key }

    public func createPreferredIfAbsent() throws -> InstallationSigningKeyInsertResult {
        if let key {
            return InstallationSigningKeyInsertResult(key: key, inserted: false)
        }
        let candidate = try keyFactory()
        key = candidate
        return InstallationSigningKeyInsertResult(key: candidate, inserted: true)
    }

    func removeForTesting() {
        key = nil
    }

    func hasKeyForTesting() -> Bool { key != nil }
}

/// Resolves the installation identity without ever replacing a missing known
/// key implicitly. OS-authenticated key-loss recovery is a separate app/host
/// control-plane operation; old captures retain their old producing identity.
public struct InstallationIdentityManager: Sendable {
    private let keyStore: any InstallationSigningKeyStore

    public init(keyStore: any InstallationSigningKeyStore) {
        self.keyStore = keyStore
    }

    public func resolve(
        evidence: InstallationIdentityEvidence
    ) async throws -> InstallationIdentityResolution {
        if let key = try await keyStore.load() {
            let identity = InstallationSigningIdentity(key: key)
            try validateRememberedIdentity(evidence.rememberedDeviceID, against: identity)
            return .available(identity: identity, origin: .existingKey)
        }

        guard !evidence.requiresExistingIdentity else {
            return .keyLoss(
                InstallationKeyLoss(
                    rememberedDeviceID: evidence.rememberedDeviceID,
                    hasIdentityBoundCaptures: evidence.hasIdentityBoundCaptures
                )
            )
        }

        let result = try await keyStore.createPreferredIfAbsent()
        let identity = InstallationSigningIdentity(key: result.key)
        return .available(
            identity: identity,
            origin: result.inserted ? .newlyCreatedKey : .existingKey
        )
    }

    private func validateRememberedIdentity(
        _ rememberedDeviceID: DeviceID?,
        against identity: InstallationSigningIdentity
    ) throws {
        guard let rememberedDeviceID, rememberedDeviceID != identity.deviceID else {
            return
        }
        throw InstallationIdentityError.rememberedIdentityMismatch(
            expected: rememberedDeviceID,
            actual: identity.deviceID
        )
    }
}
