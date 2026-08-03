import Foundation
import HarcDomain
import Testing
@testable import HarcIdentity

@Suite("HarcIdentity authorization and registry")
struct AuthorizationTests {
    @Test("minimal mobile and Mac grants follow the v1 scope policy")
    func minimalScopePolicy() {
        #expect(
            ScopePolicy.minimalScopes(for: .mobile) == [
                .recordingReadOwn,
                .recordingUploadOwn,
            ]
        )
        #expect(
            ScopePolicy.minimalScopes(for: .macClient) == [
                .processingSubmitOwn,
                .recordingReadOwn,
                .recordingUploadOwn,
            ]
        )
        #expect(!ScopePolicy.initialGrantRequiresOSAuthentication(
            scopes: ScopePolicy.minimalScopes(for: .mobile),
            for: .mobile
        ))
        #expect(!ScopePolicy.initialGrantRequiresOSAuthentication(
            scopes: ScopePolicy.minimalScopes(for: .macClient),
            for: .macClient
        ))
        #expect(ScopePolicy.initialGrantRequiresOSAuthentication(
            scopes: [.recordingReadOwn, .recordingUploadOwn, .processingSubmitOwn],
            for: .mobile
        ))
        #expect(!ScopePolicy.initialGrantRequiresOSAuthentication(
            scopes: [.recordingReadOwn, .recordingUploadOwn],
            for: .macClient
        ))
        #expect(ScopePolicy.initialGrantRequiresOSAuthentication(
            scopes: [.recordingUploadOwn, .libraryMetadataRead],
            for: .mobile
        ))
        #expect(ScopePolicy.scopeChangeRequiresOSAuthentication)
    }

    @Test("identity versions reject unsupported majors through construction and Codable")
    func identityProtocolVersionValidation() throws {
        #expect(throws: AuthorizationModelError.unsupportedProtocolMajor(2)) {
            try IdentityProtocolVersion(major: 2, minor: 0)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                IdentityProtocolVersion.self,
                from: Data(#"{"major":2,"minor":0}"#.utf8)
            )
        }
        let version = try IdentityProtocolVersion(minor: 7)
        #expect(
            try JSONDecoder().decode(
                IdentityProtocolVersion.self,
                from: JSONEncoder().encode(version)
            ) == version
        )

        let fixture = try Fixture()
        var encodedGrant = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture.grant()))
                as? [String: Any]
        )
        encodedGrant["protocolVersion"] = ["major": 2, "minor": 0]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                DeviceGrantClaims.self,
                from: JSONSerialization.data(withJSONObject: encodedGrant)
            )
        }
    }

    @Test("grant claims require canonical scopes and key-derived device identity")
    func grantValidation() throws {
        let fixture = try Fixture()
        #expect(throws: AuthorizationModelError.scopesNotCanonical) {
            try fixture.grant(
                scopes: [.recordingUploadOwn, .recordingReadOwn]
            )
        }
        #expect(throws: AuthorizationModelError.duplicateScope) {
            try fixture.grant(
                scopes: [.recordingReadOwn, .recordingReadOwn]
            )
        }
        #expect(throws: AuthorizationModelError.deviceKeyMismatch) {
            try DeviceGrantClaims(
                libraryID: fixture.libraryID,
                hostAuthorityID: fixture.hostAuthorityID,
                grantID: fixture.grantID,
                deviceID: try DeviceID(Data(repeating: 7, count: 32)),
                devicePublicKey: fixture.deviceKey.publicKey,
                scopes: [.recordingReadOwn],
                grantEpoch: .initial,
                issuedAt: fixture.issuedAt,
                minimumCompatibleProtocolMinor: 0,
                maximumCompatibleProtocolMinor: 0
            )
        }
    }

    @Test("scope replacement advances the epoch and invalidates the prior grant")
    func scopeEpochInvalidation() throws {
        let fixture = try Fixture()
        let original = try fixture.grant()
        let registry = DeviceRegistryEntry(activeGrant: original)
        try registry.authorize(grant: original, requiredScope: .recordingUploadOwn)

        let replacement = try registry.replacingScopesAfterLocalAuthorization(
            Set([.recordingReadOwn, .recordingUploadOwn, .libraryMetadataRead]),
            issuedAt: fixture.issuedAt.addingTimeInterval(1)
        )
        #expect(replacement.grant.grantID == original.grantID)
        #expect(replacement.grant.grantEpoch.rawValue == 2)

        #expect(throws: AuthorizationModelError.grantEpochMismatch(
            expected: try GrantEpoch(2),
            presented: .initial
        )) {
            try replacement.entry.authorize(
                grant: original,
                requiredScope: .recordingUploadOwn
            )
        }
        try replacement.entry.authorize(
            grant: replacement.grant,
            requiredScope: .libraryMetadataRead
        )
    }

    @Test("revocation advances the epoch and current registry state overrides a grant")
    func revocationRejectsCurrentGrant() throws {
        let fixture = try Fixture()
        let grant = try fixture.grant()
        let registry = DeviceRegistryEntry(activeGrant: grant)
        let revoked = try registry.revoking(
            revocationID: try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")),
            reasonCode: "user.revoked",
            issuedAt: fixture.issuedAt.addingTimeInterval(2)
        )

        #expect(revoked.entry.status == .revoked)
        #expect(revoked.revocation.priorGrantEpoch == .initial)
        #expect(revoked.revocation.newGrantEpoch.rawValue == 2)
        #expect(throws: AuthorizationModelError.deviceRevoked) {
            try revoked.entry.authorize(
                grant: grant,
                requiredScope: .recordingUploadOwn
            )
        }
    }

    @Test("grant, registry, replacement, and revocation mirror one validated protocol version")
    func protocolVersionMirroring() throws {
        let fixture = try Fixture()
        let version = try IdentityProtocolVersion(minor: 7)
        let grant = try fixture.grant(
            protocolVersion: version,
            minimumCompatibleProtocolMinor: 3,
            maximumCompatibleProtocolMinor: 9
        )
        let registry = DeviceRegistryEntry(activeGrant: grant)
        #expect(registry.protocolVersion == version)

        let replacement = try registry.replacingScopesAfterLocalAuthorization(
            Set([.recordingReadOwn, .recordingUploadOwn]),
            issuedAt: fixture.issuedAt.addingTimeInterval(1)
        )
        #expect(replacement.grant.protocolVersion == version)
        #expect(replacement.entry.protocolVersion == version)

        let revoked = try replacement.entry.revoking(
            revocationID: try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")),
            reasonCode: "key.lost",
            issuedAt: fixture.issuedAt.addingTimeInterval(2)
        )
        #expect(revoked.revocation.protocolVersion == version)
        #expect(revoked.entry.protocolVersion == version)
        #expect(
            try JSONDecoder().decode(
                DeviceRegistryEntry.self,
                from: JSONEncoder().encode(revoked.entry)
            ) == revoked.entry
        )

        let wrongVersionGrant = try fixture.grant(
            protocolVersion: try IdentityProtocolVersion(minor: 8),
            minimumCompatibleProtocolMinor: 3,
            maximumCompatibleProtocolMinor: 9
        )
        #expect(throws: AuthorizationModelError.grantProtocolVersionMismatch(
            expected: version,
            presented: try IdentityProtocolVersion(minor: 8)
        )) {
            try registry.authorize(
                grant: wrongVersionGrant,
                requiredScope: .recordingUploadOwn
            )
        }

        var encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(revoked.entry))
                as? [String: Any]
        )
        var revocation = try #require(encoded["revocation"] as? [String: Any])
        revocation["protocolVersion"] = ["major": 1, "minor": 8]
        encoded["revocation"] = revocation
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                DeviceRegistryEntry.self,
                from: JSONSerialization.data(withJSONObject: encoded)
            )
        }

        var incompatibleRange = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(registry))
                as? [String: Any]
        )
        incompatibleRange["minimumCompatibleProtocolMinor"] = 8
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                DeviceRegistryEntry.self,
                from: JSONSerialization.data(withJSONObject: incompatibleRange)
            )
        }
    }

    @Test("expiry and missing scopes fail closed")
    func expiryAndMissingScope() throws {
        let fixture = try Fixture()
        let grant = try fixture.grant(expiresAt: fixture.issuedAt.addingTimeInterval(10))
        let registry = DeviceRegistryEntry(activeGrant: grant)

        #expect(throws: AuthorizationModelError.grantExpired) {
            try registry.authorize(
                grant: grant,
                requiredScope: .recordingUploadOwn,
                at: fixture.issuedAt.addingTimeInterval(10)
            )
        }
        #expect(throws: AuthorizationModelError.missingScope(.libraryAudioRead)) {
            try registry.authorize(
                grant: grant,
                requiredScope: .libraryAudioRead,
                at: fixture.issuedAt.addingTimeInterval(1)
            )
        }
    }

    @Test("grant epochs reject zero and overflow")
    func epochBounds() throws {
        #expect(throws: AuthorizationModelError.zeroGrantEpoch) {
            try GrantEpoch(0)
        }
        #expect(throws: AuthorizationModelError.grantEpochOverflow) {
            try GrantEpoch(UInt64.max).next()
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GrantEpoch.self, from: Data("0".utf8))
        }
    }

    private struct Fixture {
        let libraryID = LibraryID(UUID())
        let hostAuthorityID: HostAuthorityID
        let grantID = GrantID(UUID())
        let deviceKey = SoftwareP256SigningKey()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            hostAuthorityID = SoftwareP256SigningKey().publicKey.hostAuthorityID
        }

        func grant(
            protocolVersion: IdentityProtocolVersion = .v1,
            scopes: [AuthorizationScope] = [.recordingReadOwn, .recordingUploadOwn],
            expiresAt: Date? = nil,
            minimumCompatibleProtocolMinor: UInt16 = 0,
            maximumCompatibleProtocolMinor: UInt16 = 0
        ) throws -> DeviceGrantClaims {
            try DeviceGrantClaims(
                protocolVersion: protocolVersion,
                libraryID: libraryID,
                hostAuthorityID: hostAuthorityID,
                grantID: grantID,
                deviceID: deviceKey.publicKey.deviceID,
                devicePublicKey: deviceKey.publicKey,
                scopes: scopes,
                grantEpoch: .initial,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
                maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
            )
        }
    }
}
