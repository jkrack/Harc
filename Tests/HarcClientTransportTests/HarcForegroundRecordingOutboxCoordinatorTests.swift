import CryptoKit
import Foundation
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Testing
@testable import HarcClientTransport

@Suite("Foreground recording outbox coordinator")
struct HarcForegroundRecordingOutboxCoordinatorTests {
    @Test("uploads bounded chunks in order and commits only authenticated receipt evidence")
    func orderedUploadCommitAndExactReplay() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(fixture: fixture, mode: .normal)
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )
        _ = try fixture.store.requestCleanup(
            for: fixture.plan.originRecordingID,
            requestedAt: fixture.now
        )

        let committed = try await coordinator.drive(
            fixture.plan,
            openedSession: fixture.session,
            deviceSigner: fixture.deviceKey
        )

        #expect(committed.uploadID == fixture.plan.uploadID)
        #expect(await rpc.uploadedIndexes() == [0, 1])
        #expect(await rpc.maximumObservedChunkBytes() == 4)
        #expect(try fixture.store.cleanupIntent(
            for: fixture.plan.originRecordingID
        )?.isEligible == true)
        #expect(FileManager.default.fileExists(atPath: fixture.masterURL.path))
        for chunk in fixture.plan.chunks {
            #expect(FileManager.default.fileExists(
                atPath: chunk.encodedFileURL.path
            ))
        }

        let callsBeforeReplay = await rpc.callCounts()
        let replay = try await coordinator.drive(
            fixture.plan,
            openedSession: fixture.session,
            deviceSigner: fixture.deviceKey
        )
        #expect(replay == committed)
        #expect(await rpc.callCounts() == callsBeforeReplay)
    }

    @Test("cancellation after host commit preserves exact manifest and resumes idempotently")
    func cancellationAfterCommitResumes() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(
            fixture: fixture,
            mode: .cancelFirstCommittedResponse
        )
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )

        await #expect(throws: CancellationError.self) {
            try await coordinator.drive(
                fixture.plan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        let pendingAttempt = try #require(
            try fixture.store.uploadAttempt(id: fixture.plan.uploadID)
        ).attempt
        let exactManifest = try #require(pendingAttempt.boundManifest?.exactBytes)
        #expect(try fixture.store.recordingOutbox(
            for: fixture.plan.originRecordingID
        )?.stateMachine.state == .hostCommitPending)
        #expect(try fixture.store.verifiedRecordingReceipt(
            for: fixture.plan.originRecordingID
        ) == nil)

        let committed = try await coordinator.drive(
            fixture.plan,
            openedSession: fixture.session,
            deviceSigner: fixture.deviceKey
        )
        #expect(committed.uploadID == fixture.plan.uploadID)
        #expect(await rpc.commitCallCount() == 1)
        #expect(await rpc.acceptedManifestBytes() == exactManifest)
        #expect(try fixture.store.uploadAttempt(
            id: fixture.plan.uploadID
        )?.attempt.boundManifest?.exactBytes == exactManifest)
    }

    @Test("valid response for another request cannot advance durable state")
    func crossRequestResponseFailsClosed() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(
            fixture: fixture,
            mode: .wrongBeginUploadID
        )
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )

        await #expect(throws: HarcForegroundRecordingOutboxError.self) {
            try await coordinator.drive(
                fixture.plan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        #expect(try fixture.store.uploadAttempt(id: fixture.plan.uploadID) == nil)
        #expect(try fixture.store.verifiedRecordingReceipt(
            for: fixture.plan.originRecordingID
        ) == nil)
        #expect(try fixture.store.recordingOutbox(
            for: fixture.plan.originRecordingID
        )?.stateMachine.state == .securityBlocked)
        #expect(FileManager.default.fileExists(atPath: fixture.masterURL.path))
    }

    @Test("structural receipt with invalid host signature never opens cleanup gate")
    func invalidReceiptSignatureFailsClosed() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(
            fixture: fixture,
            mode: .invalidReceiptSignature
        )
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )
        _ = try fixture.store.requestCleanup(
            for: fixture.plan.originRecordingID
        )

        await #expect(throws: HarcForegroundRecordingOutboxError.self) {
            try await coordinator.drive(
                fixture.plan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        #expect(try fixture.store.verifiedRecordingReceipt(
            for: fixture.plan.originRecordingID
        ) == nil)
        #expect(try fixture.store.cleanupIntent(
            for: fixture.plan.originRecordingID
        )?.isEligible == false)
        #expect(try fixture.store.recordingOutbox(
            for: fixture.plan.originRecordingID
        )?.stateMachine.state == .securityBlocked)
        #expect(FileManager.default.fileExists(atPath: fixture.masterURL.path))
        for chunk in fixture.plan.chunks {
            #expect(FileManager.default.fileExists(
                atPath: chunk.encodedFileURL.path
            ))
        }
    }

    @Test("lost Begin response resumes from durable intent under additive capabilities")
    func lostBeginResponseResumesFromDurableIntent() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(
            fixture: fixture,
            mode: .loseFirstBeginResponse,
            generationLifetime: 60
        )
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )

        await #expect(throws: ForegroundRecordingRPCFakeError.self) {
            try await coordinator.drive(
                fixture.plan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        let intent = try #require(
            try fixture.store.uploadBeginIntent(
                for: fixture.plan.originRecordingID
            )
        )
        #expect(intent.intent.uploadID == fixture.plan.uploadID)
        #expect(!intent.intent.exactBeginRequest.isEmpty)
        #expect(try fixture.store.uploadAttempt(id: fixture.plan.uploadID) == nil)
        #expect(try fixture.store.recordingOutbox(
            for: fixture.plan.originRecordingID
        )?.stateMachine.state == .failedRecoverable)

        let competingPlan = try fixture.plan(
            uploadID: UploadID(
                UUID(uuidString: "a9999999-6666-7777-8888-999999999999")!
            )
        )
        let competingCoordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )
        await #expect(throws: ClientStoreError.self) {
            try await competingCoordinator.drive(
                competingPlan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        #expect(await rpc.beginCallCount() == 1)

        let committed = try await coordinator.drive(
            fixture.plan,
            openedSession: try fixture.additiveSession(),
            deviceSigner: fixture.deviceKey
        )
        #expect(committed.uploadID == fixture.plan.uploadID)
        #expect(await rpc.beginCallCount() == 2)
        let recovered = try #require(
            try fixture.store.uploadAttempt(id: fixture.plan.uploadID)
        ).attempt
        #expect(recovered.firstBeganAt == fixture.now)
        #expect(recovered.generationBeganAt == fixture.now)
        #expect(recovered.generationExpiresAt
            == fixture.now.addingTimeInterval(60))
    }

    @Test("one coordinator serializes all upload IDs for an origin")
    func originLevelActorGate() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(
            fixture: fixture,
            mode: .holdFirstBegin
        )
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )
        let first = Task {
            try await coordinator.drive(
                fixture.plan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        await rpc.waitUntilBeginIsHeld()

        let competingPlan = try fixture.plan(
            uploadID: UploadID(
                UUID(uuidString: "a8888888-6666-7777-8888-999999999999")!
            )
        )
        do {
            _ = try await coordinator.drive(
                competingPlan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
            Issue.record("A second upload ID entered the same origin gate.")
        } catch let error as HarcForegroundRecordingOutboxError {
            #expect(error == .uploadAlreadyRunning(competingPlan.uploadID))
        } catch {
            Issue.record("Unexpected origin-gate error: \(error)")
        }

        await rpc.releaseHeldBegin()
        _ = try await first.value
    }

    @Test("file validation failure leaves the active chunk recoverable from ready")
    func fileFailureMakesChunkRecoverable() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data([0xff]).write(to: fixture.plan.chunks[0].encodedFileURL)
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: ForegroundRecordingRPCFake(
                fixture: fixture,
                mode: .normal
            ),
            now: { fixture.now }
        )

        await #expect(throws: HarcForegroundRecordingOutboxError.self) {
            try await coordinator.drive(
                fixture.plan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        let firstChunk = try #require(
            try fixture.store.chunks(uploadID: fixture.plan.uploadID).first
        )
        #expect(firstChunk.stateMachine.state == .failedRecoverable)
        #expect(firstChunk.stateMachine.retryPoint == .ready)
        #expect(firstChunk.stateMachine.failure?.code
            == "foreground-chunk-failed")
        #expect(try fixture.store.recordingOutbox(
            for: fixture.plan.originRecordingID
        )?.stateMachine.state == .failedRecoverable)
    }

    @Test("transport failure leaves the active chunk recoverable from ready")
    func transportFailureMakesChunkRecoverable() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(
            fixture: fixture,
            mode: .failFirstChunkTransport
        )
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )

        await #expect(throws: ForegroundRecordingRPCFakeError.self) {
            try await coordinator.drive(
                fixture.plan,
                openedSession: fixture.session,
                deviceSigner: fixture.deviceKey
            )
        }
        let firstChunk = try #require(
            try fixture.store.chunks(uploadID: fixture.plan.uploadID).first
        )
        #expect(firstChunk.stateMachine.state == .failedRecoverable)
        #expect(firstChunk.stateMachine.retryPoint == .ready)
        #expect(firstChunk.stateMachine.failure?.code
            == "foreground-chunk-failed")
        #expect(await rpc.uploadCallCount() == 1)
    }

    @Test("sub-millisecond clocks are floored once for manifest wire time")
    func subMillisecondManifestClock() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(fixture: fixture, mode: .normal)
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now.addingTimeInterval(0.000_987) }
        )

        _ = try await coordinator.drive(
            fixture.plan,
            openedSession: fixture.session,
            deviceSigner: fixture.deviceKey
        )
        let exactManifest = try #require(await rpc.acceptedManifestBytes())
        let signed = try HarcSignedObjectV1.decode(exactManifest)
        let payload = try HarcExactProtobufPayload(
            decoding: signed.exactPayloadBytes,
            as: Harc_V1_RecordingManifestV1.self
        ).message
        #expect(payload.issuedAtUnixMs
            == ForegroundCoordinatorFixture.nowMilliseconds)
    }

    @Test("physical capture clocks canonicalize to signed wire milliseconds")
    func physicalCaptureClockPrecision() async throws {
        let fixture = try ForegroundCoordinatorFixture(
            highPrecisionCaptureDates: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(fixture: fixture, mode: .normal)
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )

        _ = try await coordinator.drive(
            fixture.plan,
            openedSession: fixture.session,
            deviceSigner: fixture.deviceKey
        )

        let exactManifest = try #require(await rpc.acceptedManifestBytes())
        let signed = try HarcSignedObjectV1.decode(exactManifest)
        let payload = try HarcExactProtobufPayload(
            decoding: signed.exactPayloadBytes,
            as: Harc_V1_RecordingManifestV1.self
        ).message
        #expect(payload.captureStartedAtUnixMs == UInt64(
            (fixture.capture.captureStartedAt.timeIntervalSince1970 * 1_000)
                .rounded()
        ))
        #expect(payload.captureEndedAtUnixMs == UInt64(
            (fixture.capture.captureEndedAt.timeIntervalSince1970 * 1_000)
                .rounded()
        ))
        #expect(payload.discontinuities.first?.wallTimeUnixMs == UInt64(
            (fixture.capture.discontinuities[0].wallTime.timeIntervalSince1970
                * 1_000).rounded()
        ))
    }

    @Test("background scheduling mints exact batch capability and preserves local files")
    func backgroundScheduling() async throws {
        let fixture = try ForegroundCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = ForegroundRecordingRPCFake(fixture: fixture, mode: .normal)
        let scheduler = ForegroundBackgroundSchedulerFake()
        let coordinator = HarcForegroundRecordingOutboxCoordinator(
            store: fixture.store,
            transport: rpc,
            now: { fixture.now }
        )

        let result = try await coordinator.scheduleInBackground(
            fixture.plan,
            openedSession: fixture.session,
            deviceSigner: fixture.deviceKey,
            batchPreparer: ForegroundBackgroundBatchPreparerFake(
                root: fixture.root
            ),
            scheduler: scheduler
        )

        guard case .scheduled(let identities) = result else {
            Issue.record("expected system background scheduling")
            return
        }
        #expect(identities.map(\.taskIdentifier) == [700])
        #expect(await rpc.mintCallCount() == 1)
        #expect(await rpc.uploadCallCount() == 0)
        let plans = await scheduler.plans()
        #expect(plans.count == 1)
        #expect(plans.first?.descriptor.chunks
            == fixture.plan.chunks.map(\.descriptor))
        #expect(try fixture.store.recordingOutbox(
            for: fixture.plan.originRecordingID
        )?.stateMachine.state == .backgroundScheduled)
        #expect(try fixture.store.chunks(
            uploadID: fixture.plan.uploadID
        ).map(\.stateMachine.state) == [.scheduled, .scheduled])
        let scheduledPlan = try #require(plans.first)
        try fixture.store.persistBackgroundBatch(
            scheduledPlan.descriptor,
            bodyFileURL: scheduledPlan.bodyFileURL,
            capability: scheduledPlan.capability
        )
        try fixture.store.persistTaskMappingBeforeResume(
            identities[0],
            batchID: scheduledPlan.descriptor.batchID
        )
        let replay = try await coordinator.scheduleInBackground(
            fixture.plan,
            openedSession: fixture.session,
            deviceSigner: fixture.deviceKey,
            batchPreparer: ForegroundBackgroundBatchPreparerFake(
                root: fixture.root
            ),
            scheduler: scheduler
        )
        guard case .scheduled(let replayIdentities) = replay else {
            Issue.record("expected active system task replay")
            return
        }
        #expect(replayIdentities == identities)
        #expect(await rpc.mintCallCount() == 1)
        #expect(await scheduler.plans().count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.masterURL.path))
        for chunk in fixture.plan.chunks {
            #expect(FileManager.default.fileExists(
                atPath: chunk.encodedFileURL.path
            ))
        }
    }
}

private struct ForegroundBackgroundBatchPreparerFake:
    HarcBackgroundAudioBatchPreparingV1, Sendable
{
    let root: URL

    func prepareBatches(
        plan: HarcForegroundRecordingUploadPlan,
        generation: UploadGeneration,
        chunks: [HarcForegroundEncodedChunk]
    ) async throws -> [HarcPreparedBackgroundAudioBatchV1] {
        var body = Data("HARCAB1-fixture".utf8)
        body.append(Data(repeating: 0x41, count: 64 - body.count))
        let bodyURL = root.appendingPathComponent("fixture.harcab1")
            .standardizedFileURL
        try body.write(to: bodyURL)
        let descriptor = try ImmutableAudioBatchDescriptor(
            batchID: AudioBatchID(
                UUID(uuidString: "ab111111-2222-3333-4444-555555555555")!
            ),
            uploadID: plan.uploadID,
            generation: generation,
            uploadProfileSHA256: plan.frozenProfile.profileSHA256,
            originRecordingID: plan.originRecordingID,
            ownerDeviceID: plan.originRecordingID.deviceID,
            chunks: chunks.map(\.descriptor),
            exactBodyByteLength: UInt64(body.count),
            exactBodySHA256: try ImmutableBatchSHA256(
                Data(SHA256.hash(data: body))
            )
        )
        return [try HarcPreparedBackgroundAudioBatchV1(
            descriptor: descriptor,
            bodyFileURL: bodyURL
        )]
    }
}

private actor ForegroundBackgroundSchedulerFake:
    HarcBackgroundUploadSchedulingV1
{
    private var captured: [HarcBackgroundUploadSchedulingPlanV1] = []

    func schedule(
        _ plan: HarcBackgroundUploadSchedulingPlanV1
    ) async throws -> SystemBackgroundTaskIdentity {
        captured.append(plan)
        return try SystemBackgroundTaskIdentity(
            taskIdentifier: 700 + captured.count - 1
        )
    }

    func plans() -> [HarcBackgroundUploadSchedulingPlanV1] { captured }
}

private final class ForegroundCoordinatorStorageAttributes:
    ClientStoreStorageAttributeApplying, @unchecked Sendable {
    func isProtectedDataAvailable(
        for _: ClientStoreStoragePolicy
    ) -> Bool { true }

    func applyAndVerify(
        _ policy: ClientStoreStoragePolicy,
        to artifact: ClientStoreStorageArtifact
    ) throws {
        _ = policy
        _ = artifact
    }
}

private struct ForegroundCoordinatorFixture: @unchecked Sendable {
    static let nowMilliseconds: UInt64 = 2_000_000_000_000

    let root: URL
    let now: Date
    let masterURL: URL
    let deviceKey: SoftwareP256SigningKey
    let hostKey: SoftwareP256SigningKey
    let hostTrust: RecordingHostTrustBinding
    let negotiated: HarcValidatedNegotiatedCapabilitiesV1
    let profile: FrozenUploadProfile
    let capture: FinalizedCapture
    let plan: HarcForegroundRecordingUploadPlan
    let adoption: ValidatedClientAdoptionEvidence
    let session: HarcOpenedClientSession
    let store: HarcTransferStore

    init(highPrecisionCaptureDates: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-foreground-outbox-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        masterURL = root.appendingPathComponent("master.pcm")
        now = Self.date(Self.nowMilliseconds)
        deviceKey = SoftwareP256SigningKey()
        hostKey = SoftwareP256SigningKey()
        let libraryID = LibraryID(
            UUID(uuidString: "a1111111-2222-3333-4444-555555555555")!
        )
        hostTrust = try RecordingHostTrustBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey
        )
        negotiated = try Self.negotiatedCapabilities()
        profile = try Self.frozenProfile(negotiated: negotiated)

        let origin = OriginRecordingID(
            deviceID: deviceKey.publicKey.deviceID,
            recordingUUID: UUID(
                uuidString: "a2222222-3333-4444-5555-666666666666"
            )!
        )
        let firstBytes = Data([0x01, 0x02, 0x03, 0x04])
        let secondBytes = Data([0x05, 0x06, 0x07, 0x08])
        let canonicalBytes = firstBytes + secondBytes
        let capturePrecisionOffset = highPrecisionCaptureDates
            ? 0.000_417
            : 0
        let captureStartedAt = Self.date(
            Self.nowMilliseconds - 100_000
        ).addingTimeInterval(capturePrecisionOffset)
        let captureEndedAt = Self.date(
            Self.nowMilliseconds - 90_000
        ).addingTimeInterval(capturePrecisionOffset)
        let discontinuities = highPrecisionCaptureDates
            ? [try CaptureDiscontinuity(
                recordingID: origin,
                monotonicTimeNanoseconds: 1_500,
                wallTime: Self.date(
                    Self.nowMilliseconds - 95_000
                ).addingTimeInterval(capturePrecisionOffset),
                reason: .routeChanged,
                affectedFrames: CanonicalFrameRange(
                    startFrame: 2,
                    endFrameExclusive: 2
                ),
                canonicalizationPolicy: .annotateGapWithoutInsertedSilence
            )]
            : []
        capture = try FinalizedCapture(
            producingDeviceID: origin.deviceID,
            originRecordingID: origin,
            captureStartedAt: captureStartedAt,
            captureEndedAt: captureEndedAt,
            captureStartedMonotonicNanoseconds: 1_000,
            captureEndedMonotonicNanoseconds: 2_000,
            finalizationReason: .userStopped,
            totalCanonicalFrames: 4,
            totalCanonicalBytes: 8,
            canonicalPCMSHA256: try CanonicalPCMHash(
                Data(SHA256.hash(data: canonicalBytes))
            ),
            discontinuities: discontinuities
        )
        let chunkBytes = [firstBytes, secondBytes]
        var plannedChunks: [HarcForegroundEncodedChunk] = []
        for index in 0 ..< chunkBytes.count {
            let bytes = chunkBytes[index]
            let digest = Data(SHA256.hash(data: bytes))
            let descriptor = try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: ChunkID(
                    index == 0
                        ? UUID(uuidString: "a3333333-4444-5555-6666-777777777777")!
                        : UUID(uuidString: "a4444444-5555-6666-7777-888888888888")!
                ),
                chunkIndex: UInt32(index),
                canonicalStartFrame: UInt64(index * 2),
                canonicalFrameCount: 2,
                encoding: .rawPCMFixture,
                encodedByteLength: UInt64(bytes.count),
                encodedSHA256: try EncodedChunkSHA256(digest),
                canonicalDecodedByteLength: UInt64(bytes.count),
                canonicalDecodedSHA256: try CanonicalPCMHash(digest)
            )
            let fileURL = root.appendingPathComponent("chunk-\(index).pcm")
            try bytes.write(to: fileURL)
            plannedChunks.append(
                try HarcForegroundEncodedChunk(
                    descriptor: descriptor,
                    encodedFileURL: fileURL
                )
            )
        }
        let tuple = AdoptedTrustTuple(
            libraryID: libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID
        )
        plan = try HarcForegroundRecordingUploadPlan(
            trustTuple: tuple,
            uploadID: UploadID(
                UUID(uuidString: "a5555555-6666-7777-8888-999999999999")!
            ),
            originRecordingID: origin,
            frozenProfile: profile,
            chunks: plannedChunks
        )

        let grantClaims = try DeviceGrantClaims(
            libraryID: libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID,
            grantID: GrantID(
                UUID(uuidString: "a6666666-7777-8888-9999-aaaaaaaaaaaa")!
            ),
            devicePublicKey: deviceKey.publicKey,
            scopes: [.recordingUploadOwn],
            grantEpoch: .initial,
            issuedAt: Self.date(Self.nowMilliseconds - 10_000),
            expiresAt: Self.date(
                Self.nowMilliseconds + 40 * 86_400_000
            ),
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        let grant = try ValidatedDeviceGrantEvidence(
            hostTrust: hostTrust,
            claims: grantClaims,
            status: .active,
            exactSignedBytes: Data([0x31, 0x32])
        )
        adoption = try ValidatedClientAdoptionEvidence(
            hostTrust: hostTrust,
            transportSet: ValidatedTransportSetEvidence(
                hostTrust: hostTrust,
                epoch: 1,
                exactSignedBytes: Data([0x21, 0x22])
            ),
            grant: grant,
            adoptedAt: Self.date(Self.nowMilliseconds - 9_000)
        )
        let credential = Data([0x01])
            + Data(repeating: 0x41, count: 15)
            + Data(repeating: 0x42, count: 32)
        session = HarcOpenedClientSession(
            credential: credential,
            authorizationHeader: try HarcBootstrapAuthorization.sessionHeader(
                credential: credential
            ),
            issuedAtUnixMilliseconds: Self.nowMilliseconds - 1_000,
            expiresAtUnixMilliseconds: Self.nowMilliseconds + 1_800_000,
            serverTimeUnixMilliseconds: Self.nowMilliseconds,
            grant: grant,
            negotiatedCapabilities: negotiated,
            tlsSPKISHA256: Data(repeating: 0x51, count: 32)
        )
        store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: ForegroundCoordinatorStorageAttributes(),
            now: { Self.date(Self.nowMilliseconds) }
        )
        _ = try store.adopt(adoption)
        try canonicalBytes.write(to: masterURL)
        _ = try store.persistFinalizedCapture(
            capture,
            masterFileURL: masterURL,
            persistedAt: now
        )
    }

    private static func negotiatedCapabilities(
        additive: Bool = false
    )
        throws -> HarcValidatedNegotiatedCapabilitiesV1 {
        let additiveFeature = "library.search.v1"
        let policy = try HarcCapabilityPolicyV1(
            supportedFeatureIDs: additive
                ? [additiveFeature, "transfer.chunk.v1"]
                : ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: [ChunkDescriptorSchema.v1.rawValue],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
        var value = Harc_V1_NegotiatedCapabilitiesV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.selectedFeatureIds = additive
            ? [additiveFeature, "transfer.chunk.v1"]
            : ["transfer.chunk.v1"]
        value.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        value.encoding = Harc_V1_LosslessEncodingConfigurationV1(
            .rawPCMFixture
        )
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        return try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: value,
            policy: policy
        )
    }

    private static func frozenProfile(
        negotiated: HarcValidatedNegotiatedCapabilitiesV1
    ) throws -> FrozenUploadProfile {
        let protocolVersion = try TransferProtocolVersion(minor: 0)
        let capability = try TransferCapabilityID("transfer.chunk.v1")
        let negotiatedDigest = try NegotiatedCapabilitiesSHA256(
            negotiated.exactSHA256
        )
        let provisional = try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: .rawPCMFixture,
            requiredCapabilities: [capability],
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                Data(repeating: 0, count: 32)
            ),
            purpose: .fixtureLoopback
        )
        let exact = try HarcExactProtobufPayload(
            serializingOnce: Harc_V1_UploadProfileV1(provisional)
        )
        return try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: .rawPCMFixture,
            requiredCapabilities: [capability],
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                HarcSignedEnvelopeV1.payloadDigest(exact.exactBytes)
            ),
            purpose: .fixtureLoopback
        )
    }

    static func date(_ milliseconds: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    func plan(uploadID: UploadID) throws -> HarcForegroundRecordingUploadPlan {
        try HarcForegroundRecordingUploadPlan(
            trustTuple: plan.trustTuple,
            uploadID: uploadID,
            originRecordingID: plan.originRecordingID,
            frozenProfile: plan.frozenProfile,
            chunks: plan.chunks
        )
    }

    func additiveSession() throws -> HarcOpenedClientSession {
        let capabilities = try Self.negotiatedCapabilities(additive: true)
        return HarcOpenedClientSession(
            credential: session.credential,
            authorizationHeader: session.authorizationHeader,
            issuedAtUnixMilliseconds: session.issuedAtUnixMilliseconds,
            expiresAtUnixMilliseconds: session.expiresAtUnixMilliseconds,
            serverTimeUnixMilliseconds: session.serverTimeUnixMilliseconds,
            grant: session.grant,
            negotiatedCapabilities: capabilities,
            tlsSPKISHA256: session.tlsSPKISHA256
        )
    }
}

private enum ForegroundRecordingRPCMode: Equatable, Sendable {
    case normal
    case cancelFirstCommittedResponse
    case wrongBeginUploadID
    case invalidReceiptSignature
    case loseFirstBeginResponse
    case holdFirstBegin
    case failFirstChunkTransport
}

private enum ForegroundRecordingRPCFakeError: Error {
    case unsupported
    case invalidRequest
    case lostResponse
}

private actor ForegroundRecordingRPCFake:
    HarcRecordingTransferRPCTransport {
    private let fixture: ForegroundCoordinatorFixture
    private let mode: ForegroundRecordingRPCMode
    private let generation = UploadGeneration.initial
    private let expiresAt: Date
    private var began = false
    private var declarations: [LogicalChunkDescriptor] = []
    private var durable: [UInt32: DurableChunkStatus] = [:]
    private var exactManifest: Data?
    private var receipt: OpaqueExactObjectSlot?
    private var didCancelCommittedResponse = false
    private var beginCalls = 0
    private var declareCalls = 0
    private var uploadCalls = 0
    private var reconcileCalls = 0
    private var commitCalls = 0
    private var statusCalls = 0
    private var mintCalls = 0
    private var uploadOrder: [UInt32] = []
    private var maximumChunkBytes = 0
    private var heldBeginContinuation: CheckedContinuation<Void, Never>?

    init(
        fixture: ForegroundCoordinatorFixture,
        mode: ForegroundRecordingRPCMode,
        generationLifetime: TimeInterval = TransferLimits.uploadGenerationLifetime
    ) {
        self.fixture = fixture
        self.mode = mode
        self.expiresAt = fixture.now.addingTimeInterval(
            generationLifetime
        )
    }

    func beginUpload(
        _ request: Harc_V1_BeginUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_BeginUploadResponseV1 {
        beginCalls += 1
        let validated = try HarcValidatedBeginUploadRequestV1(request)
        guard validated.uploadID == fixture.plan.uploadID else {
            throw ForegroundRecordingRPCFakeError.invalidRequest
        }
        if mode == .wrongBeginUploadID {
            let otherUploadID = UploadID(
                UUID(uuidString: "afffffff-eeee-dddd-cccc-bbbbbbbbbbbb")!
            )
            let wrong = try UploadReconciliation(
                uploadID: otherUploadID,
                ownerDeviceID: validated.producingDeviceID,
                originRecordingID: validated.originRecordingID,
                uploadProfileSHA256: validated.frozenProfile.profileSHA256,
                generation: generation,
                firstBeganAt: fixture.now,
                generationBeganAt: fixture.now,
                generationExpiresAt: expiresAt,
                declarations: [],
                boundManifestObjectSHA256: nil,
                durableChunks: [],
                rejectedChunks: [],
                terminalReason: nil,
                existingReceipt: nil
            )
            return try beginResponse(
                uploadID: otherUploadID,
                profileSHA256: validated.frozenProfile.profileSHA256,
                disposition: .beginUploadDispositionCreated,
                reconciliation: wrong,
                receipt: nil
            )
        }
        if let receipt {
            return try beginResponse(
                uploadID: validated.uploadID,
                profileSHA256: validated.frozenProfile.profileSHA256,
                disposition: .beginUploadDispositionAlreadyCommitted,
                reconciliation: nil,
                receipt: receipt
            )
        }
        let disposition: Harc_V1_BeginUploadDispositionV1 = began
            ? .beginUploadDispositionExactReplay
            : .beginUploadDispositionCreated
        began = true
        let response = try beginResponse(
            uploadID: validated.uploadID,
            profileSHA256: validated.frozenProfile.profileSHA256,
            disposition: disposition,
            reconciliation: try reconciliation(),
            receipt: nil
        )
        if mode == .loseFirstBeginResponse, beginCalls == 1 {
            throw ForegroundRecordingRPCFakeError.lostResponse
        }
        if mode == .holdFirstBegin, beginCalls == 1 {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                heldBeginContinuation = continuation
            }
        }
        return response
    }

    func declareChunks(
        _ request: Harc_V1_DeclareChunksRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_DeclareChunksResponseV1 {
        declareCalls += 1
        let validated = try HarcValidatedDeclareChunksRequestV1(request)
        guard validated.uploadID == fixture.plan.uploadID,
              validated.generation == generation else {
            throw ForegroundRecordingRPCFakeError.invalidRequest
        }
        let firstIndex = UInt32(declarations.count)
        declarations.append(contentsOf: validated.descriptors)
        var response = Harc_V1_DeclareChunksResponseV1()
        response.protocol = validated.protocolVersion.protobufV1()
        response.uploadID = Harc_V1_UploadIDV1(validated.uploadID)
        response.uploadGeneration = generation.rawValue
        response.disposition = .chunkDeclarationDispositionAppended
        response.firstAppendedIndex = firstIndex
        response.appendedCount = UInt32(validated.descriptors.count)
        return response
    }

    func uploadChunks(
        authorization _: HarcRecordingTransferAuthorization,
        requestProducer: @escaping HarcUploadChunkRequestProducer,
        responseConsumer: @escaping HarcUploadChunkResponseConsumer
    ) async throws {
        uploadCalls += 1
        if mode == .failFirstChunkTransport, uploadCalls == 1 {
            throw ForegroundRecordingRPCFakeError.lostResponse
        }
        let writer = HarcUploadChunkRequestWriter { request in
            let response = try await self.acceptChunk(request)
            try await responseConsumer(response)
        }
        try await requestProducer(writer)
    }

    private func acceptChunk(
        _ request: Harc_V1_UploadChunkRequestV1
    ) throws -> Harc_V1_UploadChunkResponseV1 {
        let validated = try HarcValidatedUploadChunkRequestV1(request)
        guard validated.uploadID == fixture.plan.uploadID,
              validated.generation == generation,
              let descriptor = declarations.first(where: {
                $0.chunkIndex == validated.chunkIndex
              }), descriptor.chunkID == validated.chunkID,
              descriptor.encodedSHA256 == validated.encodedSHA256,
              Data(SHA256.hash(data: validated.encodedChunk))
                == validated.encodedSHA256.rawBytes else {
            throw ForegroundRecordingRPCFakeError.invalidRequest
        }
        let durableChunk = DurableChunkStatus(
            chunkIndex: validated.chunkIndex,
            chunkID: validated.chunkID,
            encodedSHA256: validated.encodedSHA256
        )
        durable[validated.chunkIndex] = durableChunk
        uploadOrder.append(validated.chunkIndex)
        maximumChunkBytes = max(
            maximumChunkBytes,
            validated.encodedChunk.count
        )
        var acknowledgement = Harc_V1_ChunkAckV1()
        acknowledgement.protocol = validated.protocolVersion.protobufV1()
        acknowledgement.uploadID = Harc_V1_UploadIDV1(validated.uploadID)
        acknowledgement.uploadGeneration = generation.rawValue
        acknowledgement.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: validated.uploadProfileSHA256.rawBytes
        )
        acknowledgement.durableChunk = try Harc_V1_DurableChunkV1(
            durableChunk
        )
        acknowledgement.durableAtUnixMs =
            ForegroundCoordinatorFixture.nowMilliseconds + 5_000
        var response = Harc_V1_UploadChunkResponseV1()
        response.protocol = validated.protocolVersion.protobufV1()
        response.result = .acknowledgement(acknowledgement)
        return response
    }

    func reconcileUpload(
        _ request: Harc_V1_ReconcileUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_ReconcileUploadResponseV1 {
        reconcileCalls += 1
        let validated = try HarcValidatedReconcileUploadRequestV1(request)
        guard validated.uploadID == fixture.plan.uploadID else {
            throw ForegroundRecordingRPCFakeError.invalidRequest
        }
        return try Harc_V1_ReconcileUploadResponseV1(
            reconciliation(),
            protocolVersion: validated.protocolVersion
        )
    }

    func commitUpload(
        _ request: Harc_V1_CommitUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_CommitUploadResponseV1 {
        commitCalls += 1
        let validated = try HarcValidatedCommitUploadRequestV1(request)
        guard validated.uploadID == fixture.plan.uploadID,
              durable.count == declarations.count else {
            throw ForegroundRecordingRPCFakeError.invalidRequest
        }
        if receipt == nil {
            exactManifest = validated.exactSignedRecordingManifest
            let codec = HarcRecordingEvidenceCodecV1()
            let manifest = try codec.validateRecordingManifest(
                exactSignedManifestBytes: validated.exactSignedRecordingManifest,
                hostTrust: fixture.hostTrust,
                producingDevicePublicKey: fixture.deviceKey.publicKey
            )
            let claims = try RecordingReceiptClaims(
                validatedManifest: manifest,
                canonicalRecordingID: CanonicalRecordingID(
                    UUID(uuidString: "a7777777-8888-9999-aaaa-bbbbbbbbbbbb")!
                ),
                canonicalRevision: .initial,
                changeCursor: ChangeCursor(1),
                receiptID: UUID(
                    uuidString: "a8888888-9999-aaaa-bbbb-cccccccccccc"
                )!,
                durableCommitTime: ForegroundCoordinatorFixture.date(
                    ForegroundCoordinatorFixture.nowMilliseconds + 20_000
                )
            )
            if mode == .invalidReceiptSignature {
                receipt = try codec.issueRecordingReceipt(
                    claims: claims,
                    hostAuthoritySigner: ForegroundInvalidSignatureSigner(
                        declaredPublicKey: fixture.hostKey.publicKey,
                        signingKey: SoftwareP256SigningKey()
                    )
                )
            } else {
                receipt = try codec.issueRecordingReceipt(
                    claims: claims,
                    hostAuthoritySigner: fixture.hostKey
                )
            }
        }
        if mode == .cancelFirstCommittedResponse,
           !didCancelCommittedResponse {
            didCancelCommittedResponse = true
            throw CancellationError()
        }
        var response = Harc_V1_CommitUploadResponseV1()
        response.protocol = validated.protocolVersion.protobufV1()
        response.disposition = .commitUploadDispositionCommitted
        guard let receipt else {
            throw ForegroundRecordingRPCFakeError.invalidRequest
        }
        response.exactSignedRecordingReceipt = Harc_V1_ExactSignedObjectV1(
            receipt
        )
        return response
    }

    func getRecordingStatus(
        _ request: Harc_V1_GetRecordingStatusRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_GetRecordingStatusResponseV1 {
        statusCalls += 1
        let validated = try HarcValidatedGetRecordingStatusRequestV1(request)
        guard validated.recordingKey == .uploadID(fixture.plan.uploadID) else {
            throw ForegroundRecordingRPCFakeError.invalidRequest
        }
        var response = Harc_V1_GetRecordingStatusResponseV1()
        response.protocol = validated.protocolVersion.protobufV1()
        response.uploadID = Harc_V1_UploadIDV1(fixture.plan.uploadID)
        response.originRecordingID = Harc_V1_OriginRecordingIDV1(
            fixture.plan.originRecordingID
        )
        if let receipt {
            response.ingestState = .recordingIngestStateReceipted
            response.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
                CanonicalRecordingID(
                    UUID(uuidString: "a7777777-8888-9999-aaaa-bbbbbbbbbbbb")!
                )
            )
            response.canonicalRecordingRevision = EntityRevision.initial.rawValue
            response.exactRecordingReceipt = Harc_V1_ExactSignedObjectV1(receipt)
        } else {
            response.ingestState = .recordingIngestStateReceiving
        }
        return response
    }

    func abandonUpload(
        _: Harc_V1_AbandonUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_AbandonUploadResponseV1 {
        throw ForegroundRecordingRPCFakeError.unsupported
    }

    func mintBackgroundUploadAuthorization(
        _ request: Harc_V1_MintBackgroundCapabilityRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_MintBackgroundCapabilityResponseV1 {
        mintCalls += 1
        let validated = try HarcValidatedMintBackgroundCapabilityRequestV1(
            request
        )
        let issuedAt = ForegroundCoordinatorFixture.nowMilliseconds
        let transportSet = try VerifiedHostTransportSetV1.issue(
            libraryID: fixture.hostTrust.libraryID,
            hostAuthorityID: fixture.hostTrust.hostAuthorityID,
            setEpoch: 1,
            issuedAtUnixMilliseconds: issuedAt,
            entries: [
                try HostTransportEntryV1(
                    tlsSPKISHA256: fixture.session.tlsSPKISHA256,
                    notBeforeUnixMilliseconds: issuedAt - 1_000,
                    notAfterUnixMilliseconds: issuedAt + 86_400_000
                ),
            ],
            using: fixture.hostKey
        )
        let path = "/v1/uploads/\(validated.uploadID)/batches/\(validated.batchID)"
        var exactTransportSet = Harc_V1_ExactSignedObjectV1()
        exactTransportSet.framedBytes = transportSet.exactSignedBytes
        var response = Harc_V1_MintBackgroundCapabilityResponseV1()
        response.protocol = validated.protocolVersion.protobufV1()
        response.absoluteUploadURL = "https://harc-test.local:7443\(path)"
        response.opaqueCapabilityCredential = Data(
            repeating: 0x73,
            count: 48
        )
        response.issuedAtUnixMs = issuedAt
        response.expiresAtUnixMs = request.requestedExpiresAtUnixMs
        response.byteCeiling = validated.exactBatchBodyLength
        response.minimumTransportSetEpoch = 1
        response.exactSignedTransportSet = exactTransportSet
        response.uploadID = Harc_V1_UploadIDV1(validated.uploadID)
        response.uploadGeneration = validated.generation.rawValue
        response.batchID = Harc_V1_AudioBatchIDV1(validated.batchID)
        response.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: validated.exactBatchBodySHA256.rawBytes
        )
        response.httpMethod = "PUT"
        response.httpPath = path
        response.expiryWasClamped = false
        return response
    }

    private func reconciliation() throws -> UploadReconciliation {
        let manifestObjectID = try exactManifest.map {
            try HarcSignedObjectV1.decode($0).objectID
        }
        return try UploadReconciliation(
            uploadID: fixture.plan.uploadID,
            ownerDeviceID: fixture.plan.originRecordingID.deviceID,
            originRecordingID: fixture.plan.originRecordingID,
            uploadProfileSHA256: fixture.profile.profileSHA256,
            generation: generation,
            firstBeganAt: fixture.now,
            generationBeganAt: fixture.now,
            generationExpiresAt: expiresAt,
            declarations: declarations,
            boundManifestObjectSHA256: manifestObjectID,
            durableChunks: durable.values.sorted {
                $0.chunkIndex < $1.chunkIndex
            },
            rejectedChunks: [],
            terminalReason: receipt == nil ? nil : .committed,
            existingReceipt: receipt
        )
    }

    private func beginResponse(
        uploadID: UploadID,
        profileSHA256: UploadProfileSHA256,
        disposition: Harc_V1_BeginUploadDispositionV1,
        reconciliation: UploadReconciliation?,
        receipt: OpaqueExactObjectSlot?
    ) throws -> Harc_V1_BeginUploadResponseV1 {
        var response = Harc_V1_BeginUploadResponseV1()
        response.protocol = HarcProtocolVersion.v1.protobufV1()
        response.disposition = disposition
        response.uploadID = Harc_V1_UploadIDV1(uploadID)
        response.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        if let reconciliation {
            response.uploadGeneration = generation.rawValue
            response.generationExpiresAtUnixMs = UInt64(
                expiresAt.timeIntervalSince1970 * 1_000
            )
            response.reconciliation = try Harc_V1_ReconcileUploadResponseV1(
                reconciliation
            )
        }
        if let receipt {
            response.exactExistingReceipt = Harc_V1_ExactSignedObjectV1(receipt)
        }
        return response
    }

    func uploadedIndexes() -> [UInt32] { uploadOrder }
    func maximumObservedChunkBytes() -> Int { maximumChunkBytes }
    func commitCallCount() -> Int { commitCalls }
    func beginCallCount() -> Int { beginCalls }
    func uploadCallCount() -> Int { uploadCalls }
    func mintCallCount() -> Int { mintCalls }

    func waitUntilBeginIsHeld() async {
        while heldBeginContinuation == nil {
            await Task.yield()
        }
    }

    func releaseHeldBegin() {
        heldBeginContinuation?.resume()
        heldBeginContinuation = nil
    }
    func acceptedManifestBytes() -> Data? { exactManifest }

    func callCounts() -> [Int] {
        [
            beginCalls,
            declareCalls,
            uploadCalls,
            reconcileCalls,
            commitCalls,
            statusCalls,
        ]
    }
}

private struct ForegroundInvalidSignatureSigner: P256DigestSigner {
    let declaredPublicKey: P256X963PublicKey
    let signingKey: SoftwareP256SigningKey

    var publicKey: P256X963PublicKey { declaredPublicKey }

    func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        try signingKey.sign(digest: digest)
    }
}
