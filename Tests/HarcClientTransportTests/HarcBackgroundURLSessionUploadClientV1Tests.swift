#if canImport(Network)
import CryptoKit
import Foundation
@testable import HarcClientStore
@testable import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Testing

@Suite("HARCAB1 background URLSession upload client")
struct HarcBackgroundURLSessionUploadClientV1Tests {
    @Test("persists every reconstruction fact and task mapping before resume")
    func persistsBeforeResumeAndBuildsExactRequest() async throws {
        let fixture = try BackgroundUploadFixture(seed: 1)
        let events = BackgroundUploadEventLog()
        let persistence = BackgroundUploadPersistenceFake(
            hostTrust: fixture.hostTrust,
            events: events
        )
        let session = BackgroundUploadSessionFake(
            nextTaskIdentifier: 11,
            events: events
        )
        let coordinator = HarcBackgroundUploadCoordinatorV1(
            persistence: persistence,
            session: session,
            verifyBody: { _ in },
            now: { fixture.now }
        )

        let identity = try await coordinator.schedule(fixture.plan)

        #expect(identity == fixture.identity(11))
        #expect(events.snapshot() == [
            "persistTransportSet",
            "persistJob",
            "makeTask",
            "persistMapping",
            "resume:11",
        ])
        let task = try #require(session.createdTasks.first)
        let request = try #require(task.originalRequest)
        #expect(task.bodyFileURL == fixture.bodyFileURL)
        #expect(task.taskDescription ==
            HarcBackgroundUploadHTTPRequestV1.taskDescription(
                batchID: fixture.descriptor.batchID
            ))
        #expect(request.url == fixture.endpointBinding.absoluteUploadURL)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "HarcUpload " + fixture.base64URLCredential)
        #expect(request.value(forHTTPHeaderField: "Content-Type") ==
            HarcBackgroundUploadHTTPRequestV1.requestContentType)
        #expect(request.value(forHTTPHeaderField: "Accept") ==
            HarcBackgroundUploadHTTPRequestV1
                .acknowledgementContentType)
        #expect(request.value(forHTTPHeaderField: "Content-Length") ==
            String(fixture.descriptor.exactBodyByteLength))
        #expect(request.value(forHTTPHeaderField: "Cache-Control") ==
            "no-store")
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == nil)
        #expect(request.value(forHTTPHeaderField: "Transfer-Encoding") == nil)
        #expect(persistence.mappings.map(\.identity) == [identity])
        #expect(persistence.persistedTransportSets == [
            fixture.transportSetEvidence,
        ])
    }

    @Test("mapping failure cancels the unresumed system task")
    func mappingFailureCancelsWithoutResume() async throws {
        let fixture = try BackgroundUploadFixture(seed: 2)
        let events = BackgroundUploadEventLog()
        let persistence = BackgroundUploadPersistenceFake(
            hostTrust: fixture.hostTrust,
            events: events
        )
        persistence.mappingFailure = .mappingPersistence
        let session = BackgroundUploadSessionFake(
            nextTaskIdentifier: 12,
            events: events
        )
        let coordinator = HarcBackgroundUploadCoordinatorV1(
            persistence: persistence,
            session: session,
            verifyBody: { _ in },
            now: { fixture.now }
        )

        await #expect(throws: BackgroundUploadFixtureError.self) {
            try await coordinator.schedule(fixture.plan)
        }

        let task = try #require(session.createdTasks.first)
        #expect(task.state == .canceling)
        #expect(events.snapshot() == [
            "persistTransportSet",
            "persistJob",
            "makeTask",
            "persistMapping",
            "cancel:12",
        ])
        #expect(!events.snapshot().contains("resume:12"))
    }

    @Test("relaunch resumes only exact stored requests and replaces tampered tasks")
    func relaunchRejectsTamperedAndOrphanTasks() async throws {
        let fixture = try BackgroundUploadFixture(seed: 3)
        let tamperedFixture = try BackgroundUploadFixture(
            seed: 4,
            now: fixture.now
        )
        let events = BackgroundUploadEventLog()
        let persistence = BackgroundUploadPersistenceFake(
            hostTrust: fixture.hostTrust,
            events: events
        )
        persistence.seed(job: fixture.job, mappingIdentity: fixture.identity(31))
        persistence.seed(
            job: tamperedFixture.job,
            mappingIdentity: tamperedFixture.identity(32)
        )

        let validRequest = try HarcBackgroundUploadHTTPRequestV1.makeRequest(
            for: fixture.job
        )
        var tamperedRequest = try HarcBackgroundUploadHTTPRequestV1.makeRequest(
            for: tamperedFixture.job
        )
        tamperedRequest.setValue(
            "HarcUpload attacker-controlled",
            forHTTPHeaderField: "Authorization"
        )
        let orphanRequest = validRequest
        let validTask = BackgroundUploadTaskFake(
            identifier: 31,
            request: validRequest,
            bodyFileURL: fixture.bodyFileURL,
            state: .suspended,
            events: events
        )
        validTask.taskDescription = HarcBackgroundUploadHTTPRequestV1
            .taskDescription(batchID: fixture.descriptor.batchID)
        let tamperedTask = BackgroundUploadTaskFake(
            identifier: 32,
            request: tamperedRequest,
            bodyFileURL: tamperedFixture.bodyFileURL,
            state: .suspended,
            events: events
        )
        tamperedTask.taskDescription = HarcBackgroundUploadHTTPRequestV1
            .taskDescription(batchID: tamperedFixture.descriptor.batchID)
        let orphanTask = BackgroundUploadTaskFake(
            identifier: 33,
            request: orphanRequest,
            bodyFileURL: fixture.bodyFileURL,
            state: .suspended,
            events: events
        )
        orphanTask.taskDescription = "unmapped-task"
        let session = BackgroundUploadSessionFake(
            nextTaskIdentifier: 40,
            existingTasks: [validTask, tamperedTask, orphanTask],
            events: events
        )
        let coordinator = HarcBackgroundUploadCoordinatorV1(
            persistence: persistence,
            session: session,
            verifyBody: { _ in },
            now: { fixture.now }
        )

        let result = try await coordinator.reconcileAfterRelaunch()

        #expect(validTask.state == .running)
        #expect(tamperedTask.state == .canceling)
        #expect(orphanTask.state == .canceling)
        #expect(persistence.lastObservedTasks == [fixture.identity(31)])
        #expect(result.storeReconciliation.matchedTasks == [
            fixture.identity(31),
        ])
        #expect(result.storeReconciliation.batchesToReschedule == [
            tamperedFixture.descriptor.batchID,
        ])
        #expect(result.newlyScheduledTasks == [fixture.identity(40)])
        #expect(result.batchesRequiringCapabilityRefresh.isEmpty)
        let replacement = try #require(session.createdTasks.first)
        #expect(replacement.state == .running)
        #expect(HarcBackgroundUploadHTTPRequestV1.matchesPersistedRequest(
            replacement.originalRequest,
            job: tamperedFixture.job
        ))
    }

    @Test("relaunch cancels a security-blocked task without rescheduling")
    func relaunchPreservesSecurityBlock() async throws {
        let fixture = try BackgroundUploadFixture(seed: 11)
        let events = BackgroundUploadEventLog()
        let persistence = BackgroundUploadPersistenceFake(
            hostTrust: fixture.hostTrust,
            events: events
        )
        let identity = fixture.identity(111)
        persistence.seed(job: fixture.job, mappingIdentity: identity)
        try persistence.persistTaskFailure(
            identity,
            batchID: fixture.descriptor.batchID,
            disposition: .securityBlocked
        )
        let task = BackgroundUploadTaskFake(
            identifier: 111,
            request: try HarcBackgroundUploadHTTPRequestV1.makeRequest(
                for: fixture.job
            ),
            bodyFileURL: fixture.bodyFileURL,
            state: .suspended,
            events: events
        )
        task.taskDescription = HarcBackgroundUploadHTTPRequestV1
            .taskDescription(batchID: fixture.descriptor.batchID)
        let coordinator = HarcBackgroundUploadCoordinatorV1(
            persistence: persistence,
            session: BackgroundUploadSessionFake(
                nextTaskIdentifier: 112,
                existingTasks: [task],
                events: events
            ),
            verifyBody: { _ in },
            now: { fixture.now }
        )

        let result = try await coordinator.reconcileAfterRelaunch()

        #expect(task.state == .canceling)
        #expect(result.storeReconciliation.batchesToReschedule.isEmpty)
        #expect(result.newlyScheduledTasks.isEmpty)
        #expect(result.batchesRequiringCapabilityRefresh.isEmpty)
    }

    @Test("final response URL must remain the capability-bound endpoint")
    func rejectsFinalURLMismatch() async throws {
        let fixture = try BackgroundUploadFixture(seed: 5)
        let context = try fixture.completionContext(taskIdentifier: 51)
        let event = try fixture.completionEvent(
            context: context,
            acknowledgementBytes:
                fixture.acknowledgement.exactAcknowledgementObject.exactBytes,
            finalURL: URL(string: "https://redirected.invalid/ack")!
        )

        do {
            try await context.coordinator.handleCompletion(event)
            #expect(Bool(false), "A redirected final URL was accepted")
        } catch let error as HarcBackgroundURLSessionUploadError {
            #expect(error == .invalidHTTPResponse(field: "url"))
        }
        #expect(context.persistence.persistedAcknowledgements.isEmpty)
        #expect(context.persistence.requestedTrustTuples.isEmpty)
        #expect(context.persistence.persistedFailureDispositions == [
            .securityBlocked,
        ])
    }

    @Test("oversized response is rejected before trust or ACK validation")
    func rejectsOversizedAcknowledgement() async throws {
        let fixture = try BackgroundUploadFixture(seed: 6)
        let context = try fixture.completionContext(taskIdentifier: 61)
        let event = try fixture.completionEvent(
            context: context,
            acknowledgementBytes: Data(),
            responseOverflowed: true
        )

        do {
            try await context.coordinator.handleCompletion(event)
            #expect(Bool(false), "An oversized ACK was accepted")
        } catch let error as HarcBackgroundURLSessionUploadError {
            #expect(error == .responseTooLarge)
        }
        #expect(context.persistence.persistedAcknowledgements.isEmpty)
        #expect(context.persistence.requestedTrustTuples.isEmpty)
        #expect(context.persistence.persistedFailureDispositions == [
            .securityBlocked,
        ])
    }

    @Test("tampered signed ACK never reaches durable persistence")
    func rejectsTamperedAcknowledgement() async throws {
        let fixture = try BackgroundUploadFixture(seed: 7)
        let context = try fixture.completionContext(taskIdentifier: 71)
        var tampered = fixture.acknowledgement
            .exactAcknowledgementObject.exactBytes
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        let event = try fixture.completionEvent(
            context: context,
            acknowledgementBytes: tampered
        )

        do {
            try await context.coordinator.handleCompletion(event)
            #expect(Bool(false), "A tampered ACK was accepted")
        } catch let error as HarcBackgroundURLSessionUploadError {
            #expect(error == .acknowledgementValidationFailed)
        }
        #expect(context.persistence.persistedAcknowledgements.isEmpty)
        #expect(context.persistence.requestedTrustTuples == [
            fixture.endpointBinding.trustTuple,
        ])
        #expect(context.persistence.persistedFailureDispositions == [
            .securityBlocked,
        ])
    }

    @Test("current adopted trust is required before ACK persistence")
    func rejectsUnavailableCurrentTrust() async throws {
        let fixture = try BackgroundUploadFixture(seed: 8)
        let context = try fixture.completionContext(taskIdentifier: 81)
        context.persistence.trustFailure = .currentTrustRejected
        let event = try fixture.completionEvent(
            context: context,
            acknowledgementBytes:
                fixture.acknowledgement.exactAcknowledgementObject.exactBytes
        )

        do {
            try await context.coordinator.handleCompletion(event)
            #expect(Bool(false), "Unavailable trust was accepted")
        } catch let error as HarcBackgroundURLSessionUploadError {
            #expect(error == .acknowledgementValidationFailed)
        }
        #expect(context.persistence.requestedTrustTuples == [
            fixture.endpointBinding.trustTuple,
        ])
        #expect(context.persistence.persistedAcknowledgements.isEmpty)
        #expect(context.persistence.persistedFailureDispositions == [
            .securityBlocked,
        ])
    }

    @Test("ordinary transport failure is durably recoverable")
    func persistsRecoverableTransportFailure() async throws {
        let fixture = try BackgroundUploadFixture(seed: 10)
        let context = try fixture.completionContext(taskIdentifier: 101)
        let failure = HarcBackgroundURLSessionUploadError.transportFailed(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost
        )
        let event = try fixture.completionEvent(
            context: context,
            acknowledgementBytes: Data(),
            transportFailure: failure
        )

        do {
            try await context.coordinator.handleCompletion(event)
            #expect(Bool(false), "A transport failure was accepted")
        } catch let error as HarcBackgroundURLSessionUploadError {
            #expect(error == failure)
        }
        #expect(context.persistence.persistedFailureDispositions == [
            .failedRecoverable,
        ])
        #expect(context.persistence.mappings.map(\.state) == [
            .failedRecoverable,
        ])
    }

    @Test("validated exact signed ACK is synchronously persisted")
    func persistsValidatedAcknowledgement() async throws {
        let fixture = try BackgroundUploadFixture(seed: 9)
        let context = try fixture.completionContext(taskIdentifier: 91)
        let event = try fixture.completionEvent(
            context: context,
            acknowledgementBytes:
                fixture.acknowledgement.exactAcknowledgementObject.exactBytes
        )

        try await context.coordinator.handleCompletion(event)

        #expect(context.persistence.requestedTrustTuples == [
            fixture.endpointBinding.trustTuple,
        ])
        #expect(context.persistence.persistedAcknowledgements == [
            fixture.acknowledgement,
        ])
        #expect(context.persistence.persistedFailureDispositions.isEmpty)
        #expect(context.persistence.mappings.map(\.state) == [.completed])
    }

    @Test("background completion waits for durable work and delivers once on main")
    func completionHandlerOrdering() async throws {
        let gate = HarcBackgroundEventCompletionGateV1()
        let probe = BackgroundCompletionProbe()

        gate.workBegan()
        gate.systemFinished()
        try gate.install {
            let deliveredOnMain = Thread.isMainThread
            Task {
                await probe.record(deliveredOnMain: deliveredOnMain)
            }
        }
        #expect(throws: HarcBackgroundURLSessionUploadError.self) {
            try gate.install {}
        }
        await yieldSeveralTimes()
        #expect(await probe.count == 0)

        gate.workEnded()
        await waitForDelivery(probe)
        #expect(await probe.count == 1)
        #expect(await probe.wasDeliveredOnMain)

        gate.systemFinished()
        await yieldSeveralTimes()
        #expect(await probe.count == 1)
    }

    @Test("production identifier is the durable store identity")
    func stableBackgroundIdentifier() {
        #expect(HarcBackgroundURLSessionConfigurationV1.stableIdentifier ==
            "com.harc.mobile.recording-upload")
        #expect(HarcBackgroundURLSessionConfigurationV1.stableIdentifier ==
            SystemBackgroundTaskIdentity.stableSessionIdentifier)
        #if os(iOS)
        #expect(HarcBackgroundURLSessionConfigurationV1
            .makeProduction().identifier ==
            SystemBackgroundTaskIdentity.stableSessionIdentifier)
        #endif
    }
}

private enum BackgroundUploadFixtureError: Error {
    case mappingPersistence
    case currentTrustRejected
    case invalidHTTPResponseFixture
}

private struct BackgroundUploadCompletionContext {
    let coordinator: HarcBackgroundUploadCoordinatorV1
    let persistence: BackgroundUploadPersistenceFake
    let request: URLRequest
    let taskIdentifier: Int
}

private struct BackgroundUploadFixture: @unchecked Sendable {
    let now: Date
    let bodyFileURL: URL
    let hostKey: SoftwareP256SigningKey
    let hostTrust: RecordingHostTrustBinding
    let descriptor: ImmutableAudioBatchDescriptor
    let credential: Data
    let endpointBinding: HarcBackgroundUploadEndpointBindingV1
    let capability: OpaqueBackgroundCapability
    let transportSetEvidence: ValidatedTransportSetEvidence
    let job: HarcBackgroundUploadJobV1
    let plan: HarcBackgroundUploadSchedulingPlanV1
    let acknowledgement: ValidatedBatchAcknowledgementEvidence

    init(
        seed: UInt32,
        now: Date = Date(timeIntervalSince1970: 2_100_000_000)
    ) throws {
        self.now = now
        hostKey = SoftwareP256SigningKey()
        let deviceID = try DeviceID(Self.digest(UInt8(seed & 0xff)))
        let libraryID = LibraryID(Self.uuid(seed * 100 + 1))
        hostTrust = try RecordingHostTrustBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey
        )
        let origin = OriginRecordingID(
            deviceID: deviceID,
            recordingUUID: Self.uuid(seed * 100 + 2)
        )
        let chunkHash = Self.digest(UInt8((seed + 1) & 0xff))
        let chunk = try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: ChunkID(Self.uuid(seed * 100 + 3)),
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: 10,
            encoding: .rawPCMFixture,
            encodedByteLength: 20,
            encodedSHA256: EncodedChunkSHA256(chunkHash),
            canonicalDecodedByteLength: 20,
            canonicalDecodedSHA256: CanonicalPCMHash(chunkHash)
        )
        descriptor = try ImmutableAudioBatchDescriptor(
            batchID: AudioBatchID(Self.uuid(seed * 100 + 4)),
            uploadID: UploadID(Self.uuid(seed * 100 + 5)),
            generation: .initial,
            uploadProfileSHA256: UploadProfileSHA256(
                Self.digest(UInt8((seed + 2) & 0xff))
            ),
            originRecordingID: origin,
            ownerDeviceID: deviceID,
            chunks: [chunk],
            exactBodyByteLength: 512,
            exactBodySHA256: ImmutableBatchSHA256(
                Self.digest(UInt8((seed + 3) & 0xff))
            )
        )
        credential = Data([0xfb, 0xff, UInt8(seed & 0xff)])
            + Data(repeating: UInt8((seed + 4) & 0xff), count: 29)
        let expiration = now.addingTimeInterval(3_600)
        endpointBinding = try HarcBackgroundUploadEndpointBindingV1(
            absoluteUploadURL: URL(
                string: "https://host-\(seed).local/v1/uploads/\(descriptor.uploadID)/batches/\(descriptor.batchID)"
            )!,
            httpMethod: "PUT",
            httpPath: "/v1/uploads/\(descriptor.uploadID)/batches/\(descriptor.batchID)",
            uploadID: descriptor.uploadID,
            generation: descriptor.generation,
            batchID: descriptor.batchID,
            exactBodyByteLength: descriptor.exactBodyByteLength,
            exactBodySHA256: descriptor.exactBodySHA256,
            byteCeiling: descriptor.exactBodyByteLength,
            minimumTransportSetEpoch: 7,
            trustTuple: AdoptedTrustTuple(
                libraryID: hostTrust.libraryID,
                hostAuthorityID: hostTrust.hostAuthorityID
            ),
            credentialSHA256: Data(SHA256.hash(data: credential)),
            expiresAt: expiration
        )
        capability = try OpaqueBackgroundCapability(
            credential: credential,
            capabilityBindings: endpointBinding.exactBytes(),
            expiresAt: expiration
        )
        transportSetEvidence = try ValidatedTransportSetEvidence(
            hostTrust: hostTrust,
            epoch: 7,
            exactSignedBytes: Data([0x48, 0x54, UInt8(seed & 0xff)])
        )
        bodyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-background-\(seed).harcab1")
        job = try HarcBackgroundUploadJobV1(
            descriptor: descriptor,
            bodyFileURL: bodyFileURL,
            capability: capability,
            endpointBinding: endpointBinding
        )
        plan = try HarcBackgroundUploadSchedulingPlanV1(
            descriptor: descriptor,
            bodyFileURL: bodyFileURL,
            capability: capability,
            endpointBinding: endpointBinding,
            transportSetEvidence: transportSetEvidence
        )
        acknowledgement = try HarcBatchAcknowledgementCodecV1()
            .issueBatchAcknowledgement(
                claims: BatchAcknowledgementClaims(
                    hostTrust: hostTrust,
                    batch: descriptor,
                    acknowledgementID: Self.uuid(seed * 100 + 6),
                    durableAt: now.addingTimeInterval(120)
                ),
                hostAuthoritySigner: hostKey
            )
    }

    var base64URLCredential: String {
        credential.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func identity(_ taskIdentifier: Int) -> SystemBackgroundTaskIdentity {
        try! SystemBackgroundTaskIdentity(taskIdentifier: taskIdentifier)
    }

    func completionContext(
        taskIdentifier: Int
    ) throws -> BackgroundUploadCompletionContext {
        let persistence = BackgroundUploadPersistenceFake(
            hostTrust: hostTrust,
            events: BackgroundUploadEventLog()
        )
        persistence.seed(
            job: job,
            mappingIdentity: identity(taskIdentifier)
        )
        let request = try HarcBackgroundUploadHTTPRequestV1.makeRequest(
            for: job
        )
        let coordinator = HarcBackgroundUploadCoordinatorV1(
            persistence: persistence,
            session: BackgroundUploadSessionFake(
                nextTaskIdentifier: taskIdentifier + 1,
                events: BackgroundUploadEventLog()
            ),
            now: { now }
        )
        return BackgroundUploadCompletionContext(
            coordinator: coordinator,
            persistence: persistence,
            request: request,
            taskIdentifier: taskIdentifier
        )
    }

    func completionEvent(
        context: BackgroundUploadCompletionContext,
        acknowledgementBytes: Data,
        finalURL: URL? = nil,
        responseOverflowed: Bool = false,
        transportFailure: HarcBackgroundURLSessionUploadError? = nil
    ) throws -> HarcBackgroundUploadCompletionEventV1 {
        let responseURL = finalURL ?? endpointBinding.absoluteUploadURL
        guard let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": HarcBackgroundUploadHTTPRequestV1
                    .acknowledgementContentType,
                "Content-Length": String(acknowledgementBytes.count),
                "Cache-Control": "no-store",
            ]
        ) else {
            throw BackgroundUploadFixtureError.invalidHTTPResponseFixture
        }
        return HarcBackgroundUploadCompletionEventV1(
            taskIdentifier: context.taskIdentifier,
            taskDescription: HarcBackgroundUploadHTTPRequestV1
                .taskDescription(batchID: descriptor.batchID),
            originalRequest: context.request,
            response: HarcBackgroundUploadHTTPResponseV1(response),
            responseBody: acknowledgementBytes,
            responseOverflowed: responseOverflowed,
            transportFailure: transportFailure
        )
    }

    private static func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    private static func uuid(_ value: UInt32) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012x",
                value
            )
        )!
    }
}

private final class BackgroundUploadEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class BackgroundUploadTaskFake:
    HarcBackgroundUploadSystemTaskV1, @unchecked Sendable
{
    let taskIdentifier: Int
    var taskDescription: String?
    let originalRequest: URLRequest?
    let bodyFileURL: URL
    private(set) var state: HarcBackgroundSystemTaskStateV1
    private let events: BackgroundUploadEventLog

    init(
        identifier: Int,
        request: URLRequest,
        bodyFileURL: URL,
        state: HarcBackgroundSystemTaskStateV1 = .suspended,
        events: BackgroundUploadEventLog
    ) {
        taskIdentifier = identifier
        originalRequest = request
        self.bodyFileURL = bodyFileURL
        self.state = state
        self.events = events
    }

    func resume() {
        state = .running
        events.append("resume:\(taskIdentifier)")
    }

    func cancel() {
        state = .canceling
        events.append("cancel:\(taskIdentifier)")
    }
}

private final class BackgroundUploadSessionFake:
    HarcBackgroundUploadSessionV1, @unchecked Sendable
{
    private var nextTaskIdentifier: Int
    private let existingTasks: [BackgroundUploadTaskFake]
    private let events: BackgroundUploadEventLog
    private(set) var createdTasks: [BackgroundUploadTaskFake] = []

    init(
        nextTaskIdentifier: Int,
        existingTasks: [BackgroundUploadTaskFake] = [],
        events: BackgroundUploadEventLog
    ) {
        self.nextTaskIdentifier = nextTaskIdentifier
        self.existingTasks = existingTasks
        self.events = events
    }

    func makeUploadTask(
        request: URLRequest,
        bodyFileURL: URL
    ) throws -> any HarcBackgroundUploadSystemTaskV1 {
        events.append("makeTask")
        let task = BackgroundUploadTaskFake(
            identifier: nextTaskIdentifier,
            request: request,
            bodyFileURL: bodyFileURL,
            events: events
        )
        nextTaskIdentifier += 1
        createdTasks.append(task)
        return task
    }

    func allTasks() async throws
        -> [any HarcBackgroundUploadSystemTaskV1] {
        existingTasks.map { $0 as any HarcBackgroundUploadSystemTaskV1 }
    }
}

private final class BackgroundUploadPersistenceFake:
    HarcBackgroundUploadPersistenceV1, @unchecked Sendable
{
    let hostTrust: RecordingHostTrustBinding
    let events: BackgroundUploadEventLog
    var mappingFailure: BackgroundUploadFixtureError?
    var trustFailure: BackgroundUploadFixtureError?
    private(set) var jobs: [AudioBatchID: HarcBackgroundUploadJobV1] = [:]
    private(set) var mappings: [StoredBackgroundTaskMapping] = []
    private(set) var persistedTransportSets: [ValidatedTransportSetEvidence] = []
    private(set) var persistedAcknowledgements: [ValidatedBatchAcknowledgementEvidence] = []
    private(set) var persistedFailureDispositions: [
        BackgroundTaskFailureDisposition
    ] = []
    private(set) var requestedTrustTuples: [AdoptedTrustTuple] = []
    private(set) var lastObservedTasks: Set<SystemBackgroundTaskIdentity> = []

    init(
        hostTrust: RecordingHostTrustBinding,
        events: BackgroundUploadEventLog
    ) {
        self.hostTrust = hostTrust
        self.events = events
    }

    func seed(
        job: HarcBackgroundUploadJobV1,
        mappingIdentity: SystemBackgroundTaskIdentity
    ) {
        jobs[job.descriptor.batchID] = job
        mappings.append(
            StoredBackgroundTaskMapping(
                identity: mappingIdentity,
                batchID: job.descriptor.batchID,
                state: .persistedBeforeResume,
                updatedAt: Date(timeIntervalSince1970: 2_100_000_000)
            )
        )
    }

    func persistTransportSet(
        _ evidence: ValidatedTransportSetEvidence
    ) throws {
        events.append("persistTransportSet")
        persistedTransportSets.append(evidence)
    }

    func persistJob(_ job: HarcBackgroundUploadJobV1) throws {
        events.append("persistJob")
        jobs[job.descriptor.batchID] = job
    }

    func job(
        batchID: AudioBatchID
    ) throws -> HarcBackgroundUploadJobV1? {
        jobs[batchID]
    }

    func persistTaskMappingBeforeResume(
        _ identity: SystemBackgroundTaskIdentity,
        batchID: AudioBatchID
    ) throws {
        events.append("persistMapping")
        if let mappingFailure { throw mappingFailure }
        mappings.append(
            StoredBackgroundTaskMapping(
                identity: identity,
                batchID: batchID,
                state: .persistedBeforeResume,
                updatedAt: Date(timeIntervalSince1970: 2_100_000_000)
            )
        )
    }

    func taskMappings() throws -> [StoredBackgroundTaskMapping] {
        mappings
    }

    func reconcileTasks(
        _ observed: Set<SystemBackgroundTaskIdentity>
    ) throws -> BackgroundTaskReconciliation {
        lastObservedTasks = observed
        let persistedByIdentity = Dictionary(
            uniqueKeysWithValues: mappings.map { ($0.identity, $0) }
        )
        let matched = observed
            .filter { persistedByIdentity[$0] != nil }
            .sorted { $0.taskIdentifier < $1.taskIdentifier }
        let missingBatches = mappings
            .filter {
                $0.state != .completed
                    && $0.state != .securityBlocked
                    && !observed.contains($0.identity)
            }
            .map(\.batchID)
            .sorted()
        let orphaned = observed
            .filter { persistedByIdentity[$0] == nil }
            .sorted { $0.taskIdentifier < $1.taskIdentifier }
        return BackgroundTaskReconciliation(
            batchesToReschedule: missingBatches,
            orphanedSystemTasks: orphaned,
            matchedTasks: matched
        )
    }

    func activeHostTrust(
        for tuple: AdoptedTrustTuple
    ) throws -> RecordingHostTrustBinding {
        requestedTrustTuples.append(tuple)
        if let trustFailure { throw trustFailure }
        return hostTrust
    }

    func persistAcknowledgement(
        _ evidence: ValidatedBatchAcknowledgementEvidence
    ) throws {
        persistedAcknowledgements.append(evidence)
        mappings = mappings.map { mapping in
            guard mapping.batchID == evidence.batchID else { return mapping }
            return StoredBackgroundTaskMapping(
                identity: mapping.identity,
                batchID: mapping.batchID,
                state: .completed,
                updatedAt: mapping.updatedAt
            )
        }
    }

    func persistTaskFailure(
        _ identity: SystemBackgroundTaskIdentity,
        batchID: AudioBatchID,
        disposition: BackgroundTaskFailureDisposition
    ) throws {
        persistedFailureDispositions.append(disposition)
        mappings = mappings.map { mapping in
            guard mapping.identity == identity,
                  mapping.batchID == batchID else { return mapping }
            return StoredBackgroundTaskMapping(
                identity: mapping.identity,
                batchID: mapping.batchID,
                state: disposition == .securityBlocked
                    ? .securityBlocked
                    : .failedRecoverable,
                updatedAt: mapping.updatedAt
            )
        }
    }
}

private actor BackgroundCompletionProbe {
    private(set) var count = 0
    private(set) var wasDeliveredOnMain = false

    func record(deliveredOnMain: Bool) {
        count += 1
        wasDeliveredOnMain = wasDeliveredOnMain || deliveredOnMain
    }
}

private func yieldSeveralTimes() async {
    for _ in 0..<20 { await Task.yield() }
}

private func waitForDelivery(_ probe: BackgroundCompletionProbe) async {
    for _ in 0..<200 {
        if await probe.count > 0 { return }
        await Task.yield()
    }
}
#endif
