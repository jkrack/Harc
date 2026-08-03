import Foundation
import Security

public enum InstallationKeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidStoredItem
    case invalidStoredKey
    case duplicateItemCouldNotBeReloaded
}

/// Keychain-backed software fallback for hardware that cannot provide a
/// noninteractive Secure Enclave signing key.
///
/// The item is non-synchronizing and uses
/// `AfterFirstUnlockThisDeviceOnly`, matching background-signing requirements.
/// Private bytes never leave this module through a public API.
public actor KeychainSoftwareInstallationKeyStore: InstallationSigningKeyStore {
    public static let defaultService = "com.harc.Harc.installation-identity"
    public static let defaultAccount = "device-p256-signing-v1"

    private let service: String
    private let account: String

    public init(
        service: String = KeychainSoftwareInstallationKeyStore.defaultService,
        account: String = KeychainSoftwareInstallationKeyStore.defaultAccount
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
            do {
                return InstallationSigningKey(
                    keychainSoftware: try SoftwareP256SigningKey(rawRepresentation: data)
                )
            } catch {
                throw InstallationKeychainError.invalidStoredKey
            }
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
        let softwareKey = SoftwareP256SigningKey()
        let candidate = InstallationSigningKey(keychainSoftware: softwareKey)
        var attributes = baseQuery
        attributes[kSecValueData as String] = softwareKey.persistedRawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Harc device signing identity"

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
