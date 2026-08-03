import Foundation
import Security

/// Keychain persistence for CryptoKit's same-device Secure Enclave key
/// reference. The stored blob is opaque and cannot export the private key.
public actor SecureEnclaveInstallationKeyStore: InstallationSigningKeyStore {
    public static let defaultService = "com.harc.Harc.installation-identity"
    public static let defaultAccount = "device-p256-secure-enclave-v1"

    private let service: String
    private let account: String

    public init(
        service: String = SecureEnclaveInstallationKeyStore.defaultService,
        account: String = SecureEnclaveInstallationKeyStore.defaultAccount
    ) {
        precondition(!service.isEmpty)
        precondition(!account.isEmpty)
        self.service = service
        self.account = account
    }

    public func load() throws -> InstallationSigningKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw InstallationKeychainError.invalidStoredItem
            }
            return InstallationSigningKey(
                secureEnclave: try SecureEnclaveP256SigningKey(
                    opaqueDataRepresentation: data
                )
            )
        case errSecItemNotFound:
            return nil
        default:
            throw InstallationKeychainError.unexpectedStatus(status)
        }
    }

    public func createPreferredIfAbsent() throws -> InstallationSigningKeyInsertResult {
        if let existing = try load() {
            return InstallationSigningKeyInsertResult(key: existing, inserted: false)
        }
        let secureKey = try SecureEnclaveP256SigningKey()
        let candidate = InstallationSigningKey(secureEnclave: secureKey)
        var attributes = baseQuery
        attributes[kSecValueData as String] = secureKey.persistedOpaqueDataRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Harc Secure Enclave device signing identity"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return InstallationSigningKeyInsertResult(key: candidate, inserted: true)
        case errSecDuplicateItem:
            guard let existing = try load() else {
                throw InstallationKeychainError.duplicateItemCouldNotBeReloaded
            }
            return InstallationSigningKeyInsertResult(key: existing, inserted: false)
        default:
            throw InstallationKeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
    }

    private var loadQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}

/// Production selector: preserve any existing identity, otherwise prefer a
/// noninteractive Secure Enclave key and use Keychain software only when the
/// capability is unavailable (including simulators).
public actor PreferredInstallationSigningKeyStore: InstallationSigningKeyStore {
    private let secureEnclaveStore: any InstallationSigningKeyStore
    private let softwareStore: any InstallationSigningKeyStore
    private let secureEnclaveAvailable: @Sendable () -> Bool

    public init() {
        self.secureEnclaveStore = SecureEnclaveInstallationKeyStore()
        self.softwareStore = KeychainSoftwareInstallationKeyStore()
        self.secureEnclaveAvailable = { SecureEnclaveP256SigningKey.isAvailable }
    }

    init(
        secureEnclaveStore: any InstallationSigningKeyStore,
        softwareStore: any InstallationSigningKeyStore,
        secureEnclaveAvailable: @escaping @Sendable () -> Bool
    ) {
        self.secureEnclaveStore = secureEnclaveStore
        self.softwareStore = softwareStore
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    public func load() async throws -> InstallationSigningKey? {
        if let secureKey = try await secureEnclaveStore.load() {
            return secureKey
        }
        return try await softwareStore.load()
    }

    public func createPreferredIfAbsent() async throws -> InstallationSigningKeyInsertResult {
        if let existing = try await load() {
            return InstallationSigningKeyInsertResult(key: existing, inserted: false)
        }
        if secureEnclaveAvailable() {
            return try await secureEnclaveStore.createPreferredIfAbsent()
        }
        return try await softwareStore.createPreferredIfAbsent()
    }
}
