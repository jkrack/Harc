import Foundation
import HarcDomain
import Security
import Testing
@testable import HarcIdentity

// These tests install and remove process-global Security.framework keys and
// certificates. Serial execution keeps one fixture's cleanup from racing
// another fixture's SecIdentity/key lookup under a heavily parallel full run.
@Suite("HarcIdentity permanent TLS key and X.509 server identity", .serialized)
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
        let facts = try tlsIdentity.issueServerCertificate(
            request: request,
            serialNumber: fixedSerial
        )
        let issued = try tlsIdentity.resolveServerIdentity(
            certificateDER: facts.certificateDER,
            request: request
        )
        defer { deleteCertificate(issued.certificate.certificateDER) }

        #expect(issued.certificate == facts)
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

    @Test("serial canonicalization retains only a required positive sign octet")
    func serialCanonicalizationRetainsRequiredSignOctet() throws {
        var signOctetRequired = [UInt8](repeating: 0x22, count: 20)
        signOctetRequired[0] = 0x80
        signOctetRequired[1] = 0x80
        let retained = try HostTLSCertificateSerialNumber.canonicalize(
            signOctetRequired
        )
        #expect(retained.count == 20)
        #expect(retained.prefix(2) == Data([0x00, 0x80]))

        var signOctetRedundant = signOctetRequired
        signOctetRedundant[1] = 0x7f
        let trimmed = try HostTLSCertificateSerialNumber.canonicalize(
            signOctetRedundant
        )
        #expect(trimmed.count == 19)
        #expect(trimmed.first == 0x7f)

        let key = try HostSecurityP256SigningKey
            .createLegacyKeychainTestFixture(
                applicationTag: Data("com.harc.tests.tls.\(UUID())".utf8)
            )
        defer { key.deletePersistentKeyBestEffort() }
        let tlsIdentity = HostTLSSigningIdentity(
            key: .securityFramework(key)
        )
        let certificate = try tlsIdentity.issueServerCertificate(
            request: request(for: tlsIdentity),
            serialNumber: retained
        )

        #expect(certificate.serialNumber == retained)
        #expect(certificate.serialNumber.first == 0x00)
        #expect(certificate.serialNumber[certificate.serialNumber.index(
            after: certificate.serialNumber.startIndex
        )] & 0x80 != 0)
    }

    @Test("concurrent load-or-create persists intent before creating one permanent TLS key")
    func concurrentCreationUsesOnlyWinningIntent() async throws {
        let backend = ForcedConcurrentHostRecordBackend()
        let tracker = PermanentTLSKeyTracker()
        let tlsFactory = durableLegacyFactory(tracker: tracker)
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
        #expect(createdKeys.count == 1)
        let winningKey = try #require(createdKeys.only)
        #expect(winningKey.publicKey == firstState.tlsIdentity.publicKey)
        #expect(
            try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                applicationTag: winningKey.applicationTag,
                protection: .keychainSoftware
            ).publicKey == winningKey.publicKey
        )
    }

    @Test("a failed record insert creates no permanent TLS key")
    func failedCreationNeverCreatesCandidateKey() async throws {
        let backend = RejectingHostRecordBackend()
        let tracker = PermanentTLSKeyTracker()
        let store = KeychainHostCryptographicStateStore(
            backend: backend,
            tlsKeyFactory: durableLegacyFactory(tracker: tracker),
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )

        await #expect(throws: ForcedHostRecordFailure.insert) {
            try await store.loadOrCreate(libraryID: LibraryID.random())
        }

        #expect(tracker.snapshot().isEmpty)
    }

    @Test("a losing staged-key CAS creates no orphaned permanent key")
    func concurrentStageCreatesOnlyWinningIntentKey() async throws {
        let tracker = PermanentTLSKeyTracker()
        let factory = durableLegacyFactory(tracker: tracker)
        let setupBackend = InMemoryHostCryptographicStateRecordBackend()
        let setup = KeychainHostCryptographicStateStore(
            backend: setupBackend,
            tlsKeyFactory: factory,
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )
        let initial = try await setup.loadOrCreate(libraryID: .random())
        let initialRecord = try #require(await setupBackend.loadRecord())
        let backend = ConcurrentStageHostRecordBackend(record: initialRecord)
        let first = KeychainHostCryptographicStateStore(
            backend: backend,
            tlsKeyFactory: factory,
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )
        let second = KeychainHostCryptographicStateStore(
            backend: backend,
            tlsKeyFactory: factory,
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )

        async let firstWon = stageOnce(first, state: initial)
        async let secondWon = stageOnce(second, state: initial)
        let wins = await [firstWon, secondWon].filter { $0 }.count
        #expect(wins == 1)

        let persisted = try await first.load(requiredTuple: initial.tuple)
        let staged = try #require(persisted.stagedTLSIdentity)
        let keys = tracker.snapshot()
        defer { keys.forEach { $0.deletePersistentKeyBestEffort() } }
        #expect(keys.count == 2)
        let winner = try #require(keys.first { $0.publicKey == staged.publicKey })
        #expect(
            try HostSecurityP256SigningKey.loadLegacyKeychainTestFixture(
                applicationTag: winner.applicationTag,
                protection: .keychainSoftware
            ).publicKey == winner.publicKey
        )
    }

    @Test("a created intent key is inspected without mutation and recovered idempotently")
    func creationIntentCrashRecovery() async throws {
        let backend = FailFirstReplaceHostRecordBackend()
        let tracker = PermanentTLSKeyTracker()
        let factory = durableLegacyFactory(tracker: tracker)
        let authority = HostProtectedP256SigningKey.keychainSoftware(
            SoftwareP256SigningKey()
        )
        let hostStateID = HostStateID.random()
        let libraryID = LibraryID.random()
        let tuple = HostCryptographicStateTuple(
            libraryID: libraryID,
            hostAuthorityID: authority.publicKey.hostAuthorityID,
            hostStateID: hostStateID
        )
        let store = KeychainHostCryptographicStateStore(
            backend: backend,
            authorityKeyFactory: HostProtectedP256SigningKeyFactory { authority },
            tlsKeyFactory: factory,
            hostStateIDFactory: { hostStateID },
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )

        await #expect(throws: ForcedHostRecordFailure.replace) {
            try await store.loadOrCreate(libraryID: libraryID)
        }
        let beforeInspection = try #require(await backend.loadRecord())
        let inspection = try await store.inspect(requiredTuple: tuple)
        #expect(inspection.activeTLSPublicKey == nil)
        #expect(inspection.pendingTLSKeyCreation?.targetRole == .tlsServer)
        #expect(inspection.pendingTLSKeyCreation?.keyExists == true)
        #expect(inspection.pendingTLSKeyCreation?.publicKey != nil)
        #expect(await backend.loadRecord() == beforeInspection)

        let recovered = try await store.load(requiredTuple: tuple)
        #expect(
            recovered.activeTLSIdentity.publicKey
                == inspection.pendingTLSKeyCreation?.publicKey
        )
        let after = try await store.inspect(requiredTuple: tuple)
        #expect(after.pendingTLSKeyCreation == nil)
        #expect(after.activeTLSPublicKey == recovered.activeTLSIdentity.publicKey)
        tracker.snapshot().forEach { $0.deletePersistentKeyBestEffort() }
    }

    @Test("checked deletion remains journaled after failure and retries on load")
    func deletionJournalRetry() async throws {
        let backend = InMemoryHostCryptographicStateRecordBackend()
        let tracker = PermanentTLSKeyTracker()
        let deletionGate = DeleteFailureGate()
        let factory = durableLegacyFactory(
            tracker: tracker,
            deletionGate: deletionGate
        )
        let store = KeychainHostCryptographicStateStore(
            backend: backend,
            tlsKeyFactory: factory,
            persistentSecurityKeyLoader: Self.loadLegacyTestFixture
        )
        let initial = try await store.loadOrCreate(libraryID: .random())
        let staged = try await store.stageReplacementTLSIdentity(
            for: initial.tuple,
            expectedActivePublicKey: initial.activeTLSIdentity.publicKey
        )
        let stagedIdentity = try #require(staged.stagedTLSIdentity)
        let stagedKey = try #require(
            tracker.snapshot().first { $0.publicKey == stagedIdentity.publicKey }
        )

        do {
            _ = try await store.discardStagedTLSIdentity(
                for: initial.tuple,
                expectedStagedPublicKey: stagedIdentity.publicKey
            )
            Issue.record("Expected checked deletion failure to remain journaled")
        } catch let error as HostCryptographicStateError {
            #expect(
                error == .persistentKeyDeletionIncomplete(role: .tlsServerStaged)
            )
        }
        let journaledBytes = try #require(await backend.loadRecord())
        let journaled = try await store.inspect(requiredTuple: initial.tuple)
        #expect(journaled.stagedTLSPublicKey == nil)
        #expect(journaled.pendingTLSKeyDeletions.count == 1)
        #expect(journaled.pendingTLSKeyDeletions.first?.formerRole == .tlsServerStaged)
        #expect(journaled.pendingTLSKeyDeletions.first?.keyExists == true)
        #expect(await backend.loadRecord() == journaledBytes)

        let recovered = try await store.load(requiredTuple: initial.tuple)
        #expect(recovered.stagedTLSIdentity == nil)
        let clean = try await store.inspect(requiredTuple: initial.tuple)
        #expect(clean.pendingTLSKeyDeletions.isEmpty)
        #expect(
            try HostSecurityP256SigningKey.loadLegacyKeychainTestFixtureIfPresent(
                applicationTag: stagedKey.applicationTag
            ) == nil
        )
        tracker.snapshot().forEach { $0.deletePersistentKeyBestEffort() }
    }

    private func durableLegacyFactory(
        tracker: PermanentTLSKeyTracker,
        deletionGate: DeleteFailureGate? = nil
    ) -> HostProtectedP256SigningKeyFactory {
        let prefix = "com.harc.tests.durable-tls.\(UUID().uuidString.lowercased())"
        return HostProtectedP256SigningKeyFactory(
            makeKey: {
                .securityFramework(try tracker.createKey())
            },
            permanentLifecycle: HostPermanentTLSKeyLifecycle(
                applicationTag: { tuple, generation in
                    Data("\(prefix).\(tuple.hostStateID).g\(generation)".utf8)
                },
                loadIfPresent: { tag in
                    try tracker.loadIfPresent(applicationTag: tag)
                        .map { .securityFramework($0) }
                },
                loadOrCreate: { tag in
                    .securityFramework(
                        try tracker.loadOrCreate(applicationTag: tag)
                    )
                },
                deleteAndConfirmAbsent: { tag, protection, publicKey in
                    if let deletionGate {
                        try deletionGate.delete(
                            applicationTag: tag,
                            protection: protection,
                            publicKey: publicKey
                        )
                    } else {
                        try HostSecurityP256SigningKey
                            .deleteLegacyKeychainTestFixtureAndConfirmAbsent(
                                applicationTag: tag,
                                protection: protection,
                                expectedPublicKey: publicKey
                            )
                    }
                }
            )
        )
    }

    private func stageOnce(
        _ store: KeychainHostCryptographicStateStore,
        state: HostCryptographicState
    ) async -> Bool {
        do {
            _ = try await store.stageReplacementTLSIdentity(
                for: state.tuple,
                expectedActivePublicKey: state.activeTLSIdentity.publicKey
            )
            return true
        } catch {
            return false
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
        HostTLSSigningIdentity.deleteInstalledServerCertificateBestEffort(
            certificateDER: der
        )
    }
}

private actor ConcurrentStageHostRecordBackend: HostCryptographicStateRecordBackend {
    private var record: Data
    private var synchronizedLoads = 0
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?

    init(record: Data) {
        self.record = record
    }

    func loadRecord() async -> Data? {
        if synchronizedLoads < 2 {
            let snapshot = record
            synchronizedLoads += 1
            if synchronizedLoads == 1 {
                await withCheckedContinuation { continuation in
                    firstLoadContinuation = continuation
                }
            } else {
                firstLoadContinuation?.resume()
                firstLoadContinuation = nil
            }
            return snapshot
        }
        return record
    }

    func insertRecordIfAbsent(_ record: Data) -> Bool { false }

    func replaceRecord(expected: Data, with replacement: Data) -> Bool {
        guard record == expected else { return false }
        record = replacement
        return true
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
    case replace
    case delete
}

private actor RejectingHostRecordBackend: HostCryptographicStateRecordBackend {
    func loadRecord() -> Data? { nil }

    func insertRecordIfAbsent(_ record: Data) throws -> Bool {
        throw ForcedHostRecordFailure.insert
    }

    func replaceRecord(expected: Data, with replacement: Data) -> Bool { false }
}

private actor FailFirstReplaceHostRecordBackend: HostCryptographicStateRecordBackend {
    private var record: Data?
    private var shouldFailReplacement = true

    func loadRecord() -> Data? { record }

    func insertRecordIfAbsent(_ record: Data) -> Bool {
        guard self.record == nil else { return false }
        self.record = record
        return true
    }

    func replaceRecord(expected: Data, with replacement: Data) throws -> Bool {
        guard record == expected else { return false }
        if shouldFailReplacement {
            shouldFailReplacement = false
            throw ForcedHostRecordFailure.replace
        }
        record = replacement
        return true
    }
}

private final class DeleteFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func delete(
        applicationTag: Data,
        protection: InstallationKeyProtection,
        publicKey: P256X963PublicKey
    ) throws {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail { throw ForcedHostRecordFailure.delete }
        try HostSecurityP256SigningKey
            .deleteLegacyKeychainTestFixtureAndConfirmAbsent(
                applicationTag: applicationTag,
                protection: protection,
                expectedPublicKey: publicKey
            )
    }
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

    func loadIfPresent(
        applicationTag: Data
    ) throws -> HostSecurityP256SigningKey? {
        try HostSecurityP256SigningKey.loadLegacyKeychainTestFixtureIfPresent(
            applicationTag: applicationTag
        )
    }

    func loadOrCreate(
        applicationTag: Data
    ) throws -> HostSecurityP256SigningKey {
        if let existing = try loadIfPresent(applicationTag: applicationTag) {
            return existing
        }
        let key = try HostSecurityP256SigningKey
            .loadOrCreateLegacyKeychainTestFixture(applicationTag: applicationTag)
        lock.lock()
        if !keys.contains(where: { $0.applicationTag == applicationTag }) {
            keys.append(key)
        }
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
