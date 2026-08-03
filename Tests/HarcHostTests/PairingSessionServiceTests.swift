import CryptoKit
import Foundation
import GRDB
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

@Suite("Pairing claims and application sessions", .serialized)
struct PairingSessionServiceTests {
    @Test("pairing reserves once, stores only bindings, derives the golden SAS, and cancels mismatches")
    func pairingProofAndCancellation() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let service = try HarcPairingClaimService(
            store: store,
            protocolBoundary: pairingProtocolBoundary()
        )
        let scopes = ScopePolicy.minimalScopes(for: .mobile)
        let begun = try await beginPairing(
            service: service,
            store: store,
            fixture: fixture,
            clock: clock,
            label: "Work iPhone",
            scopes: scopes
        )

        let persistence = try await store.dbQueue.read { db -> (Data, Data, Int) in
            let ticketBinding = try #require(try Data.fetchOne(
                db,
                sql: "SELECT ticket_secret_binding_sha256 FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [begun.ticketID.uuidString.lowercased()]
            ))
            let tokenBinding = try #require(try Data.fetchOne(
                db,
                sql: "SELECT claimant_token_binding_sha256 FROM pairing_attempts WHERE claim_id = ?",
                arguments: [begun.response.claimID.uuidString.lowercased()]
            ))
            let attempts = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pairing_attempts WHERE ticket_id = ?",
                arguments: [begun.ticketID.uuidString.lowercased()]
            ) ?? 0
            return (ticketBinding, tokenBinding, attempts)
        }
        #expect(persistence.0.count == 32)
        #expect(persistence.0 != begun.ticketSecret)
        #expect(persistence.1.count == 32)
        #expect(persistence.1 != begun.response.claimantToken)
        #expect(persistence.2 == 1)

        let transcript = try pairingTranscript(for: begun, fixture: fixture)
        let signature = try transcript.signClientProof(using: fixture.deviceKey)
        await #expect(throws: HarcHostError.pairingProofRejected) {
            _ = try await service.provePairingClaim(
                ProveHostPairingClaimRequest(
                    claimID: begun.response.claimID,
                    claimantToken: Data(repeating: 0xFE, count: 32),
                    clientSignature: signature
                )
            )
        }
        #expect(
            try await service.pairingStatus(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken
            ) == .pending
        )

        let otherKey = SoftwareP256SigningKey()
        let competing = try BeginHostPairingClaimRequest(
            ticketID: begun.ticketID,
            ticketSecret: begun.ticketSecret,
            clientNonce: Data(repeating: 0x91, count: 32),
            devicePublicKey: otherKey.publicKey,
            requestedScopes: scopes,
            deviceLabel: "Other phone",
            source: try source(0x31),
            context: try pairingContext(fixture: fixture)
        )
        await #expect(throws: HarcHostError.pairingClaimRejected) {
            _ = try await service.beginPairingClaim(competing)
        }
        let attemptCount = try await store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pairing_attempts WHERE ticket_id = ?",
                arguments: [begun.ticketID.uuidString.lowercased()]
            ) ?? 0
        }
        #expect(attemptCount == 1)

        let proof = try await service.provePairingClaim(
            ProveHostPairingClaimRequest(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken,
                clientSignature: signature
            )
        )
        let expectedPhrase = try HarcSASDictionaryV1.bundled().phrase(
            for: transcript,
            clientSignature: signature
        )
        #expect(proof.sasDigest == expectedPhrase.digest)
        #expect(proof.sasWordIndexes == expectedPhrase.indexes.map(UInt16.init))
        #expect(proof.sasWords == expectedPhrase.words)
        await #expect(throws: HarcHostError.pairingProofRejected) {
            _ = try await service.provePairingClaim(
                ProveHostPairingClaimRequest(
                    claimID: begun.response.claimID,
                    claimantToken: begun.response.claimantToken,
                    clientSignature: signature
                )
            )
        }
        #expect(
            try await service.pairingStatus(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken
            ) == .pending
        )

        await #expect(throws: DatabaseError.self) {
            try await store.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE pairing_attempts SET sas_digest = ? WHERE claim_id = ?",
                    arguments: [
                        Data(repeating: 0xFF, count: 32),
                        begun.response.claimID.uuidString.lowercased(),
                    ]
                )
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await store.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE pairing_attempts SET protocol_state_version = 0 WHERE claim_id = ?",
                    arguments: [begun.response.claimID.uuidString.lowercased()]
                )
            }
        }

        let mismatched = try await beginPairing(
            service: service,
            store: store,
            fixture: fixture,
            clock: clock,
            label: "Travel iPhone",
            scopes: scopes,
            sourceByte: 0x32
        )
        let mismatchedTranscript = try pairingTranscript(for: mismatched, fixture: fixture)
        let mismatchedSignature = try otherKey.sign(
            digest: mismatchedTranscript.clientProofDigest()
        )
        await #expect(throws: HarcHostError.pairingProofRejected) {
            _ = try await service.provePairingClaim(
                ProveHostPairingClaimRequest(
                    claimID: mismatched.response.claimID,
                    claimantToken: mismatched.response.claimantToken,
                    clientSignature: mismatchedSignature
                )
            )
        }
        #expect(
            try await service.pairingStatus(
                claimID: mismatched.response.claimID,
                claimantToken: mismatched.response.claimantToken
            ) == .cancelled
        )
        let cancelledTicket = try await ticketState(mismatched.ticketID, store: store)
        #expect(cancelledTicket == .cancelled)
    }

    @Test("a stale bad proof cannot cancel a concurrently approved claim")
    func staleBadProofCannotCancelApproval() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let interlock = SuspendingAuthenticationHook()
        let service = try HarcPairingClaimService(
            store: store,
            protocolBoundary: pairingProtocolBoundary(),
            beforeProofFailureTermination: {
                await interlock.suspend()
            }
        )
        let scopes = ScopePolicy.minimalScopes(for: .mobile)
        let begun = try await beginPairing(
            service: service,
            store: store,
            fixture: fixture,
            clock: clock,
            label: "Race iPhone",
            scopes: scopes
        )
        let transcript = try pairingTranscript(for: begun, fixture: fixture)
        let validSignature = try transcript.signClientProof(using: fixture.deviceKey)
        let staleSignature = try SoftwareP256SigningKey().sign(
            digest: transcript.clientProofDigest()
        )

        let staleProof = Task {
            try await service.provePairingClaim(
                ProveHostPairingClaimRequest(
                    claimID: begun.response.claimID,
                    claimantToken: begun.response.claimantToken,
                    clientSignature: staleSignature
                )
            )
        }
        await interlock.waitUntilSuspended()

        _ = try await service.provePairingClaim(
            ProveHostPairingClaimRequest(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken,
                clientSignature: validSignature
            )
        )
        let issued = try await HarcLocalPairingApprovalService(
            store: store,
            issuer: TestPairingIssuer()
        ).approve(begun.response.claimID)

        await interlock.release()
        await #expect(throws: HarcHostError.pairingProofRejected) {
            _ = try await staleProof.value
        }
        #expect(
            try await service.pairingStatus(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken
            ) == .approved(exactGrantBytes: issued.exactSignedGrantBytes)
        )
        #expect(try await ticketState(begun.ticketID, store: store) == .consumed)
    }

    @Test("a durable approved grant remains deliverable after claim expiry")
    func approvedGrantRemainsDeliverableAfterExpiry() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let service = try HarcPairingClaimService(
            store: store,
            protocolBoundary: pairingProtocolBoundary()
        )
        let begun = try await beginPairing(
            service: service,
            store: store,
            fixture: fixture,
            clock: clock,
            label: "Durable iPhone",
            scopes: ScopePolicy.minimalScopes(for: .mobile)
        )
        let transcript = try pairingTranscript(for: begun, fixture: fixture)
        _ = try await service.provePairingClaim(
            ProveHostPairingClaimRequest(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken,
                clientSignature: try transcript.signClientProof(using: fixture.deviceKey)
            )
        )
        let issued = try await HarcLocalPairingApprovalService(
            store: store,
            issuer: TestPairingIssuer()
        ).approve(begun.response.claimID)

        clock.set(begun.response.expiresAt)
        #expect(
            try await service.pairingStatus(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken
            ) == .approved(exactGrantBytes: issued.exactSignedGrantBytes)
        )
    }

    @Test("approval narrows scopes and crash recovery atomically publishes grant and label")
    func approvalCrashRecoveryAndRetention() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let requested: [AuthorizationScope] = [
            .libraryMetadataRead,
            .recordingReadOwn,
            .recordingUploadOwn,
        ].sorted()
        let granted: [AuthorizationScope] = [.recordingUploadOwn]
        let expectedGrantBytes = TestPairingIssuer.exactGrantBytes(
            epoch: .initial,
            scopes: granted
        )
        let begun: BegunPairing

        do {
            let crashing = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                securityFailureInjector: OneShotSecurityFailureInjector(.afterHighWaterAdvance),
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: clock.read
            )
            let claims = try HarcPairingClaimService(
                store: crashing,
                protocolBoundary: pairingProtocolBoundary()
            )
            begun = try await beginPairing(
                service: claims,
                store: crashing,
                fixture: fixture,
                clock: clock,
                label: "Jordan’s iPhone",
                scopes: requested
            )
            let transcript = try pairingTranscript(for: begun, fixture: fixture)
            _ = try await claims.provePairingClaim(
                ProveHostPairingClaimRequest(
                    claimID: begun.response.claimID,
                    claimantToken: begun.response.claimantToken,
                    clientSignature: try transcript.signClientProof(using: fixture.deviceKey)
                )
            )
            let approval = HarcLocalPairingApprovalService(
                store: crashing,
                issuer: TestPairingIssuer()
            )
            await #expect(throws: HarcHostError.pairingGrantMismatch) {
                _ = try await approval.approve(
                    begun.response.claimID,
                    grantedScopes: [.libraryAudioRead]
                )
            }
            await #expect(throws: InjectedHostCrash.security(.afterHighWaterAdvance)) {
                _ = try await approval.approve(
                    begun.response.claimID,
                    grantedScopes: granted
                )
            }
            let beforeRepair = try await crashing.dbQueue.read { db -> (Int, String, String?) in
                let devices = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM devices") ?? 0
                let attempt = try #require(try String.fetchOne(
                    db,
                    sql: "SELECT state FROM pairing_attempts WHERE claim_id = ?",
                    arguments: [begun.response.claimID.uuidString.lowercased()]
                ))
                let label = try String.fetchOne(
                    db,
                    sql: "SELECT label FROM devices WHERE device_id = ?",
                    arguments: [fixture.deviceID.rawBytes]
                )
                return (devices, attempt, label)
            }
            #expect(beforeRepair.0 == 0)
            #expect(beforeRepair.1 == PairingAttemptState.awaitingApproval.rawValue)
            #expect(beforeRepair.2 == nil)
        }

        let repaired = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let claims = try HarcPairingClaimService(
            store: repaired,
            protocolBoundary: pairingProtocolBoundary()
        )
        #expect(
            try await claims.pairingStatus(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken
            ) == .approved(exactGrantBytes: expectedGrantBytes)
        )
        let repairedState = try await repaired.dbQueue.read { db -> (String?, Data, Data) in
            let label = try String.fetchOne(
                db,
                sql: "SELECT label FROM devices WHERE device_id = ?",
                arguments: [fixture.deviceID.rawBytes]
            )
            let scopes = try #require(try Data.fetchOne(
                db,
                sql: "SELECT scopes_json FROM devices WHERE device_id = ?",
                arguments: [fixture.deviceID.rawBytes]
            ))
            let exactGrant = try #require(try Data.fetchOne(
                db,
                sql: "SELECT exact_grant_bytes FROM grants WHERE is_current = 1"
            ))
            return (label, scopes, exactGrant)
        }
        #expect(repairedState.0 == "Jordan’s iPhone")
        #expect(
            try HarcHostStore.decode([AuthorizationScope].self, from: repairedState.1)
                == granted
        )
        #expect(repairedState.2 == expectedGrantBytes)
        #expect(try await repaired.registryRevision() == 1)
        #expect(await highWater.loadRegistryRevision() == 1)

        await #expect(throws: DatabaseError.self) {
            try await repaired.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE pairing_attempts SET exact_grant_bytes = ? WHERE claim_id = ?",
                    arguments: [
                        Data("replacement".utf8),
                        begun.response.claimID.uuidString.lowercased(),
                    ]
                )
            }
        }

        let terminalAt = clock.read()
        let sessions = HarcSessionService(
            store: repaired,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        )
        clock.set(terminalAt.addingTimeInterval(
            HostAuthenticationRetention.terminalRowLifetime - 1
        ))
        try await sessions.pruneAuthenticationState()
        #expect(try await pairingAttemptCount(store: repaired) == 1)
        clock.set(terminalAt.addingTimeInterval(
            HostAuthenticationRetention.terminalRowLifetime
        ))
        try await sessions.pruneAuthenticationState()
        #expect(try await pairingAttemptCount(store: repaired) == 0)
        #expect(try await ticketCount(store: repaired) == 0)
        #expect(try await repaired.deviceRegistryEntry(deviceID: fixture.deviceID) != nil)
    }

    @Test("same-key readoption replaces the label, advances the epoch, and invalidates sessions")
    func readoptionLabelAndSessionInvalidation() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            localOSAuthenticationBoundary: AllowingHostLocalOSAuthenticationBoundary(),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("initial-grant".utf8)
        )
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE devices SET label = 'Old Mac' WHERE device_id = ?",
                arguments: [fixture.deviceID.rawBytes]
            )
        }

        let sessionService = HarcSessionService(
            store: store,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        )
        let session = try await openSession(
            service: sessionService,
            fixture: fixture,
            grant: initial
        )
        let pairing = try HarcPairingClaimService(
            store: store,
            protocolBoundary: pairingProtocolBoundary()
        )
        let begun = try await beginPairing(
            service: pairing,
            store: store,
            fixture: fixture,
            clock: clock,
            label: "Work MacBook",
            scopes: ScopePolicy.minimalScopes(for: .mobile)
        )
        let transcript = try pairingTranscript(for: begun, fixture: fixture)
        _ = try await pairing.provePairingClaim(
            ProveHostPairingClaimRequest(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken,
                clientSignature: try transcript.signClientProof(using: fixture.deviceKey)
            )
        )
        let approval = HarcLocalPairingApprovalService(
            store: store,
            issuer: TestPairingIssuer()
        )
        let issued = try await approval.approve(begun.response.claimID)
        #expect(issued.claims.grantID == initial.grantID)
        #expect(issued.claims.grantEpoch == (try initial.grantEpoch.next()))
        let current = try #require(
            try await store.deviceRegistryEntry(deviceID: fixture.deviceID)
        )
        #expect(current.currentGrantID == initial.grantID)
        #expect(current.currentGrantEpoch == (try initial.grantEpoch.next()))
        let label = try await store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT label FROM devices WHERE device_id = ?",
                arguments: [fixture.deviceID.rawBytes]
            )
        }
        #expect(label == "Work MacBook")
        await #expect(throws: HarcHostError.sessionCredentialRejected) {
            _ = try await sessionService.authenticate(
                credential: session.opened.credential,
                tlsSPKISHA256: session.tlsSPKISHA256
            )
        }
        let invalidation = try await store.dbQueue.read { db -> (Double?, String?) in
            guard let row = try Row.fetchOne(db, sql: "SELECT invalidated_at, invalidation_reason FROM session_tokens") else {
                return (nil, nil)
            }
            return (row["invalidated_at"] as Double?, row["invalidation_reason"] as String?)
        }
        #expect(invalidation.0 == HarcHostStore.unixTime(clock.read()))
        #expect(invalidation.1 == "readopted")
    }

    @Test("emergency trust repair blocks sessions and is visible in local pairing approval")
    func emergencyTrustRepairUsesVisiblePairingPath() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            localOSAuthenticationBoundary: AllowingHostLocalOSAuthenticationBoundary(),
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let initial = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            initial,
            exactGrantBytes: Data("initial-grant".utf8)
        )
        let sessions = HarcSessionService(
            store: store,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        )
        let existingSession = try await openSession(
            service: sessions,
            fixture: fixture,
            grant: initial
        )
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE devices
                    SET trust_repair_required = 1
                    WHERE device_id = ?
                    """,
                arguments: [fixture.deviceID.rawBytes]
            )
        }

        await #expect(throws: HarcHostError.sessionCredentialRejected) {
            _ = try await sessions.authenticate(
                credential: existingSession.opened.credential,
                tlsSPKISHA256: existingSession.tlsSPKISHA256
            )
        }
        let deniedBegin = try await sessions.beginSession(
            BeginHostSessionRequest(
                claimedDeviceID: fixture.deviceID,
                grantID: initial.grantID,
                source: try source(0x58),
                tlsSPKISHA256: tlsSPKISHA256
            )
        )
        let admitted = try await store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT is_admitted FROM session_challenges WHERE challenge_id = ?",
                arguments: [deniedBegin.challengeID.uuidString.lowercased()]
            )
        }
        #expect(admitted == 0)

        let pairing = try HarcPairingClaimService(
            store: store,
            protocolBoundary: pairingProtocolBoundary()
        )
        let begun = try await beginPairing(
            service: pairing,
            store: store,
            fixture: fixture,
            clock: clock,
            label: "Repaired Work MacBook",
            scopes: ScopePolicy.minimalScopes(for: .mobile),
            sourceByte: 0x59
        )
        let transcript = try pairingTranscript(for: begun, fixture: fixture)
        _ = try await pairing.provePairingClaim(
            ProveHostPairingClaimRequest(
                claimID: begun.response.claimID,
                claimantToken: begun.response.claimantToken,
                clientSignature: try transcript.signClientProof(using: fixture.deviceKey)
            )
        )
        let approval = HarcLocalPairingApprovalService(
            store: store,
            issuer: TestPairingIssuer()
        )
        let pending = try await approval.pendingClaim(begun.response.claimID)
        #expect(pending.requiresTransportTrustRepair)
        let repairedGrant = try await approval.approve(begun.response.claimID)
        #expect(repairedGrant.claims.grantEpoch == (try initial.grantEpoch.next()))
        #expect(try await store.deviceRequiresTransportTrustRepair(
            deviceID: fixture.deviceID
        ) == false)

        _ = try await openSession(
            service: sessions,
            fixture: fixture,
            grant: repairedGrant.claims
        )
    }

    @Test("session proof is single-use, persists only a token binding, and survives restart")
    func sessionLifecycleAndRestart() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let grant = try fixture.grant()
        let opened: OpenedSessionFixture

        do {
            let store = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: clock.read
            )
            try await store.seedDeviceGrantForTesting(
                grant,
                exactGrantBytes: Data("signed-grant".utf8)
            )
            let service = HarcSessionService(
                store: store,
                protocolBoundary: sessionProtocolBoundary(
                    capabilityPolicy: try sessionCapabilityPolicy()
                )
            )
            opened = try await openSession(
                service: service,
                fixture: fixture,
                grant: grant,
                inspectChallenge: { challengeID in
                    let challenge = try await store.dbQueue.read {
                        db -> (Data?, Data?, String?, String?, Int64, Int64) in
                        let row = try #require(try Row.fetchOne(
                            db,
                            sql: """
                                SELECT exact_capabilities_bytes,
                                       capabilities_sha256,
                                       selected_codec, selected_container,
                                       protocol_major, protocol_minor
                                FROM session_challenges
                                WHERE challenge_id = ?
                            """,
                            arguments: [challengeID.uuidString.lowercased()]
                        ))
                        return (
                            row["exact_capabilities_bytes"] as Data?,
                            row["capabilities_sha256"] as Data?,
                            row["selected_codec"] as String?,
                            row["selected_container"] as String?,
                            row["protocol_major"] as Int64,
                            row["protocol_minor"] as Int64
                        )
                    }
                    #expect(challenge.0 == nil)
                    #expect(challenge.1 == nil)
                    #expect(challenge.2 == nil)
                    #expect(challenge.3 == nil)
                    #expect(challenge.4 == 1)
                    #expect(challenge.5 == 0)
                    await #expect(throws: DatabaseError.self) {
                        try await store.dbQueue.write { db in
                            try db.execute(
                                sql: "UPDATE session_challenges SET server_nonce = ? WHERE challenge_id = ?",
                                arguments: [
                                    Data(repeating: 0xEE, count: 32),
                                    challengeID.uuidString.lowercased(),
                                ]
                            )
                        }
                    }
                }
            )
            let tokenPersistence = try await store.dbQueue.read { db -> (Data, Int) in
                let binding = try #require(try Data.fetchOne(
                    db,
                    sql: "SELECT token_binding_sha256 FROM session_tokens"
                ))
                let challenges = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_challenges"
                ) ?? 0
                return (binding, challenges)
            }
            #expect(tokenPersistence.0.count == 32)
            #expect(tokenPersistence.0 != Data(opened.opened.credential.suffix(32)))
            #expect(tokenPersistence.0 != opened.opened.credential)
            #expect(tokenPersistence.1 == 0)

            let authenticated = try await service.authenticate(
                credential: opened.opened.credential,
                tlsSPKISHA256: opened.tlsSPKISHA256,
                requiredScope: .recordingUploadOwn
            )
            #expect(authenticated.context.grantID == grant.grantID)
            #expect(authenticated.context.grantEpoch == grant.grantEpoch)
            #expect(authenticated.exactCapabilitiesBytes == opened.capabilities.exactBytes)
            #expect(authenticated.capabilitiesSHA256 == opened.capabilities.sha256)
            #expect(authenticated.selectedCodec == opened.capabilities.selectedCodec)
            #expect(authenticated.selectedContainer == opened.capabilities.selectedContainer)

            await #expect(throws: HarcHostError.sessionProofRejected) {
                _ = try await service.openSession(opened.openRequest)
            }
            await #expect(throws: HarcHostError.sessionProofRejected) {
                _ = try await service.openSession(opened.openRequest)
            }
            let audit = try await store.auditEvents(limit: 20).first {
                $0.code == "session-proof-rejected"
            }
            #expect(audit?.deviceID == nil)
            #expect(audit?.aggregateCount == 2)

            await #expect(throws: DatabaseError.self) {
                try await store.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE session_tokens SET selected_codec = 'flac'"
                    )
                }
            }
        }

        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let authenticated = try await HarcSessionService(
            store: reopened,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        ).authenticate(
            credential: opened.opened.credential,
            tlsSPKISHA256: opened.tlsSPKISHA256
        )
        #expect(authenticated.context.authenticatedDeviceID == fixture.deviceID)
    }

    @Test("OpenSession, not BeginSession, validates the exact negotiated capability payload")
    func openSessionOwnsCapabilityValidation() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { fixture.beganAt.addingTimeInterval(10) }
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("signed-grant".utf8)
        )
        let productionOnlyPolicy = try HarcCapabilityPolicyV1(
            compatibility: HarcProtobufCompatibilityPolicy(
                versionPolicy: .currentV1,
                supportedRequiredFeatures: ["transfer.chunk.v1"]
            ),
            supportedFeatureIDs: ["capture.gaps.v1", "transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.cafALAC]
        )
        let service = HarcSessionService(
            store: store,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: productionOnlyPolicy
            )
        )
        let begin = try await service.beginSession(
            BeginHostSessionRequest(
                claimedDeviceID: fixture.deviceID,
                grantID: grant.grantID,
                source: try source(0x54),
                tlsSPKISHA256: tlsSPKISHA256
            )
        )
        let capabilities = try sessionCapabilities()
        let clientNonce = Data(repeating: 0x55, count: 32)
        let transcript = try SessionTranscriptV1(
            protocolVersion: sessionProtocolVersion,
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            tlsSPKISHA256: tlsSPKISHA256,
            deviceID: fixture.deviceID,
            grantID: grant.grantID.rawValue,
            grantEpoch: grant.grantEpoch.rawValue,
            challengeID: begin.challengeID,
            serverNonce: begin.serverNonce,
            clientNonce: clientNonce,
            capabilitiesSHA256: capabilities.sha256
        )
        let request = try OpenHostSessionRequest(
            challengeID: begin.challengeID,
            clientNonce: clientNonce,
            exactCapabilitiesBytes: capabilities.exactBytes,
            capabilitiesSHA256: capabilities.sha256,
            clientSignature: transcript.signClientProof(using: fixture.deviceKey),
            tlsSPKISHA256: tlsSPKISHA256
        )

        await #expect(throws: HarcHostError.sessionProofRejected) {
            _ = try await service.openSession(request)
        }
        #expect(try await challengeCount(store: store) == 0)
        #expect(try await tokenCount(store: store) == 0)
    }

    @Test("session limits use device/source identity and challenges expire immediately")
    func sessionRateIdentityAndChallengeExpiry() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: clock.read
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("grant".utf8)
        )
        let service = HarcSessionService(
            store: store,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        )
        for _ in 0..<HarcSessionService.maximumOutstandingChallenges {
            _ = try await service.beginSession(
                BeginHostSessionRequest(
                    claimedDeviceID: fixture.deviceID,
                    grantID: .random(),
                    source: try source(0x61),
                    tlsSPKISHA256: tlsSPKISHA256
                )
            )
        }
        await #expect(throws: HarcHostError.sessionAdmissionRejected) {
            _ = try await service.beginSession(
                BeginHostSessionRequest(
                    claimedDeviceID: fixture.deviceID,
                    grantID: .random(),
                    source: try source(0x61),
                    tlsSPKISHA256: tlsSPKISHA256
                )
            )
        }
        #expect(try await challengeCount(store: store) == 5)
        clock.set(clock.read().addingTimeInterval(HarcSessionService.challengeLifetime))
        try await service.pruneAuthenticationState()
        #expect(try await challengeCount(store: store) == 0)
    }

    @Test("expired and revoked tokens fail immediately but remain for seven days")
    func sessionTerminalRetention() async throws {
        let fixture = HostTestFixture()

        let expiryDirectory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: expiryDirectory) }
        let expiryClock = LockedHostClock(fixture.beganAt.addingTimeInterval(10))
        let expiryStore = try await HarcHostStore.inMemory(
            stagingRoot: expiryDirectory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: expiryClock.read
        )
        let expiryGrant = try fixture.grant()
        try await expiryStore.seedDeviceGrantForTesting(
            expiryGrant,
            exactGrantBytes: Data("expiry-grant".utf8)
        )
        let expiryService = HarcSessionService(
            store: expiryStore,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        )
        let expiring = try await openSession(
            service: expiryService,
            fixture: fixture,
            grant: expiryGrant
        )
        expiryClock.set(expiring.opened.expiresAt)
        await #expect(throws: HarcHostError.sessionCredentialRejected) {
            _ = try await expiryService.authenticate(
                credential: expiring.opened.credential,
                tlsSPKISHA256: expiring.tlsSPKISHA256
            )
        }
        #expect(try await tokenCount(store: expiryStore) == 1)
        expiryClock.set(expiring.opened.expiresAt.addingTimeInterval(
            HostAuthenticationRetention.terminalRowLifetime - 1
        ))
        try await expiryService.pruneAuthenticationState()
        #expect(try await tokenCount(store: expiryStore) == 1)
        expiryClock.set(expiring.opened.expiresAt.addingTimeInterval(
            HostAuthenticationRetention.terminalRowLifetime
        ))
        try await expiryService.pruneAuthenticationState()
        #expect(try await tokenCount(store: expiryStore) == 0)

        let revokedFixture = HostTestFixture()
        let revokeDirectory = try revokedFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: revokeDirectory) }
        let revokeClock = LockedHostClock(revokedFixture.beganAt.addingTimeInterval(10))
        let revokeStore = try await HarcHostStore.inMemory(
            stagingRoot: revokeDirectory,
            metadata: revokedFixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: revokeClock.read
        )
        let revokeGrant = try revokedFixture.grant()
        try await revokeStore.seedDeviceGrantForTesting(
            revokeGrant,
            exactGrantBytes: Data("revoke-grant".utf8)
        )
        let revokeService = HarcSessionService(
            store: revokeStore,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        )
        let revoked = try await openSession(
            service: revokeService,
            fixture: revokedFixture,
            grant: revokeGrant
        )
        let revokedAt = revokeClock.read().addingTimeInterval(1)
        revokeClock.set(revokedAt)
        try await revokeStore.revokeDevice(
            revokedFixture.deviceID,
            revocationID: UUID(),
            reasonCode: "user.revoked",
            exactRevocationBytes: Data("revocation".utf8)
        )
        await #expect(throws: HarcHostError.sessionCredentialRejected) {
            _ = try await revokeService.authenticate(
                credential: revoked.opened.credential,
                tlsSPKISHA256: revoked.tlsSPKISHA256
            )
        }
        #expect(try await tokenCount(store: revokeStore) == 1)
        revokeClock.set(revokedAt.addingTimeInterval(
            HostAuthenticationRetention.terminalRowLifetime - 1
        ))
        try await revokeService.pruneAuthenticationState()
        #expect(try await tokenCount(store: revokeStore) == 1)
        revokeClock.set(revokedAt.addingTimeInterval(
            HostAuthenticationRetention.terminalRowLifetime
        ))
        try await revokeService.pruneAuthenticationState()
        #expect(try await tokenCount(store: revokeStore) == 0)
    }

    @Test("a corrupt current-grant join produces only a dummy challenge")
    func currentGrantJoinFailsClosed() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { fixture.beganAt.addingTimeInterval(10) }
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("real-current-grant".utf8)
        )
        let corruptGrantID = GrantID.random()
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE grants SET grant_id = ?, exact_grant_bytes = ? WHERE is_current = 1",
                arguments: [
                    corruptGrantID.description,
                    Data("corrupt-current-grant".utf8),
                ]
            )
        }
        let response = try await HarcSessionService(
            store: store,
            protocolBoundary: sessionProtocolBoundary(
                capabilityPolicy: try sessionCapabilityPolicy()
            )
        ).beginSession(
            BeginHostSessionRequest(
                claimedDeviceID: fixture.deviceID,
                grantID: grant.grantID,
                source: try source(0x71),
                tlsSPKISHA256: tlsSPKISHA256
            )
        )
        let admitted = try await store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT is_admitted FROM session_challenges WHERE challenge_id = ?",
                arguments: [response.challengeID.uuidString.lowercased()]
            )
        }
        #expect(admitted == 0)
        #expect(response.serverNonce.count == 32)
        #expect(response.exactSignedGrantBytes.count == 512)
        #expect(response.exactSignedGrantBytes != Data("corrupt-current-grant".utf8))
    }

    // MARK: - Pairing fixtures

    private func beginPairing(
        service: HarcPairingClaimService,
        store: HarcHostStore,
        fixture: HostTestFixture,
        clock: LockedHostClock,
        label: String,
        scopes: [AuthorizationScope],
        sourceByte: UInt8 = 0x30
    ) async throws -> BegunPairing {
        let ticketID = UUID()
        let ticketSecret = Data(repeating: UInt8(truncatingIfNeeded: ticketID.hashValue), count: 24)
        let now = clock.read()
        try await store.insertPairingTicketPlaceholder(
            PairingTicketPlaceholder(
                ticketID: ticketID,
                ticketSecretBindingSHA256: try HostPairingSecretBinding.sha256(
                    ticketID: ticketID,
                    secret: ticketSecret,
                    using: pairingProtocolBoundary()
                ),
                issuedAt: now.addingTimeInterval(-1),
                expiresAt: now.addingTimeInterval(119)
            )
        )
        let clientNonce = Data(repeating: sourceByte &+ 1, count: 32)
        let context = try pairingContext(fixture: fixture)
        let response = try await service.beginPairingClaim(
            BeginHostPairingClaimRequest(
                ticketID: ticketID,
                ticketSecret: ticketSecret,
                clientNonce: clientNonce,
                devicePublicKey: fixture.deviceKey.publicKey,
                requestedScopes: scopes,
                deviceLabel: label,
                source: try source(sourceByte),
                context: context
            )
        )
        return BegunPairing(
            ticketID: ticketID,
            ticketSecret: ticketSecret,
            clientNonce: clientNonce,
            scopes: scopes,
            context: context,
            response: response
        )
    }

    private func pairingTranscript(
        for begun: BegunPairing,
        fixture: HostTestFixture
    ) throws -> PairingTranscriptV1 {
        try PairingTranscriptV1(
            protocolVersion: HarcProtocolVersion(
                major: begun.context.protocolMajor,
                minor: begun.context.protocolMinor
            ),
            ticketID: begun.ticketID,
            claimID: begun.response.claimID,
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: fixture.hostKey.publicKey,
            tlsSPKISHA256: begun.context.tlsSPKISHA256,
            deviceID: fixture.deviceID,
            devicePublicKey: fixture.deviceKey.publicKey,
            clientNonce: begun.clientNonce,
            hostNonce: begun.response.hostNonce,
            ticketSecretBindingSHA256: try HostPairingSecretBinding.sha256(
                ticketID: begun.ticketID,
                secret: begun.ticketSecret,
                using: pairingProtocolBoundary()
            ),
            requestedScopes: begun.scopes
        )
    }

    private func pairingContext(
        fixture: HostTestFixture
    ) throws -> HostPairingClaimContext {
        try HostPairingClaimContext(
            hostAuthorityPublicKey: fixture.hostKey.publicKey,
            tlsSPKISHA256: tlsSPKISHA256
        )
    }

    // MARK: - Session fixtures

    private func openSession(
        service: HarcSessionService,
        fixture: HostTestFixture,
        grant: DeviceGrantClaims,
        inspectChallenge: ((UUID) async throws -> Void)? = nil
    ) async throws -> OpenedSessionFixture {
        let capabilities = try sessionCapabilities()
        let begin = try await service.beginSession(
            BeginHostSessionRequest(
                claimedDeviceID: fixture.deviceID,
                grantID: grant.grantID,
                source: try source(0x50),
                tlsSPKISHA256: tlsSPKISHA256
            )
        )
        try await inspectChallenge?(begin.challengeID)
        let clientNonce = Data(repeating: 0x52, count: 32)
        let transcript = try SessionTranscriptV1(
            protocolVersion: HarcProtocolVersion(
                major: capabilities.protocolMajor,
                minor: capabilities.protocolMinor
            ),
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            tlsSPKISHA256: tlsSPKISHA256,
            deviceID: fixture.deviceID,
            grantID: grant.grantID.rawValue,
            grantEpoch: grant.grantEpoch.rawValue,
            challengeID: begin.challengeID,
            serverNonce: begin.serverNonce,
            clientNonce: clientNonce,
            capabilitiesSHA256: capabilities.sha256
        )
        let request = try OpenHostSessionRequest(
            challengeID: begin.challengeID,
            clientNonce: clientNonce,
            exactCapabilitiesBytes: capabilities.exactBytes,
            capabilitiesSHA256: capabilities.sha256,
            clientSignature: transcript.signClientProof(using: fixture.deviceKey),
            tlsSPKISHA256: tlsSPKISHA256
        )
        return OpenedSessionFixture(
            opened: try await service.openSession(request),
            openRequest: request,
            capabilities: capabilities,
            tlsSPKISHA256: tlsSPKISHA256
        )
    }

    private func sessionCapabilities() throws -> HostNegotiatedSessionCapabilities {
        let exactBytes = try #require(Data(
            base64Encoded: "ChcIARoTChF0cmFuc2Zlci5jaHVuay52MRIPY2FwdHVyZS5nYXBzLnYxEhF0cmFuc2Zlci5jaHVuay52MRoYaGFyYy5jaHVuay1kZXNjcmlwdG9yLnYxIgQIAxADKgcIgH0QARgB"
        ))
        return try HostNegotiatedSessionCapabilities(
            exactBytes: exactBytes,
            protocolMinor: 0,
            selectedCodec: "raw-pcm-s16le-fixture",
            selectedContainer: "raw-pcm-fixture"
        )
    }

    private func sessionCapabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            compatibility: HarcProtobufCompatibilityPolicy(
                versionPolicy: .currentV1,
                supportedRequiredFeatures: ["transfer.chunk.v1"]
            ),
            supportedFeatureIDs: ["capture.gaps.v1", "transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
    }

    private func pairingProtocolBoundary() throws -> TestPairingProtocolBoundary {
        try TestPairingProtocolBoundary()
    }

    private func sessionProtocolBoundary(
        capabilityPolicy: HarcCapabilityPolicyV1
    ) -> TestSessionProtocolBoundary {
        TestSessionProtocolBoundary(capabilityPolicy: capabilityPolicy)
    }

    private func source(_ byte: UInt8) throws -> HostPreauthenticationSource {
        try HostPreauthenticationSource(
            bindingSHA256: Data(repeating: byte, count: 32)
        )
    }

    private var tlsSPKISHA256: Data { Data(repeating: 0x44, count: 32) }
    private var sessionProtocolVersion: HarcProtocolVersion {
        HarcProtocolVersion(major: 1, minor: 0)
    }

    // MARK: - Durable assertions

    private func ticketState(
        _ ticketID: UUID,
        store: HarcHostStore
    ) async throws -> PairingTicketState? {
        try await store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [ticketID.uuidString.lowercased()]
            ).flatMap(PairingTicketState.init(rawValue:))
        }
    }

    private func pairingAttemptCount(store: HarcHostStore) async throws -> Int {
        try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pairing_attempts") ?? 0
        }
    }

    private func ticketCount(store: HarcHostStore) async throws -> Int {
        try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pairing_tickets") ?? 0
        }
    }

    private func challengeCount(store: HarcHostStore) async throws -> Int {
        try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_challenges") ?? 0
        }
    }

    private func tokenCount(store: HarcHostStore) async throws -> Int {
        try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_tokens") ?? 0
        }
    }
}

private struct TestPairingProtocolBoundary:
    HostPairingAuthenticationProtocolBoundary
{
    private let sasDictionary: HarcSASDictionaryV1

    init() throws {
        sasDictionary = try .bundled()
    }

    func pairingTicketSecretBindingSHA256(
        ticketID: UUID,
        secret: Data
    ) throws -> Data {
        try PairingTicketV1.ticketSecretBindingSHA256(
            ticketID: ticketID,
            secret: secret
        )
    }

    func validatePairingProofAndDeriveSAS(
        _ input: HostPairingProofValidationInput
    ) throws -> HostPairingProofResult {
        let transcript = try PairingTranscriptV1(
            protocolVersion: HarcProtocolVersion(
                major: input.protocolMajor,
                minor: input.protocolMinor
            ),
            ticketID: input.ticketID,
            claimID: input.claimID,
            libraryID: input.libraryID,
            hostAuthorityID: input.hostAuthorityID,
            hostAuthorityPublicKey: input.hostAuthorityPublicKey,
            tlsSPKISHA256: input.tlsSPKISHA256,
            deviceID: input.deviceID,
            devicePublicKey: input.devicePublicKey,
            clientNonce: input.clientNonce,
            hostNonce: input.hostNonce,
            ticketSecretBindingSHA256: input.ticketSecretBindingSHA256,
            requestedScopes: input.requestedScopes
        )
        try transcript.verifyClientProof(input.clientSignature)
        let phrase = try sasDictionary.phrase(
            for: transcript,
            clientSignature: input.clientSignature
        )
        return try HostPairingProofResult(
            sasDigest: phrase.digest,
            sasWordIndexes: phrase.indexes.map(UInt16.init),
            sasWords: phrase.words
        )
    }
}

private struct TestSessionProtocolBoundary:
    HostSessionAuthenticationProtocolBoundary
{
    let capabilityPolicy: HarcCapabilityPolicyV1

    func validateProtocolVersion(major: UInt16, minor: UInt16) throws {
        try capabilityPolicy.compatibility.versionPolicy.validate(
            HarcProtocolVersion(major: major, minor: minor)
        )
    }

    func validateNegotiatedCapabilities(
        exactBytes: Data,
        expectedSHA256: Data,
        protocolMajor: UInt16,
        protocolMinor: UInt16
    ) throws -> HostNegotiatedSessionCapabilities {
        let validated = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: exactBytes,
            expectedSHA256: expectedSHA256,
            policy: capabilityPolicy
        )
        guard validated.protocolVersion.major == protocolMajor,
              validated.protocolVersion.minor == protocolMinor else {
            throw HarcProtocolCodecError.headerPayloadMismatch(
                field: "negotiatedCapabilities.protocol"
            )
        }
        return try HostNegotiatedSessionCapabilities(
            exactBytes: validated.exactPayload.exactBytes,
            sha256: validated.exactSHA256,
            protocolMajor: validated.protocolVersion.major,
            protocolMinor: validated.protocolVersion.minor,
            selectedCodec: validated.encoding.codec.rawValue,
            selectedContainer: validated.encoding.container.rawValue
        )
    }

    func validateSessionProof(
        _ input: HostSessionProofValidationInput
    ) throws {
        let transcript = try SessionTranscriptV1(
            protocolVersion: HarcProtocolVersion(
                major: input.protocolMajor,
                minor: input.protocolMinor
            ),
            libraryID: input.libraryID,
            hostAuthorityID: input.hostAuthorityID,
            tlsSPKISHA256: input.tlsSPKISHA256,
            deviceID: input.deviceID,
            grantID: input.grantID.rawValue,
            grantEpoch: input.grantEpoch.rawValue,
            challengeID: input.challengeID,
            serverNonce: input.serverNonce,
            clientNonce: input.clientNonce,
            capabilitiesSHA256: input.capabilitiesSHA256
        )
        try transcript.verifyClientProof(
            input.clientSignature,
            using: input.devicePublicKey
        )
    }
}

private struct BegunPairing {
    let ticketID: UUID
    let ticketSecret: Data
    let clientNonce: Data
    let scopes: [AuthorizationScope]
    let context: HostPairingClaimContext
    let response: BeginHostPairingClaimResponse
}

private actor SuspendingAuthenticationHook {
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !reached else { return }
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilSuspended() async {
        if reached { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct OpenedSessionFixture {
    let opened: HostOpenedSession
    let openRequest: OpenHostSessionRequest
    let capabilities: HostNegotiatedSessionCapabilities
    let tlsSPKISHA256: Data
}

private struct TestPairingIssuer: HostPairingGrantIssuingBoundary {
    func issueGrant(
        for request: HostPairingGrantIssuanceRequest
    ) async throws -> HostPairingIssuedGrant {
        let epoch: GrantEpoch
        let grantID: GrantID
        if let existing = request.existingEntry {
            epoch = try existing.currentGrantEpoch.next()
            grantID = existing.status == .active
                ? existing.currentGrantID
                : .random()
        } else {
            epoch = .initial
            grantID = .random()
        }
        let claims = try DeviceGrantClaims(
            libraryID: request.libraryID,
            hostAuthorityID: request.hostAuthorityID,
            grantID: grantID,
            devicePublicKey: request.devicePublicKey,
            scopes: Set(request.approvedScopes),
            grantEpoch: epoch,
            issuedAt: request.approvedAt,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        return try HostPairingIssuedGrant(
            claims: claims,
            exactSignedGrantBytes: Self.exactGrantBytes(
                epoch: epoch,
                scopes: request.approvedScopes
            )
        )
    }

    static func exactGrantBytes(
        epoch: GrantEpoch,
        scopes: [AuthorizationScope]
    ) -> Data {
        Data(
            "test-grant-v\(epoch.rawValue):\(scopes.map(\.rawValue).joined(separator: ","))"
                .utf8
        )
    }
}

private struct AllowingHostLocalOSAuthenticationBoundary:
    HostLocalOSAuthenticationBoundary {
    func authorizeInitialGrantExpansion(
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind,
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool { true }

    func authorizeGrantScopeChange(
        for deviceID: DeviceID,
        currentScopes: [AuthorizationScope],
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool { true }

    func authorizeSameKeyReadoption(
        for deviceID: DeviceID
    ) async throws -> Bool { true }
}
