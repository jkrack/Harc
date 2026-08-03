import CryptoKit
import Foundation
import LocalAuthentication
@preconcurrency import Security

final class HostSecurityP256SigningKey: @unchecked Sendable {
    private enum KeychainDomain: Sendable {
        case dataProtection
        /// SwiftPM's unsigned test executable has no Data Protection Keychain
        /// entitlement. This package-internal domain exists only so tests can
        /// exercise a genuinely permanent SecKey and SecIdentity. Production
        /// creation and loading never select it.
        case legacyTestFixture
    }

    let applicationTag: Data
    let protection: InstallationKeyProtection
    let publicKey: P256X963PublicKey
    private let privateKey: SecKey
    private let keychainDomain: KeychainDomain

    private init(
        privateKey: SecKey,
        applicationTag: Data,
        protection: InstallationKeyProtection,
        keychainDomain: KeychainDomain
    ) throws {
        guard !applicationTag.isEmpty else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        self.privateKey = privateKey
        self.applicationTag = applicationTag
        self.protection = protection
        self.keychainDomain = keychainDomain
        try Self.validatePersistentAttributes(
            of: privateKey,
            applicationTag: applicationTag,
            protection: protection,
            keychainDomain: keychainDomain
        )
        self.publicKey = try Self.publicKey(for: privateKey)
    }

    static func createPreferred(applicationTag: Data) throws -> Self {
        if SecureEnclaveP256SigningKey.isAvailable {
            do {
                return try create(
                    applicationTag: applicationTag,
                    protection: .secureEnclave,
                    keychainDomain: .dataProtection
                )
            } catch {
                // A capability can be reported present while unavailable to
                // the current process (notably simulators and restored test
                // environments). Remove any partially-created tag before the
                // noninteractive Keychain-software fallback.
                _ = SecItemDelete(
                    keyQuery(
                        applicationTag: applicationTag,
                        keychainDomain: .dataProtection
                    ) as CFDictionary
                )
            }
        }
        return try create(
            applicationTag: applicationTag,
            protection: .keychainSoftware,
            keychainDomain: .dataProtection
        )
    }

    static func createSoftware(applicationTag: Data) throws -> Self {
        try create(
            applicationTag: applicationTag,
            protection: .keychainSoftware,
            keychainDomain: .dataProtection
        )
    }

    /// A package-internal fixture for unit tests hosted outside an entitled
    /// application. It retains permanent, non-synchronizing,
    /// AfterFirstUnlockThisDeviceOnly software-key semantics, but uses the
    /// legacy macOS Keychain because the SwiftPM runner cannot access the Data
    /// Protection Keychain.
    static func createLegacyKeychainTestFixture(applicationTag: Data) throws -> Self {
        try create(
            applicationTag: applicationTag,
            protection: .keychainSoftware,
            keychainDomain: .legacyTestFixture
        )
    }

    static func load(
        applicationTag: Data,
        protection: InstallationKeyProtection
    ) throws -> Self {
        try load(
            applicationTag: applicationTag,
            protection: protection,
            keychainDomain: .dataProtection
        )
    }

    static func loadLegacyKeychainTestFixture(
        applicationTag: Data,
        protection: InstallationKeyProtection
    ) throws -> Self {
        try load(
            applicationTag: applicationTag,
            protection: protection,
            keychainDomain: .legacyTestFixture
        )
    }

    private static func load(
        applicationTag: Data,
        protection: InstallationKeyProtection,
        keychainDomain: KeychainDomain
    ) throws -> Self {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            loadQuery(
                applicationTag: applicationTag,
                keychainDomain: keychainDomain
            ) as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        guard status == errSecSuccess else {
            throw HostCryptographicStateError.unexpectedKeychainStatus(status)
        }
        guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        let key = result as! SecKey
        return try Self(
            privateKey: key,
            applicationTag: applicationTag,
            protection: protection,
            keychainDomain: keychainDomain
        )
    }

    func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureDigestX962SHA256,
            digest.rawBytes as CFData,
            &signingError
        ) as Data? else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        do {
            let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
            return try P256RawSignature.normalizing(parsed.rawRepresentation)
        } catch {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
    }

    func copyPrivateKeyForCertificateIssuance() -> SecKey {
        privateKey
    }

    var usesDataProtectionKeychain: Bool {
        keychainDomain == .dataProtection
    }

    func deletePersistentKeyBestEffort() {
        _ = SecItemDelete(
            Self.keyQuery(
                applicationTag: applicationTag,
                keychainDomain: keychainDomain
            ) as CFDictionary
        )
    }

    private static func create(
        applicationTag: Data,
        protection: InstallationKeyProtection,
        keychainDomain: KeychainDomain
    ) throws -> Self {
        precondition(!applicationTag.isEmpty)
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: kCFBooleanTrue as Any,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrLabel as String: "Harc TLS server P-256 private key",
        ]

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        if keychainDomain == .dataProtection {
            attributes[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        }

        switch protection {
        case .secureEnclave:
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.privateKeyUsage],
                &accessControlError
            ) else {
                throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
            }
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            privateAttributes[kSecAttrAccessControl as String] = accessControl
        case .keychainSoftware:
            privateAttributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        attributes[kSecPrivateKeyAttrs as String] = privateAttributes

        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
            if let error = creationError?.takeRetainedValue(),
               CFErrorGetDomain(error) == (kCFErrorDomainOSStatus as CFString)
            {
                throw HostCryptographicStateError.unexpectedKeychainStatus(
                    OSStatus(CFErrorGetCode(error))
                )
            }
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        do {
            return try Self(
                privateKey: key,
                applicationTag: applicationTag,
                protection: protection,
                keychainDomain: keychainDomain
            )
        } catch {
            // `SecKeyCreateRandomKey` may have committed the permanent item
            // before a post-creation policy/public-key validation fails.
            // Never strand that unreferenced candidate.
            _ = SecItemDelete(
                keyQuery(
                    applicationTag: applicationTag,
                    keychainDomain: keychainDomain
                ) as CFDictionary
            )
            throw error
        }
    }

    private static func loadQuery(
        applicationTag: Data,
        keychainDomain: KeychainDomain
    ) -> [String: Any] {
        var query = keyQuery(
            applicationTag: applicationTag,
            keychainDomain: keychainDomain
        )
        query[kSecUseAuthenticationContext as String] = noninteractiveContext()
        query[kSecReturnRef as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func keyQuery(
        applicationTag: Data,
        keychainDomain: KeychainDomain
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if keychainDomain == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        }
        query[kSecUseAuthenticationContext as String] = noninteractiveContext()
        return query
    }

    private static func validatePersistentAttributes(
        of key: SecKey,
        applicationTag: Data,
        protection: InstallationKeyProtection,
        keychainDomain: KeychainDomain
    ) throws {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue == 256
        else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }

        let tokenID = attributes[kSecAttrTokenID as String] as? String
        switch protection {
        case .secureEnclave:
            guard tokenID == (kSecAttrTokenIDSecureEnclave as String) else {
                throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
            }
        case .keychainSoftware:
            guard tokenID != (kSecAttrTokenIDSecureEnclave as String) else {
                throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
            }
        }

        // `SecKeyCopyAttributes` does not reliably expose item persistence or
        // accessibility. Reload the item and its Keychain attributes by its
        // unique application tag instead; a successful exact lookup proves it
        // was made permanent, while the returned attributes prove the storage
        // policy.
        var query = keyQuery(
            applicationTag: applicationTag,
            keychainDomain: keychainDomain
        )
        query[kSecUseAuthenticationContext as String] = noninteractiveContext()
        query[kSecReturnRef as String] = kCFBooleanTrue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let reloaded = item[kSecValueRef as String],
              CFGetTypeID(reloaded as CFTypeRef) == SecKeyGetTypeID(),
              let storedTag = item[kSecAttrApplicationTag as String] as? Data,
              storedTag == applicationTag,
              (item[kSecAttrIsPermanent as String] as? NSNumber)?.boolValue == true,
              (item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true
        else {
            throw status == errSecSuccess
                ? HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
                : HostCryptographicStateError.unexpectedKeychainStatus(status)
        }
        if keychainDomain == .dataProtection {
            guard let accessibility = item[kSecAttrAccessible as String] as? String,
                  accessibility
                    == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            else {
                throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
            }
        } else if let accessibility = item[kSecAttrAccessible as String] as? String {
            // The legacy macOS Keychain normally omits this attribute on
            // return. If an implementation does expose it, it must agree with
            // the exact match predicate above.
            guard accessibility
                    == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            else {
                throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
            }
        }
        let reloadedKey = reloaded as! SecKey
        guard try publicKey(for: reloadedKey) == publicKey(for: key) else {
            throw HostCryptographicStateError.publicKeyMismatch(role: .tlsServer)
        }
    }

    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func publicKey(for privateKey: SecKey) throws -> P256X963PublicKey {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        var exportError: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
        do {
            return try P256X963PublicKey(bytes)
        } catch {
            throw HostCryptographicStateError.privateKeyUnavailable(role: .tlsServer)
        }
    }
}
