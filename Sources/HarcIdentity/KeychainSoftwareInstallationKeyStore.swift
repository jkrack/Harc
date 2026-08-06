import Foundation
import Security

public enum InstallationKeychainError: Error, Equatable, Sendable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidStoredItem
    case invalidStoredKey
    case duplicateItemCouldNotBeReloaded

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let systemMessage = SecCopyErrorMessageString(status, nil)
                .map { String($0) }
                ?? "Unknown Keychain error"
            return "The Keychain operation failed (OSStatus \(status)): \(systemMessage)"
        case .invalidStoredItem:
            return "The stored installation identity has an unexpected Keychain format."
        case .invalidStoredKey:
            return "The stored installation identity contains an invalid signing key."
        case .duplicateItemCouldNotBeReloaded:
            return "The installation identity already exists in Keychain but could not be reloaded."
        }
    }
}

/// Selects the Security.framework Keychain domain appropriate to the shipping
/// process. iOS application identities use the Data Protection Keychain.
/// Harc's non-sandboxed Developer ID macOS processes are not provisioned for
/// that domain and must use the local, non-synchronizing login Keychain.
public enum InstallationKeychainDomain: Equatable, Sendable {
    case dataProtection
    case legacyMacOS
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
    private let domain: InstallationKeychainDomain

    public init(
        service: String = KeychainSoftwareInstallationKeyStore.defaultService,
        account: String = KeychainSoftwareInstallationKeyStore.defaultAccount,
        domain: InstallationKeychainDomain = .dataProtection
    ) {
        precondition(!service.isEmpty)
        precondition(!account.isEmpty)
        self.service = service
        self.account = account
        self.domain = domain
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if domain == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        }
        return query
    }

    private var loadQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}
