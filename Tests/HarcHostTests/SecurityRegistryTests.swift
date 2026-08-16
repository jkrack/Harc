import Foundation
import GRDB
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity

@Suite("HarcHost security registry")
struct SecurityRegistryTests {
    @Test("issue, scope change, and revocation advance one journaled epoch each")
    func issueChangeRevoke() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
            capacityProvider: FixedHostVolumeCapacityProvider()
        )

        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(initial, exactGrantBytes: Data("grant-1".utf8))
        #expect(try await store.registryRevision() == 1)
        _ = try await store.authorize(
            fixture.context(for: initial),
            requiredScope: .recordingUploadOwn,
            objectOwner: fixture.deviceID,
            at: fixture.beganAt.addingTimeInterval(1)
        )

        let current = try #require(try await store.deviceRegistryEntry(deviceID: fixture.deviceID))
        let replacement = try current.replacingScopesAfterLocalAuthorization(
            [.recordingUploadOwn, .recordingReadOwn, .libraryMetadataRead],
            issuedAt: fixture.beganAt.addingTimeInterval(2)
        )
        try await store.replaceDeviceGrant(
            replacement.grant,
            exactGrantBytes: Data("grant-2".utf8)
        )
        #expect(try await store.registryRevision() == 2)
        await #expect(throws: HarcHostError.grantMismatch) {
            _ = try await store.authorize(
                fixture.context(for: initial),
                requiredScope: .recordingUploadOwn,
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        _ = try await store.authorize(
            fixture.context(for: replacement.grant),
            requiredScope: .libraryMetadataRead,
            at: fixture.beganAt.addingTimeInterval(3)
        )

        try await store.revokeDevice(
            fixture.deviceID,
            revocationID: UUID(),
            reasonCode: "user.revoked",
            exactRevocationBytes: Data("revoke-3".utf8),
            issuedAt: fixture.beganAt.addingTimeInterval(4)
        )
        #expect(try await store.registryRevision() == 3)
        #expect(await highWater.loadRegistryRevision() == 3)
        await #expect(throws: HarcHostError.deviceRevoked) {
            _ = try await store.authorize(
                fixture.context(for: replacement.grant),
                requiredScope: .recordingUploadOwn,
                at: fixture.beganAt.addingTimeInterval(5)
            )
        }
    }

    @Test("fractional revocation time preserves the canonical pending mutation")
    func fractionalRevocationTime() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory(
            "security-fractional-revocation-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fractionalTime = Date(
            timeIntervalSince1970: 2_000_000_000.123_456_7
        )
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            localOSAuthenticationBoundary:
                FixedHostLocalOSAuthenticationBoundary(authorized: true),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { fractionalTime }
        )

        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("fractional-grant".utf8)
        )
        try await store.revokeDevice(
            fixture.deviceID,
            revocationID: UUID(),
            reasonCode: "user.revoked",
            exactRevocationBytes: Data("fractional-revocation".utf8)
        )

        #expect(try await store.registryRevision() == 2)
        #expect(await highWater.loadRegistryRevision() == 2)
        #expect(
            try await store.deviceRegistryEntry(
                deviceID: fixture.deviceID
            )?.status == .revoked
        )
    }

    @Test("clock rollback clamps session invalidation for scope replacement and revocation")
    func clockRollbackClampsGrantMutationSessionInvalidation() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory(
            "security-session-clock-rollback-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutationDate = fixture.beganAt.addingTimeInterval(10)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            localOSAuthenticationBoundary:
                FixedHostLocalOSAuthenticationBoundary(authorized: true),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { mutationDate }
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("initial-grant".utf8)
        )

        let replacementTokenID = UUID()
        let replacementTokenIssuedAt = mutationDate.addingTimeInterval(60)
        try await insertSessionToken(
            replacementTokenID,
            grant: initial,
            issuedAt: replacementTokenIssuedAt,
            store: store
        )
        let current = try #require(
            try await store.deviceRegistryEntry(deviceID: fixture.deviceID)
        )
        let replacement = try current.replacingScopesAfterLocalAuthorization(
            [.recordingUploadOwn, .recordingReadOwn, .libraryMetadataRead],
            issuedAt: mutationDate
        ).grant
        try await store.replaceDeviceGrant(
            replacement,
            exactGrantBytes: Data("replacement-grant".utf8)
        )

        let replacementInvalidation = try await store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT invalidated_at, invalidation_reason
                    FROM session_tokens WHERE token_id = ?
                    """,
                arguments: [replacementTokenID.uuidString.lowercased()]
            )
        }
        #expect(
            replacementInvalidation?["invalidated_at"] as Double?
                == HarcHostStore.unixTime(replacementTokenIssuedAt)
        )
        #expect(
            replacementInvalidation?["invalidation_reason"] as String?
                == "grant-replaced"
        )

        let revocationTokenID = UUID()
        let revocationTokenIssuedAt = mutationDate.addingTimeInterval(120)
        try await insertSessionToken(
            revocationTokenID,
            grant: replacement,
            issuedAt: revocationTokenIssuedAt,
            store: store
        )
        try await store.revokeDevice(
            fixture.deviceID,
            revocationID: UUID(),
            reasonCode: "test.clock-rollback",
            exactRevocationBytes: Data("revocation".utf8)
        )

        let revocationInvalidation = try await store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT invalidated_at, invalidation_reason
                    FROM session_tokens WHERE token_id = ?
                    """,
                arguments: [revocationTokenID.uuidString.lowercased()]
            )
        }
        #expect(
            revocationInvalidation?["invalidated_at"] as Double?
                == HarcHostStore.unixTime(revocationTokenIssuedAt)
        )
        #expect(
            revocationInvalidation?["invalidation_reason"] as String?
                == "revoked"
        )
        #expect(try await store.registryRevision() == 3)
        #expect(await highWater.loadRegistryRevision() == 3)
    }

    @Test("initial expanded grants require local OS authentication")
    func initialExpandedGrantRequiresLocalOSAuthentication() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { fixture.beganAt.addingTimeInterval(3) }
        )
        let ticketID = UUID()
        try await installApprovedTicket(
            ticketID,
            for: fixture.deviceID,
            fixture: fixture,
            store: store
        )
        let expanded = try fixture.grant(scopes: [
            .recordingReadOwn,
            .recordingUploadOwn,
            .libraryMetadataRead,
        ])

        await #expect(throws: HarcHostError.localOSAuthenticationRequired) {
            try await store.issueDeviceGrant(
                expanded,
                exactGrantBytes: Data("expanded-grant".utf8),
                pairingTicketID: ticketID
            )
        }
        #expect(try await store.registryRevision() == 0)
        #expect(try await store.deviceRegistryEntry(deviceID: fixture.deviceID) == nil)
        #expect(try await ticketState(ticketID, in: store) == .approved)
    }

    @Test("an authenticated initial expansion and the selected Mac minimum are admitted")
    func initialGrantScopePolicyUsesDurableClientKind() async throws {
        let fixture = HostTestFixture()

        let authorizedDirectory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: authorizedDirectory) }
        let authorizedStore = try await HarcHostStore.inMemory(
            stagingRoot: authorizedDirectory,
            metadata: fixture.metadata,
            localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { fixture.beganAt.addingTimeInterval(3) }
        )
        let expandedTicketID = UUID()
        try await installApprovedTicket(
            expandedTicketID,
            for: fixture.deviceID,
            fixture: fixture,
            store: authorizedStore
        )
        let expanded = try fixture.grant(scopes: [
            .recordingReadOwn,
            .recordingUploadOwn,
            .libraryMetadataRead,
        ])
        try await authorizedStore.issueDeviceGrant(
            expanded,
            exactGrantBytes: Data("authorized-expanded-grant".utf8),
            pairingTicketID: expandedTicketID
        )

        let macFixture = HostTestFixture()
        let macDirectory = try macFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: macDirectory) }
        let macStore = try await HarcHostStore.inMemory(
            stagingRoot: macDirectory,
            metadata: macFixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { macFixture.beganAt.addingTimeInterval(3) }
        )
        let macTicketID = UUID()
        try await installApprovedTicket(
            macTicketID,
            for: macFixture.deviceID,
            clientKind: .macClient,
            fixture: macFixture,
            store: macStore
        )
        let macMinimum = try macFixture.grant(
            scopes: Set(ScopePolicy.minimalScopes(for: .macClient))
        )
        try await macStore.issueDeviceGrant(
            macMinimum,
            exactGrantBytes: Data("mac-minimum-grant".utf8),
            pairingTicketID: macTicketID
        )
        #expect(try await macStore.registryRevision() == 1)
    }

    @Test("later scope changes require local OS authentication")
    func scopeChangeRequiresLocalOSAuthentication() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("initial-grant".utf8)
        )
        let current = try #require(try await store.deviceRegistryEntry(deviceID: fixture.deviceID))
        let replacement = try current.replacingScopesAfterLocalAuthorization(
            [.recordingReadOwn, .recordingUploadOwn, .libraryMetadataRead],
            issuedAt: fixture.beganAt.addingTimeInterval(2)
        ).grant

        await #expect(throws: HarcHostError.localOSAuthenticationRequired) {
            try await store.replaceDeviceGrant(
                replacement,
                exactGrantBytes: Data("replacement-grant".utf8)
            )
        }
        #expect(try await store.registryRevision() == 1)
        #expect(try await store.deviceRegistryEntry(deviceID: fixture.deviceID) == DeviceRegistryEntry(activeGrant: initial))
    }

    @Test("scope replacement atomically invalidates background capabilities")
    func scopeReplacementInvalidatesBackgroundCapabilities() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acceptedAt = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { acceptedAt }
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("initial-grant".utf8)
        )

        let uploadID = UploadID.random()
        let origin = OriginRecordingID(
            deviceID: fixture.deviceID,
            recordingUUID: UUID()
        )
        _ = try await store.beginUpload(
            context: fixture.context(for: initial),
            sessionCapabilities: try fixture.sessionCapabilities(for: fixture.profile()),
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO background_capabilities (
                        capability_id, upload_id, owner_device_id, grant_id,
                        grant_epoch, generation, capability_binding_sha256,
                        expires_at, state, created_at
                    ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, 'issued', ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    uploadID.description,
                    fixture.deviceID.rawBytes,
                    initial.grantID.description,
                    Int64(initial.grantEpoch.rawValue),
                    Data(repeating: 0xA2, count: 32),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(100)),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(2)),
                ]
            )
        }

        let current = try #require(
            try await store.deviceRegistryEntry(deviceID: fixture.deviceID)
        )
        let replacement = try current.replacingScopesAfterLocalAuthorization(
            [.recordingUploadOwn, .recordingReadOwn, .libraryMetadataRead],
            issuedAt: fixture.beganAt.addingTimeInterval(2)
        )
        try await store.replaceDeviceGrant(
            replacement.grant,
            exactGrantBytes: Data("replacement-grant".utf8)
        )

        let capability = try await store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, invalidated_at FROM background_capabilities WHERE upload_id = ?",
                arguments: [uploadID.description]
            )
        }
        #expect(capability?["state"] as String? == "grant-replaced")
        #expect(
            capability?["invalidated_at"] as Double?
                == HarcHostStore.unixTime(acceptedAt)
        )
    }

    @Test("all five security journal crash boundaries reopen safely")
    func crashBoundaryRepair() async throws {
        for point in SecurityRegistryFailurePoint.allCases {
            let fixture = HostTestFixture()
            let directory = try fixture.temporaryDirectory("security-\(point.rawValue)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let databaseURL = directory.appendingPathComponent("HarcHost.db")
            let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
            let highWater = InMemorySecurityRegistryHighWaterMarkStore()
            let injector = OneShotSecurityFailureInjector(point)
            let grant = try fixture.grant()

            do {
                let crashingStore = try await HarcHostStore.onDisk(
                    databaseURL: databaseURL,
                    stagingRoot: stagingRoot,
                    metadata: fixture.metadata,
                    highWaterMarkStore: highWater,
                    securityFailureInjector: injector,
                    capacityProvider: FixedHostVolumeCapacityProvider()
                )
                await #expect(throws: InjectedHostCrash.security(point)) {
                    try await crashingStore.seedDeviceGrantForTesting(
                        grant,
                        exactGrantBytes: Data("grant".utf8)
                    )
                }
            }

            let reopened = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            if point == .beforePendingMutation {
                #expect(try await reopened.registryRevision() == 0)
                #expect(try await reopened.deviceRegistryEntry(deviceID: fixture.deviceID) == nil)
                try await reopened.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("grant".utf8))
            }
            #expect(try await reopened.registryRevision() == 1)
            #expect(try await reopened.deviceRegistryEntry(deviceID: fixture.deviceID) != nil)
            #expect(await highWater.loadRegistryRevision() == 1)
        }
    }

    @Test("restored HostDB behind the high-water mark fails closed")
    func rollbackFailsClosed() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore(initialRevision: 1)

        await #expect(throws: HarcHostError.securityRegistryRollback(
            databaseRevision: 0,
            highWaterRevision: 1
        )) {
            _ = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
        }
    }

    @Test("scope-change and revocation mutations recover across process reopen")
    func changeAndRevocationCrashRepair() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let initial = try fixture.grant()

        do {
            let store = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            try await store.seedDeviceGrantForTesting(initial, exactGrantBytes: Data("grant-1".utf8))
        }

        let replacement: DeviceGrantClaims
        do {
            let store = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
                securityFailureInjector: OneShotSecurityFailureInjector(.afterHighWaterAdvance),
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            let current = try #require(try await store.deviceRegistryEntry(deviceID: fixture.deviceID))
            replacement = try current.replacingScopesAfterLocalAuthorization(
                [.recordingUploadOwn, .recordingReadOwn, .libraryMetadataRead],
                issuedAt: fixture.beganAt.addingTimeInterval(2)
            ).grant
            await #expect(throws: InjectedHostCrash.security(.afterHighWaterAdvance)) {
                try await store.replaceDeviceGrant(
                    replacement,
                    exactGrantBytes: Data("grant-2".utf8)
                )
            }
        }

        do {
            let repaired = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            #expect(try await repaired.registryRevision() == 2)
            #expect(try await repaired.deviceRegistryEntry(deviceID: fixture.deviceID)?.currentGrantEpoch == replacement.grantEpoch)
        }

        do {
            let store = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                securityFailureInjector: OneShotSecurityFailureInjector(.afterPendingMutation),
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            await #expect(throws: InjectedHostCrash.security(.afterPendingMutation)) {
                try await store.revokeDevice(
                    fixture.deviceID,
                    revocationID: UUID(),
                    reasonCode: "user.revoked",
                    exactRevocationBytes: Data("revoke-3".utf8),
                    issuedAt: fixture.beganAt.addingTimeInterval(3)
                )
            }
        }

        let repaired = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(try await repaired.registryRevision() == 3)
        #expect(try await repaired.deviceRegistryEntry(deviceID: fixture.deviceID)?.status == .revoked)
    }

    @Test("pairing placeholders persist only the secret binding and have terminal states")
    func pairingPlaceholderTransitions() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let issueTime = fixture.beganAt.addingTimeInterval(3)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { issueTime }
        )
        let ticketID = UUID()
        let ticket = try PairingTicketPlaceholder(
            ticketID: ticketID,
            ticketSecretBindingSHA256: Data(repeating: 0xAB, count: 32),
            issuedAt: fixture.beganAt,
            expiresAt: fixture.beganAt.addingTimeInterval(120)
        )
        try await store.insertPairingTicketPlaceholder(ticket)
        try await store.reservePairingTicket(
            ticketID: ticketID,
            for: fixture.deviceID,
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await store.transitionPairingTicket(
            ticketID: ticketID,
            to: .approved,
            at: fixture.beganAt.addingTimeInterval(2)
        )
        await #expect(throws: HarcHostError.invalidPairingTransition) {
            try await store.transitionPairingTicket(
                ticketID: ticketID,
                to: .expired,
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        try await store.issueDeviceGrant(
            fixture.grant(),
            exactGrantBytes: Data("paired-grant".utf8),
            pairingTicketID: ticketID
        )
        await #expect(throws: HarcHostError.invalidPairingTransition) {
            try await store.transitionPairingTicket(
                ticketID: ticketID,
                to: .issued,
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
    }

    @Test("initial grants require a live approved ticket reserved to the exact device")
    func initialGrantRequiresExactLiveTicket() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let issuanceTime = fixture.beganAt.addingTimeInterval(121)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { issuanceTime }
        )
        let ticketID = UUID()
        let ticket = try PairingTicketPlaceholder(
            ticketID: ticketID,
            ticketSecretBindingSHA256: Data(repeating: 0xBC, count: 32),
            issuedAt: fixture.beganAt,
            expiresAt: fixture.beganAt.addingTimeInterval(120)
        )
        try await store.insertPairingTicketPlaceholder(
            ticket,
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await store.reservePairingTicket(
            ticketID: ticketID,
            for: fixture.deviceID,
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await store.transitionPairingTicket(
            ticketID: ticketID,
            to: .approved,
            at: fixture.beganAt.addingTimeInterval(2)
        )
        await #expect(throws: HarcHostError.securityMutationInvalid(
            "Pairing ticket expired before the grant transition became durable."
        )) {
            try await store.issueDeviceGrant(
                fixture.grant(),
                exactGrantBytes: Data("expired-grant".utf8),
                pairingTicketID: ticketID
            )
        }
        #expect(try await store.registryRevision() == 0)
        #expect(await highWater.loadRegistryRevision() == 0)

        let secondDirectory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        let liveTime = fixture.beganAt.addingTimeInterval(10)
        let mismatchStore = try await HarcHostStore.inMemory(
            stagingRoot: secondDirectory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { liveTime }
        )
        let mismatchTicketID = UUID()
        try await mismatchStore.insertPairingTicketPlaceholder(
            PairingTicketPlaceholder(
                ticketID: mismatchTicketID,
                ticketSecretBindingSHA256: Data(repeating: 0xCD, count: 32),
                issuedAt: fixture.beganAt,
                expiresAt: fixture.beganAt.addingTimeInterval(120)
            )
        )
        let otherDeviceID = SoftwareP256SigningKey().publicKey.deviceID
        try await mismatchStore.reservePairingTicket(
            ticketID: mismatchTicketID,
            for: otherDeviceID,
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await mismatchStore.transitionPairingTicket(
            ticketID: mismatchTicketID,
            to: .approved,
            at: fixture.beganAt.addingTimeInterval(2)
        )
        await #expect(throws: HarcHostError.securityMutationInvalid(
            "Pairing ticket is reserved to a different device."
        )) {
            try await mismatchStore.issueDeviceGrant(
                fixture.grant(),
                exactGrantBytes: Data("mismatched-grant".utf8),
                pairingTicketID: mismatchTicketID
            )
        }
    }

    @Test("a durably pending grant repairs after its pairing ticket expires")
    func pendingGrantRepairsAfterTicketExpiry() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let ticketID = UUID()
        let grant = try fixture.grant()
        let acceptedAt = fixture.beganAt.addingTimeInterval(10)

        do {
            let crashing = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                securityFailureInjector: OneShotSecurityFailureInjector(.afterPendingMutation),
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: { acceptedAt }
            )
            try await crashing.insertPairingTicketPlaceholder(
                PairingTicketPlaceholder(
                    ticketID: ticketID,
                    ticketSecretBindingSHA256: Data(repeating: 0xDE, count: 32),
                    issuedAt: fixture.beganAt,
                    expiresAt: fixture.beganAt.addingTimeInterval(120)
                )
            )
            try await crashing.reservePairingTicket(
                ticketID: ticketID,
                for: fixture.deviceID,
                at: fixture.beganAt.addingTimeInterval(1)
            )
            try await crashing.transitionPairingTicket(
                ticketID: ticketID,
                to: .approved,
                at: fixture.beganAt.addingTimeInterval(2)
            )
            await #expect(throws: InjectedHostCrash.security(.afterPendingMutation)) {
                try await crashing.issueDeviceGrant(
                    grant,
                    exactGrantBytes: Data("paired-grant".utf8),
                    pairingTicketID: ticketID
                )
            }
        }

        let afterExpiry = fixture.beganAt.addingTimeInterval(121)
        let repaired = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { afterExpiry }
        )
        #expect(try await repaired.registryRevision() == 1)
        #expect(try await repaired.deviceRegistryEntry(deviceID: fixture.deviceID) != nil)
        let ticketState = try await repaired.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            )
        }
        #expect(ticketState == PairingTicketState.consumed.rawValue)
    }

    @Test("active same-key re-adoption preserves grant ID, advances one epoch, and invalidates old authorization")
    func activeSameKeyReadoption() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acceptedAt = fixture.beganAt.addingTimeInterval(10)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { acceptedAt }
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("initial-grant".utf8)
        )

        // Persist one old-epoch upload capability so the final transaction's
        // explicit invalidation is exercised alongside registry/session checks.
        let uploadID = UploadID.random()
        let origin = OriginRecordingID(
            deviceID: fixture.deviceID,
            recordingUUID: UUID()
        )
        _ = try await store.beginUpload(
            context: fixture.context(for: initial),
            sessionCapabilities: try fixture.sessionCapabilities(for: fixture.profile()),
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO background_capabilities (
                        capability_id, upload_id, owner_device_id, grant_id,
                        grant_epoch, generation, capability_binding_sha256,
                        expires_at, state, created_at
                    ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, 'issued', ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    uploadID.description,
                    fixture.deviceID.rawBytes,
                    initial.grantID.description,
                    Int64(initial.grantEpoch.rawValue),
                    Data(repeating: 0xA1, count: 32),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(100)),
                    HarcHostStore.unixTime(fixture.beganAt.addingTimeInterval(2)),
                ]
            )
        }

        let ticketID = UUID()
        try await installApprovedTicket(
            ticketID,
            for: fixture.deviceID,
            fixture: fixture,
            store: store
        )
        let wrongGrantID = try fixture.grant(
            id: .random(),
            epoch: initial.grantEpoch.next()
        )
        await #expect(throws: HarcHostError.securityMutationInvalid(
            "Active-device re-adoption must preserve the current grant ID."
        )) {
            try await store.readoptDevice(
                wrongGrantID,
                exactGrantBytes: Data("invalid-new-id".utf8),
                pairingTicketID: ticketID
            )
        }
        #expect(try await store.registryRevision() == 1)
        #expect(try await ticketState(ticketID, in: store) == .approved)

        let next = try fixture.grant(
            id: initial.grantID,
            epoch: initial.grantEpoch.next(),
            scopes: [.recordingUploadOwn, .recordingReadOwn, .libraryMetadataRead]
        )
        try await store.readoptDevice(
            next,
            exactGrantBytes: Data("readopted-active-grant".utf8),
            pairingTicketID: ticketID
        )

        let entry = try #require(try await store.deviceRegistryEntry(deviceID: fixture.deviceID))
        #expect(entry.status == .active)
        #expect(entry.deviceID == fixture.deviceID)
        #expect(entry.devicePublicKey == fixture.deviceKey.publicKey)
        #expect(entry.currentGrantID == initial.grantID)
        let expectedActiveEpoch = try initial.grantEpoch.next()
        #expect(entry.currentGrantEpoch == expectedActiveEpoch)
        #expect(try await store.registryRevision() == 2)
        #expect(await highWater.loadRegistryRevision() == 2)
        #expect(try await ticketState(ticketID, in: store) == .consumed)
        #expect(try await store.exactCurrentGrantBytes(deviceID: fixture.deviceID) == Data("readopted-active-grant".utf8))
        await #expect(throws: HarcHostError.grantMismatch) {
            _ = try await store.authorize(
                fixture.context(for: initial),
                requiredScope: .recordingUploadOwn,
                at: acceptedAt
            )
        }
        let capability = try await store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, invalidated_at FROM background_capabilities WHERE upload_id = ?",
                arguments: [uploadID.description]
            )
        }
        #expect(capability?["state"] as String? == "grant-replaced")
        #expect(capability?["invalidated_at"] as Double? == HarcHostStore.unixTime(acceptedAt))
    }

    @Test("revoked same-key re-adoption requires a fresh grant ID at the exact next epoch")
    func revokedSameKeyReadoption() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acceptedAt = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { acceptedAt }
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(initial, exactGrantBytes: Data("initial".utf8))
        try await store.revokeDevice(
            fixture.deviceID,
            revocationID: UUID(),
            reasonCode: "user.revoked",
            exactRevocationBytes: Data("revoked".utf8),
            issuedAt: fixture.beganAt.addingTimeInterval(3)
        )
        let revoked = try #require(try await store.deviceRegistryEntry(deviceID: fixture.deviceID))
        #expect(revoked.status == .revoked)

        let ticketID = UUID()
        try await installApprovedTicket(
            ticketID,
            for: fixture.deviceID,
            fixture: fixture,
            store: store
        )
        let reusedID = try fixture.grant(
            id: initial.grantID,
            epoch: revoked.currentGrantEpoch.next()
        )
        await #expect(throws: HarcHostError.securityMutationInvalid(
            "Revoked-device re-adoption requires a fresh grant ID."
        )) {
            try await store.readoptDevice(
                reusedID,
                exactGrantBytes: Data("invalid-reused-id".utf8),
                pairingTicketID: ticketID
            )
        }
        #expect(try await ticketState(ticketID, in: store) == .approved)

        let freshGrantID = GrantID.random()
        let readopted = try fixture.grant(
            id: freshGrantID,
            epoch: revoked.currentGrantEpoch.next()
        )
        try await store.readoptDevice(
            readopted,
            exactGrantBytes: Data("readopted-revoked-grant".utf8),
            pairingTicketID: ticketID
        )

        let entry = try #require(try await store.deviceRegistryEntry(deviceID: fixture.deviceID))
        #expect(entry.status == .active)
        #expect(entry.deviceID == revoked.deviceID)
        #expect(entry.devicePublicKey == revoked.devicePublicKey)
        #expect(entry.currentGrantID == freshGrantID)
        let expectedRevokedEpoch = try revoked.currentGrantEpoch.next()
        #expect(entry.currentGrantEpoch == expectedRevokedEpoch)
        #expect(try await store.registryRevision() == 3)
        #expect(try await ticketState(ticketID, in: store) == .consumed)
    }

    @Test("same-key re-adoption rejects missing local OS authentication")
    func readoptionRequiresLocalOSAuthentication() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acceptedAt = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { acceptedAt }
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(initial, exactGrantBytes: Data("initial".utf8))
        let ticketID = UUID()
        try await installApprovedTicket(
            ticketID,
            for: fixture.deviceID,
            fixture: fixture,
            store: store
        )
        let next = try fixture.grant(
            id: initial.grantID,
            epoch: initial.grantEpoch.next()
        )

        await #expect(throws: HarcHostError.localOSAuthenticationRequired) {
            try await store.readoptDevice(
                next,
                exactGrantBytes: Data("readopted".utf8),
                pairingTicketID: ticketID
            )
        }
        #expect(try await store.registryRevision() == 1)
        #expect(try await ticketState(ticketID, in: store) == .approved)
    }

    @Test("same-key re-adoption rejects wrong-device, expired, nonapproved, and consumed tickets")
    func readoptionRequiresExactLiveApprovedTicket() async throws {
        enum TicketCase: CaseIterable {
            case wrongDevice
            case expired
            case nonapproved
            case consumed
        }

        for ticketCase in TicketCase.allCases {
            let fixture = HostTestFixture()
            let directory = try fixture.temporaryDirectory("readopt-ticket-\(ticketCase)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let acceptedAt = ticketCase == .expired
                ? fixture.beganAt.addingTimeInterval(121)
                : fixture.beganAt.addingTimeInterval(10)
            let store = try await HarcHostStore.inMemory(
                stagingRoot: directory,
                metadata: fixture.metadata,
                localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: { acceptedAt }
            )
            let initial = try fixture.grant()
            try await store.seedDeviceGrantForTesting(initial, exactGrantBytes: Data("initial".utf8))
            let ticketID = UUID()
            let reservedDeviceID = ticketCase == .wrongDevice
                ? SoftwareP256SigningKey().publicKey.deviceID
                : fixture.deviceID
            try await store.insertPairingTicketPlaceholder(
                PairingTicketPlaceholder(
                    ticketID: ticketID,
                    ticketSecretBindingSHA256: Data(repeating: 0xE1, count: 32),
                    issuedAt: fixture.beganAt,
                    expiresAt: fixture.beganAt.addingTimeInterval(120)
                ),
                at: fixture.beganAt.addingTimeInterval(1)
            )
            try await store.reservePairingTicket(
                ticketID: ticketID,
                for: reservedDeviceID,
                at: fixture.beganAt.addingTimeInterval(1)
            )
            if ticketCase != .nonapproved {
                try await store.transitionPairingTicket(
                    ticketID: ticketID,
                    to: .approved,
                    at: fixture.beganAt.addingTimeInterval(2)
                )
            }
            if ticketCase == .consumed {
                try await store.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE pairing_tickets SET state = 'consumed' WHERE ticket_id = ?",
                        arguments: [ticketID.uuidString.lowercased()]
                    )
                }
            }

            let next = try fixture.grant(
                id: initial.grantID,
                epoch: initial.grantEpoch.next()
            )
            let expectedError: HarcHostError = switch ticketCase {
            case .wrongDevice:
                .securityMutationInvalid("Pairing ticket is reserved to a different device.")
            case .expired:
                .securityMutationInvalid(
                    "Pairing ticket expired before the grant transition became durable."
                )
            case .nonapproved, .consumed:
                .securityMutationInvalid("Pairing ticket is not locally approved.")
            }
            await #expect(throws: expectedError) {
                try await store.readoptDevice(
                    next,
                    exactGrantBytes: Data("readopted".utf8),
                    pairingTicketID: ticketID
                )
            }
            #expect(try await store.registryRevision() == 1)
        }
    }

    @Test("same-key re-adoption repairs every three-phase crash boundary without re-authentication")
    func readoptionCrashBoundaryRepair() async throws {
        for point in SecurityRegistryFailurePoint.allCases {
            let fixture = HostTestFixture()
            let directory = try fixture.temporaryDirectory("readopt-\(point.rawValue)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let databaseURL = directory.appendingPathComponent("HarcHost.db")
            let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
            let highWater = InMemorySecurityRegistryHighWaterMarkStore()
            let initial = try fixture.grant()
            let readopted = try fixture.grant(
                id: initial.grantID,
                epoch: initial.grantEpoch.next()
            )
            let ticketID = UUID()
            let acceptedAt = fixture.beganAt.addingTimeInterval(10)

            do {
                let setup = try await HarcHostStore.onDisk(
                    databaseURL: databaseURL,
                    stagingRoot: stagingRoot,
                    metadata: fixture.metadata,
                    highWaterMarkStore: highWater,
                    capacityProvider: FixedHostVolumeCapacityProvider(),
                    now: { acceptedAt }
                )
                try await setup.seedDeviceGrantForTesting(
                    initial,
                    exactGrantBytes: Data("initial".utf8)
                )
                try await installApprovedTicket(
                    ticketID,
                    for: fixture.deviceID,
                    fixture: fixture,
                    store: setup
                )
            }

            do {
                let crashing = try await HarcHostStore.onDisk(
                    databaseURL: databaseURL,
                    stagingRoot: stagingRoot,
                    metadata: fixture.metadata,
                    highWaterMarkStore: highWater,
                    localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(authorized: true),
                    securityFailureInjector: OneShotSecurityFailureInjector(point),
                    capacityProvider: FixedHostVolumeCapacityProvider(),
                    now: { acceptedAt }
                )
                await #expect(throws: InjectedHostCrash.security(point)) {
                    try await crashing.readoptDevice(
                        readopted,
                        exactGrantBytes: Data("readopted".utf8),
                        pairingTicketID: ticketID
                    )
                }
            }

            let reopenTime = point == .beforePendingMutation
                ? acceptedAt
                : fixture.beganAt.addingTimeInterval(121)
            let repaired = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(
                    authorized: point == .beforePendingMutation
                ),
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: { reopenTime }
            )
            if point == .beforePendingMutation {
                try await repaired.readoptDevice(
                    readopted,
                    exactGrantBytes: Data("readopted".utf8),
                    pairingTicketID: ticketID
                )
            }
            #expect(try await repaired.registryRevision() == 2)
            #expect(await highWater.loadRegistryRevision() == 2)
            #expect(try await repaired.deviceRegistryEntry(deviceID: fixture.deviceID) == DeviceRegistryEntry(activeGrant: readopted))
            #expect(try await ticketState(ticketID, in: repaired) == .consumed)
        }
    }

    @Test("emergency transport trust requires the explicit repair mutation")
    func emergencyTransportTrustRequiresExplicitRepair() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acceptedAt = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(
                authorized: true
            ),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { acceptedAt }
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("initial".utf8)
        )
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE devices SET trust_repair_required = 1 WHERE device_id = ?",
                arguments: [fixture.deviceID.rawBytes]
            )
        }
        let ticketID = UUID()
        try await installApprovedTicket(
            ticketID,
            for: fixture.deviceID,
            fixture: fixture,
            store: store
        )
        let repairedGrant = try fixture.grant(
            id: initial.grantID,
            epoch: initial.grantEpoch.next()
        )

        await #expect(throws: HarcHostError.emergencyTrustRepairRequired) {
            try await store.readoptDevice(
                repairedGrant,
                exactGrantBytes: Data("repaired".utf8),
                pairingTicketID: ticketID
            )
        }
        #expect(try await ticketState(ticketID, in: store) == .approved)
        #expect(try await store.registryRevision() == 1)

        try await store.repairTransportTrust(
            repairedGrant,
            exactGrantBytes: Data("repaired".utf8),
            pairingTicketID: ticketID
        )
        #expect(try await store.deviceRequiresTransportTrustRepair(
            deviceID: fixture.deviceID
        ) == false)
        #expect(try await store.registryRevision() == 2)
        #expect(try await ticketState(ticketID, in: store) == .consumed)
        #expect(
            try await store.deviceRegistryEntry(deviceID: fixture.deviceID)
                == DeviceRegistryEntry(activeGrant: repairedGrant)
        )
    }

    @Test("emergency transport-trust repair recovers across every journal crash boundary")
    func emergencyTransportTrustRepairCrashRecovery() async throws {
        for point in SecurityRegistryFailurePoint.allCases {
            let fixture = HostTestFixture()
            let directory = try fixture.temporaryDirectory(
                "trust-repair-\(point.rawValue)-\(UUID())"
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let databaseURL = directory.appendingPathComponent("HarcHost.db")
            let stagingRoot = directory.appendingPathComponent(
                "staging",
                isDirectory: true
            )
            let highWater = InMemorySecurityRegistryHighWaterMarkStore()
            let initial = try fixture.grant()
            let repairedGrant = try fixture.grant(
                id: initial.grantID,
                epoch: initial.grantEpoch.next()
            )
            let ticketID = UUID()
            let acceptedAt = fixture.beganAt.addingTimeInterval(10)

            do {
                let setup = try await HarcHostStore.onDisk(
                    databaseURL: databaseURL,
                    stagingRoot: stagingRoot,
                    metadata: fixture.metadata,
                    highWaterMarkStore: highWater,
                    capacityProvider: FixedHostVolumeCapacityProvider(),
                    now: { acceptedAt }
                )
                try await setup.seedDeviceGrantForTesting(
                    initial,
                    exactGrantBytes: Data("initial".utf8)
                )
                try await setup.dbQueue.write { db in
                    try db.execute(
                        sql: """
                            UPDATE devices
                            SET trust_repair_required = 1
                            WHERE device_id = ?
                            """,
                        arguments: [fixture.deviceID.rawBytes]
                    )
                }
                try await installApprovedTicket(
                    ticketID,
                    for: fixture.deviceID,
                    fixture: fixture,
                    store: setup
                )
            }

            do {
                let crashing = try await HarcHostStore.onDisk(
                    databaseURL: databaseURL,
                    stagingRoot: stagingRoot,
                    metadata: fixture.metadata,
                    highWaterMarkStore: highWater,
                    localOSAuthenticationBoundary:
                        FixedHostLocalOSAuthenticationBoundary(authorized: true),
                    securityFailureInjector: OneShotSecurityFailureInjector(point),
                    capacityProvider: FixedHostVolumeCapacityProvider(),
                    now: { acceptedAt }
                )
                await #expect(throws: InjectedHostCrash.security(point)) {
                    try await crashing.repairTransportTrust(
                        repairedGrant,
                        exactGrantBytes: Data("repaired".utf8),
                        pairingTicketID: ticketID
                    )
                }
            }

            let reopenTime = point == .beforePendingMutation
                ? acceptedAt
                : fixture.beganAt.addingTimeInterval(121)
            let repaired = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                localOSAuthenticationBoundary: FixedHostLocalOSAuthenticationBoundary(
                    authorized: point == .beforePendingMutation
                ),
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: { reopenTime }
            )
            if point == .beforePendingMutation {
                try await repaired.repairTransportTrust(
                    repairedGrant,
                    exactGrantBytes: Data("repaired".utf8),
                    pairingTicketID: ticketID
                )
            }
            #expect(try await repaired.registryRevision() == 2)
            #expect(await highWater.loadRegistryRevision() == 2)
            #expect(try await repaired.deviceRequiresTransportTrustRepair(
                deviceID: fixture.deviceID
            ) == false)
            #expect(
                try await repaired.deviceRegistryEntry(deviceID: fixture.deviceID)
                    == DeviceRegistryEntry(activeGrant: repairedGrant)
            )
            #expect(try await ticketState(ticketID, in: repaired) == .consumed)
        }
    }

    @Test("public pairing admission uses host time and rejects future or expired tickets")
    func publicPairingAdmissionUsesHostClock() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialTime = fixture.beganAt.addingTimeInterval(1)
        let clock = LockedHostClock(initialTime)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )

        let futureTicket = try PairingTicketPlaceholder(
            ticketID: UUID(),
            ticketSecretBindingSHA256: Data(repeating: 0xF2, count: 32),
            issuedAt: initialTime.addingTimeInterval(1),
            expiresAt: initialTime.addingTimeInterval(121)
        )
        await #expect(throws: HarcHostError.invalidPairingTransition) {
            try await store.insertPairingTicketPlaceholder(futureTicket)
        }

        let ticketID = UUID()
        let expiresAt = fixture.beganAt.addingTimeInterval(120)
        try await store.insertPairingTicketPlaceholder(
            PairingTicketPlaceholder(
                ticketID: ticketID,
                ticketSecretBindingSHA256: Data(repeating: 0xF3, count: 32),
                issuedAt: fixture.beganAt,
                expiresAt: expiresAt
            )
        )
        clock.set(expiresAt)
        await #expect(throws: HarcHostError.invalidPairingTransition) {
            try await store.reservePairingTicket(
                ticketID: ticketID,
                for: fixture.deviceID
            )
        }
        #expect(try await ticketState(ticketID, in: store) == .expired)
    }

    @Test("pairing-ticket decoding cannot bypass digest and validity validation")
    func pairingTicketDecodingValidatesInvariants() throws {
        let fixture = HostTestFixture()
        let ticket = try PairingTicketPlaceholder(
            ticketID: UUID(),
            ticketSecretBindingSHA256: Data(repeating: 0xF4, count: 32),
            issuedAt: fixture.beganAt,
            expiresAt: fixture.beganAt.addingTimeInterval(120)
        )
        let encoded = try JSONEncoder().encode(ticket)
        #expect(try JSONDecoder().decode(PairingTicketPlaceholder.self, from: encoded) == ticket)

        var malformedDigest = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        malformedDigest["ticketSecretBindingSHA256"] = Data([0x01]).base64EncodedString()
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                PairingTicketPlaceholder.self,
                from: JSONSerialization.data(withJSONObject: malformedDigest)
            )
        }

        var invalidValidity = malformedDigest
        invalidValidity["ticketSecretBindingSHA256"] = Data(repeating: 0xF4, count: 32).base64EncodedString()
        invalidValidity["expiresAt"] = invalidValidity["issuedAt"]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                PairingTicketPlaceholder.self,
                from: JSONSerialization.data(withJSONObject: invalidValidity)
            )
        }
    }

    private func installApprovedTicket(
        _ ticketID: UUID,
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind = .mobile,
        fixture: HostTestFixture,
        store: HarcHostStore
    ) async throws {
        try await store.insertPairingTicketPlaceholder(
            PairingTicketPlaceholder(
                ticketID: ticketID,
                ticketSecretBindingSHA256: Data(repeating: 0xF1, count: 32),
                clientKind: clientKind,
                issuedAt: fixture.beganAt,
                expiresAt: fixture.beganAt.addingTimeInterval(120)
            )
        )
        try await store.reservePairingTicket(
            ticketID: ticketID,
            for: deviceID,
            at: fixture.beganAt.addingTimeInterval(1)
        )
        try await store.transitionPairingTicket(
            ticketID: ticketID,
            to: .approved,
            at: fixture.beganAt.addingTimeInterval(2)
        )
    }

    private func ticketState(
        _ ticketID: UUID,
        in store: HarcHostStore
    ) async throws -> PairingTicketState? {
        try await store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            ).flatMap(PairingTicketState.init(rawValue:))
        }
    }

    private func insertSessionToken(
        _ tokenID: UUID,
        grant: DeviceGrantClaims,
        issuedAt: Date,
        store: HarcHostStore
    ) async throws {
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session_tokens (
                        token_id, token_binding_sha256, device_id, grant_id,
                        grant_epoch, tls_spki_sha256, exact_capabilities_bytes,
                        capabilities_sha256, protocol_major, protocol_minor,
                        selected_codec, selected_container, issued_at, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0, 'opus', 'ogg', ?, ?)
                    """,
                arguments: [
                    tokenID.uuidString.lowercased(),
                    Data(repeating: 0xA1, count: 32),
                    grant.deviceID.rawBytes,
                    grant.grantID.description,
                    Int64(grant.grantEpoch.rawValue),
                    Data(repeating: 0xA2, count: 32),
                    Data([0x01]),
                    Data(repeating: 0xA3, count: 32),
                    HarcHostStore.unixTime(issuedAt),
                    HarcHostStore.unixTime(
                        issuedAt.addingTimeInterval(10 * 60)
                    ),
                ]
            )
        }
    }
}

private struct FixedHostLocalOSAuthenticationBoundary: HostLocalOSAuthenticationBoundary {
    let authorized: Bool

    func authorizeInitialGrantExpansion(
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind,
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool {
        authorized
    }

    func authorizeGrantScopeChange(
        for deviceID: DeviceID,
        currentScopes: [AuthorizationScope],
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool {
        authorized
    }

    func authorizeSameKeyReadoption(for deviceID: DeviceID) async throws -> Bool {
        authorized
    }
}
