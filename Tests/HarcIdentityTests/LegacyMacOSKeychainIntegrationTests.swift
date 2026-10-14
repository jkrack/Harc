import Foundation
import HarcDomain
import Security
import Testing
@testable import HarcIdentity

/// These fixtures exercise the process's real legacy Keychain. Serializing only
/// the TLS child suite does not isolate it from password fixtures in sibling
/// suites. Keep all physical Keychain lifetimes in this serialized parent;
/// concurrency inside each test (including competing TLS stores) still runs.
@Suite("Legacy macOS Keychain integration", .serialized)
struct LegacyMacOSKeychainIntegrationTests {
    @Test("Production macOS identity persists in the legacy login Keychain")
    func productionLegacyMacOSKeychainIdentity() async throws {
        let service = "com.harc.tests.installation-identity.\(UUID().uuidString.lowercased())"
        let account = "device-p256-signing-v1"
        let cleanupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { SecItemDelete(cleanupQuery as CFDictionary) }

        let firstStore = KeychainSoftwareInstallationKeyStore(
            service: service,
            account: account,
            domain: .legacyMacOS
        )
        let first = try await InstallationIdentityManager(
            keyStore: firstStore
        ).resolve(evidence: .cleanInstallation)
        guard case .available(let firstIdentity, let firstOrigin) = first else {
            Issue.record("Expected a newly persisted macOS identity")
            return
        }
        #expect(firstOrigin == .newlyCreatedKey)

        let reopenedStore = KeychainSoftwareInstallationKeyStore(
            service: service,
            account: account,
            domain: .legacyMacOS
        )
        let reopened = try await InstallationIdentityManager(
            keyStore: reopenedStore
        ).resolve(evidence: InstallationIdentityEvidence(
            rememberedDeviceID: firstIdentity.deviceID,
            hasPriorIdentityState: true
        ))
        guard case .available(let reopenedIdentity, let reopenedOrigin) = reopened else {
            Issue.record("Expected the persisted macOS identity")
            return
        }
        #expect(reopenedOrigin == .existingKey)
        #expect(reopenedIdentity.deviceID == firstIdentity.deviceID)
    }

    @Test("production host record works without Data Protection Keychain entitlement")
    func productionLegacyKeychainRecord() async throws {
        let service = "com.harc.tests.host-state.\(UUID().uuidString.lowercased())"
        let account = "record"
        let cleanupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { SecItemDelete(cleanupQuery as CFDictionary) }
        let backend = SecurityHostCryptographicStateRecordBackend(
            service: service,
            account: account
        )
        let first = Data("host-state-v1".utf8)
        let second = Data("host-state-v2".utf8)

        #expect(try await backend.loadRecord() == nil)
        #expect(try await backend.insertRecordIfAbsent(first))
        #expect(try await backend.loadRecord() == first)
        #expect(try await backend.replaceRecord(expected: first, with: second))
        #expect(try await backend.loadRecord() == second)
    }

}
