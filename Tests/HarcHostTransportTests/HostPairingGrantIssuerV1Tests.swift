import Foundation
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
import HarcIdentity
import HarcProtocol
import Testing

@Suite("Host pairing grant issuer V1")
struct HostPairingGrantIssuerV1Tests {
    private let approvedAt = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A new adoption receives an initial authority-signed grant")
    func newAdoption() async throws {
        let fixture = try await makeFixture()
        let deviceKey = SoftwareP256SigningKey()

        let issued = try await fixture.issuer.issueGrant(
            for: request(
                fixture: fixture,
                devicePublicKey: deviceKey.publicKey,
                scopes: ScopePolicy.minimalScopes(for: .mobile)
            )
        )

        #expect(issued.claims.libraryID == fixture.state.tuple.libraryID)
        #expect(
            issued.claims.hostAuthorityID
                == fixture.state.tuple.hostAuthorityID
        )
        #expect(issued.claims.deviceID == deviceKey.publicKey.deviceID)
        #expect(issued.claims.devicePublicKey == deviceKey.publicKey)
        #expect(issued.claims.grantEpoch == .initial)
        #expect(
            issued.claims.grantID.rawValue
                != HarcSignedEnvelopeV1.zeroUUID
        )
        #expect(issued.claims.minimumCompatibleProtocolMinor == 0)
        #expect(issued.claims.maximumCompatibleProtocolMinor == 0)
    }

    @Test("Active repair preserves grant ID while revoked re-adoption replaces it")
    func repairAndReadoptionEpochs() async throws {
        let fixture = try await makeFixture()
        let deviceKey = SoftwareP256SigningKey()
        let initialGrantID = GrantID.random()
        let initialEpoch = try GrantEpoch(7)
        let initialClaims = try DeviceGrantClaims(
            libraryID: fixture.state.tuple.libraryID,
            hostAuthorityID: fixture.state.tuple.hostAuthorityID,
            grantID: initialGrantID,
            devicePublicKey: deviceKey.publicKey,
            scopes: Set(ScopePolicy.minimalScopes(for: .macClient)),
            grantEpoch: initialEpoch,
            issuedAt: approvedAt.addingTimeInterval(-60),
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        let activeEntry = DeviceRegistryEntry(activeGrant: initialClaims)

        let repaired = try await fixture.issuer.issueGrant(
            for: request(
                fixture: fixture,
                devicePublicKey: deviceKey.publicKey,
                scopes: [.libraryMetadataRead, .recordingUploadOwn],
                existingEntry: activeEntry
            )
        )
        #expect(repaired.claims.grantID == initialGrantID)
        #expect(repaired.claims.grantEpoch == (try initialEpoch.next()))

        let revokedEntry = try activeEntry.revoking(
            revocationID: UUID(),
            reasonCode: "user.revoked",
            issuedAt: approvedAt.addingTimeInterval(-30)
        ).entry
        let readopted = try await fixture.issuer.issueGrant(
            for: request(
                fixture: fixture,
                devicePublicKey: deviceKey.publicKey,
                scopes: [.recordingReadOwn, .recordingUploadOwn],
                existingEntry: revokedEntry
            )
        )
        #expect(readopted.claims.grantID != initialGrantID)
        #expect(
            readopted.claims.grantEpoch
                == (try revokedEntry.currentGrantEpoch.next())
        )
        #expect(readopted.claims.deviceID == activeEntry.deviceID)
        #expect(readopted.claims.devicePublicKey == activeEntry.devicePublicKey)
    }

    @Test("Approved scopes are serialized once in canonical set order")
    func canonicalScopes() async throws {
        let fixture = try await makeFixture()
        let deviceKey = SoftwareP256SigningKey()
        let approvedScopes: [AuthorizationScope] = [
            .recordingUploadOwn,
            .libraryMetadataRead,
            .recordingUploadOwn,
            .libraryAudioRead,
        ]
        let expected = Array(Set(approvedScopes)).sorted()

        let issued = try await fixture.issuer.issueGrant(
            for: request(
                fixture: fixture,
                devicePublicKey: deviceKey.publicKey,
                scopes: approvedScopes
            )
        )
        let authenticated = try authenticate(issued, fixture: fixture)

        #expect(issued.claims.scopes == expected)
        #expect(authenticated.claims.scopes == expected)
        #expect(
            try authenticated.exactPayload.message.scopes.map {
                try $0.domainValue()
            } == expected
        )
    }

    @Test("Exact returned bytes authenticate back to identical claims")
    func exactSignedBytesAuthenticate() async throws {
        let fixture = try await makeFixture()
        let deviceKey = SoftwareP256SigningKey()
        let issued = try await fixture.issuer.issueGrant(
            for: request(
                fixture: fixture,
                devicePublicKey: deviceKey.publicKey,
                scopes: ScopePolicy.minimalScopes(for: .macClient)
            )
        )

        let authenticated = try authenticate(issued, fixture: fixture)
        #expect(authenticated.claims == issued.claims)
        #expect(
            authenticated.signedObject.exactFramedBytes
                == issued.exactSignedGrantBytes
        )
        #expect(
            authenticated.exactPayload.exactBytes
                == authenticated.signedObject.exactPayloadBytes
        )

        let wrongAuthority = SoftwareP256SigningKey()
        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(
            field: "hostAuthorityID"
        )) {
            try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
                issued.exactSignedGrantBytes,
                using: wrongAuthority.publicKey,
                purpose: .historicalEvidence
            )
        }
    }

    @Test("Sub-millisecond approval time is floored to canonical wire time")
    func submillisecondClockCanonicalization() async throws {
        let fixture = try await makeFixture()
        let deviceKey = SoftwareP256SigningKey()
        let observed = Date(
            timeIntervalSince1970: 2_000_000_000.987_654
        )
        let expectedMilliseconds = UInt64(
            (observed.timeIntervalSince1970 * 1_000).rounded(.down)
        )
        let expectedDate = Date(
            timeIntervalSince1970: Double(expectedMilliseconds) / 1_000
        )

        let issued = try await fixture.issuer.issueGrant(
            for: request(
                fixture: fixture,
                devicePublicKey: deviceKey.publicKey,
                scopes: ScopePolicy.minimalScopes(for: .mobile),
                approvedAt: observed
            )
        )
        let object = try HarcSignedObjectV1.decode(
            issued.exactSignedGrantBytes
        )

        #expect(issued.claims.issuedAt == expectedDate)
        #expect(
            object.header.issuedAtUnixMilliseconds
                == expectedMilliseconds
        )
    }

    @Test("Tuple and existing-device mismatches fail before signing")
    func mismatchedAuthorityAndDevice() async throws {
        let fixture = try await makeFixture()
        let deviceKey = SoftwareP256SigningKey()
        let otherKey = SoftwareP256SigningKey()
        let wrongAuthorityID = otherKey.publicKey.hostAuthorityID

        await #expect(throws: HarcHostError.pairingGrantMismatch) {
            _ = try await fixture.issuer.issueGrant(
                for: HostPairingGrantIssuanceRequest(
                    libraryID: fixture.state.tuple.libraryID,
                    hostAuthorityID: wrongAuthorityID,
                    clientKind: .mobile,
                    devicePublicKey: deviceKey.publicKey,
                    approvedScopes: ScopePolicy.minimalScopes(for: .mobile),
                    existingEntry: nil,
                    approvedAt: approvedAt
                )
            )
        }

        let otherClaims = try DeviceGrantClaims(
            libraryID: fixture.state.tuple.libraryID,
            hostAuthorityID: fixture.state.tuple.hostAuthorityID,
            grantID: .random(),
            devicePublicKey: otherKey.publicKey,
            scopes: Set(ScopePolicy.minimalScopes(for: .mobile)),
            grantEpoch: .initial,
            issuedAt: approvedAt.addingTimeInterval(-10),
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        await #expect(throws: HarcHostError.pairingGrantMismatch) {
            _ = try await fixture.issuer.issueGrant(
                for: request(
                    fixture: fixture,
                    devicePublicKey: deviceKey.publicKey,
                    scopes: ScopePolicy.minimalScopes(for: .mobile),
                    existingEntry: DeviceRegistryEntry(
                        activeGrant: otherClaims
                    )
                )
            )
        }
    }

    private func makeFixture() async throws -> IssuerFixture {
        let store = InMemoryHostCryptographicStateStore()
        let state = try await store.resolve(
            .loadOrCreate(libraryID: .random())
        )
        return IssuerFixture(
            state: state,
            issuer: HarcHostPairingGrantIssuerV1(
                cryptographicStateStore: store,
                expectedTuple: state.tuple
            )
        )
    }

    private func request(
        fixture: IssuerFixture,
        devicePublicKey: P256X963PublicKey,
        scopes: [AuthorizationScope],
        existingEntry: DeviceRegistryEntry? = nil,
        approvedAt: Date? = nil
    ) -> HostPairingGrantIssuanceRequest {
        HostPairingGrantIssuanceRequest(
            libraryID: fixture.state.tuple.libraryID,
            hostAuthorityID: fixture.state.tuple.hostAuthorityID,
            clientKind: .mobile,
            devicePublicKey: devicePublicKey,
            approvedScopes: scopes,
            existingEntry: existingEntry,
            approvedAt: approvedAt ?? self.approvedAt
        )
    }

    private func authenticate(
        _ issued: HostPairingIssuedGrant,
        fixture: IssuerFixture
    ) throws -> AuthenticatedGrant {
        let authenticated = try HarcAuthenticatedSignedObjectV1
            .decodeAndAuthenticate(
                issued.exactSignedGrantBytes,
                using: fixture.state.authorityIdentity.publicKey,
                purpose: .historicalEvidence
            )
        guard case let .deviceGrant(
            exactPayload,
            claims
        ) = authenticated.payload else {
            throw HarcProtocolCodecError.headerPayloadMismatch(
                field: "deviceGrant"
            )
        }
        return AuthenticatedGrant(
            claims: claims,
            exactPayload: exactPayload,
            signedObject: authenticated.signedObject
        )
    }
}

private struct IssuerFixture {
    let state: HostCryptographicState
    let issuer: HarcHostPairingGrantIssuerV1
}

private struct AuthenticatedGrant {
    let claims: DeviceGrantClaims
    let exactPayload: HarcExactProtobufPayload<Harc_V1_DeviceGrantV1>
    let signedObject: HarcSignedObjectV1
}
