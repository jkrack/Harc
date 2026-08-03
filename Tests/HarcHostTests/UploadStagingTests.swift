import CryptoKit
import Foundation
import GRDB
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity
import HarcTransfer

@Suite("HarcHost upload state and bounded staging")
struct UploadStagingTests {
    private struct AuthorizingHostLocalOSAuthenticationBoundary: HostLocalOSAuthenticationBoundary {
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

        func authorizeSameKeyReadoption(for deviceID: DeviceID) async throws -> Bool { true }
    }

    private struct StartedUpload {
        let store: HarcHostStore
        let grant: DeviceGrantClaims
        let context: AuthenticatedDeviceContext
        let uploadID: UploadID
        let origin: OriginRecordingID
        let profile: FrozenUploadProfile
        let descriptor: LogicalChunkDescriptor
        let bytes: Data
    }

    private func generatedObjectURLs(in stagingRoot: URL) throws -> [URL] {
        let objects = stagingRoot.appendingPathComponent("objects", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: objects,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.pathExtension == "chunk" }
    }

    private func generatedObjectBytes(in stagingRoot: URL) throws -> UInt64 {
        try generatedObjectURLs(in: stagingRoot).reduce(into: UInt64(0)) { total, url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            total += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
    }

    private func startUpload(
        fixture: HostTestFixture,
        directory: URL,
        databaseURL: URL? = nil,
        highWaterMarkStore: any SecurityRegistryHighWaterMarkStore = InMemorySecurityRegistryHighWaterMarkStore(),
        localOSAuthenticationBoundary: any HostLocalOSAuthenticationBoundary = RejectingHostLocalOSAuthenticationBoundary(),
        stagingInjector: any StagingFailureInjector = NoStagingFailureInjector(),
        quota: HostStagingQuotaPolicy = HostStagingQuotaPolicy(),
        grantExpiresAt: Date? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        bytes: Data = Data([0, 1, 2, 3, 4, 5, 6, 7])
    ) async throws -> StartedUpload {
        let store: HarcHostStore
        if let databaseURL {
            store = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: directory,
                metadata: fixture.metadata,
                highWaterMarkStore: highWaterMarkStore,
                localOSAuthenticationBoundary: localOSAuthenticationBoundary,
                stagingFailureInjector: stagingInjector,
                quotaPolicy: quota,
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: now
            )
        } else {
            store = try await HarcHostStore.inMemory(
                stagingRoot: directory,
                metadata: fixture.metadata,
                highWaterMarkStore: highWaterMarkStore,
                localOSAuthenticationBoundary: localOSAuthenticationBoundary,
                stagingFailureInjector: stagingInjector,
                quotaPolicy: quota,
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: now
            )
        }
        let grant = try fixture.grant(expiresAt: grantExpiresAt)
        try await store.seedDeviceGrantForTesting(grant, exactGrantBytes: Data("grant".utf8))
        let context = fixture.context(for: grant)
        let uploadID = UploadID.random()
        let origin = OriginRecordingID(deviceID: fixture.deviceID, recordingUUID: UUID())
        let profile = try fixture.profile()
        let descriptor = try fixture.descriptor(origin: origin, bytes: bytes)
        let begin = try await store.beginUpload(
            context: context,
            sessionCapabilities: try fixture.sessionCapabilities(for: profile),
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: profile,
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: fixture.beganAt.addingTimeInterval(1)
        )
        guard case .created = begin else {
            Issue.record("Expected a fresh upload")
            throw HarcHostError.uploadConflict("test setup")
        }
        _ = try await store.declareChunks(
            context: context,
            uploadID: uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: profile.profileSHA256,
            descriptors: [descriptor],
            at: fixture.beganAt.addingTimeInterval(2)
        )
        return StartedUpload(
            store: store,
            grant: grant,
            context: context,
            uploadID: uploadID,
            origin: origin,
            profile: profile,
            descriptor: descriptor,
            bytes: bytes
        )
    }

    @Test("begin and declaration are exact-idempotent; gaps reject and immutable conflicts block")
    func declarationReplayGapAndConflict() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)

        let wrongProfileSHA256 = try UploadProfileSHA256(Data(repeating: 0xFF, count: 32))
        await #expect(throws: TransferValidationError.profileMismatch(
            field: "uploadProfileSHA256"
        )) {
            _ = try await upload.store.declareChunks(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: wrongProfileSHA256,
                descriptors: [upload.descriptor],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        let replay = try await upload.store.declareChunks(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            descriptors: [upload.descriptor],
            at: fixture.beganAt.addingTimeInterval(3)
        )
        #expect(replay == .exactReplay)

        let beginReplay = try await upload.store.beginUpload(
            context: upload.context,
            sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
            request: BeginHostUploadRequest(
                uploadID: upload.uploadID,
                originRecordingID: upload.origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: fixture.beganAt.addingTimeInterval(3)
        )
        guard case .exactReplay = beginReplay else {
            Issue.record("Expected exact BeginUpload replay")
            return
        }

        let conflicting = try fixture.descriptor(
            origin: upload.origin,
            chunkIndex: 0,
            startFrame: 0,
            bytes: Data([8, 9, 10, 11, 12, 13, 14, 15])
        )
        await #expect(throws: TransferValidationError.self) {
            _ = try await upload.store.declareChunks(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                descriptors: [conflicting],
                at: fixture.beganAt.addingTimeInterval(4)
            )
        }
        await #expect(throws: TransferValidationError.declarationBlocked) {
            _ = try await upload.store.declareChunks(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                descriptors: [upload.descriptor],
                at: fixture.beganAt.addingTimeInterval(5)
            )
        }
    }

    @Test("expired upload reopens with a new generation and abandon is terminal")
    func reopenAndAbandon() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)
        let reopenedAt = fixture.beganAt.addingTimeInterval(TransferLimits.uploadGenerationLifetime + 2)
        let reopened = try await upload.store.beginUpload(
            context: upload.context,
            sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
            request: BeginHostUploadRequest(
                uploadID: upload.uploadID,
                originRecordingID: upload.origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: reopenedAt
        )
        guard case .reopened(let state) = reopened else {
            Issue.record("Expected expired attempt to reopen")
            return
        }
        #expect(state.generation.rawValue == 2)
        #expect(state.declarations == [upload.descriptor])

        let wrongProfileSHA256 = try UploadProfileSHA256(Data(repeating: 0xFF, count: 32))
        await #expect(throws: TransferValidationError.profileMismatch(
            field: "uploadProfileSHA256"
        )) {
            _ = try await upload.store.abandonUpload(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: state.generation,
                expectedUploadProfileSHA256: wrongProfileSHA256,
                at: reopenedAt.addingTimeInterval(0.5)
            )
        }
        await #expect(throws: HarcHostError.staleUploadGeneration(
            expected: state.generation.rawValue,
            actual: UploadGeneration.initial.rawValue
        )) {
            _ = try await upload.store.abandonUpload(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                at: reopenedAt.addingTimeInterval(0.5)
            )
        }
        let originalTerminalAt = reopenedAt.addingTimeInterval(1)
        let abandonment = try await upload.store.abandonUpload(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: state.generation,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            at: originalTerminalAt
        )
        #expect(abandonment.uploadID == upload.uploadID)
        #expect(abandonment.terminalReason == .abandoned)
        #expect(abandonment.terminalAt == originalTerminalAt)
        let replay = try await upload.store.abandonUpload(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: state.generation,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            at: reopenedAt.addingTimeInterval(2)
        )
        #expect(replay == abandonment)
        #expect(try await upload.store.incompleteRemoteUploads(at: reopenedAt.addingTimeInterval(2)).isEmpty)
        await #expect(throws: HarcHostError.self) {
            _ = try await upload.store.beginUpload(
                context: upload.context,
                sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
                request: BeginHostUploadRequest(
                    uploadID: upload.uploadID,
                    originRecordingID: upload.origin,
                    frozenProfile: try fixture.profile(),
                    beganAt: fixture.beganAt
                ),
                at: reopenedAt.addingTimeInterval(2)
            )
        }
    }

    @Test("a newer same-origin attempt blocks reopening the older expired upload ID")
    func sameOriginOwnerBlocksExpiredIDReopen() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await startUpload(fixture: fixture, directory: directory)
        let replacementID = UploadID.random()
        let replacementBeganAt = fixture.beganAt.addingTimeInterval(
            1 + TransferLimits.uploadGenerationLifetime
        )
        let replacement = try await original.store.beginUpload(
            context: original.context,
            sessionCapabilities: try fixture.sessionCapabilities(for: original.profile),
            request: BeginHostUploadRequest(
                uploadID: replacementID,
                originRecordingID: original.origin,
                frozenProfile: try fixture.profile(),
                beganAt: replacementBeganAt
            ),
            at: replacementBeganAt
        )
        guard case .created = replacement else {
            Issue.record("The newer same-origin attempt was not created after expiry")
            return
        }

        await #expect(throws: TransferValidationError.invalidUploadAttempt(
            reason: "Upload ID was permanently superseded by a newer attempt for this origin recording."
        )) {
            _ = try await original.store.beginUpload(
                context: original.context,
                sessionCapabilities: try fixture.sessionCapabilities(for: original.profile),
                request: BeginHostUploadRequest(
                    uploadID: original.uploadID,
                    originRecordingID: original.origin,
                    frozenProfile: try fixture.profile(),
                    beganAt: fixture.beganAt.addingTimeInterval(1)
                ),
                at: replacementBeganAt.addingTimeInterval(1)
            )
        }
    }

    @Test("verified, synchronized bytes ACK exactly once and corruption remains recoverable")
    func stageSuccessReplayAndCorruption() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)

        let accepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [Data(upload.bytes.prefix(3)), Data(upload.bytes.dropFirst(3))],
            at: fixture.beganAt.addingTimeInterval(3)
        )
        guard case .durablyAccepted(let acknowledgement) = accepted else {
            Issue.record("Expected durable ACK")
            return
        }
        #expect(acknowledgement.uploadID == upload.uploadID)
        #expect(acknowledgement.generation == .initial)
        #expect(acknowledgement.uploadProfileSHA256 == upload.profile.profileSHA256)
        #expect(acknowledgement.durableChunk.chunkID == upload.descriptor.chunkID)
        #expect(acknowledgement.durableAt == fixture.beganAt.addingTimeInterval(3))

        let replay = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(4)
        )
        guard case .exactReplay(let replayAcknowledgement) = replay else {
            Issue.record("Expected exact staging replay")
            return
        }
        #expect(replayAcknowledgement == acknowledgement)
        let wrongProfileSHA256 = try UploadProfileSHA256(Data(repeating: 0xFF, count: 32))
        await #expect(throws: TransferValidationError.profileMismatch(
            field: "uploadProfileSHA256"
        )) {
            _ = try await upload.store.reconciliation(
                for: upload.uploadID,
                expectedUploadProfileSHA256: wrongProfileSHA256,
                context: upload.context,
                at: fixture.beganAt.addingTimeInterval(5)
            )
        }
        let reconciliation = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: fixture.beganAt.addingTimeInterval(5)
        )
        #expect(reconciliation.durableChunks.count == 1)
        #expect(reconciliation.rejectedChunks.isEmpty)
    }

    @Test("truncated, oversized, corrupt, and quota-exhausted bodies never ACK")
    func invalidBodiesAndQuota() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)

        let wrongProfileSHA256 = try UploadProfileSHA256(Data(repeating: 0xFF, count: 32))
        await #expect(throws: TransferValidationError.profileMismatch(
            field: "uploadProfileSHA256"
        )) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: wrongProfileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [upload.bytes],
                at: fixture.beganAt.addingTimeInterval(2.5)
            )
        }
        await #expect(throws: TransferValidationError.profileMismatch(field: "chunkID")) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: .random(),
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [upload.bytes],
                at: fixture.beganAt.addingTimeInterval(2.5)
            )
        }
        let wrongEncodedSHA256 = try EncodedChunkSHA256(Data(repeating: 0xFF, count: 32))
        await #expect(throws: TransferValidationError.profileMismatch(field: "encodedSHA256")) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: wrongEncodedSHA256,
                bodyFragments: [upload.bytes],
                at: fixture.beganAt.addingTimeInterval(2.5)
            )
        }
        await #expect(throws: HarcHostError.incompleteBody) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [Data(upload.bytes.prefix(2))],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        await #expect(throws: HarcHostError.encodedLengthMismatch(
            expected: UInt64(upload.bytes.count),
            actual: UInt64(upload.bytes.count + 1)
        )) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [upload.bytes + Data([99])],
                at: fixture.beganAt.addingTimeInterval(4)
            )
        }
        await #expect(throws: HarcHostError.encodedHashMismatch) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [Data(repeating: 0xEE, count: upload.bytes.count)],
                at: fixture.beganAt.addingTimeInterval(5)
            )
        }

        let quotaDirectory = try fixture.temporaryDirectory("quota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: quotaDirectory) }
        let quotaUpload = try await startUpload(
            fixture: fixture,
            directory: quotaDirectory,
            quota: HostStagingQuotaPolicy(
                perDeviceBytes: 4,
                globalBytes: 4,
                minimumFreeBytes: 0,
                minimumFreePermille: 0
            )
        )
        await #expect(throws: HarcHostError.quotaExceeded(
            scope: "per-device",
            limit: 4,
            requestedTotal: UInt64(quotaUpload.bytes.count)
        )) {
            _ = try await quotaUpload.store.stageChunk(
                context: quotaUpload.context,
                uploadID: quotaUpload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: quotaUpload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: quotaUpload.descriptor.chunkID,
                declaredEncodedLength: UInt64(quotaUpload.bytes.count),
                claimedEncodedSHA256: quotaUpload.descriptor.encodedSHA256,
                bodyFragments: [quotaUpload.bytes],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
    }

    @Test("reopen removes rejected bytes left by a post-rejection process death before quota reuse")
    func rejectedObjectIsRemovedBeforeQuotaReuseOnReopen() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("rejected-object-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let quota = HostStagingQuotaPolicy(
            perDeviceBytes: 8,
            globalBytes: 8,
            minimumFreeBytes: 0,
            minimumFreePermille: 0
        )

        var uploadID: UploadID?
        var context: AuthenticatedDeviceContext?
        var bytes: Data?
        var profile: FrozenUploadProfile?
        var descriptor: LogicalChunkDescriptor?
        var rejectedRelativePath: String?
        do {
            let upload = try await startUpload(
                fixture: fixture,
                directory: directory,
                databaseURL: databaseURL,
                highWaterMarkStore: highWater,
                stagingInjector: OneShotStagingFailureInjector(.afterDatabaseAcknowledgement),
                quota: quota
            )
            uploadID = upload.uploadID
            context = upload.context
            bytes = upload.bytes
            profile = upload.profile
            descriptor = upload.descriptor
            await #expect(throws: InjectedHostCrash.staging(.afterDatabaseAcknowledgement)) {
                _ = try await upload.store.stageChunk(
                    context: upload.context,
                    uploadID: upload.uploadID,
                    generation: .initial,
                    expectedUploadProfileSHA256: upload.profile.profileSHA256,
                    chunkIndex: 0,
                    claimedChunkID: upload.descriptor.chunkID,
                    declaredEncodedLength: UInt64(upload.bytes.count),
                    claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                    bodyFragments: [Data(repeating: 0xEE, count: upload.bytes.count)],
                    at: fixture.beganAt.addingTimeInterval(3)
                )
            }
            rejectedRelativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
            let status = try await upload.store.dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                    arguments: [upload.uploadID.description]
                )
            }
            #expect(status == "rejected")
            #expect(try generatedObjectBytes(in: directory) == UInt64(upload.bytes.count))
        }

        let recoveredUploadID = try #require(uploadID)
        let recoveredContext = try #require(context)
        let recoveredBytes = try #require(bytes)
        let recoveredProfile = try #require(profile)
        let recoveredDescriptor = try #require(descriptor)
        let rejectedPath = try #require(rejectedRelativePath)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(rejectedPath).path))

        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            quotaPolicy: quota,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(rejectedPath).path))
        #expect(try generatedObjectBytes(in: directory) == 0)

        guard case .durablyAccepted = try await reopened.stageChunk(
            context: recoveredContext,
            uploadID: recoveredUploadID,
            generation: .initial,
            expectedUploadProfileSHA256: recoveredProfile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: recoveredDescriptor.chunkID,
            declaredEncodedLength: UInt64(recoveredBytes.count),
            claimedEncodedSHA256: recoveredDescriptor.encodedSHA256,
            bodyFragments: [recoveredBytes],
            at: fixture.beganAt.addingTimeInterval(4)
        ) else {
            Issue.record("Expected quota to be reusable after rejected-object cleanup")
            return
        }
        #expect(try generatedObjectURLs(in: directory).count == 1)
        #expect(try generatedObjectBytes(in: directory) == quota.globalBytes)
    }

    @Test("a suspended post-rejection unlink keeps its bytes charged to quota")
    func rejectedObjectRemainsChargedUntilDurableDeletion() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("pending-rejected-quota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let quota = HostStagingQuotaPolicy(
            perDeviceBytes: 8,
            globalBytes: 8,
            minimumFreeBytes: 0,
            minimumFreePermille: 0
        )
        let injector = SuspendingStagingFailureInjector(.afterDatabaseAcknowledgement)
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            stagingInjector: injector,
            quota: quota
        )
        let secondBytes = Data([8, 9, 10, 11, 12, 13, 14, 15])
        let secondDescriptor = try fixture.descriptor(
            origin: upload.origin,
            chunkIndex: 1,
            startFrame: UInt64(upload.bytes.count / 2),
            bytes: secondBytes
        )
        _ = try await upload.store.declareChunks(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            descriptors: [secondDescriptor],
            at: fixture.beganAt.addingTimeInterval(2.5)
        )

        let rejectionTask = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [Data(repeating: 0xEE, count: upload.bytes.count)],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        await injector.waitUntilSuspended()

        let pendingDeletion = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, object_deleted_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        let pendingStatus: String? = pendingDeletion?["status"]
        let pendingDeletedAt: Double? = pendingDeletion?["object_deleted_at"]
        #expect(pendingStatus == "rejected")
        #expect(pendingDeletedAt == nil)
        #expect(try generatedObjectBytes(in: directory) == quota.globalBytes)

        await #expect(throws: HarcHostError.quotaExceeded(
            scope: "per-device",
            limit: quota.perDeviceBytes,
            requestedTotal: 16
        )) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 1,
                claimedChunkID: secondDescriptor.chunkID,
                declaredEncodedLength: UInt64(secondBytes.count),
                claimedEncodedSHA256: secondDescriptor.encodedSHA256,
                bodyFragments: [secondBytes],
                at: fixture.beganAt.addingTimeInterval(3.5)
            )
        }

        await injector.release()
        await #expect(throws: HarcHostError.encodedHashMismatch) {
            _ = try await rejectionTask.value
        }
        let deletionRecorded = try await upload.store.dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT object_deleted_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        #expect(deletionRecorded != nil)
        #expect(try generatedObjectBytes(in: directory) == 0)

        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 1,
            claimedChunkID: secondDescriptor.chunkID,
            declaredEncodedLength: UInt64(secondBytes.count),
            claimedEncodedSHA256: secondDescriptor.encodedSHA256,
            bodyFragments: [secondBytes],
            at: fixture.beganAt.addingTimeInterval(4)
        ) else {
            Issue.record("Expected deletion completion to release rejected-byte quota")
            return
        }
        #expect(try generatedObjectBytes(in: directory) == quota.globalBytes)
    }

    @Test("reopen removes an obsolete object left after journal path replacement before quota reuse")
    func obsoleteReplacementObjectIsRemovedBeforeQuotaReuseOnReopen() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("obsolete-object-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let quota = HostStagingQuotaPolicy(
            perDeviceBytes: 8,
            globalBytes: 8,
            minimumFreeBytes: 0,
            minimumFreePermille: 0
        )
        let injector = SequencedStagingFailureInjector([
            .afterDatabaseAcknowledgement,
            .afterJournalReservation,
        ])

        var uploadID: UploadID?
        var context: AuthenticatedDeviceContext?
        var bytes: Data?
        var profile: FrozenUploadProfile?
        var descriptor: LogicalChunkDescriptor?
        var obsoleteRelativePath: String?
        var replacementRelativePath: String?
        do {
            let upload = try await startUpload(
                fixture: fixture,
                directory: directory,
                databaseURL: databaseURL,
                highWaterMarkStore: highWater,
                stagingInjector: injector,
                quota: quota
            )
            uploadID = upload.uploadID
            context = upload.context
            bytes = upload.bytes
            profile = upload.profile
            descriptor = upload.descriptor
            await #expect(throws: InjectedHostCrash.staging(.afterDatabaseAcknowledgement)) {
                _ = try await upload.store.stageChunk(
                    context: upload.context,
                    uploadID: upload.uploadID,
                    generation: .initial,
                    expectedUploadProfileSHA256: upload.profile.profileSHA256,
                    chunkIndex: 0,
                    claimedChunkID: upload.descriptor.chunkID,
                    declaredEncodedLength: UInt64(upload.bytes.count),
                    claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                    bodyFragments: [Data(repeating: 0xEE, count: upload.bytes.count)],
                    at: fixture.beganAt.addingTimeInterval(3)
                )
            }
            obsoleteRelativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )

            await #expect(throws: InjectedHostCrash.staging(.afterJournalReservation)) {
                _ = try await upload.store.stageChunk(
                    context: upload.context,
                    uploadID: upload.uploadID,
                    generation: .initial,
                    expectedUploadProfileSHA256: upload.profile.profileSHA256,
                    chunkIndex: 0,
                    claimedChunkID: upload.descriptor.chunkID,
                    declaredEncodedLength: UInt64(upload.bytes.count),
                    claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                    bodyFragments: [upload.bytes],
                    at: fixture.beganAt.addingTimeInterval(4)
                )
            }
            replacementRelativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        }

        let recoveredUploadID = try #require(uploadID)
        let recoveredContext = try #require(context)
        let recoveredBytes = try #require(bytes)
        let recoveredProfile = try #require(profile)
        let recoveredDescriptor = try #require(descriptor)
        let obsoletePath = try #require(obsoleteRelativePath)
        let replacementPath = try #require(replacementRelativePath)
        #expect(obsoletePath != replacementPath)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(obsoletePath).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(replacementPath).path))
        #expect(try generatedObjectBytes(in: directory) == UInt64(recoveredBytes.count))

        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            quotaPolicy: quota,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(obsoletePath).path))
        #expect(try generatedObjectBytes(in: directory) == 0)

        guard case .durablyAccepted = try await reopened.stageChunk(
            context: recoveredContext,
            uploadID: recoveredUploadID,
            generation: .initial,
            expectedUploadProfileSHA256: recoveredProfile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: recoveredDescriptor.chunkID,
            declaredEncodedLength: UInt64(recoveredBytes.count),
            claimedEncodedSHA256: recoveredDescriptor.encodedSHA256,
            bodyFragments: [recoveredBytes],
            at: fixture.beganAt.addingTimeInterval(5)
        ) else {
            Issue.record("Expected quota to be reusable after obsolete-object cleanup")
            return
        }
        #expect(try generatedObjectURLs(in: directory).count == 1)
        #expect(try generatedObjectBytes(in: directory) == quota.globalBytes)
    }

    @Test("two suspended chunk streams do not reconcile or unlink each other")
    func concurrentChunkStreamsBothAcknowledge() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstBytes = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let secondBytes = Data([8, 9, 10, 11, 12, 13, 14, 15])
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            bytes: firstBytes
        )
        let secondDescriptor = try fixture.descriptor(
            origin: upload.origin,
            chunkIndex: 1,
            startFrame: UInt64(firstBytes.count / 2),
            bytes: secondBytes
        )
        _ = try await upload.store.declareChunks(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            descriptors: [secondDescriptor],
            at: fixture.beganAt.addingTimeInterval(2.5)
        )

        let (firstStream, firstContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (secondStream, secondContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        firstContinuation.yield(Data(firstBytes.prefix(4)))
        secondContinuation.yield(Data(secondBytes.prefix(4)))

        let firstTask = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(firstBytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                body: HostChunkBody(stream: firstStream),
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        let secondTask = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 1,
                claimedChunkID: secondDescriptor.chunkID,
                declaredEncodedLength: UInt64(secondBytes.count),
                claimedEncodedSHA256: secondDescriptor.encodedSHA256,
                body: HostChunkBody(stream: secondStream),
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }

        var writingCount = 0
        for _ in 0 ..< 1_000 {
            writingCount = try await upload.store.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM staged_chunks WHERE upload_id = ? AND status = 'writing'",
                    arguments: [upload.uploadID.description]
                ) ?? 0
            }
            if writingCount == 2 { break }
            await Task.yield()
        }
        guard writingCount == 2 else {
            firstContinuation.finish()
            secondContinuation.finish()
            firstTask.cancel()
            secondTask.cancel()
            Issue.record("Both writers did not reach their suspended journal reservations")
            return
        }

        firstContinuation.yield(Data(firstBytes.dropFirst(4)))
        secondContinuation.yield(Data(secondBytes.dropFirst(4)))
        firstContinuation.finish()
        secondContinuation.finish()
        let firstDisposition = try await firstTask.value
        let secondDisposition = try await secondTask.value
        guard case .durablyAccepted = firstDisposition else {
            Issue.record("First concurrent stream did not receive a durable ACK")
            return
        }
        guard case .durablyAccepted = secondDisposition else {
            Issue.record("Second concurrent stream did not receive a durable ACK")
            return
        }

        let state = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: fixture.beganAt.addingTimeInterval(4)
        )
        #expect(state.durableChunks.count == 2)
        #expect(state.rejectedChunks.isEmpty)
    }

    @Test("a device is limited to two active staging streams and every exit releases its slot")
    func activeStagingStreamLimitAndRelease() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstBytes = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let secondBytes = Data([8, 9, 10, 11, 12, 13, 14, 15])
        let thirdBytes = Data([16, 17, 18, 19, 20, 21, 22, 23])
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            bytes: firstBytes
        )
        let secondDescriptor = try fixture.descriptor(
            origin: upload.origin,
            chunkIndex: 1,
            startFrame: 4,
            bytes: secondBytes
        )
        let thirdDescriptor = try fixture.descriptor(
            origin: upload.origin,
            chunkIndex: 2,
            startFrame: 8,
            bytes: thirdBytes
        )
        _ = try await upload.store.declareChunks(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            descriptors: [secondDescriptor, thirdDescriptor],
            at: fixture.beganAt.addingTimeInterval(2.5)
        )

        let (firstStream, firstContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (secondStream, secondContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        firstContinuation.yield(Data(firstBytes.prefix(4)))
        secondContinuation.yield(Data(secondBytes.prefix(4)))
        let firstTask = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(firstBytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                body: HostChunkBody(stream: firstStream),
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        let secondTask = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 1,
                claimedChunkID: secondDescriptor.chunkID,
                declaredEncodedLength: UInt64(secondBytes.count),
                claimedEncodedSHA256: secondDescriptor.encodedSHA256,
                body: HostChunkBody(stream: secondStream),
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }

        var writingCount = 0
        for _ in 0 ..< 1_000 {
            writingCount = try await upload.store.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM staged_chunks WHERE upload_id = ? AND status = 'writing'",
                    arguments: [upload.uploadID.description]
                ) ?? 0
            }
            if writingCount == 2 { break }
            await Task.yield()
        }
        guard writingCount == 2 else {
            firstContinuation.finish()
            secondContinuation.finish()
            firstTask.cancel()
            secondTask.cancel()
            Issue.record("The first two staging streams were not admitted")
            return
        }

        await #expect(throws: HarcHostError.activeStagingStreamLimitExceeded(limit: 2)) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 2,
                claimedChunkID: thirdDescriptor.chunkID,
                declaredEncodedLength: UInt64(thirdBytes.count),
                claimedEncodedSHA256: thirdDescriptor.encodedSHA256,
                bodyFragments: [thirdBytes],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }

        firstContinuation.yield(Data(firstBytes.dropFirst(4)))
        firstContinuation.finish()
        guard case .durablyAccepted = try await firstTask.value else {
            Issue.record("Closing the first stream did not durably accept it")
            return
        }
        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 2,
            claimedChunkID: thirdDescriptor.chunkID,
            declaredEncodedLength: UInt64(thirdBytes.count),
            claimedEncodedSHA256: thirdDescriptor.encodedSHA256,
            bodyFragments: [thirdBytes],
            at: fixture.beganAt.addingTimeInterval(3)
        ) else {
            Issue.record("The third stream was not admitted after a slot was released")
            return
        }

        secondContinuation.yield(Data(secondBytes.dropFirst(4)))
        secondContinuation.finish()
        guard case .durablyAccepted = try await secondTask.value else {
            Issue.record("Closing the second stream did not durably accept it")
            return
        }
        let durableCount = try await upload.store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM staged_chunks WHERE upload_id = ? AND status = 'durable'",
                arguments: [upload.uploadID.description]
            ) ?? 0
        }
        #expect(durableCount == 3)
    }

    @Test("a suspended body observes fresh host time and cannot ACK after grant expiry")
    func suspendedBodyRejectsAfterClockAdvance() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialTime = fixture.beganAt.addingTimeInterval(3)
        let grantExpiry = fixture.beganAt.addingTimeInterval(10)
        let clock = LockedHostClock(initialTime)
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            grantExpiresAt: grantExpiry,
            now: { clock.read() }
        )
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data(upload.bytes.prefix(4)))
        let task = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                body: HostChunkBody(stream: stream)
            )
        }

        var relativePath: String?
        for _ in 0 ..< 1_000 {
            relativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
            if relativePath != nil { break }
            await Task.yield()
        }
        let stagedRelativePath = try #require(relativePath)
        var partialLength: UInt64 = 0
        for _ in 0 ..< 1_000 {
            let stagedURL = directory.appendingPathComponent(stagedRelativePath)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: stagedURL.path),
               let fileSize = attributes[.size] as? NSNumber {
                partialLength = fileSize.uint64Value
            }
            if partialLength == 4 { break }
            await Task.yield()
        }
        #expect(partialLength == 4)
        clock.set(grantExpiry.addingTimeInterval(1))
        continuation.yield(Data(upload.bytes.dropFirst(4)))
        await #expect(throws: HarcHostError.grantExpired) {
            _ = try await task.value
        }
        continuation.finish()

        let persistedState = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, durable_acknowledged_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        let status: String? = persistedState?["status"]
        let acknowledgedAt: Double? = persistedState?["durable_acknowledged_at"]
        #expect(status == "rejected")
        #expect(acknowledgedAt == nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(stagedRelativePath).path
        ))
    }

    @Test("an idle staging body is terminated promptly when its current grant is revoked")
    func idleBodyTerminatesAfterCurrentGrantRevocation() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("idle-revocation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(3))
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            now: { clock.read() }
        )
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data(upload.bytes.prefix(4)))
        let task = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                body: HostChunkBody(stream: stream)
            )
        }

        var relativePath: String?
        var partialLength: UInt64 = 0
        for _ in 0 ..< 1_000 {
            relativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
            if let relativePath,
               let attributes = try? FileManager.default.attributesOfItem(
                   atPath: directory.appendingPathComponent(relativePath).path
               ),
               let size = attributes[.size] as? NSNumber {
                partialLength = size.uint64Value
            }
            if partialLength == 4 { break }
            await Task.yield()
        }
        let stagedRelativePath = try #require(relativePath)
        #expect(partialLength == 4)

        clock.set(fixture.beganAt.addingTimeInterval(4))
        try await upload.store.revokeDevice(
            fixture.deviceID,
            revocationID: UUID(),
            reasonCode: "test.revoke-idle-staging",
            exactRevocationBytes: Data("revocation".utf8)
        )
        let terminationStarted = ContinuousClock.now
        await #expect(throws: HarcHostError.deviceRevoked) {
            _ = try await task.value
        }
        #expect(terminationStarted.duration(to: .now) < .seconds(5))

        continuation.yield(Data(upload.bytes.dropFirst(4)))
        continuation.finish()
        let rejected = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, persisted_encoded_length, object_deleted_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        let status: String? = rejected?["status"]
        let persistedLength: Int64? = rejected?["persisted_encoded_length"]
        let deletedAt: Double? = rejected?["object_deleted_at"]
        #expect(status == "rejected")
        #expect(persistedLength == nil)
        #expect(deletedAt != nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(stagedRelativePath).path
        ))
    }

    @Test("an idle staging body is terminated when an authorized replacement removes upload scope")
    func idleBodyTerminatesAfterUploadScopeRemoval() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("idle-scope-removal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(3))
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            localOSAuthenticationBoundary: AuthorizingHostLocalOSAuthenticationBoundary(),
            now: { clock.read() }
        )
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data(upload.bytes.prefix(4)))
        let task = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                body: HostChunkBody(stream: stream)
            )
        }

        var relativePath: String?
        var partialLength: UInt64 = 0
        for _ in 0 ..< 1_000 {
            relativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
            if let relativePath,
               let attributes = try? FileManager.default.attributesOfItem(
                   atPath: directory.appendingPathComponent(relativePath).path
               ),
               let size = attributes[.size] as? NSNumber {
                partialLength = size.uint64Value
            }
            if partialLength == 4 { break }
            await Task.yield()
        }
        let stagedRelativePath = try #require(relativePath)
        #expect(partialLength == 4)

        clock.set(fixture.beganAt.addingTimeInterval(4))
        let current = try #require(
            try await upload.store.deviceRegistryEntry(deviceID: fixture.deviceID)
        )
        let replacement = try current.replacingScopesAfterLocalAuthorization(
            Set<AuthorizationScope>([.recordingReadOwn]),
            issuedAt: fixture.beganAt.addingTimeInterval(4)
        )
        try await upload.store.replaceDeviceGrant(
            replacement.grant,
            exactGrantBytes: Data("scope-removed".utf8)
        )

        let terminationStarted = ContinuousClock.now
        await #expect(throws: HarcHostError.grantMismatch) {
            _ = try await task.value
        }
        #expect(terminationStarted.duration(to: .now) < .seconds(5))

        continuation.yield(Data(upload.bytes.dropFirst(4)))
        continuation.finish()
        let rejected = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, persisted_encoded_length, object_deleted_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        let status: String? = rejected?["status"]
        let persistedLength: Int64? = rejected?["persisted_encoded_length"]
        let deletedAt: Double? = rejected?["object_deleted_at"]
        #expect(status == "rejected")
        #expect(persistedLength == nil)
        #expect(deletedAt != nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(stagedRelativePath).path
        ))
    }

    @Test("an idle staging body is terminated promptly when its upload is abandoned")
    func idleBodyTerminatesAfterUploadAbandonment() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("idle-abandonment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(3))
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            now: { clock.read() }
        )
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data(upload.bytes.prefix(4)))
        let task = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                body: HostChunkBody(stream: stream)
            )
        }

        var relativePath: String?
        var partialLength: UInt64 = 0
        for _ in 0 ..< 1_000 {
            relativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
            if let relativePath,
               let attributes = try? FileManager.default.attributesOfItem(
                   atPath: directory.appendingPathComponent(relativePath).path
               ),
               let size = attributes[.size] as? NSNumber {
                partialLength = size.uint64Value
            }
            if partialLength == 4 { break }
            await Task.yield()
        }
        let stagedRelativePath = try #require(relativePath)
        #expect(partialLength == 4)

        clock.set(fixture.beganAt.addingTimeInterval(4))
        try await upload.store.abandonUpload(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256
        )
        let terminationStarted = ContinuousClock.now
        await #expect(throws: TransferValidationError.uploadTerminal) {
            _ = try await task.value
        }
        #expect(terminationStarted.duration(to: .now) < .seconds(5))

        continuation.yield(Data(upload.bytes.dropFirst(4)))
        continuation.finish()
        let rejected = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, persisted_encoded_length, object_deleted_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        let status: String? = rejected?["status"]
        let persistedLength: Int64? = rejected?["persisted_encoded_length"]
        let deletedAt: Double? = rejected?["object_deleted_at"]
        #expect(status == "rejected")
        #expect(persistedLength == nil)
        #expect(deletedAt != nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(stagedRelativePath).path
        ))
    }

    @Test("the final transaction reads fresh host time after fsync before ACK")
    func postSynchronizationClockAdvanceRejectsACK() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialTime = fixture.beganAt.addingTimeInterval(3)
        let grantExpiry = fixture.beganAt.addingTimeInterval(10)
        let clock = LockedHostClock(initialTime)
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            stagingInjector: ClockAdvancingStagingInjector(
                point: .afterDirectorySynchronization,
                clock: clock,
                advancedTime: grantExpiry.addingTimeInterval(1)
            ),
            grantExpiresAt: grantExpiry,
            now: { clock.read() }
        )
        await #expect(throws: HarcHostError.grantExpired) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [upload.bytes]
            )
        }
        let durableCount = try await upload.store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM staged_chunks WHERE upload_id = ? AND status = 'durable'",
                arguments: [upload.uploadID.description]
            ) ?? 0
        }
        #expect(durableCount == 0)
    }

    @Test("restart cannot ACK fsynced bytes after their grant expires")
    func restartRejectsFsyncedWritingRowAfterGrantExpiry() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let initialTime = fixture.beganAt.addingTimeInterval(3)
        let grantExpiry = fixture.beganAt.addingTimeInterval(10)
        let clock = LockedHostClock(initialTime)

        var uploadID: UploadID?
        var stagedRelativePath: String?
        do {
            let upload = try await startUpload(
                fixture: fixture,
                directory: directory,
                databaseURL: databaseURL,
                highWaterMarkStore: highWater,
                stagingInjector: ClockAdvancingCrashStagingInjector(
                    point: .afterDirectorySynchronization,
                    clock: clock,
                    advancedTime: grantExpiry.addingTimeInterval(1)
                ),
                grantExpiresAt: grantExpiry,
                now: { clock.read() }
            )
            uploadID = upload.uploadID
            await #expect(throws: InjectedHostCrash.staging(.afterDirectorySynchronization)) {
                _ = try await upload.store.stageChunk(
                    context: upload.context,
                    uploadID: upload.uploadID,
                    generation: .initial,
                    expectedUploadProfileSHA256: upload.profile.profileSHA256,
                    chunkIndex: 0,
                    claimedChunkID: upload.descriptor.chunkID,
                    declaredEncodedLength: UInt64(upload.bytes.count),
                    claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                    bodyFragments: [upload.bytes]
                )
            }
            stagedRelativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        }

        let recoveredUploadID = try #require(uploadID)
        let recoveredRelativePath = try #require(stagedRelativePath)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(recoveredRelativePath).path
        ))

        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let persistedState = try await reopened.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, durable_acknowledged_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [recoveredUploadID.description]
            )
        }
        let status: String? = persistedState?["status"]
        let acknowledgedAt: Double? = persistedState?["durable_acknowledged_at"]
        #expect(status == "rejected")
        #expect(acknowledgedAt == nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(recoveredRelativePath).path
        ))
    }

    @Test("restart cannot ACK fsynced bytes after their upload generation expires")
    func restartRejectsFsyncedWritingRowAfterGenerationExpiry() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let initialTime = fixture.beganAt.addingTimeInterval(3)
        let generationExpiry = fixture.beganAt.addingTimeInterval(
            1 + TransferLimits.uploadGenerationLifetime
        )
        let clock = LockedHostClock(initialTime)

        var uploadID: UploadID?
        var stagedRelativePath: String?
        do {
            let upload = try await startUpload(
                fixture: fixture,
                directory: directory,
                databaseURL: databaseURL,
                highWaterMarkStore: highWater,
                stagingInjector: ClockAdvancingCrashStagingInjector(
                    point: .afterDirectorySynchronization,
                    clock: clock,
                    advancedTime: generationExpiry.addingTimeInterval(1)
                ),
                now: { clock.read() }
            )
            uploadID = upload.uploadID
            await #expect(throws: InjectedHostCrash.staging(.afterDirectorySynchronization)) {
                _ = try await upload.store.stageChunk(
                    context: upload.context,
                    uploadID: upload.uploadID,
                    generation: .initial,
                    expectedUploadProfileSHA256: upload.profile.profileSHA256,
                    chunkIndex: 0,
                    claimedChunkID: upload.descriptor.chunkID,
                    declaredEncodedLength: UInt64(upload.bytes.count),
                    claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                    bodyFragments: [upload.bytes]
                )
            }
            stagedRelativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        }

        let recoveredUploadID = try #require(uploadID)
        let recoveredRelativePath = try #require(stagedRelativePath)
        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let persistedState = try await reopened.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, durable_acknowledged_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [recoveredUploadID.description]
            )
        }
        let status: String? = persistedState?["status"]
        let acknowledgedAt: Double? = persistedState?["durable_acknowledged_at"]
        #expect(status == "rejected")
        #expect(acknowledgedAt == nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(recoveredRelativePath).path
        ))
    }

    @Test("restart cannot ACK fsynced bytes authorized by a subsequently revoked grant")
    func restartRejectsFsyncedWritingRowAfterRevocation() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("HarcHost.db")
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(3))

        var uploadID: UploadID?
        var stagedRelativePath: String?
        do {
            let upload = try await startUpload(
                fixture: fixture,
                directory: directory,
                databaseURL: databaseURL,
                highWaterMarkStore: highWater,
                stagingInjector: OneShotStagingFailureInjector(.afterDirectorySynchronization),
                now: { clock.read() }
            )
            uploadID = upload.uploadID
            await #expect(throws: InjectedHostCrash.staging(.afterDirectorySynchronization)) {
                _ = try await upload.store.stageChunk(
                    context: upload.context,
                    uploadID: upload.uploadID,
                    generation: .initial,
                    expectedUploadProfileSHA256: upload.profile.profileSHA256,
                    chunkIndex: 0,
                    claimedChunkID: upload.descriptor.chunkID,
                    declaredEncodedLength: UInt64(upload.bytes.count),
                    claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                    bodyFragments: [upload.bytes]
                )
            }
            stagedRelativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
            clock.set(fixture.beganAt.addingTimeInterval(4))
            try await upload.store.revokeDevice(
                fixture.deviceID,
                revocationID: UUID(),
                reasonCode: "test.revoked-before-reopen",
                exactRevocationBytes: Data("revocation".utf8)
            )
        }

        let recoveredUploadID = try #require(uploadID)
        let recoveredRelativePath = try #require(stagedRelativePath)
        let reopened = try await HarcHostStore.onDisk(
            databaseURL: databaseURL,
            stagingRoot: directory,
            metadata: fixture.metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let persistedState = try await reopened.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status, durable_acknowledged_at FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [recoveredUploadID.description]
            )
        }
        let status: String? = persistedState?["status"]
        let acknowledgedAt: Double? = persistedState?["durable_acknowledged_at"]
        #expect(status == "rejected")
        #expect(acknowledgedAt == nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(recoveredRelativePath).path
        ))
    }

    @Test("every staging crash boundary reconciles without a false ACK")
    func crashBoundaries() async throws {
        for point in StagingFailurePoint.allCases where
            point != .beforeReapCandidateRead
                && point != .afterReapCandidateSnapshot
                && point != .afterReapCandidateClaim
                && point != .afterReapObjectDeletion
        {
            let fixture = HostTestFixture()
            let directory = try fixture.temporaryDirectory("staging-\(point.rawValue)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let injector = OneShotStagingFailureInjector(point)
            let highWater = InMemorySecurityRegistryHighWaterMarkStore()
            let databaseURL = directory.appendingPathComponent("HarcHost.db")
            let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(3))
            let upload = try await startUpload(
                fixture: fixture,
                directory: directory,
                databaseURL: databaseURL,
                highWaterMarkStore: highWater,
                stagingInjector: injector,
                now: { clock.read() }
            )
            await #expect(throws: InjectedHostCrash.staging(point)) {
                _ = try await upload.store.stageChunk(
                    context: upload.context,
                    uploadID: upload.uploadID,
                    generation: .initial,
                    expectedUploadProfileSHA256: upload.profile.profileSHA256,
                    chunkIndex: 0,
                    claimedChunkID: upload.descriptor.chunkID,
                    declaredEncodedLength: UInt64(upload.bytes.count),
                    claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                    bodyFragments: [upload.bytes]
                )
            }
            clock.set(fixture.beganAt.addingTimeInterval(4))
            let reopened = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: directory,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: { clock.read() }
            )
            let state = try await reopened.reconciliation(
                for: upload.uploadID,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                context: upload.context,
                at: fixture.beganAt.addingTimeInterval(4)
            )
            switch point {
            case .afterJournalReservation, .afterFileCreation:
                #expect(state.durableChunks.isEmpty)
                #expect(state.rejectedChunks.count == 1)
            case .afterBodyWrite, .afterFileSynchronization,
                 .afterDirectorySynchronization, .afterDatabaseAcknowledgement:
                #expect(state.durableChunks.count == 1)
                #expect(state.rejectedChunks.isEmpty)
            case .beforeReapCandidateRead, .afterReapCandidateSnapshot,
                 .afterReapCandidateClaim, .afterReapObjectDeletion:
                Issue.record("Reaper-only fault points must use their dedicated race tests")
            }
        }
    }

    @Test("symlink and traversal attacks cannot leave the generated staging namespace")
    func symlinkAndTraversal() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            stagingInjector: OneShotStagingFailureInjector(.afterJournalReservation)
        )
        await #expect(throws: InjectedHostCrash.self) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [upload.bytes],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        let relative = try #require(
            try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        )
        let victim = directory.appendingPathComponent("victim")
        try Data("do-not-touch".utf8).write(to: victim)
        let stagedURL = directory.appendingPathComponent(relative)
        try FileManager.default.createSymbolicLink(at: stagedURL, withDestinationURL: victim)
        try await upload.store.reconcileStagingJournalOnReopen()
        #expect(try Data(contentsOf: victim) == Data("do-not-touch".utf8))
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))

        try await upload.store.replaceStagingRelativePathForTesting(
            uploadID: upload.uploadID,
            chunkIndex: 0,
            relativePath: "../../victim"
        )
        try await upload.store.reconcileStagingJournalOnReopen()
        #expect(try Data(contentsOf: victim) == Data("do-not-touch".utf8))
        let state = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: fixture.beganAt.addingTimeInterval(4)
        )
        #expect(state.rejectedChunks.count == 1)
    }

    @Test("ancestor replacement cannot redirect a suspended staging write")
    func ancestorReplacementFailsClosed() async throws {
        let fixture = HostTestFixture()
        let container = try fixture.temporaryDirectory(
            "staging-ancestor-swap-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let stagingRoot = container.appendingPathComponent("staging", isDirectory: true)
        let retainedRoot = container.appendingPathComponent("retained", isDirectory: true)
        let victimRoot = container.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(
            at: victimRoot,
            withIntermediateDirectories: false
        )

        let injector = SuspendingStagingFailureInjector(.afterJournalReservation)
        let upload = try await startUpload(
            fixture: fixture,
            directory: stagingRoot,
            stagingInjector: injector
        )
        let stagingTask = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [upload.bytes],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        await injector.waitUntilSuspended()

        try FileManager.default.moveItem(at: stagingRoot, to: retainedRoot)
        try FileManager.default.createSymbolicLink(
            at: stagingRoot,
            withDestinationURL: victimRoot
        )
        await injector.release()

        await #expect(throws: HarcHostError.unsafeStagingRoot) {
            _ = try await stagingTask.value
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: victimRoot.path).isEmpty)
        #expect(try generatedObjectURLs(in: retainedRoot).isEmpty)
    }

    @Test("hard-linked staging objects are rejected without mutating either link")
    func hardLinkedObjectFailsClosed() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory(
            "staging-hardlink-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)
        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(3)
        ) else {
            Issue.record("Expected durable staging before the hard-link attack")
            return
        }

        let relativePath = try #require(
            try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        )
        let stagedURL = directory.appendingPathComponent(relativePath)
        let externalURL = directory.appendingPathComponent("outside-generated-namespace")
        try FileManager.default.linkItem(at: stagedURL, to: externalURL)

        await #expect(throws: HarcHostError.unsafeStagingPath) {
            try await upload.store.reconcileStagingJournalOnReopen()
        }
        #expect(try Data(contentsOf: stagedURL) == upload.bytes)
        #expect(try Data(contentsOf: externalURL) == upload.bytes)

        try FileManager.default.removeItem(at: externalURL)
        try await upload.store.reconcileStagingJournalOnReopen()
        #expect(try Data(contentsOf: stagedURL) == upload.bytes)
    }

    @Test("generated staging enumeration starts at zero on every reconciliation")
    func repeatedGeneratedObjectEnumeration() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory(
            "staging-repeat-enumeration-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)
        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(3)
        ) else {
            Issue.record("Expected durable staging before repeated enumeration")
            return
        }
        let relativePath = try #require(
            try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        )
        let expectedName = try HostStagingDirectory.objectName(
            forGeneratedRelativePath: relativePath
        )

        let firstNames = try upload.store.stagingDirectory.generatedObjectNames()
        let secondNames = try upload.store.stagingDirectory.generatedObjectNames()
        #expect(Set(firstNames) == [expectedName])
        #expect(Set(secondNames) == [expectedName])

        try await upload.store.reconcileStagingJournalOnReopen()
        try await upload.store.reconcileStagingJournalOnReopen()
        #expect(
            try upload.store.stagingDirectory.generatedObjectNames()
                .contains(expectedName)
        )
    }

    @Test("manifest binding stops at the PR5 precommit boundary and recovery is separate")
    func manifestPrecommitBoundary() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)
        _ = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(3)
        )
        let pcmDigest = Data(SHA256.hash(data: upload.bytes))
        let capture = try FinalizedCapture(
            producingDeviceID: fixture.deviceID,
            originRecordingID: upload.origin,
            captureStartedAt: fixture.beganAt,
            captureEndedAt: fixture.beganAt.addingTimeInterval(1),
            captureStartedMonotonicNanoseconds: 100,
            captureEndedMonotonicNanoseconds: 200,
            finalizationReason: .userStopped,
            totalCanonicalFrames: UInt64(upload.bytes.count / 2),
            totalCanonicalBytes: UInt64(upload.bytes.count),
            canonicalPCMSHA256: try CanonicalPCMHash(pcmDigest),
            discontinuities: []
        )
        let chunked = try ChunkedFinalizedCapture(capture: capture, chunks: [upload.descriptor])
        let manifestBytes = Data("opaque-pr4-manifest".utf8)
        let manifest = try OpaqueExactObjectSlot(
            kind: .recordingManifestV1,
            exactBytes: manifestBytes,
            objectSHA256: ExactObjectSHA256(Data(SHA256.hash(data: manifestBytes)))
        )
        let evidence = try ValidatedRecordingManifestEvidence(
            hostTrust: RecordingHostTrustBinding(
                libraryID: fixture.libraryID,
                hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: fixture.hostKey.publicKey
            ),
            exactManifestObject: manifest,
            uploadID: upload.uploadID,
            producingDevicePublicKey: fixture.deviceKey.publicKey,
            originRecordingID: upload.origin,
            uploadProfileSHA256: (try fixture.profile()).profileSHA256,
            finalizedCapture: chunked
        )
        let bound = try await upload.store.bindFinalManifestForPrecommit(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            evidence: evidence,
            at: fixture.beganAt.addingTimeInterval(4)
        )
        #expect(bound == .bound(missingChunkIndexes: []))
        let replay = try await upload.store.bindFinalManifestForPrecommit(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            evidence: evidence,
            at: fixture.beganAt.addingTimeInterval(5)
        )
        #expect(replay == .exactReplay(missingChunkIndexes: []))
        #expect(throws: HarcHostError.canonicalCommitUnavailableUntilPR5) {
            try upload.store.commitUploadUnavailableUntilPR5()
        }
        let recovery = try await upload.store.incompleteRemoteUploads(
            at: fixture.beganAt.addingTimeInterval(5)
        )
        #expect(recovery.count == 1)
        #expect(recovery[0].uploadID == upload.uploadID)
        #expect(recovery[0].reason == .awaitingChunks || recovery[0].reason == .manifestAwaitingChunks)
    }

    @Test("abandoned staging is retained seven days then reaped without erasing replay identity")
    func abandonedRetentionReaping() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)
        _ = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(3)
        )
        let abandonedAt = fixture.beganAt.addingTimeInterval(4)
        try await upload.store.abandonUpload(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            at: abandonedAt
        )
        #expect(try await upload.store.reapEligibleStaging(
            at: abandonedAt.addingTimeInterval(TransferLimits.abandonedStagingRetention - 1)
        ) == 0)
        #expect(try await upload.store.reapEligibleStaging(
            at: abandonedAt.addingTimeInterval(TransferLimits.abandonedStagingRetention)
        ) == 1)
        await #expect(throws: HarcHostError.self) {
            _ = try await upload.store.beginUpload(
                context: upload.context,
                sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
                request: BeginHostUploadRequest(
                    uploadID: upload.uploadID,
                    originRecordingID: upload.origin,
                    frozenProfile: try fixture.profile(),
                    beganAt: fixture.beganAt
                ),
                at: abandonedAt.addingTimeInterval(TransferLimits.abandonedStagingRetention + 1)
            )
        }
    }

    @Test("a claimed reap is aborted when the upload reopens before unlink")
    func reaperClaimDoesNotDeleteReopenedUpload() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("reaper-reopened-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let injector = SuspendingStagingFailureInjector(
            .afterReapCandidateClaim,
            initiallyArmed: false
        )
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            stagingInjector: injector
        )
        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(3)
        ) else {
            Issue.record("Expected initial durable staging")
            return
        }
        let initialState = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: fixture.beganAt.addingTimeInterval(4)
        )
        let durableRelativePath = try #require(
            try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        )

        await injector.arm()
        let reaperTask = Task {
            try await upload.store.reapEligibleStaging(
                at: initialState.generationExpiresAt.addingTimeInterval(
                    TransferLimits.abandonedStagingRetention
                )
            )
        }
        await injector.waitUntilSuspended()

        let reopenedAt = initialState.generationExpiresAt.addingTimeInterval(1)
        let reopened = try await upload.store.beginUpload(
            context: upload.context,
            sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
            request: BeginHostUploadRequest(
                uploadID: upload.uploadID,
                originRecordingID: upload.origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: reopenedAt
        )
        guard case .reopened(let reopenedState) = reopened else {
            Issue.record("Expected the snapshotted upload to reopen")
            await injector.release()
            _ = try await reaperTask.value
            return
        }
        #expect(reopenedState.generation.rawValue == 2)
        #expect(reopenedState.durableChunks.isEmpty)

        await injector.release()
        #expect(try await reaperTask.value == 0)
        let preserved = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT generated_relative_path, status FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        let preservedPath: String? = preserved?["generated_relative_path"]
        let preservedStatus: String? = preserved?["status"]
        #expect(preservedPath == durableRelativePath)
        #expect(preservedStatus == "durable")
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(durableRelativePath).path
        ))
    }

    @Test("an immediate retry after reopen exact-replays a durable pre-unlink reap claim")
    func immediatePostReopenRetryRestoresClaimedDurableChunk() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("reaper-immediate-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let injector = SuspendingStagingFailureInjector(
            .afterReapCandidateClaim,
            initiallyArmed: false
        )
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            stagingInjector: injector
        )
        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(3)
        ) else {
            Issue.record("Expected initial durable staging")
            return
        }
        let initialState = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: fixture.beganAt.addingTimeInterval(4)
        )
        let durableRelativePath = try #require(
            try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        )

        await injector.arm()
        let reaperTask = Task {
            try await upload.store.reapEligibleStaging(
                at: initialState.generationExpiresAt.addingTimeInterval(
                    TransferLimits.abandonedStagingRetention
                )
            )
        }
        await injector.waitUntilSuspended()

        let reopenedAt = initialState.generationExpiresAt.addingTimeInterval(1)
        let reopened = try await upload.store.beginUpload(
            context: upload.context,
            sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
            request: BeginHostUploadRequest(
                uploadID: upload.uploadID,
                originRecordingID: upload.origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: reopenedAt
        )
        guard case .reopened(let reopenedState) = reopened else {
            Issue.record("Expected the claimed upload to reopen")
            await injector.release()
            _ = try await reaperTask.value
            return
        }
        #expect(reopenedState.durableChunks.isEmpty)
        let preRetryStatus = try await upload.store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT status FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        #expect(preRetryStatus == "reaping")

        let retry: StagedChunkDisposition
        do {
            retry = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: reopenedState.generation,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [Data(repeating: 0xEE, count: upload.bytes.count)],
                at: reopenedAt.addingTimeInterval(1)
            )
        } catch {
            await injector.release()
            _ = try? await reaperTask.value
            throw error
        }
        guard case .exactReplay(let replay) = retry else {
            Issue.record("Expected the intact pre-unlink durable object to exact-replay")
            await injector.release()
            _ = try await reaperTask.value
            return
        }
        #expect(replay.durableChunk.chunkIndex == 0)
        #expect(try await upload.store.stagingRelativePathForTesting(
            uploadID: upload.uploadID,
            chunkIndex: 0
        ) == durableRelativePath)
        #expect(try Data(
            contentsOf: directory.appendingPathComponent(durableRelativePath)
        ) == upload.bytes)

        await injector.release()
        #expect(try await reaperTask.value == 0)
        let preservedStatus = try await upload.store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT status FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                arguments: [upload.uploadID.description]
            )
        }
        #expect(preservedStatus == "durable")
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(durableRelativePath).path
        ))
    }

    @Test("reaper compare-delete preserves a retry that replaced the removed journal path")
    func reaperCompareDeletePreservesReplacementPath() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("reaper-replacement-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let injector = SuspendingStagingFailureInjector(.afterReapObjectDeletion)
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            stagingInjector: injector
        )
        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: fixture.beganAt.addingTimeInterval(3)
        ) else {
            Issue.record("Expected initial durable staging")
            return
        }
        let initialState = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: fixture.beganAt.addingTimeInterval(4)
        )
        let oldRelativePath = try #require(
            try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        )
        let reaperTask = Task {
            try await upload.store.reapEligibleStaging(
                at: initialState.generationExpiresAt.addingTimeInterval(
                    TransferLimits.abandonedStagingRetention
                )
            )
        }
        await injector.waitUntilSuspended()
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(oldRelativePath).path
        ))

        let reopenedAt = initialState.generationExpiresAt.addingTimeInterval(1)
        let reopened = try await upload.store.beginUpload(
            context: upload.context,
            sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
            request: BeginHostUploadRequest(
                uploadID: upload.uploadID,
                originRecordingID: upload.origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: reopenedAt
        )
        guard case .reopened(let reopenedState) = reopened else {
            Issue.record("Expected the expired upload to reopen during the reaper suspension")
            await injector.release()
            _ = try await reaperTask.value
            return
        }
        #expect(reopenedState.durableChunks.isEmpty)
        #expect(try await upload.store.reapEligibleStaging(
            at: initialState.generationExpiresAt.addingTimeInterval(
                TransferLimits.abandonedStagingRetention
            )
        ) == 1)
        let stateAfterNestedReap = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: reopenedAt
        )
        #expect(stateAfterNestedReap.durableChunks.isEmpty)
        guard case .durablyAccepted = try await upload.store.stageChunk(
            context: upload.context,
            uploadID: upload.uploadID,
            generation: reopenedState.generation,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            chunkIndex: 0,
            claimedChunkID: upload.descriptor.chunkID,
            declaredEncodedLength: UInt64(upload.bytes.count),
            claimedEncodedSHA256: upload.descriptor.encodedSHA256,
            bodyFragments: [upload.bytes],
            at: reopenedAt.addingTimeInterval(1)
        ) else {
            Issue.record("Expected the retry to reserve and durably stage a replacement path")
            await injector.release()
            _ = try await reaperTask.value
            return
        }
        let replacementRelativePath = try #require(
            try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
        )
        #expect(replacementRelativePath != oldRelativePath)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(replacementRelativePath).path
        ))

        await injector.release()
        #expect(try await reaperTask.value == 0)
        #expect(try await upload.store.stagingRelativePathForTesting(
            uploadID: upload.uploadID,
            chunkIndex: 0
        ) == replacementRelativePath)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(replacementRelativePath).path
        ))
    }

    @Test("reopen repairs interrupted reap claims before and after unlink")
    func reopenRepairsInterruptedReapClaims() async throws {
        for point in [
            StagingFailurePoint.afterReapCandidateClaim,
            .afterReapObjectDeletion,
        ] {
            let fixture = HostTestFixture()
            let directory = try fixture.temporaryDirectory("reap-reopen-\(point.rawValue)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let databaseURL = directory.appendingPathComponent("HarcHost.db")
            let highWater = InMemorySecurityRegistryHighWaterMarkStore()
            let clock = LockedHostClock(fixture.beganAt.addingTimeInterval(3))
            let upload = try await startUpload(
                fixture: fixture,
                directory: directory,
                databaseURL: databaseURL,
                highWaterMarkStore: highWater,
                stagingInjector: OneShotStagingFailureInjector(point),
                now: { clock.read() }
            )
            guard case .durablyAccepted = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [upload.bytes],
                at: fixture.beganAt.addingTimeInterval(3)
            ) else {
                Issue.record("Expected durable staging before reap crash")
                continue
            }
            let initialState = try await upload.store.reconciliation(
                for: upload.uploadID,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                context: upload.context,
                at: fixture.beganAt.addingTimeInterval(4)
            )
            let relativePath = try #require(
                try await upload.store.stagingRelativePathForTesting(
                    uploadID: upload.uploadID,
                    chunkIndex: 0
                )
            )
            let reapedAt = initialState.generationExpiresAt.addingTimeInterval(
                TransferLimits.abandonedStagingRetention
            )
            clock.set(reapedAt)

            await #expect(throws: InjectedHostCrash.staging(point)) {
                _ = try await upload.store.reapEligibleStaging(at: reapedAt)
            }
            let interruptedStatus = try await upload.store.dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                    arguments: [upload.uploadID.description]
                )
            }
            #expect(interruptedStatus == "reaping")
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(relativePath).path
                ) == (point == .afterReapCandidateClaim)
            )

            let reopened = try await HarcHostStore.onDisk(
                databaseURL: databaseURL,
                stagingRoot: directory,
                metadata: fixture.metadata,
                highWaterMarkStore: highWater,
                capacityProvider: FixedHostVolumeCapacityProvider(),
                now: { clock.read() }
            )
            let repairedRowCount = try await reopened.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM staged_chunks WHERE upload_id = ? AND chunk_index = 0",
                    arguments: [upload.uploadID.description]
                ) ?? 0
            }
            #expect(repairedRowCount == 0)
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(relativePath).path
            ))
            let repairedState = try await reopened.reconciliation(
                for: upload.uploadID,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                context: upload.context,
                at: reapedAt
            )
            #expect(repairedState.durableChunks.isEmpty)
        }
    }

    @Test("reaper rechecks current active writers after its awaited candidate read boundary")
    func reaperDoesNotUnlinkWriterAdmittedDuringCandidateRead() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory("reaper-active-writer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let injector = SuspendingStagingFailureInjector(
            .beforeReapCandidateRead,
            initiallyArmed: false
        )
        let upload = try await startUpload(
            fixture: fixture,
            directory: directory,
            stagingInjector: injector
        )
        await #expect(throws: HarcHostError.encodedHashMismatch) {
            _ = try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: .initial,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                bodyFragments: [Data(repeating: 0xEE, count: upload.bytes.count)],
                at: fixture.beganAt.addingTimeInterval(3)
            )
        }
        let initialState = try await upload.store.reconciliation(
            for: upload.uploadID,
            expectedUploadProfileSHA256: upload.profile.profileSHA256,
            context: upload.context,
            at: fixture.beganAt.addingTimeInterval(4)
        )
        let reopenedAt = initialState.generationExpiresAt.addingTimeInterval(1)
        let reopened = try await upload.store.beginUpload(
            context: upload.context,
            sessionCapabilities: try fixture.sessionCapabilities(for: upload.profile),
            request: BeginHostUploadRequest(
                uploadID: upload.uploadID,
                originRecordingID: upload.origin,
                frozenProfile: try fixture.profile(),
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: reopenedAt
        )
        guard case .reopened(let reopenedState) = reopened else {
            Issue.record("Expected the expired upload to reopen")
            return
        }

        await injector.arm()
        let reaperTask = Task {
            try await upload.store.reapEligibleStaging(
                at: reopenedState.generationExpiresAt.addingTimeInterval(
                    TransferLimits.abandonedStagingRetention
                )
            )
        }
        await injector.waitUntilSuspended()

        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data(upload.bytes.prefix(4)))
        let writerTask = Task {
            try await upload.store.stageChunk(
                context: upload.context,
                uploadID: upload.uploadID,
                generation: reopenedState.generation,
                expectedUploadProfileSHA256: upload.profile.profileSHA256,
                chunkIndex: 0,
                claimedChunkID: upload.descriptor.chunkID,
                declaredEncodedLength: UInt64(upload.bytes.count),
                claimedEncodedSHA256: upload.descriptor.encodedSHA256,
                body: HostChunkBody(stream: stream),
                at: reopenedAt.addingTimeInterval(1)
            )
        }
        var activeRelativePath: String?
        var activeLength: UInt64 = 0
        for _ in 0 ..< 1_000 {
            activeRelativePath = try await upload.store.stagingRelativePathForTesting(
                uploadID: upload.uploadID,
                chunkIndex: 0
            )
            if let activeRelativePath,
               let attributes = try? FileManager.default.attributesOfItem(
                   atPath: directory.appendingPathComponent(activeRelativePath).path
               ),
               let size = attributes[.size] as? NSNumber {
                activeLength = size.uint64Value
            }
            if activeLength == 4 { break }
            await Task.yield()
        }
        let writerRelativePath = try #require(activeRelativePath)
        #expect(activeLength == 4)

        await injector.release()
        #expect(try await reaperTask.value == 0)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(writerRelativePath).path
        ))

        continuation.yield(Data(upload.bytes.dropFirst(4)))
        continuation.finish()
        guard case .durablyAccepted = try await writerTask.value else {
            Issue.record("Expected the active writer to complete after the reaper skipped it")
            return
        }
    }

    @Test("typed declaration drift fails closed before staged bytes are interpreted")
    func typedDeclarationDriftFailsClosed() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = try await startUpload(fixture: fixture, directory: directory)
        try await upload.store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chunk_declarations SET encoded_byte_length = encoded_byte_length - 1 WHERE upload_id = ?",
                arguments: [upload.uploadID.description]
            )
        }
        await #expect(throws: HarcHostError.databaseFailure(
            "Typed chunk declaration conflicts with its preserved descriptor."
        )) {
            try await upload.store.validateUploadPersistenceOnReopen()
        }
    }
}
