#if os(macOS)
import LocalAuthentication
import Foundation
import Security

/// Removes obsolete public leaves and their provably unreferenced Harc keys.
/// TLS keys retained by Host state remain durable pairing authority.
public enum HostTLSCertificateMigration {
    public struct Result: Sendable {
        public let certificatesRemoved: Int
        public let orphanKeysRemoved: Int
    }

    /// Idempotent, no trust changes, no authentication UI. Call off MainActor.
    /// Exact refs make concurrent cleanup safe (already absent is success).
    public static func removeLegacyCertificates() throws -> Result {
        var keychain: SecKeychain?
        let path = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        try check(SecKeychainOpen(path, &keychain))
        guard let keychain else { throw Failure.invalidResult }
        return try removeLegacyCertificates(from: keychain)
    }

    static func removeLegacyCertificates(from keychain: SecKeychain) throws -> Result {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecMatchSearchList: [keychain],
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
            kSecReturnAttributes: true,
            kSecUseAuthenticationContext: noninteractiveContext(),
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return Result(certificatesRemoved: 0, orphanKeysRemoved: 0) }
        try check(status)
        guard let items = result as? [[String: Any]] else { throw Failure.invalidResult }
        var candidates: [SecCertificate] = []
        var candidateKeys = Set<Data>()
        var otherKeys = Set<Data>()
        var allKeysComparable = true
        for item in items {
            guard let reference = item[kSecValueRef as String],
                  CFGetTypeID(reference as CFTypeRef) == SecCertificateGetTypeID() else {
                throw Failure.invalidResult
            }
            let certificate = reference as! SecCertificate
            let label = item[kSecAttrLabel as String] as? String
            let owned = (label == "Harc Local Host" || label == "Harc TLS server certificate")
                && matchesHarcProfile(certificate)
            let publicBytes = SecCertificateCopyKey(certificate).flatMap {
                SecKeyCopyExternalRepresentation($0, nil) as Data?
            }
            if owned {
                candidates.append(certificate)
                if let publicBytes { candidateKeys.insert(publicBytes) }
            } else if let publicBytes {
                otherKeys.insert(publicBytes)
            } else {
                allKeysComparable = false
            }
        }
        // Never remove a key also used by a certificate outside our migration.
        let removableKeys = allKeysComparable ? candidateKeys.subtracting(otherKeys) : []
        let keysRemoved = removableKeys.isEmpty ? 0 : try removeOrphanKeys(
            publicKeys: removableKeys, keychain: keychain
        )
        var removed = 0
        for certificate in candidates {
            let deletion = SecItemDelete([
                kSecClass: kSecClassCertificate,
                kSecMatchSearchList: [keychain],
                kSecValueRef: certificate,
                kSecUseAuthenticationContext: noninteractiveContext(),
            ] as CFDictionary)
            if deletion == errSecSuccess { removed += 1 }
            else if deletion != errSecItemNotFound { try check(deletion) }
        }
        return Result(certificatesRemoved: removed, orphanKeysRemoved: keysRemoved)
    }

    private static func removeOrphanKeys(
        publicKeys: Set<Data>, keychain: SecKeychain
    ) throws -> Int {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrLabel: "Harc TLS server P-256 private key",
            kSecMatchSearchList: [keychain],
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnRef: true,
            kSecUseAuthenticationContext: noninteractiveContext(),
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return 0 }
        try check(status)
        guard let keys = result as? [[String: Any]] else { throw Failure.invalidResult }
        let retained = try retainedKeyReferences(keychain: keychain)
        var count = 0
        for item in keys {
            guard let tag = item[kSecAttrApplicationTag as String] as? Data,
                  let text = String(data: tag, encoding: .utf8),
                  text.hasPrefix("com.harc.Harc.host-cryptographic-state.") || text.hasPrefix("com.harc.tests."),
                  let reference = item[kSecValueRef as String],
                  CFGetTypeID(reference as CFTypeRef) == SecKeyGetTypeID() else { continue }
            let key = reference as! SecKey
            guard let publicKey = SecKeyCopyPublicKey(key),
                  let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
                  publicKeys.contains(bytes) else { continue }
            // Snapshot candidate keys before reading authority. Creation always
            // commits a tagged intent first, and generation tags are never reused.
            // Preserve every active/staged/retiring/pending reference, including
            // records using a non-default service/account.
            // Missing authority is not proof that a production key is orphaned.
            if retained.isEmpty && !text.hasPrefix("com.harc.tests.") { continue }
            if retained.contains(tag.base64EncodedString()) { continue }
            let deletion = SecItemDelete([
                kSecClass: kSecClassKey,
                kSecValueRef: key,
                kSecMatchSearchList: [keychain],
                kSecUseAuthenticationContext: noninteractiveContext(),
            ] as CFDictionary)
            if deletion == errSecSuccess { count += 1 }
            else if deletion != errSecItemNotFound { try check(deletion) }
        }
        return count
    }

    private static func retainedKeyReferences(keychain: SecKeychain) throws -> Set<String> {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrLabel: "Harc host authority, TLS key references, and anti-rollback state",
            kSecMatchSearchList: [keychain],
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnPersistentRef: true,
            kSecUseAuthenticationContext: noninteractiveContext(),
        ] as CFDictionary, &result)
        if status != errSecItemNotFound { try check(status) }
        var records: [Data] = []
        if status == errSecSuccess {
            guard let references = result as? [Data] else { throw Failure.invalidResult }
            // Legacy Keychain rejects match-all password-data queries. Read
            // each already-selected authority item by its persistent reference.
            for reference in references {
                var value: CFTypeRef?
                let readStatus = SecItemCopyMatching([
                    kSecClass: kSecClassGenericPassword,
                    kSecValuePersistentRef: reference,
                    kSecMatchSearchList: [keychain],
                    kSecReturnData: true,
                    kSecUseAuthenticationContext: noninteractiveContext(),
                ] as CFDictionary, &value)
                try check(readStatus)
                guard let bytes = value as? Data else { throw Failure.invalidResult }
                records.append(bytes)
            }
        }
        // Always check the canonical authority by service/account too. An old
        // or manually edited display label cannot make its active key orphaned.
        var canonical: CFTypeRef?
        let canonicalStatus = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainHostCryptographicStateStore.defaultService,
            kSecAttrAccount: KeychainHostCryptographicStateStore.defaultAccount,
            kSecMatchSearchList: [keychain],
            kSecReturnData: true,
            kSecUseAuthenticationContext: noninteractiveContext(),
        ] as CFDictionary, &canonical)
        if canonicalStatus != errSecItemNotFound {
            try check(canonicalStatus)
            guard let bytes = canonical as? Data else { throw Failure.invalidResult }
            records.append(bytes)
        }
        var strings = Set<String>()
        func collect(_ value: Any) {
            if let string = value as? String { strings.insert(string) }
            else if let map = value as? [String: Any] { map.values.forEach(collect) }
            else if let array = value as? [Any] { array.forEach(collect) }
        }
        for record in records {
            guard let object = try JSONSerialization.jsonObject(with: record) as? [String: Any],
                  object["magic"] as? String == "harc-host-cryptographic-state",
                  let version = object["formatVersion"] as? Int,
                  (1...3).contains(version) else { throw Failure.invalidResult }
            collect(object)
        }
        return strings
    }

    static func matchesHarcProfile(_ certificate: SecCertificate) -> Bool {
        // Check the exact DER name, not a substring or displayed common name.
        let name = Data([0x30, 0x1a, 0x31, 0x18, 0x30, 0x16, 0x06, 0x03,
                         0x55, 0x04, 0x03, 0x0c, 0x0f]) + Data("Harc Local Host".utf8)
        let bytes = SecCertificateCopyData(certificate) as Data
        // The Harc certificate parser verifies its self-signature, exact name,
        // private extension and full profile before migration can delete it.
        return HostTLSServerCertificateFacts.isLegacyHarcCertificate(bytes, name: name)
    }

    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func check(_ status: OSStatus, operation: String = #function) throws {
        guard status == errSecSuccess else { throw Failure.keychain(status, operation) }
    }
    private enum Failure: Error { case keychain(OSStatus, String), invalidResult }
}
#endif
