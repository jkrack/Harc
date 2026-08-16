import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer
import Testing
@testable import HarcClientStore

@Suite("HarcTransferStore trust persistence")
struct TrustPersistenceTests {
    @Test("forgetting retires authorization but preserves trust history")
    func forgetActiveHost() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let tuple = ClientStoreFixtures.tuple(library: 90, authorityByte: 90)
        let adoptedAt = ClientStoreFixtures.baseDate
        let forgottenAt = adoptedAt.addingTimeInterval(30)
        let store = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root)
                .transferDatabase,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes,
            now: { forgottenAt }
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 90,
                transportEpoch: 4,
                transportByte: 40,
                grantEpoch: 7,
                grantByte: 70,
                adoptedAt: adoptedAt
            )
        )

        #expect(try store.forgetActiveHost())
        #expect(try store.forgetActiveHost() == false)
        #expect(try store.activeAdoption() == nil)
        #expect(throws: ClientStoreError.noActiveAdoption) {
            try store.authorizingAdoption(
                for: tuple,
                requiredScope: .recordingUploadOwn
            )
        }
        let history = try store.historicalAdoptions()
        #expect(history.count == 1)
        #expect(history[0].tuple == tuple)
        #expect(history[0].transportEpochAtRead == 4)
        #expect(history[0].grantEpoch == 7)
        #expect(history[0].endedAt == forgottenAt)
        #expect(history[0].isAuthorizing == false)

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        #expect(try reopened.activeAdoption() == nil)
        #expect(try reopened.historicalAdoptions().count == 1)
    }

    @Test("foreground pairing can re-adopt a Host-revoked installation")
    func foregroundPairingReadoption() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tuple = ClientStoreFixtures.tuple(library: 91, authorityByte: 91)
        let firstGrantID = GrantID(ClientStoreFixtures.uuid(1_901))
        let replacementGrantID = GrantID(ClientStoreFixtures.uuid(1_902))
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes()
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 91,
                transportEpoch: 4,
                transportByte: 41,
                grantEpoch: 7,
                grantByte: 71,
                grantID: firstGrantID
            )
        )
        #expect(try store.forgetActiveHost())

        let replacement = ClientStoreFixtures.adoption(
            tuple: tuple,
            keyByte: 91,
            transportEpoch: 4,
            transportByte: 41,
            grantEpoch: 9,
            grantByte: 72,
            grantID: replacementGrantID,
            adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
        )
        #expect(throws: ClientStoreError.self) {
            try store.adopt(replacement)
        }
        let readopted = try store.adoptApprovedForegroundPairing(replacement)
        #expect(readopted.grant.grantID == replacementGrantID)
        #expect(readopted.grant.registryEpoch == 9)
        #expect(readopted.grant.status == .active)
        #expect(
            try store.authorizingAdoption(
                for: tuple,
                requiredScope: .recordingUploadOwn
            ).adoptionID == readopted.adoptionID
        )
        #expect(try store.historicalAdoptions().count == 1)
        #expect(
            try store.adoptApprovedForegroundPairing(replacement)
                .adoptionID == readopted.adoptionID
        )
    }

    @Test("transport high-water and grant-next rules survive reopen")
    func epochsAndReopen() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 21)

        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
            let adoption = ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 21,
                transportEpoch: 4,
                transportByte: 40,
                grantEpoch: 7,
                grantByte: 50
            )
            let snapshot = try store.adopt(adoption)
            #expect(snapshot.transportSet.epoch == 4)
            #expect(snapshot.grant.registryEpoch == 7)

            #expect(
                try store.persistVerifiedTransportSet(
                    ClientStoreFixtures.transportEvidence(
                        tuple: tuple,
                        keyByte: 21,
                        epoch: 4,
                        exactSignedBytes: adoption.transportSet.exactSignedBytes
                    )
                ) == .exactReplay(epoch: 4)
            )
            #expect(
                try store.persistVerifiedTransportSet(
                    ClientStoreFixtures.transportEvidence(
                        tuple: tuple,
                        keyByte: 21,
                        epoch: 9,
                        exactSignedBytes: Data([90])
                    )
                ) == .advanced(previous: 4, current: 9)
            )
            let nextGrant = ClientStoreFixtures.grantEvidence(
                tuple: tuple,
                keyByte: 21,
                grantID: adoption.grant.grantID,
                registryEpoch: 8,
                status: .active,
                exactSignedBytes: Data([80])
            )
            #expect(
                try store.persistNextVerifiedGrant(nextGrant)
                    == .advanced(previous: 7, current: 8)
            )
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        let active = try #require(try reopened.activeAdoption())
        #expect(active.transportSet.epoch == 9)
        #expect(active.transportSet.exactSignedBytes == Data([90]))
        #expect(active.grant.registryEpoch == 8)

        #expect(throws: ClientStoreError.self) {
            try reopened.persistVerifiedTransportSet(
                ClientStoreFixtures.transportEvidence(
                    tuple: tuple,
                    keyByte: 21,
                    epoch: 8,
                    exactSignedBytes: Data([80])
                )
            )
        }
        #expect(throws: ClientStoreError.self) {
            try reopened.persistVerifiedTransportSet(
                ClientStoreFixtures.transportEvidence(
                    tuple: tuple,
                    keyByte: 21,
                    epoch: 9,
                    exactSignedBytes: Data([91])
                )
            )
        }
        #expect(throws: ClientStoreError.self) {
            try reopened.persistNextVerifiedGrant(
                ClientStoreFixtures.grantEvidence(
                    tuple: tuple,
                    keyByte: 21,
                    grantID: GrantID(ClientStoreFixtures.uuid(110)),
                    registryEpoch: 10,
                    status: .active,
                    exactSignedBytes: Data([100])
                )
            )
        }
        #expect(throws: ClientStoreError.self) {
            try reopened.persistNextVerifiedGrant(
                ClientStoreFixtures.grantEvidence(
                    tuple: tuple,
                    keyByte: 21,
                    grantID: active.grant.grantID,
                    registryEpoch: 8,
                    status: active.grant.status,
                    exactSignedBytes: Data([81])
                )
            )
        }
        #expect(throws: ClientStoreError.self) {
            try reopened.persistNextVerifiedGrant(
                ClientStoreFixtures.grantEvidence(
                    tuple: tuple,
                    keyByte: 21,
                    grantID: GrantID(ClientStoreFixtures.uuid(999)),
                    registryEpoch: 9,
                    status: .active,
                    exactSignedBytes: Data([90])
                )
            )
        }
        #expect(throws: ClientStoreError.self) {
            try reopened.persistNextVerifiedGrant(
                ClientStoreFixtures.grantEvidence(
                    tuple: tuple,
                    keyByte: 21,
                    grantID: active.grant.grantID,
                    deviceByte: 2,
                    registryEpoch: 9,
                    status: .active,
                    exactSignedBytes: Data([91])
                )
            )
        }

        let revoked = ClientStoreFixtures.grantEvidence(
            tuple: tuple,
            keyByte: 21,
            grantID: active.grant.grantID,
            registryEpoch: 9,
            status: .revoked,
            exactSignedBytes: Data([92])
        )
        #expect(
            try reopened.persistNextVerifiedGrant(revoked)
                == .advanced(previous: 8, current: 9)
        )
        #expect(try reopened.activeAdoption()?.hasActiveGrantStatus == false)
        #expect(throws: ClientStoreError.self) {
            try reopened.authorizingAdoption(
                for: tuple,
                requiredScope: .recordingUploadOwn
            )
        }

        let revokedReopen = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        let reopenedGrant = try #require(try revokedReopen.activeAdoption()?.grant)
        #expect(reopenedGrant.grantID == revoked.grantID)
        #expect(reopenedGrant.registryEpoch == revoked.registryEpoch)
        #expect(reopenedGrant.status == revoked.status)
        #expect(reopenedGrant.exactSignedBytes == revoked.exactSignedBytes)
        #expect(throws: ClientStoreError.self) {
            try revokedReopen.authorizingAdoption(
                for: tuple,
                requiredScope: .recordingUploadOwn
            )
        }
    }

    @Test("adoption validates authority derivation and installation-device binding")
    func adoptionIdentityBindings() throws {
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        #expect(throws: IdentityCryptoError.self) {
            try RecordingHostTrustBinding(
                libraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID,
                hostAuthorityPublicKeyX963: Data([0x04]) + Data(repeating: 0, count: 64)
            )
        }
        #expect(throws: TransferValidationError.self) {
            try RecordingHostTrustBinding(
                libraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID,
                hostAuthorityPublicKeyX963: ClientStoreFixtures.authorityKey(2)
            )
        }

        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes()
        )
        #expect(throws: ClientStoreError.self) {
            try store.adopt(
                ClientStoreFixtures.adoption(
                    tuple: tuple,
                    keyByte: 1,
                    transportEpoch: 1,
                    transportByte: 1,
                    grantEpoch: 1,
                    grantByte: 1,
                    deviceByte: 2
                )
            )
        }
        #expect(try store.activeAdoption() == nil)

        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        let wrongInstallation = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(2),
            storageAttributes: RecordingStorageAttributes()
        )
        #expect(throws: ClientStoreError.self) {
            try wrongInstallation.activeAdoption()
        }
        #expect(throws: ClientStoreError.self) {
            try wrongInstallation.authorizingAdoption(
                for: tuple,
                requiredScope: .recordingUploadOwn
            )
        }
    }

    @Test("adoption replacement is atomic and history never authorizes")
    func transactionalReplacementAndHistory() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let firstTuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let secondTuple = ClientStoreFixtures.tuple(library: 2, authorityByte: 2)

        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
            _ = try store.adopt(
                ClientStoreFixtures.adoption(
                    tuple: firstTuple,
                    keyByte: 1,
                    transportEpoch: 3,
                    transportByte: 3,
                    grantEpoch: 2,
                    grantByte: 2
                )
            )
        }

        let faulty = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes,
            faultInjector: PointFaultInjector(point: .afterDeactivatingPriorAdoption)
        )
        #expect(throws: InjectedClientStoreFault.self) {
            try faulty.adopt(
                ClientStoreFixtures.adoption(
                    tuple: secondTuple,
                    keyByte: 2,
                    transportEpoch: 1,
                    transportByte: 4,
                    grantEpoch: 1,
                    grantByte: 5,
                    adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(1)
                )
            )
        }
        #expect(try faulty.activeAdoption()?.tuple == firstTuple)
        #expect(try faulty.historicalAdoptions().isEmpty)

        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: secondTuple,
                keyByte: 2,
                transportEpoch: 1,
                transportByte: 4,
                grantEpoch: 1,
                grantByte: 5,
                adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
            )
        )
        #expect(
            try store.authorizingAdoption(
                for: secondTuple,
                requiredScope: .recordingUploadOwn
            ).tuple == secondTuple
        )
        #expect(throws: ClientStoreError.self) {
            try store.authorizingAdoption(
                for: firstTuple,
                requiredScope: .recordingUploadOwn
            )
        }
        let history = try store.historicalAdoptions()
        #expect(history.count == 1)
        #expect(history[0].tuple == firstTuple)
        #expect(history[0].isAuthorizing == false)
    }

    @Test("historical tuple transport high-water cannot reset on re-adoption")
    func historicalAntiRollbackNamespace() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes()
        )
        let firstTuple = ClientStoreFixtures.tuple(library: 4, authorityByte: 4)
        let secondTuple = ClientStoreFixtures.tuple(library: 5, authorityByte: 5)
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: firstTuple,
                keyByte: 4,
                transportEpoch: 10,
                transportByte: 10,
                grantEpoch: 3,
                grantByte: 3
            )
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: secondTuple,
                keyByte: 5,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1,
                adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(1)
            )
        )

        #expect(throws: ClientStoreError.self) {
            try store.adopt(
                ClientStoreFixtures.adoption(
                    tuple: firstTuple,
                    keyByte: 4,
                    transportEpoch: 9,
                    transportByte: 9,
                    grantEpoch: 4,
                    grantByte: 4,
                    adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
                )
            )
        }
        #expect(try store.activeAdoption()?.tuple == secondTuple)
    }

    @Test("validator evidence cannot be tuple-swapped before or during persistence")
    func tupleSwapEvidenceRejected() throws {
        let firstTuple = ClientStoreFixtures.tuple(library: 11, authorityByte: 11)
        let secondTuple = ClientStoreFixtures.tuple(library: 12, authorityByte: 12)
        let firstTrust = ClientStoreFixtures.hostTrust(tuple: firstTuple, keyByte: 11)
        let firstGrant = ClientStoreFixtures.grantEvidence(
            tuple: firstTuple,
            keyByte: 11,
            grantID: GrantID(ClientStoreFixtures.uuid(1_101)),
            registryEpoch: 1,
            status: .active,
            exactSignedBytes: Data([0x11])
        )
        #expect(firstGrant.protocolVersion == .v1)
        #expect(firstGrant.devicePublicKey.deviceID == firstGrant.deviceID)
        #expect(firstGrant.scopes == [.recordingUploadOwn])
        #expect(firstGrant.issuedAt == ClientStoreFixtures.baseDate)
        #expect(firstGrant.expiresAt == nil)
        #expect(firstGrant.minimumCompatibleProtocolMinor == 0)
        #expect(firstGrant.maximumCompatibleProtocolMinor == 0)
        let secondTransport = ClientStoreFixtures.transportEvidence(
            tuple: secondTuple,
            keyByte: 12,
            epoch: 1,
            exactSignedBytes: Data([0x12])
        )

        #expect(throws: TransferValidationError.self) {
            try ValidatedClientAdoptionEvidence(
                hostTrust: firstTrust,
                transportSet: secondTransport,
                grant: firstGrant,
                adoptedAt: ClientStoreFixtures.baseDate
            )
        }

        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes()
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: firstTuple,
                keyByte: 11,
                transportEpoch: 1,
                transportByte: 0x21,
                grantEpoch: 1,
                grantByte: 0x22,
                grantID: firstGrant.grantID
            )
        )

        #expect(throws: ClientStoreError.self) {
            try store.persistVerifiedTransportSet(secondTransport)
        }
        let secondGrant = ClientStoreFixtures.grantEvidence(
            tuple: secondTuple,
            keyByte: 12,
            grantID: GrantID(ClientStoreFixtures.uuid(1_102)),
            registryEpoch: 2,
            status: .active,
            exactSignedBytes: Data([0x13])
        )
        #expect(throws: ClientStoreError.self) {
            try store.persistNextVerifiedGrant(secondGrant)
        }

        let active = try #require(try store.activeAdoption())
        #expect(active.tuple == firstTuple)
        #expect(active.transportSet.epoch == 1)
        #expect(active.grant.grantID == firstGrant.grantID)
        #expect(try store.historicalAdoptions().isEmpty)
    }

    @Test("revoked grant revival requires explicit atomic same-key re-adoption")
    func explicitRevokedGrantReadoption() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let tuple = ClientStoreFixtures.tuple(library: 13, authorityByte: 13)
        let originalGrantID = GrantID(ClientStoreFixtures.uuid(1_301))
        let replacementGrantID = GrantID(ClientStoreFixtures.uuid(1_302))

        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
            _ = try store.adopt(
                ClientStoreFixtures.adoption(
                    tuple: tuple,
                    keyByte: 13,
                    transportEpoch: 4,
                    transportByte: 0x31,
                    grantEpoch: 7,
                    grantByte: 0x32,
                    grantID: originalGrantID
                )
            )
            let revocation = ClientStoreFixtures.grantEvidence(
                tuple: tuple,
                keyByte: 13,
                grantID: originalGrantID,
                registryEpoch: 8,
                status: .revoked,
                exactSignedBytes: Data([0x33])
            )
            _ = try store.persistNextVerifiedGrant(revocation)

            let ordinaryRevival = ClientStoreFixtures.grantEvidence(
                tuple: tuple,
                keyByte: 13,
                grantID: originalGrantID,
                registryEpoch: 9,
                status: .active,
                exactSignedBytes: Data([0x34])
            )
            #expect(throws: ClientStoreError.self) {
                try store.persistNextVerifiedGrant(ordinaryRevival)
            }
            let ordinaryReplacement = ClientStoreFixtures.grantEvidence(
                tuple: tuple,
                keyByte: 13,
                grantID: replacementGrantID,
                registryEpoch: 9,
                status: .active,
                exactSignedBytes: Data([0x35])
            )
            #expect(throws: ClientStoreError.self) {
                try store.persistNextVerifiedGrant(ordinaryReplacement)
            }
            #expect(throws: ClientStoreError.self) {
                try store.adopt(
                    ClientStoreFixtures.adoption(
                        tuple: tuple,
                        keyByte: 13,
                        transportEpoch: 4,
                        transportByte: 0x31,
                        grantEpoch: 9,
                        grantByte: 0x34,
                        grantID: originalGrantID,
                        adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
                    )
                )
            }
        }

        let replacement = ClientStoreFixtures.adoption(
            tuple: tuple,
            keyByte: 13,
            transportEpoch: 4,
            transportByte: 0x31,
            grantEpoch: 9,
            grantByte: 0x35,
            grantID: replacementGrantID,
            adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(3)
        )
        let faulty = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes,
            faultInjector: PointFaultInjector(point: .afterDeactivatingPriorAdoption)
        )
        #expect(throws: InjectedClientStoreFault.self) {
            try faulty.readoptRevokedGrant(replacement)
        }

        do {
            let reopened = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: attributes
            )
            let stillRevoked = try #require(try reopened.activeAdoption())
            #expect(stillRevoked.grant.grantID == originalGrantID)
            #expect(stillRevoked.grant.registryEpoch == 8)
            #expect(stillRevoked.grant.status == .revoked)
            #expect(try reopened.historicalAdoptions().isEmpty)
            _ = try reopened.readoptRevokedGrant(replacement)
        }

        let finalReopen = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        let active = try finalReopen.authorizingAdoption(
            for: tuple,
            requiredScope: .recordingUploadOwn
        )
        #expect(active.grant.grantID == replacementGrantID)
        #expect(active.grant.deviceID == ClientStoreFixtures.device())
        #expect(active.grant.registryEpoch == 9)
        #expect(active.grant.status == .active)
        #expect(try finalReopen.historicalAdoptions().count == 1)

        let replayed = try finalReopen.readoptRevokedGrant(replacement)
        #expect(replayed.adoptionID == active.adoptionID)
        #expect(replayed.grant == active.grant)
        #expect(try finalReopen.historicalAdoptions().count == 1)

        let replayReopen = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        #expect(try replayReopen.activeAdoption()?.adoptionID == active.adoptionID)
        #expect(try replayReopen.historicalAdoptions().count == 1)
    }

    @Test("same-library authority replacement requires bound local choice and OS authentication")
    func explicitAuthorityReplacementAndRollback() async throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let tupleA = ClientStoreFixtures.tuple(library: 21, authorityByte: 21)
        let tupleB = ClientStoreFixtures.tuple(library: 21, authorityByte: 22)
        let grantIDA = GrantID(ClientStoreFixtures.uuid(2_101))
        let grantIDB = GrantID(ClientStoreFixtures.uuid(2_102))
        let adoptionA = ClientStoreFixtures.adoption(
            tuple: tupleA,
            keyByte: 21,
            transportEpoch: 3,
            transportByte: 0x21,
            grantEpoch: 1,
            grantByte: 0x31,
            grantID: grantIDA
        )
        let adoptionB = ClientStoreFixtures.adoption(
            tuple: tupleB,
            keyByte: 22,
            transportEpoch: 1,
            transportByte: 0x22,
            grantEpoch: 1,
            grantByte: 0x32,
            grantID: grantIDB,
            adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(1)
        )
        let replaceAWithB = ClientStoreFixtures.authorityReplacementEvidence(
            replacingTuple: tupleA,
            replacingKeyByte: 21,
            replacement: adoptionB
        )

        let failClosed = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes
        )
        _ = try failClosed.adopt(adoptionA)
        #expect(throws: ClientStoreError.authorityReplacementRequiresExplicitAuthorization(
            libraryID: tupleA.libraryID,
            remembered: tupleA.hostAuthorityID,
            presented: tupleB.hostAuthorityID
        )) {
            try failClosed.adopt(adoptionB)
        }
        await #expect(
            throws: ClientStoreError.authorityReplacementOSAuthenticationRequired
        ) {
            try await failClosed.replaceHostAuthority(replaceAWithB)
        }
        #expect(try failClosed.activeAdoption()?.tuple == tupleA)
        #expect(try failClosed.historicalAdoptions().isEmpty)

        let authorization = RecordingAuthorityReplacementAuthorizationBoundary()
        let authorized = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes,
            authorityReplacementAuthorizationBoundary: authorization
        )
        _ = try await authorized.replaceHostAuthority(replaceAWithB)
        #expect(try authorized.activeAdoption()?.tuple == tupleB)
        #expect(
            await authorization.recordedRequests() == [
                ClientAuthorityReplacementRequest(
                    libraryID: tupleA.libraryID,
                    replacingHostAuthorityID: tupleA.hostAuthorityID,
                    replacementHostAuthorityID: tupleB.hostAuthorityID
                )
            ]
        )

        // Returning to a historical authority is also an authority transition,
        // not an ordinary adoption or a chance to reset its high-water marks.
        let returnToA = ClientStoreFixtures.adoption(
            tuple: tupleA,
            keyByte: 21,
            transportEpoch: 4,
            transportByte: 0x23,
            grantEpoch: 2,
            grantByte: 0x33,
            grantID: grantIDA,
            adoptedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
        )
        #expect(throws: ClientStoreError.authorityReplacementRequiresExplicitAuthorization(
            libraryID: tupleB.libraryID,
            remembered: tupleB.hostAuthorityID,
            presented: tupleA.hostAuthorityID
        )) {
            try authorized.adopt(returnToA)
        }
        let replaceBWithA = ClientStoreFixtures.authorityReplacementEvidence(
            replacingTuple: tupleB,
            replacingKeyByte: 22,
            replacement: returnToA
        )

        let faulty = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes,
            faultInjector: PointFaultInjector(point: .afterDeactivatingPriorAdoption),
            authorityReplacementAuthorizationBoundary: authorization
        )
        await #expect(throws: InjectedClientStoreFault.self) {
            try await faulty.replaceHostAuthority(replaceBWithA)
        }
        #expect(try faulty.activeAdoption()?.tuple == tupleB)
        #expect(try faulty.historicalAdoptions().map(\.tuple) == [tupleA])

        let final = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: attributes,
            authorityReplacementAuthorizationBoundary: authorization
        )
        _ = try await final.replaceHostAuthority(replaceBWithA)
        #expect(try final.activeAdoption()?.tuple == tupleA)
        #expect(try final.activeAdoption()?.transportSet.epoch == 4)
        #expect(try final.activeAdoption()?.grant.registryEpoch == 2)
        #expect(try final.historicalAdoptions().map(\.tuple) == [tupleA, tupleB])
    }

    @Test("scope, expiry, and protocol claims remain authorizing constraints after reopen")
    func grantClaimsAuthorizeByScopeTimeAndReopen() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tuple = ClientStoreFixtures.tuple(library: 23, authorityByte: 23)
        let expiresAt = ClientStoreFixtures.baseDate.addingTimeInterval(60)
        let protocolVersion = try IdentityProtocolVersion(minor: 1)
        let storedProtocolVersion = try ClientGrantProtocolVersion(minor: 1)
        let adoption = ClientStoreFixtures.adoption(
            tuple: tuple,
            keyByte: 23,
            transportEpoch: 1,
            transportByte: 0x41,
            grantEpoch: 1,
            grantByte: 0x42,
            protocolVersion: protocolVersion,
            scopes: [.recordingUploadOwn],
            grantExpiresAt: expiresAt,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 1
        )

        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: RecordingStorageAttributes(),
                now: { ClientStoreFixtures.baseDate.addingTimeInterval(59) }
            )
            _ = try store.adopt(adoption)
            let authorized = try store.authorizingAdoption(
                for: tuple,
                requiredScope: .recordingUploadOwn
            )
            #expect(authorized.grant.protocolVersion == storedProtocolVersion)
            #expect(
                authorized.grant.devicePublicKeyX963
                    == adoption.grant.devicePublicKey.rawBytes
            )
            #expect(authorized.grant.scopes == [.recordingUploadOwn])
            #expect(authorized.grant.issuedAt == ClientStoreFixtures.baseDate)
            #expect(authorized.grant.expiresAt == expiresAt)
            #expect(authorized.grant.minimumCompatibleProtocolMinor == 0)
            #expect(authorized.grant.maximumCompatibleProtocolMinor == 1)
            #expect(throws: ClientStoreError.grantMissingRequiredScope(.recordingReadOwn)) {
                try store.authorizingAdoption(
                    for: tuple,
                    requiredScope: .recordingReadOwn
                )
            }
        }

        do {
            let reopenedBeforeExpiry = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: RecordingStorageAttributes(),
                now: { ClientStoreFixtures.baseDate.addingTimeInterval(59) }
            )
            let persisted = try #require(try reopenedBeforeExpiry.activeAdoption())
            #expect(persisted.grant.protocolVersion == storedProtocolVersion)
            #expect(persisted.grant.scopes == [.recordingUploadOwn])
            #expect(persisted.grant.expiresAt == expiresAt)
            #expect(
                throws: ClientStoreError.grantMissingRequiredScope(.recordingReadOwn)
            ) {
                try reopenedBeforeExpiry.authorizingAdoption(
                    for: tuple,
                    requiredScope: .recordingReadOwn
                )
            }
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes(),
            now: { expiresAt }
        )
        let persisted = try #require(try reopened.activeAdoption())
        #expect(persisted.grant.protocolVersion == storedProtocolVersion)
        #expect(persisted.grant.scopes == [.recordingUploadOwn])
        #expect(persisted.grant.expiresAt == expiresAt)
        #expect(throws: ClientStoreError.grantExpired) {
            try reopened.authorizingAdoption(
                for: tuple,
                requiredScope: .recordingUploadOwn
            )
        }
    }
}

private actor RecordingAuthorityReplacementAuthorizationBoundary:
    ClientAuthorityReplacementAuthorizationBoundary {
    private var requests: [ClientAuthorityReplacementRequest] = []

    func authorizeAuthorityReplacement(
        _ request: ClientAuthorityReplacementRequest
    ) async throws {
        requests.append(request)
    }

    func recordedRequests() -> [ClientAuthorityReplacementRequest] {
        requests
    }
}
