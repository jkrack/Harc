#if canImport(Network)
import Foundation
import HarcHost
@testable import HarcHostTransport
import Network
import Testing

@Suite("Resident transport generation driver")
struct ResidentTransportGenerationDriverTests {
    @Test("withdrawal precedes concurrent admission stop and drain")
    func readinessAndConcurrentDrainOrder() async throws {
        let events = GenerationEventLog()
        let admissionBarrier = TwoPartyBarrier()
        let grpc = TestGRPCRuntime(
            events: events,
            admissionBarrier: admissionBarrier
        )
        let upload = TestUploadRuntime(
            events: events,
            admissionBarrier: admissionBarrier
        )
        let publisher = TestGenerationPublisher(events: events)
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: grpc,
            uploadRuntime: upload,
            publisher: publisher
        )
        let generationID = UUID()

        try await driver.activateGeneration(
            id: generationID,
            grpcFactory: try grpcFactory(generationID: generationID),
            uploadListener: try uploadListener(),
            terminationReporter: reporter(generationID)
        )

        let drain = Task {
            try await driver.withdrawAdvertisementAndDrainGeneration()
        }
        await admissionBarrier.waitUntilBothArrived()

        let beforeRelease = await events.values
        let withdrawIndex = try #require(
            beforeRelease.firstIndex(of: "bonjour.withdraw")
        )
        let grpcAdmissionIndex = try #require(
            beforeRelease.firstIndex(of: "grpc.admission.stop")
        )
        let uploadAdmissionIndex = try #require(
            beforeRelease.firstIndex(of: "upload.admission.stop")
        )
        #expect(withdrawIndex < grpcAdmissionIndex)
        #expect(withdrawIndex < uploadAdmissionIndex)
        #expect(!beforeRelease.contains("grpc.drain"))
        #expect(!beforeRelease.contains("upload.drain"))

        await admissionBarrier.releaseBoth()
        try await drain.value

        #expect(await driver.activeGenerationID == nil)
        #expect((await events.values).contains("grpc.drain"))
        #expect((await events.values).contains("upload.drain"))
    }

    @Test("partial activation withdraws and hard-stops every runtime")
    func partialActivationRollback() async throws {
        let events = GenerationEventLog()
        let grpc = TestGRPCRuntime(events: events)
        let upload = TestUploadRuntime(events: events, failStart: true)
        let publisher = TestGenerationPublisher(events: events)
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: grpc,
            uploadRuntime: upload,
            publisher: publisher
        )
        let generationID = UUID()

        await #expect(throws: GenerationTestError.startRejected) {
            try await driver.activateGeneration(
                id: generationID,
                grpcFactory: try grpcFactory(generationID: generationID),
                uploadListener: try uploadListener(),
                terminationReporter: reporter(generationID)
            )
        }

        #expect(await driver.activeGenerationID == nil)
        let values = await events.values
        #expect(values.starts(with: ["grpc.start", "upload.start"]))
        #expect(values.contains("bonjour.withdraw"))
        #expect(values.contains("upload.stop"))
        #expect(values.contains("grpc.stop"))
    }

    @Test("activation rejects a reporter bound to another generation")
    func reporterGenerationMustMatch() async throws {
        let events = GenerationEventLog()
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: TestGRPCRuntime(events: events),
            uploadRuntime: TestUploadRuntime(events: events),
            publisher: TestGenerationPublisher(events: events)
        )
        let generationID = UUID()

        await #expect(throws:
            HarcResidentTransportGenerationDriverError
                .terminationReporterGenerationMismatch
        ) {
            try await driver.activateGeneration(
                id: generationID,
                grpcFactory: try grpcFactory(generationID: generationID),
                uploadListener: try uploadListener(),
                terminationReporter: reporter(UUID())
            )
        }

        #expect(await events.values.isEmpty)
        #expect(await driver.activeGenerationID == nil)
    }

    @Test("stop during bind waits until activation has fully unwound")
    func reentrantStopAwaitsActivationUnwind() async throws {
        let events = GenerationEventLog()
        let startGate = AsyncGate()
        let grpc = TestGRPCRuntime(events: events, startGate: startGate)
        let upload = TestUploadRuntime(events: events)
        let publisher = TestGenerationPublisher(events: events)
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: grpc,
            uploadRuntime: upload,
            publisher: publisher
        )
        let generationID = UUID()
        let activation = Task {
            try await driver.activateGeneration(
                id: generationID,
                grpcFactory: try grpcFactory(generationID: generationID),
                uploadListener: try uploadListener(),
                terminationReporter: reporter(generationID)
            )
        }

        await startGate.waitUntilEntered()
        let stopProbe = CompletionProbe()
        let stop = Task {
            await driver.stopGenerationImmediately()
            await stopProbe.markCompleted()
        }
        await publisher.waitUntilWithdrawn(generationID)
        #expect(!(await stopProbe.isCompleted))
        #expect(await driver.generationIDBeingTornDown == generationID)

        await #expect(throws:
            HarcResidentTransportGenerationDriverError.generationAlreadyActive
        ) {
            let replacementID = UUID()
            try await driver.activateGeneration(
                id: replacementID,
                grpcFactory: try grpcFactory(generationID: replacementID),
                uploadListener: try uploadListener(),
                terminationReporter: reporter(replacementID)
            )
        }

        await startGate.release()
        await #expect(throws:
            HarcResidentTransportGenerationDriverError.activationSuperseded
        ) {
            try await activation.value
        }
        await stop.value
        #expect(await stopProbe.isCompleted)
        #expect(await driver.activeGenerationID == nil)
    }

    @Test("withdrawal tombstones a generation before late publish returns")
    func latePublishCannotReadvertise() async throws {
        let events = GenerationEventLog()
        let publishGate = AsyncGate()
        let grpc = TestGRPCRuntime(events: events)
        let upload = TestUploadRuntime(events: events)
        let publisher = TestGenerationPublisher(
            events: events,
            publishGate: publishGate
        )
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: grpc,
            uploadRuntime: upload,
            publisher: publisher
        )
        let generationID = UUID()
        let activation = Task {
            try await driver.activateGeneration(
                id: generationID,
                grpcFactory: try grpcFactory(generationID: generationID),
                uploadListener: try uploadListener(),
                terminationReporter: reporter(generationID)
            )
        }

        await publishGate.waitUntilEntered()
        let stop = Task { await driver.stopGenerationImmediately() }
        await publisher.waitUntilWithdrawn(generationID)

        await #expect(throws:
            HarcResidentTransportGenerationDriverError.generationAlreadyActive
        ) {
            let replacementID = UUID()
            try await driver.activateGeneration(
                id: replacementID,
                grpcFactory: try grpcFactory(generationID: replacementID),
                uploadListener: try uploadListener(),
                terminationReporter: reporter(replacementID)
            )
        }

        await publishGate.release()
        await #expect(throws:
            HarcResidentTransportGenerationDriverError.activationSuperseded
        ) {
            try await activation.value
        }
        await stop.value

        #expect(await publisher.advertisedGenerationID == nil)
        #expect(await driver.activeGenerationID == nil)
    }

    @Test("unexpected gRPC exit tears down and emits a scoped terminal event")
    func unexpectedGRPCExitFailsClosed() async throws {
        let events = GenerationEventLog()
        let grpc = TestGRPCRuntime(events: events)
        let upload = TestUploadRuntime(events: events)
        let publisher = TestGenerationPublisher(events: events)
        let reports = TerminationReportRecorder()
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: grpc,
            uploadRuntime: upload,
            publisher: publisher
        )
        let generationID = UUID()

        try await driver.activateGeneration(
            id: generationID,
            grpcFactory: try grpcFactory(generationID: generationID),
            uploadListener: try uploadListener(),
            terminationReporter: reporter(generationID) {
                await reports.record(generationID)
            }
        )
        await grpc.triggerUnexpectedExit(generationID: generationID)

        #expect(await driver.activeGenerationID == nil)
        #expect(await publisher.advertisedGenerationID == nil)
        #expect(await reports.values == [generationID])
        let values = await events.values
        #expect(values.contains("bonjour.withdraw"))
        #expect(values.contains("upload.stop"))
        #expect(values.contains("grpc.stop"))
    }

    @Test("activation teardown reasserts hard stop after a late upload start")
    func lateUploadStartIsStoppedAfterActivationUnwinds() async throws {
        let events = GenerationEventLog()
        let uploadStartGate = AsyncGate()
        let grpc = TestGRPCRuntime(events: events)
        let upload = TestUploadRuntime(
            events: events,
            startGate: uploadStartGate
        )
        let publisher = TestGenerationPublisher(events: events)
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: grpc,
            uploadRuntime: upload,
            publisher: publisher
        )
        let generationID = UUID()
        let activation = Task {
            try await driver.activateGeneration(
                id: generationID,
                grpcFactory: try grpcFactory(generationID: generationID),
                uploadListener: try uploadListener(),
                terminationReporter: reporter(generationID)
            )
        }

        await uploadStartGate.waitUntilEntered()
        let stop = Task { await driver.stopGenerationImmediately() }
        await publisher.waitUntilWithdrawn(generationID)
        await uploadStartGate.release()

        await #expect(throws:
            HarcResidentTransportGenerationDriverError.activationSuperseded
        ) {
            try await activation.value
        }
        await stop.value

        let values = await events.values
        #expect(values.filter { $0 == "upload.stop" }.count == 2)
        #expect(await driver.activeGenerationID == nil)
    }

    @Test("teardown waiters are released before the lifecycle reporter runs")
    func teardownFinishesBeforeTerminationReporter() async throws {
        let events = GenerationEventLog()
        let uploadStopGate = AsyncGate()
        let sinkGate = AsyncGate()
        let grpc = TestGRPCRuntime(events: events)
        let upload = TestUploadRuntime(
            events: events,
            immediateStopGate: uploadStopGate
        )
        let publisher = TestGenerationPublisher(events: events)
        let driver = HarcResidentTransportGenerationDriver(
            grpcRuntime: grpc,
            uploadRuntime: upload,
            publisher: publisher
        )
        let generationID = UUID()

        try await driver.activateGeneration(
            id: generationID,
            grpcFactory: try grpcFactory(generationID: generationID),
            uploadListener: try uploadListener(),
            terminationReporter: reporter(generationID) {
                await sinkGate.enterAndWait()
            }
        )
        let unexpectedExit = Task {
            await grpc.triggerUnexpectedExit(generationID: generationID)
        }
        await uploadStopGate.waitUntilEntered()

        let stop = Task { await driver.stopGenerationImmediately() }
        await uploadStopGate.release()
        await sinkGate.waitUntilEntered()

        // This must complete while the lifecycle reporter is still suspended.
        // Otherwise a reporter needing HostTransportLifecycle's operation gate
        // can deadlock against a lifecycle operation awaiting driver teardown.
        await stop.value
        await sinkGate.release()
        await unexpectedExit.value
        #expect(await driver.activeGenerationID == nil)
    }

    private func grpcFactory(
        generationID: UUID
    ) throws -> HarcGRPCNWListenerFactory {
        HarcGRPCNWListenerFactory(
            servedIdentityBinding: HarcGRPCServedIdentityBinding(
                generationID: generationID
            ),
            unreadyListenerProvider: { try NWListener(using: .tcp) }
        )
    }

    private func uploadListener() throws -> NWListener {
        try NWListener(using: .tcp)
    }

    private func reporter(
        _ generationID: UUID,
        onReport: @escaping @Sendable () async -> Void = {}
    ) -> HostTransportGenerationTerminationReporter {
        HostTransportGenerationTerminationReporter(
            generationID: generationID,
            report: onReport
        )
    }
}

private enum GenerationTestError: Error, Equatable {
    case startRejected
}

private actor GenerationEventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor TestGRPCRuntime: HarcGRPCServerRuntimeBoundary {
    let events: GenerationEventLog
    let startGate: AsyncGate?
    let admissionBarrier: TwoPartyBarrier?
    private var unexpectedExitHandler: HarcGRPCUnexpectedExitHandler?

    init(
        events: GenerationEventLog,
        startGate: AsyncGate? = nil,
        admissionBarrier: TwoPartyBarrier? = nil
    ) {
        self.events = events
        self.startGate = startGate
        self.admissionBarrier = admissionBarrier
    }

    func start(
        generationID _: UUID,
        listenerFactory _: HarcGRPCNWListenerFactory,
        unexpectedExitHandler: @escaping HarcGRPCUnexpectedExitHandler
    ) async throws {
        self.unexpectedExitHandler = unexpectedExitHandler
        await events.append("grpc.start")
        if let startGate { await startGate.enterAndWait() }
    }

    func stopAcceptingNewConnections() async {
        await events.append("grpc.admission.stop")
        if let admissionBarrier { await admissionBarrier.arriveAndWait() }
    }

    func finishGracefulShutdown() async {
        await events.append("grpc.drain")
    }

    func stopImmediately() async {
        await events.append("grpc.stop")
    }

    func triggerUnexpectedExit(generationID: UUID) async {
        if let unexpectedExitHandler {
            await unexpectedExitHandler(generationID)
        }
    }
}

private actor TestUploadRuntime: HarcBackgroundUploadListenerRuntimeBoundary {
    let events: GenerationEventLog
    let failStart: Bool
    let admissionBarrier: TwoPartyBarrier?
    let startGate: AsyncGate?
    let immediateStopGate: AsyncGate?

    init(
        events: GenerationEventLog,
        failStart: Bool = false,
        admissionBarrier: TwoPartyBarrier? = nil,
        startGate: AsyncGate? = nil,
        immediateStopGate: AsyncGate? = nil
    ) {
        self.events = events
        self.failStart = failStart
        self.admissionBarrier = admissionBarrier
        self.startGate = startGate
        self.immediateStopGate = immediateStopGate
    }

    func start(listener _: NWListener) async throws {
        await events.append("upload.start")
        if let startGate { await startGate.enterAndWait() }
        if failStart { throw GenerationTestError.startRejected }
    }

    func stopAcceptingNewConnections() async {
        await events.append("upload.admission.stop")
        if let admissionBarrier { await admissionBarrier.arriveAndWait() }
    }

    func finishGracefulShutdown() async {
        await events.append("upload.drain")
    }

    func stopImmediately() async {
        await events.append("upload.stop")
        if let immediateStopGate {
            await immediateStopGate.enterAndWait()
        }
    }
}

private actor TestGenerationPublisher: HarcBonjourGenerationPublisherBoundary {
    let events: GenerationEventLog
    let publishGate: AsyncGate?
    private var withdrawn: Set<UUID> = []
    private var withdrawalWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var advertisedGenerationID: UUID?

    init(events: GenerationEventLog, publishGate: AsyncGate? = nil) {
        self.events = events
        self.publishGate = publishGate
    }

    func publishGeneration(id: UUID) async throws {
        await events.append("bonjour.publish.begin")
        if let publishGate { await publishGate.enterAndWait() }
        guard !withdrawn.contains(id) else {
            await events.append("bonjour.publish.tombstoned")
            return
        }
        advertisedGenerationID = id
        await events.append("bonjour.publish")
    }

    func withdrawAdvertisement(forGenerationID id: UUID) async {
        withdrawn.insert(id)
        if advertisedGenerationID == id { advertisedGenerationID = nil }
        await events.append("bonjour.withdraw")
        let waiters = withdrawalWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilWithdrawn(_ id: UUID) async {
        guard !withdrawn.contains(id) else { return }
        await withCheckedContinuation { continuation in
            withdrawalWaiters[id, default: []].append(continuation)
        }
    }
}

private actor TerminationReportRecorder {
    private(set) var values: [UUID] = []

    func record(_ generationID: UUID) {
        values.append(generationID)
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor TwoPartyBarrier {
    private var arrivals = 0
    private var released = false
    private var bothWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == 2 {
            for waiter in bothWaiters { waiter.resume() }
            bothWaiters.removeAll()
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBothArrived() async {
        guard arrivals >= 2 else {
            await withCheckedContinuation { bothWaiters.append($0) }
            return
        }
    }

    func releaseBoth() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}
#endif
