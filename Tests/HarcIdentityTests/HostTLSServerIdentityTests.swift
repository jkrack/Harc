import Foundation
import HarcDomain
import Security
import Testing
@testable import HarcIdentity

@Suite("HarcIdentity permanent TLS key and X.509 server identity")
struct HostTLSServerIdentityTests {
    @Test("a permanent P-256 SecKey issues the exact Harc leaf and resolves a SecIdentity")
    func issuesAndResolvesServerIdentity() throws {
        let key = try HostSecurityP256SigningKey.createLegacyKeychainTestFixture(
            applicationTag: Data("com.harc.tests.tls.\(UUID())".utf8)
        )
        defer { key.deletePersistentKeyBestEffort() }
        let tlsIdentity = HostTLSSigningIdentity(key: .securityFramework(key))
        let request = try request(for: tlsIdentity)
        let fixedSerial = Data([0x12, 0x34, 0x56, 0x78])
        let issued = try tlsIdentity.issueServerIdentity(
            request: request,
            serialNumber: fixedSerial
        )
        defer { deleteCertificate(issued.certificate.certificateDER) }

        #expect(issued.certificate.serialNumber == fixedSerial)
        #expect(issued.certificate.publicKeyX963 == tlsIdentity.publicKey)
        #expect(issued.certificate.tlsSPKISHA256 == tlsIdentity.tlsSPKISHA256)
        #expect(
            issued.certificate.framedSignedTransportSet
                == request.framedSignedTransportSet
        )
        #expect(issued.certificate.notValidBefore >= request.transportSetEntryNotBefore)
        #expect(issued.certificate.notValidAfter <= request.transportSetEntryNotAfter)

        var certificate: SecCertificate?
        #expect(
            SecIdentityCopyCertificate(
                issued.securityIdentity,
                &certificate
            ) == errSecSuccess
        )
        let copied = try #require(certificate)
        #expect(SecCertificateCopyData(copied) as Data == issued.certificate.certificateDER)

        var privateKey: SecKey?
        #expect(
            SecIdentityCopyPrivateKey(
                issued.securityIdentity,
                &privateKey
            ) == errSecSuccess
        )
        #expect(privateKey != nil)

        let reparsed = try HostTLSServerCertificateFacts.validate(
            certificateDER: issued.certificate.certificateDER,
            request: request
        )
        #expect(reparsed == issued.certificate)
    }

    @Test("certificate requests reject invalid validity, SPKI, and extension bounds")
    func requestValidation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let digest = Data(repeating: 0x31, count: 32)

        #expect(throws: HostCryptographicStateError.self) {
            try HostTLSServerCertificateRequest(
                transportSetEntryNotBefore: start,
                transportSetEntryNotAfter: start,
                expectedTLSSPKISHA256: digest,
                framedSignedTransportSet: Data([1])
            )
        }
        #expect(throws: HostCryptographicStateError.self) {
            try HostTLSServerCertificateRequest(
                transportSetEntryNotBefore: start,
                transportSetEntryNotAfter: start + 91 * 24 * 60 * 60,
                expectedTLSSPKISHA256: digest,
                framedSignedTransportSet: Data([1])
            )
        }
        #expect(throws: HostCryptographicStateError.self) {
            try HostTLSServerCertificateRequest(
                transportSetEntryNotBefore: start,
                transportSetEntryNotAfter: start + 60,
                expectedTLSSPKISHA256: Data(repeating: 0, count: 31),
                framedSignedTransportSet: Data([1])
            )
        }
        #expect(throws: HostCryptographicStateError.self) {
            try HostTLSServerCertificateRequest(
                transportSetEntryNotBefore: start,
                transportSetEntryNotAfter: start + 60,
                expectedTLSSPKISHA256: digest,
                framedSignedTransportSet: Data()
            )
        }
        #expect(throws: HostCryptographicStateError.self) {
            try HostTLSServerCertificateRequest(
                transportSetEntryNotBefore: start,
                transportSetEntryNotAfter: start + 60,
                expectedTLSSPKISHA256: digest,
                framedSignedTransportSet: Data(
                    repeating: 0x44,
                    count: HostTLSServerCertificateRequest.maximumTransportSetExtensionBytes + 1
                )
            )
        }
    }

    @Test("SPKI binding and strict certificate parsing fail closed on tamper")
    func bindingAndParserNegatives() throws {
        let key = try HostSecurityP256SigningKey.createLegacyKeychainTestFixture(
            applicationTag: Data("com.harc.tests.tls.\(UUID())".utf8)
        )
        defer { key.deletePersistentKeyBestEffort() }
        let tlsIdentity = HostTLSSigningIdentity(key: .securityFramework(key))
        let request = try request(for: tlsIdentity)

        let wrongSPKI = try HostTLSServerCertificateRequest(
            transportSetEntryNotBefore: request.transportSetEntryNotBefore,
            transportSetEntryNotAfter: request.transportSetEntryNotAfter,
            expectedTLSSPKISHA256: Data(repeating: 0xa5, count: 32),
            framedSignedTransportSet: request.framedSignedTransportSet
        )
        #expect(throws: HostCryptographicStateError.self) {
            try tlsIdentity.issueServerIdentity(request: wrongSPKI)
        }

        let issued = try tlsIdentity.issueServerIdentity(
            request: request,
            serialNumber: Data([0x22])
        )
        defer { deleteCertificate(issued.certificate.certificateDER) }

        var extensionTamper = issued.certificate.certificateDER
        let extensionRange = try #require(
            extensionTamper.range(of: request.framedSignedTransportSet)
        )
        extensionTamper[extensionRange.lowerBound] ^= 0x01
        #expect(throws: HostCryptographicStateError.self) {
            try HostTLSServerCertificateFacts.validate(
                certificateDER: extensionTamper,
                request: request
            )
        }

        // The maximal long-form length used to overflow checked arithmetic in
        // a generic DER reader. Public validation must reject it, never trap.
        let hostileLength = Data([0x30, 0x88] + [UInt8](repeating: 0xff, count: 8))
        #expect(throws: HostCryptographicStateError.self) {
            try HostTLSServerCertificateFacts.validate(
                certificateDER: hostileLength,
                request: request
            )
        }
    }

    @Test("production issuance uses independent positive random serials")
    func randomSerials() throws {
        let key = try HostSecurityP256SigningKey.createLegacyKeychainTestFixture(
            applicationTag: Data("com.harc.tests.tls.\(UUID())".utf8)
        )
        defer { key.deletePersistentKeyBestEffort() }
        let tlsIdentity = HostTLSSigningIdentity(key: .securityFramework(key))
        let request = try request(for: tlsIdentity)

        let first = try tlsIdentity.issueServerIdentity(request: request)
        let second = try tlsIdentity.issueServerIdentity(request: request)
        defer {
            deleteCertificate(first.certificate.certificateDER)
            deleteCertificate(second.certificate.certificateDER)
        }

        #expect(first.certificate.serialNumber != second.certificate.serialNumber)
        for serial in [first.certificate.serialNumber, second.certificate.serialNumber] {
            #expect(!serial.isEmpty)
            #expect(serial.count <= 20)
            #expect(serial.first! & 0x80 == 0)
            #expect(serial.contains(where: { $0 != 0 }))
        }
    }

    @Test("a losing load-or-create CAS removes only its orphaned permanent TLS key")
    func concurrentCreationCleansLosingKey() async throws {
        let backend = ForcedConcurrentHostRecordBackend()
        let tracker = PermanentTLSKeyTracker()
        let tlsFactory = HostProtectedP256SigningKeyFactory {
            .securityFramework(try tracker.createKey())
        }
        let firstStore = KeychainHostCryptographicStateStore(
            backend: backend,
            tlsKeyFactory: tlsFactory,
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )
        let secondStore = KeychainHostCryptographicStateStore(
            backend: backend,
            tlsKeyFactory: tlsFactory,
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )
        let libraryID = LibraryID.random()

        async let first = firstStore.loadOrCreate(libraryID: libraryID)
        async let second = secondStore.loadOrCreate(libraryID: libraryID)
        let (firstState, secondState) = try await (first, second)
        #expect(firstState.tuple == secondState.tuple)
        #expect(firstState.tlsIdentity.publicKey == secondState.tlsIdentity.publicKey)

        let createdKeys = tracker.snapshot()
        defer { createdKeys.forEach { $0.deletePersistentKeyBestEffort() } }
        #expect(createdKeys.count == 2)
        let winningKey = try #require(
            createdKeys.first { $0.publicKey == firstState.tlsIdentity.publicKey }
        )
        let losingKey = try #require(
            createdKeys.first { $0.publicKey != firstState.tlsIdentity.publicKey }
        )
        #expect(
            try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                applicationTag: winningKey.applicationTag,
                protection: .keychainSoftware
            ).publicKey == winningKey.publicKey
        )
        #expect(throws: HostCryptographicStateError.self) {
            try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                applicationTag: losingKey.applicationTag,
                protection: .keychainSoftware
            )
        }
    }

    @Test("a failed record insert removes its orphaned permanent TLS key")
    func failedCreationCleansCandidateKey() async throws {
        let backend = RejectingHostRecordBackend()
        let tracker = PermanentTLSKeyTracker()
        let store = KeychainHostCryptographicStateStore(
            backend: backend,
            tlsKeyFactory: HostProtectedP256SigningKeyFactory {
                .securityFramework(try tracker.createKey())
            },
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )

        await #expect(throws: ForcedHostRecordFailure.insert) {
            try await store.loadOrCreate(libraryID: LibraryID.random())
        }

        let candidate = try #require(tracker.snapshot().only)
        defer { candidate.deletePersistentKeyBestEffort() }
        #expect(throws: HostCryptographicStateError.self) {
            try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                applicationTag: candidate.applicationTag,
                protection: .keychainSoftware
            )
        }
    }

    private func request(
        for identity: HostTLSSigningIdentity
    ) throws -> HostTLSServerCertificateRequest {
        try HostTLSServerCertificateRequest(
            transportSetEntryNotBefore: Date(timeIntervalSince1970: 1_800_000_000),
            transportSetEntryNotAfter: Date(timeIntervalSince1970: 1_800_086_400),
            expectedTLSSPKISHA256: identity.tlsSPKISHA256,
            framedSignedTransportSet: Data("HARCSIGNED-TRANSPORT-SET-V1".utf8)
        )
    }

    private static func loadLegacyTestFixture(
        applicationTag: Data,
        protection: InstallationKeyProtection
    ) throws -> HostProtectedP256SigningKey {
        .securityFramework(
            try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                applicationTag: applicationTag,
                protection: protection
            )
        )
    }

    private func deleteCertificate(_ der: Data) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

private actor ForcedConcurrentHostRecordBackend: HostCryptographicStateRecordBackend {
    private var forcedEmptyLoadsRemaining = 2
    private var record: Data?

    func loadRecord() -> Data? {
        if forcedEmptyLoadsRemaining > 0 {
            forcedEmptyLoadsRemaining -= 1
            return nil
        }
        return record
    }

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
}

private enum ForcedHostRecordFailure: Error, Equatable {
    case insert
}

private actor RejectingHostRecordBackend: HostCryptographicStateRecordBackend {
    func loadRecord() -> Data? { nil }

    func insertRecordIfAbsent(_ record: Data) throws -> Bool {
        throw ForcedHostRecordFailure.insert
    }

    func replaceRecord(expected: Data, with replacement: Data) -> Bool { false }
}

private final class PermanentTLSKeyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [HostSecurityP256SigningKey] = []

    func createKey() throws -> HostSecurityP256SigningKey {
        let key = try HostSecurityP256SigningKey.createLegacyKeychainTestFixture(
            applicationTag: Data("com.harc.tests.tls.\(UUID())".utf8)
        )
        lock.lock()
        keys.append(key)
        lock.unlock()
        return key
    }

    func snapshot() -> [HostSecurityP256SigningKey] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
