import CryptoKit
import Foundation
import HarcDomain
import LocalAuthentication
import Security

private enum HostCryptographicKeychainSynchronization {
    /// Keychain calls are synchronous. The digest attribute supplies the
    /// cross-process compare-and-swap predicate; this lock also prevents two
    /// repository instances in the resident process from interleaving a
    /// read/validate/update sequence.
    static let processLock = NSLock()
}

actor SecurityHostCryptographicStateRecordBackend: HostCryptographicStateRecordBackend {
    private let service: String
    private let account: String

    init(service: String, account: String) {
        precondition(!service.isEmpty)
        precondition(!account.isEmpty)
        self.service = service
        self.account = account
    }

    func loadRecord() throws -> Data? {
        HostCryptographicKeychainSynchronization.processLock.lock()
        defer { HostCryptographicKeychainSynchronization.processLock.unlock() }
        return try loadRecordLocked()
    }

    func insertRecordIfAbsent(_ record: Data) throws -> Bool {
        HostCryptographicKeychainSynchronization.processLock.lock()
        defer { HostCryptographicKeychainSynchronization.processLock.unlock() }

        var attributes = baseQuery
        attributes[kSecValueData as String] = record
        attributes[kSecAttrGeneric as String] = Self.integrityDigest(record)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] =
            "Harc host authority, TLS key references, and anti-rollback state"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw HostCryptographicStateError.unexpectedKeychainStatus(status)
        }
    }

    func replaceRecord(expected: Data, with replacement: Data) throws -> Bool {
        HostCryptographicKeychainSynchronization.processLock.lock()
        defer { HostCryptographicKeychainSynchronization.processLock.unlock() }

        guard let current = try loadRecordLocked() else { return false }
        guard current == expected else { return false }

        var query = operationQuery
        query[kSecAttrGeneric as String] = Self.integrityDigest(expected)
        let replacementAttributes: [String: Any] = [
            kSecValueData as String: replacement,
            kSecAttrGeneric as String: Self.integrityDigest(replacement),
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            replacementAttributes as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw HostCryptographicStateError.unexpectedKeychainStatus(status)
        }
    }

    private func loadRecordLocked() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let attributes = result as? [String: Any],
                  let record = attributes[kSecValueData as String] as? Data,
                  let storedDigest = attributes[kSecAttrGeneric as String] as? Data,
                  storedDigest == Self.integrityDigest(record),
                  let accessibility = attributes[kSecAttrAccessible as String] as? String,
                  accessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            else {
                throw HostCryptographicStateError.corruptKeychainItem
            }
            return record
        case errSecItemNotFound:
            return nil
        default:
            throw HostCryptographicStateError.unexpectedKeychainStatus(status)
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

    private var operationQuery: [String: Any] {
        var query = baseQuery
        // This record and both contained key references are intentionally
        // background-usable; Keychain must never display authentication UI.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private var loadQuery: [String: Any] {
        var query = operationQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func integrityDigest(_ record: Data) -> Data {
        Data(SHA256.hash(data: record))
    }
}

/// Production host cryptographic persistence. One non-synchronizing,
/// `AfterFirstUnlockThisDeviceOnly` Keychain item atomically binds the exact
/// host tuple, distinct active/staged/retiring key references, and both
/// anti-rollback marks.
public struct KeychainHostCryptographicStateStore: HostCryptographicStateStore, Sendable {
    public static let defaultService = "com.harc.Harc.host-cryptographic-state"
    public static let defaultAccount = "authority-tls-and-marks-v1"

    private let repository: HostCryptographicStateRepository

    public init(
        service: String = KeychainHostCryptographicStateStore.defaultService,
        account: String = KeychainHostCryptographicStateStore.defaultAccount
    ) {
        repository = HostCryptographicStateRepository(
            backend: SecurityHostCryptographicStateRecordBackend(
                service: service,
                account: account
            ),
            authorityKeyFactory: .preferred,
            tlsKeyFactory: .permanentTLS(
                applicationTagPrefix: "\(service).\(account).tls-p256-v1"
            )
        )
    }

    init(
        backend: any HostCryptographicStateRecordBackend,
        authorityKeyFactory: HostProtectedP256SigningKeyFactory = .software,
        tlsKeyFactory: HostProtectedP256SigningKeyFactory = .software,
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
        repository = HostCryptographicStateRepository(
            backend: backend,
            authorityKeyFactory: authorityKeyFactory,
            tlsKeyFactory: tlsKeyFactory,
            hostStateIDFactory: hostStateIDFactory,
            persistentSecurityKeyLoader: persistentSecurityKeyLoader
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
