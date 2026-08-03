import Foundation
import GRDB
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity
import HarcTransfer

@Suite("HarcHost authorization and operation replay")
struct AuthorizationReplayTests {
    @Test("authorization is derived from the authenticated context, scope, owner, and live epoch")
    func authenticatedContextIsAuthoritative() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("grant".utf8))
        let context = fixture.context(for: grant)

        _ = try await HostAuthorizer(store: store).authorize(
            context,
            requiredScope: .recordingUploadOwn,
            objectOwner: fixture.deviceID,
            at: fixture.beganAt.addingTimeInterval(1)
        )
        await #expect(throws: HarcHostError.objectOwnershipMismatch) {
            _ = try await store.authorize(
                context,
                requiredScope: .recordingUploadOwn,
                objectOwner: SoftwareP256SigningKey().publicKey.deviceID,
                at: fixture.beganAt.addingTimeInterval(1)
            )
        }
        await #expect(throws: HarcHostError.missingScope(.libraryMetadataWrite)) {
            _ = try await store.authorize(
                context,
                requiredScope: .libraryMetadataWrite,
                at: fixture.beganAt.addingTimeInterval(1)
            )
        }
        let stale = AuthenticatedDeviceContext(
            libraryID: context.libraryID,
            hostAuthorityID: context.hostAuthorityID,
            authenticatedDeviceID: context.authenticatedDeviceID,
            grantID: context.grantID,
            grantEpoch: try GrantEpoch(2)
        )
        await #expect(throws: HarcHostError.grantMismatch) {
            _ = try await store.authorize(
                stale,
                requiredScope: .recordingUploadOwn,
                at: fixture.beganAt.addingTimeInterval(1)
            )
        }
    }

    @Test("public authorization and upload admission use the current host clock")
    func publicAuthorizationAndUploadAdmissionUseHostClock() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialTime = fixture.beganAt.addingTimeInterval(1)
        let expiry = fixture.beganAt.addingTimeInterval(5)
        let clock = LockedHostClock(initialTime)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let grant = try fixture.grant(expiresAt: expiry)
        try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("clock-grant".utf8))
        let context = fixture.context(for: grant)

        clock.set(expiry)

        await #expect(throws: HarcHostError.grantExpired) {
            _ = try await HostAuthorizer(store: store).authorize(
                context,
                requiredScope: .recordingUploadOwn,
                objectOwner: fixture.deviceID
            )
        }
        await #expect(throws: HarcHostError.grantExpired) {
            _ = try await store.beginUpload(
                context: context,
                request: BeginHostUploadRequest(
                    uploadID: .random(),
                    originRecordingID: OriginRecordingID(
                        deviceID: fixture.deviceID,
                        recordingUUID: UUID()
                    ),
                    frozenProfile: try fixture.profile(),
                    beganAt: initialTime
                )
            )
        }
    }

    @Test("package operation admission rejects commands expired at the current host clock")
    func packageOperationAdmissionUsesHostClock() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let issuedAt = fixture.beganAt.addingTimeInterval(1)
        let expiresAt = fixture.beganAt.addingTimeInterval(5)
        let clock = LockedHostClock(issuedAt)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("operation-clock-grant".utf8))
        let context = fixture.context(for: grant)
        clock.set(expiresAt)

        await #expect(throws: HarcHostError.commandExpired) {
            _ = try await store.checkAndApplyHostDatabaseOperation(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.host-clock.v1",
                operationID: .random(),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: Data("expired-command".utf8)
            ) { _ in Data("must-not-apply".utf8) }
        }
        await #expect(throws: HarcHostError.commandExpired) {
            _ = try await store.prepareExternalOperationEffect(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.host-clock-prepared.v1",
                operationID: .random(),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: Data("expired-prepared-command".utf8),
                preparedEffect: Data("must-not-prepare".utf8)
            )
        }
        let operationCount = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processed_operations")
        }
        #expect(operationCount == 0)
    }

    @Test("replay-key decoding cannot bypass message and operation identity validation")
    func replayKeyDecodingValidatesInvariants() throws {
        let fixture = HostTestFixture()
        let key = try HostOperationReplayKey(
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            messageType: "transfer.valid.v1",
            signer: .device(fixture.deviceID),
            operationID: .random()
        )
        let encoded = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(HostOperationReplayKey.self, from: encoded) == key)

        var malformedMessage = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        malformedMessage["messageType"] = "Transfer/Invalid"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                HostOperationReplayKey.self,
                from: JSONSerialization.data(withJSONObject: malformedMessage)
            )
        }

        var zeroOperation = malformedMessage
        zeroOperation["messageType"] = "transfer.valid.v1"
        zeroOperation["operationID"] = "00000000-0000-0000-0000-000000000000"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                HostOperationReplayKey.self,
                from: JSONSerialization.data(withJSONObject: zeroOperation)
            )
        }

        let hostSignedKey = try HostOperationReplayKey(
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            messageType: "host.valid.v1",
            signer: .hostAuthority(fixture.hostKey.publicKey.hostAuthorityID),
            operationID: .random()
        )
        let hostSignedBytes = try JSONEncoder().encode(hostSignedKey)
        #expect(
            try JSONDecoder().decode(HostOperationReplayKey.self, from: hostSignedBytes)
                == hostSignedKey
        )
        var mismatchedHostSigner = try #require(
            JSONSerialization.jsonObject(with: hostSignedBytes) as? [String: Any]
        )
        let otherHostAuthorityID = SoftwareP256SigningKey().publicKey.hostAuthorityID
        mismatchedHostSigner["signer"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                HostOperationSigner.hostAuthority(otherHostAuthorityID)
            )
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                HostOperationReplayKey.self,
                from: JSONSerialization.data(withJSONObject: mismatchedHostSigner)
            )
        }
    }

    @Test("exact replay returns the original result and equivocation is rejected and audited")
    func exactReplayAndConflict() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            auditMaximumRows: 10
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("grant".utf8))
        let context = fixture.context(for: grant)
        let operationID = OperationID.random()
        let issuedAt = fixture.beganAt.addingTimeInterval(10)
        let expiresAt = issuedAt.addingTimeInterval(600)

        try await store.dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE operation_test_counter (value INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO operation_test_counter VALUES (0)")
        }

        let accepted = try await store.checkAndApplyHostDatabaseOperation(
            context: context,
            requiredScope: .recordingUploadOwn,
            messageType: "transfer.begin-upload.v1",
            operationID: operationID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: Data("request-a".utf8),
            at: issuedAt
        ) { db in
            try db.execute(sql: "UPDATE operation_test_counter SET value = value + 1")
            return Data("result-a".utf8)
        }
        #expect(accepted == .accepted(originalResult: Data("result-a".utf8)))

        let replay = try await store.checkAndApplyHostDatabaseOperation(
            context: context,
            requiredScope: .recordingUploadOwn,
            messageType: "transfer.begin-upload.v1",
            operationID: operationID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: Data("request-a".utf8),
            at: issuedAt.addingTimeInterval(1)
        ) { db in
            try db.execute(sql: "UPDATE operation_test_counter SET value = value + 1")
            return Data("a-recomputed-result-is-never-created".utf8)
        }
        #expect(replay == .exactReplay(originalResult: Data("result-a".utf8)))

        await #expect(throws: HarcHostError.replayConflict) {
            _ = try await store.checkAndApplyHostDatabaseOperation(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.begin-upload.v1",
                operationID: operationID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: Data("request-b".utf8),
                at: issuedAt.addingTimeInterval(2)
            ) { db in
                try db.execute(sql: "UPDATE operation_test_counter SET value = value + 1")
                return Data("result-b".utf8)
            }
        }
        let applicationCount = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM operation_test_counter")
        }
        #expect(applicationCount == 1)
        let events = try await store.auditEvents()
        #expect(events.contains { $0.code == "request-fingerprint-conflict" })
    }

    @Test("unexpired replay rows hit the per-device hard cap instead of being discarded")
    func operationCapacity() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            operationMaximumRowsPerDevice: 1
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("grant".utf8))
        let context = fixture.context(for: grant)
        let issuedAt = fixture.beganAt.addingTimeInterval(10)
        let expiresAt = issuedAt.addingTimeInterval(600)
        _ = try await store.checkAndApplyHostDatabaseOperation(
            context: context,
            requiredScope: .recordingUploadOwn,
            messageType: "transfer.test.v1",
            operationID: .random(),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: Data([1]),
            at: issuedAt
        ) { _ in Data([2]) }
        await #expect(throws: HarcHostError.operationCapacityExhausted) {
            _ = try await store.checkAndApplyHostDatabaseOperation(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.test.v1",
                operationID: .random(),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: Data([3]),
                at: issuedAt
            ) { _ in Data([4]) }
        }
    }

    @Test("accepted replay survives expiry and conflicting reuse remains rejected beyond retention")
    func replayIdentityIsPermanentAcrossReopen() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let grant = try fixture.grant()
        let context = fixture.context(for: grant)
        let operationID = OperationID.random()
        let issuedAt = fixture.beganAt.addingTimeInterval(10)
        let expiresAt = issuedAt.addingTimeInterval(600)
        let request = Data("permanent-request".utf8)
        let result = Data("permanent-result".utf8)

        do {
            let store = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("grant".utf8))
            try await store.dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE permanent_replay_counter (value INTEGER NOT NULL)")
                try db.execute(sql: "INSERT INTO permanent_replay_counter VALUES (0)")
            }
            let accepted = try await store.checkAndApplyHostDatabaseOperation(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.permanent-replay.v1",
                operationID: operationID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: request,
                at: issuedAt
            ) { db in
                try db.execute(sql: "UPDATE permanent_replay_counter SET value = value + 1")
                return result
            }
            #expect(accepted == .accepted(originalResult: result))
        }

        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        let beyondRetention = expiresAt.addingTimeInterval(31 * 24 * 60 * 60)
        let replay = try await reopened.checkAndApplyHostDatabaseOperation(
            context: context,
            requiredScope: .recordingUploadOwn,
            messageType: "transfer.permanent-replay.v1",
            operationID: operationID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: request,
            at: beyondRetention
        ) { db in
            try db.execute(sql: "UPDATE permanent_replay_counter SET value = value + 1")
            return Data("must-not-be-recomputed".utf8)
        }
        #expect(replay == .exactReplay(originalResult: result))

        await #expect(throws: HarcHostError.replayConflict) {
            _ = try await reopened.checkAndApplyHostDatabaseOperation(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.permanent-replay.v1",
                operationID: operationID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: Data("conflicting-request".utf8),
                at: beyondRetention.addingTimeInterval(1)
            ) { db in
                try db.execute(sql: "UPDATE permanent_replay_counter SET value = value + 1")
                return Data("conflicting-result".utf8)
            }
        }

        let applicationCount = try await reopened.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM permanent_replay_counter")
        }
        let durableReplayCount = try await reopened.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processed_operations")
        }
        #expect(applicationCount == 1)
        #expect(durableReplayCount == 1)

        await #expect(throws: HarcHostError.commandExpired) {
            _ = try await reopened.checkAndApplyHostDatabaseOperation(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.first-seen-expired.v1",
                operationID: .random(),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: Data("first-seen-expired".utf8),
                at: beyondRetention
            ) { _ in Data("must-not-apply".utf8) }
        }
    }

    @Test("prepared external effects survive reopen and complete without blind reapplication")
    func preparedExternalEffectRecovery() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let grant = try fixture.grant()
        let context = fixture.context(for: grant)
        let operationID = OperationID.random()
        let issuedAt = fixture.beganAt.addingTimeInterval(10)
        let expiresAt = issuedAt.addingTimeInterval(600)
        let request = Data("publish-recording".utf8)
        let effect = Data("canonical-path-and-object-id".utf8)

        do {
            let store = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: stagingRoot,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider()
            )
            try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("grant".utf8))
            let prepared = try await store.prepareExternalOperationEffect(
                context: context,
                requiredScope: .recordingUploadOwn,
                messageType: "transfer.publish.v1",
                operationID: operationID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                exactRequestBytes: request,
                preparedEffect: effect,
                at: issuedAt
            )
            #expect(prepared == .prepared)
        }

        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: stagingRoot,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        let replay = try await reopened.prepareExternalOperationEffect(
            context: context,
            requiredScope: .recordingUploadOwn,
            messageType: "transfer.publish.v1",
            operationID: operationID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: request,
            preparedEffect: effect,
            at: issuedAt.addingTimeInterval(1)
        )
        #expect(replay == .exactPreparedReplay(preparedEffect: effect))

        let key = try HostOperationReplayKey(
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            messageType: "transfer.publish.v1",
            signer: .device(fixture.deviceID),
            operationID: operationID
        )
        let result = Data("published".utf8)
        let completed = try await reopened.markPreparedOperationApplied(
            key: key,
            exactRequestBytes: request,
            preparedEffect: effect,
            originalResult: result
        )
        #expect(completed == .accepted(originalResult: result))
        let completedReplay = try await reopened.markPreparedOperationApplied(
            key: key,
            exactRequestBytes: request,
            preparedEffect: effect,
            originalResult: result
        )
        #expect(completedReplay == .exactReplay(originalResult: result))
    }
}
