import Foundation
import HarcDomain
import Testing
@testable import HarcIdentity

@Suite("HarcIdentity installation identity lifecycle")
struct InstallationIdentityTests {
    @Test("production selection prefers Secure Enclave, falls back by capability, and preserves an existing key")
    func protectionSelection() async throws {
        let secureBackend = InMemorySoftwareInstallationKeyStore {
            InstallationSigningKey(
                signer: SoftwareP256SigningKey(),
                protection: .secureEnclave
            )
        }
        let softwareBackend = InMemorySoftwareInstallationKeyStore()
        let preferred = PreferredInstallationSigningKeyStore(
            secureEnclaveStore: secureBackend,
            softwareStore: softwareBackend,
            secureEnclaveAvailable: { true }
        )
        let preferredResolution = try await InstallationIdentityManager(
            keyStore: preferred
        ).resolve(evidence: .cleanInstallation)
        guard case .available(let preferredIdentity, _) = preferredResolution else {
            Issue.record("Expected a preferred identity")
            return
        }
        #expect(preferredIdentity.keyProtection == .secureEnclave)

        let unavailableSecureBackend = InMemorySoftwareInstallationKeyStore {
            InstallationSigningKey(
                signer: SoftwareP256SigningKey(),
                protection: .secureEnclave
            )
        }
        let fallbackSoftwareBackend = InMemorySoftwareInstallationKeyStore()
        let fallback = PreferredInstallationSigningKeyStore(
            secureEnclaveStore: unavailableSecureBackend,
            softwareStore: fallbackSoftwareBackend,
            secureEnclaveAvailable: { false }
        )
        let fallbackResolution = try await InstallationIdentityManager(
            keyStore: fallback
        ).resolve(evidence: .cleanInstallation)
        guard case .available(let fallbackIdentity, _) = fallbackResolution else {
            Issue.record("Expected a fallback identity")
            return
        }
        #expect(fallbackIdentity.keyProtection == .keychainSoftware)

        let existingSoftware = InstallationSigningKey(
            keychainSoftware: SoftwareP256SigningKey()
        )
        let existingSoftwareBackend = InMemorySoftwareInstallationKeyStore(
            initialKey: existingSoftware,
            keyFactory: { InstallationSigningKey(keychainSoftware: SoftwareP256SigningKey()) }
        )
        let preservingSelector = PreferredInstallationSigningKeyStore(
            secureEnclaveStore: InMemorySoftwareInstallationKeyStore {
                InstallationSigningKey(
                    signer: SoftwareP256SigningKey(),
                    protection: .secureEnclave
                )
            },
            softwareStore: existingSoftwareBackend,
            secureEnclaveAvailable: { true }
        )
        let preserved = try await preservingSelector.createPreferredIfAbsent()
        #expect(!preserved.inserted)
        #expect(preserved.key.protection == .keychainSoftware)
        #expect(preserved.key.publicKey == existingSoftware.publicKey)
    }

    @Test("a clean installation creates once and reloads the same identity")
    func cleanInstallAndReload() async throws {
        let store = InMemorySoftwareInstallationKeyStore()
        let first = try await InstallationIdentityManager(keyStore: store).resolve(
            evidence: .cleanInstallation
        )
        guard case .available(let firstIdentity, let firstOrigin) = first else {
            Issue.record("Expected a new identity")
            return
        }
        #expect(firstOrigin == .newlyCreatedKey)

        let second = try await InstallationIdentityManager(keyStore: store).resolve(
            evidence: InstallationIdentityEvidence(
                rememberedDeviceID: firstIdentity.deviceID,
                hasPriorIdentityState: true
            )
        )
        guard case .available(let secondIdentity, let secondOrigin) = second else {
            Issue.record("Expected the stored identity")
            return
        }
        #expect(secondOrigin == .existingKey)
        #expect(secondIdentity.deviceID == firstIdentity.deviceID)
        #expect(secondIdentity.publicKey == firstIdentity.publicKey)

        let digest = P256SHA256Digest(hashing: Data("reload-proof".utf8))
        let signature = try secondIdentity.sign(digest: digest)
        #expect(firstIdentity.publicKey.isValidSignature(signature, for: digest))
    }

    @Test("a missing known key reports key loss without silently minting a replacement")
    func knownKeyLossFailsClosed() async throws {
        let store = InMemorySoftwareInstallationKeyStore()
        let rememberedID = try DeviceID(Data(repeating: 0x44, count: 32))

        let resolution = try await InstallationIdentityManager(keyStore: store).resolve(
            evidence: InstallationIdentityEvidence(
                rememberedDeviceID: rememberedID,
                hasPriorIdentityState: true
            )
        )
        guard case .keyLoss(let loss) = resolution else {
            Issue.record("Expected explicit key loss")
            return
        }
        #expect(loss.rememberedDeviceID == rememberedID)
        #expect(!loss.hasIdentityBoundCaptures)
        #expect(await !store.hasKeyForTesting())
    }

    @Test("identity-bound captures alone prevent silent key replacement")
    func capturesTriggerKeyLossPolicy() async throws {
        let store = InMemorySoftwareInstallationKeyStore()
        let resolution = try await InstallationIdentityManager(keyStore: store).resolve(
            evidence: InstallationIdentityEvidence(hasIdentityBoundCaptures: true)
        )

        guard case .keyLoss(let loss) = resolution else {
            Issue.record("Expected explicit key loss")
            return
        }
        #expect(loss.rememberedDeviceID == nil)
        #expect(loss.hasIdentityBoundCaptures)
        #expect(await !store.hasKeyForTesting())
    }

    @Test("a stored key that disagrees with durable identity evidence fails closed")
    func storedKeyMismatch() async throws {
        let store = InMemorySoftwareInstallationKeyStore(initialKey: SoftwareP256SigningKey())
        let rememberedID = try DeviceID(Data(repeating: 0xaa, count: 32))

        await #expect(throws: InstallationIdentityError.self) {
            try await InstallationIdentityManager(keyStore: store).resolve(
                evidence: InstallationIdentityEvidence(rememberedDeviceID: rememberedID)
            )
        }
    }

    @Test("origin IDs remain bound to the installation key independently of pairing")
    func originIdentityBeforePairing() async throws {
        let store = InMemorySoftwareInstallationKeyStore()
        let resolution = try await InstallationIdentityManager(keyStore: store).resolve(
            evidence: .cleanInstallation
        )
        guard case .available(let identity, _) = resolution else {
            Issue.record("Expected an identity")
            return
        }
        let uuid = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let origin = identity.originRecordingID(recordingUUID: uuid)
        #expect(origin.deviceID == identity.deviceID)
        #expect(origin.recordingUUID == uuid)
    }
}
