import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import Testing

@Suite("Current grant authorization binding")
struct CurrentGrantAuthorizationTests {
    @Test("initial command acceptance binds the complete live registry identity")
    func completeIdentityBinding() throws {
        let hostKey = ProtocolCodecFixtures.key(121)
        let otherHostKey = ProtocolCodecFixtures.key(122)
        let deviceKey = ProtocolCodecFixtures.key(123)
        let otherDeviceKey = ProtocolCodecFixtures.key(124)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(12_100))
        let otherLibraryID = LibraryID(ProtocolCodecFixtures.uuid(12_101))
        let grantID = ProtocolCodecFixtures.uuid(12_102)
        let issuedAt = ProtocolCodecFixtures.issuedAt
        let header = try commandHeader(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceID: deviceKey.publicKey.deviceID,
            grantID: grantID,
            grantEpoch: 4,
            issuedAt: issuedAt
        )
        let registration = try HarcRegisteredSignedObjectV1.registered(
            messageType: .metadataMutation,
            payloadType: .metadataMutation
        )
        let valid = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 4,
            scopes: [.libraryMetadataWrite]
        )
        try registration.validateInitialAcceptance(
            header: header,
            atUnixMilliseconds: issuedAt + 1,
            currentGrant: valid,
            using: deviceKey.publicKey
        )

        let staleEpoch = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 5,
            scopes: [.libraryMetadataWrite]
        )
        try expectStale(staleEpoch, header: header, registration: registration, key: deviceKey)

        let wrongLibrary = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: otherLibraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 4,
            scopes: [.libraryMetadataWrite]
        )
        try expectStale(wrongLibrary, header: header, registration: registration, key: deviceKey)

        let wrongAuthority = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: otherHostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 4,
            scopes: [.libraryMetadataWrite]
        )
        try expectStale(wrongAuthority, header: header, registration: registration, key: deviceKey)

        let wrongDevice = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: otherDeviceKey,
            grantID: grantID,
            grantEpoch: 4,
            scopes: [.libraryMetadataWrite]
        )
        try expectStale(wrongDevice, header: header, registration: registration, key: deviceKey)

        let missingScope = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 4,
            scopes: [.processingSubmitOwn]
        )
        try expectStale(missingScope, header: header, registration: registration, key: deviceKey)

        #expect(throws: HarcProtocolCodecError.staleGrant) {
            try registration.validateInitialAcceptance(
                header: header,
                atUnixMilliseconds: issuedAt + 1,
                currentGrant: valid,
                using: otherDeviceKey.publicKey
            )
        }
    }

    @Test("initial command acceptance rejects inactive and out-of-window registry grants")
    func activeLifetimeBinding() throws {
        let hostKey = ProtocolCodecFixtures.key(125)
        let deviceKey = ProtocolCodecFixtures.key(126)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(12_110))
        let grantID = ProtocolCodecFixtures.uuid(12_111)
        let issuedAt = ProtocolCodecFixtures.issuedAt
        let header = try commandHeader(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceID: deviceKey.publicKey.deviceID,
            grantID: grantID,
            grantEpoch: 7,
            issuedAt: issuedAt
        )
        let registration = try HarcRegisteredSignedObjectV1.registered(
            messageType: .metadataMutation,
            payloadType: .metadataMutation
        )

        let expired = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 7,
            scopes: [.libraryMetadataWrite],
            expiresAtUnixMilliseconds: issuedAt + 10
        )
        #expect(throws: HarcProtocolCodecError.commandExpired) {
            try registration.validateInitialAcceptance(
                header: header,
                atUnixMilliseconds: issuedAt + 11,
                currentGrant: expired,
                using: deviceKey.publicKey
            )
        }

        let issuedAfterCommand = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 7,
            scopes: [.libraryMetadataWrite],
            issuedAtUnixMilliseconds: issuedAt + 10
        )
        #expect(throws: HarcProtocolCodecError.staleGrant) {
            try registration.validateInitialAcceptance(
                header: header,
                atUnixMilliseconds: issuedAt + 11,
                currentGrant: issuedAfterCommand,
                using: deviceKey.publicKey
            )
        }

        let activeGrant = try DeviceGrantClaims(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            grantID: GrantID(grantID),
            devicePublicKey: deviceKey.publicKey,
            scopes: [.libraryMetadataWrite],
            grantEpoch: GrantEpoch(7),
            issuedAt: Date(timeIntervalSince1970: Double(issuedAt - 1_000) / 1_000),
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        let revoked = try DeviceRegistryEntry(activeGrant: activeGrant).revoking(
            revocationID: ProtocolCodecFixtures.uuid(12_112),
            reasonCode: "test",
            issuedAt: Date(timeIntervalSince1970: Double(issuedAt) / 1_000)
        ).entry
        #expect(throws: HarcProtocolCodecError.staleGrant) {
            _ = try HarcCurrentGrantBindingV1(registryEntry: revoked)
        }
    }

    private func expectStale(
        _ binding: HarcCurrentGrantBindingV1,
        header: HarcSignedEnvelopeV1,
        registration: HarcRegisteredSignedObjectV1,
        key: SoftwareP256SigningKey
    ) throws {
        #expect(throws: HarcProtocolCodecError.staleGrant) {
            try registration.validateInitialAcceptance(
                header: header,
                atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1,
                currentGrant: binding,
                using: key.publicKey
            )
        }
    }

    private func commandHeader(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        deviceID: DeviceID,
        grantID: UUID,
        grantEpoch: UInt64,
        issuedAt: UInt64
    ) throws -> HarcSignedEnvelopeV1 {
        try HarcSignedEnvelopeV1(
            messageType: .metadataMutation,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            signerDeviceID: deviceID,
            grantID: grantID,
            grantEpoch: grantEpoch,
            operationID: ProtocolCodecFixtures.uuid(12_120),
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: issuedAt + 60_000,
            payloadType: .metadataMutation,
            expectedRevision: 1,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(Data())
        )
    }
}
