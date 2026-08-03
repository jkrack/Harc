#if canImport(Network)
import Foundation
@testable import HarcHostTransport
import Network
import Testing

@Suite("gRPC server runtime lifecycle")
struct GRPCServerRuntimeLifecycleTests {
    @Test("startup uses Harc readiness and never needs a socket address")
    func harcOwnedReadiness() async throws {
        let sleeper = ManualRuntimeSleeper()
        let metrics = RuntimeProcessMetrics()
        let runtime = makeRuntime(
            sleeper: sleeper,
            metrics: metrics,
            mode: .waitForCancellation,
            bindsOnStart: true
        )
        let generationID = UUID()
        let factory = try grpcFactory(generationID: generationID)

        try await runtime.start(
            generationID: generationID,
            listenerFactory: factory,
            unexpectedExitHandler: { _ in }
        )

        #expect(await runtime.isRunning)
        await runtime.stopImmediately()
    }

    @Test("graceful stop during startup cancels without touching gRPC graceful state")
    func startingStopNeverCallsGracefulAPI() async throws {
        let sleeper = ManualRuntimeSleeper()
        let metrics = RuntimeProcessMetrics()
        let runtime = makeRuntime(
            sleeper: sleeper,
            metrics: metrics,
            mode: .waitForCancellation,
            bindsOnStart: false
        )
        let generationID = UUID()
        let factory = try grpcFactory(generationID: generationID)
        let start = Task {
            try await runtime.start(
                generationID: generationID,
                listenerFactory: factory,
                unexpectedExitHandler: { _ in }
            )
        }

        await metrics.waitUntilServing()
        await runtime.stopAcceptingNewConnections()
        await runtime.finishGracefulShutdown()

        await #expect(throws: (any Error).self) {
            try await start.value
        }
        #expect(metrics.gracefulShutdownCount == 0)
        #expect(metrics.cancellationCount == 1)
        #expect(!(await runtime.isRunning))
    }

    @Test("bind deadline cancels startup and invalidates its identity binding")
    func finiteBindDeadline() async throws {
        let sleeper = ManualRuntimeSleeper()
        let metrics = RuntimeProcessMetrics()
        let runtime = makeRuntime(
            sleeper: sleeper,
            metrics: metrics,
            mode: .waitForCancellation,
            bindsOnStart: false
        )
        let generationID = UUID()
        let factory = try grpcFactory(generationID: generationID)
        let start = Task {
            try await runtime.start(
                generationID: generationID,
                listenerFactory: factory,
                unexpectedExitHandler: { _ in }
            )
        }

        await metrics.waitUntilServing()
        await sleeper.waitUntilWaiterCount(1)
        await sleeper.fireNext()

        await #expect(throws:
            HarcGRPCListenerReadinessError.bindingTimedOut
        ) {
            try await start.value
        }
        #expect(metrics.cancellationCount == 1)
        #expect(throwsInvalidated(factory.servedIdentityBinding, generationID))
    }

    @Test("graceful drain deadline escalates to cancellation")
    func boundedGracefulDrainEscalates() async throws {
        let sleeper = ManualRuntimeSleeper()
        let metrics = RuntimeProcessMetrics()
        let runtime = makeRuntime(
            sleeper: sleeper,
            metrics: metrics,
            mode: .waitForCancellation,
            bindsOnStart: true
        )
        let generationID = UUID()
        let factory = try grpcFactory(
            generationID: generationID,
            initiallyBound: true
        )

        try await runtime.start(
            generationID: generationID,
            listenerFactory: factory,
            unexpectedExitHandler: { _ in }
        )
        await runtime.stopAcceptingNewConnections()
        #expect(
            try factory.servedIdentityBinding.requireTLSSPKISHA256(
                generationID: generationID
            ) == Data(repeating: 0xA7, count: 32)
        )
        let finish = Task { await runtime.finishGracefulShutdown() }
        await sleeper.waitUntilWaiterCount(1)
        await sleeper.fireNext()
        await finish.value

        #expect(metrics.gracefulShutdownCount == 1)
        #expect(metrics.cancellationCount == 1)
        #expect(!(await runtime.isRunning))
        #expect(!(await runtime.isStopping))
        #expect(throwsInvalidated(factory.servedIdentityBinding, generationID))
    }

    @Test("unexpected process exit reports the exact generation and invalidates binding")
    func unexpectedExitIsGenerationScoped() async throws {
        let sleeper = ManualRuntimeSleeper()
        let metrics = RuntimeProcessMetrics()
        let exitGate = RuntimeExitGate()
        let runtime = makeRuntime(
            sleeper: sleeper,
            metrics: metrics,
            mode: .waitForRelease(exitGate),
            bindsOnStart: true
        )
        let generationID = UUID()
        let factory = try grpcFactory(generationID: generationID)
        let exits = RuntimeExitRecorder()

        try await runtime.start(
            generationID: generationID,
            listenerFactory: factory
        ) { id in
            await exits.record(id)
        }
        await exitGate.release()
        await exits.waitForValue()

        #expect(await exits.values == [generationID])
        #expect(!(await runtime.isRunning))
        #expect(throwsInvalidated(factory.servedIdentityBinding, generationID))
    }

    @Test("successful graceful completion always invalidates the binding")
    func successfulGracefulCompletionInvalidatesBinding() async throws {
        let sleeper = ManualRuntimeSleeper()
        let metrics = RuntimeProcessMetrics()
        let exitGate = RuntimeExitGate()
        let runtime = makeRuntime(
            sleeper: sleeper,
            metrics: metrics,
            mode: .waitForRelease(exitGate),
            bindsOnStart: true
        )
        let generationID = UUID()
        let factory = try grpcFactory(
            generationID: generationID,
            initiallyBound: true
        )

        try await runtime.start(
            generationID: generationID,
            listenerFactory: factory,
            unexpectedExitHandler: { _ in }
        )
        await runtime.stopAcceptingNewConnections()
        await exitGate.release()
        await runtime.finishGracefulShutdown()

        #expect(throwsInvalidated(factory.servedIdentityBinding, generationID))
        #expect(!(await runtime.isRunning))
        #expect(!(await runtime.isStopping))
    }

    @Test("caller cancellation after bind cannot promote the runtime")
    func cancellationAfterBindFailsClosed() async throws {
        let cleanupGate = RuntimeCancellationCleanupGate()
        let metrics = RuntimeProcessMetrics()
        let runtime = HarcGRPCServerRuntime(
            bindTimeout: .seconds(1),
            gracefulDrainTimeout: .seconds(1),
            hardStopTimeout: .seconds(1),
            sleep: { _ in try await cleanupGate.sleepUntilReleased() }
        ) { factory, _ in
            ControlledGRPCProcess(
                listenerFactory: factory,
                metrics: metrics,
                mode: .waitForCancellation,
                bindsOnStart: true
            )
        }
        let generationID = UUID()
        let factory = try grpcFactory(generationID: generationID)
        let start = Task {
            try await runtime.start(
                generationID: generationID,
                listenerFactory: factory,
                unexpectedExitHandler: { _ in }
            )
        }

        await cleanupGate.waitUntilCancellationCleanupStarted()
        start.cancel()
        await cleanupGate.release()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(metrics.cancellationCount == 1)
        #expect(!(await runtime.isRunning))
    }

    private func makeRuntime(
        sleeper: ManualRuntimeSleeper,
        metrics: RuntimeProcessMetrics,
        mode: ControlledGRPCProcess.Mode,
        bindsOnStart: Bool
    ) -> HarcGRPCServerRuntime {
        HarcGRPCServerRuntime(
            bindTimeout: .seconds(1),
            gracefulDrainTimeout: .seconds(1),
            hardStopTimeout: .seconds(1),
            sleep: { duration in try await sleeper.sleep(duration) }
        ) { factory, _ in
            ControlledGRPCProcess(
                listenerFactory: factory,
                metrics: metrics,
                mode: mode,
                bindsOnStart: bindsOnStart
            )
        }
    }

    private func grpcFactory(
        generationID: UUID,
        initiallyBound: Bool = false
    ) throws -> HarcGRPCNWListenerFactory {
        let binding = if initiallyBound {
            try HarcGRPCServedIdentityBinding(
                generationID: generationID,
                testTLSSPKISHA256: Data(repeating: 0xA7, count: 32)
            )
        } else {
            HarcGRPCServedIdentityBinding(generationID: generationID)
        }
        return HarcGRPCNWListenerFactory(
            servedIdentityBinding: binding,
            unreadyListenerProvider: { try NWListener(using: .tcp) }
        )
    }

    private func throwsInvalidated(
        _ binding: HarcGRPCServedIdentityBinding,
        _ generationID: UUID
    ) -> Bool {
        do {
            _ = try binding.requireTLSSPKISHA256(generationID: generationID)
            return false
        } catch HarcGRPCServedIdentityBindingError.invalidated {
            return true
        } catch {
            return false
        }
    }
}

private final class ControlledGRPCProcess:
    HarcGRPCServerProcessBoundary, @unchecked Sendable
{
    enum Mode: Sendable {
        case waitForCancellation
        case waitForRelease(RuntimeExitGate)
    }

    let listenerFactory: HarcGRPCNWListenerFactory
    let metrics: RuntimeProcessMetrics
    let mode: Mode
    let bindsOnStart: Bool

    init(
        listenerFactory: HarcGRPCNWListenerFactory,
        metrics: RuntimeProcessMetrics,
        mode: Mode,
        bindsOnStart: Bool
    ) {
        self.listenerFactory = listenerFactory
        self.metrics = metrics
        self.mode = mode
        self.bindsOnStart = bindsOnStart
    }

    func serve() async throws {
        metrics.markServing()
        if bindsOnStart {
            try await listenerFactory.reportBound()
        }
        switch mode {
        case .waitForCancellation:
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                metrics.markCancelled()
                throw error
            }
        case .waitForRelease(let gate):
            await gate.wait()
        }
    }

    func beginGracefulShutdown() {
        metrics.markGracefulShutdown()
    }
}

private final class RuntimeProcessMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var serving = false
    private var servingWaiters: [CheckedContinuation<Void, Never>] = []
    private var gracefulCount = 0
    private var cancelledCount = 0

    var gracefulShutdownCount: Int {
        lock.withLock { gracefulCount }
    }

    var cancellationCount: Int {
        lock.withLock { cancelledCount }
    }

    func markServing() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            serving = true
            defer { servingWaiters.removeAll() }
            return servingWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilServing() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if serving { return true }
                servingWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func markGracefulShutdown() {
        lock.withLock { gracefulCount += 1 }
    }

    func markCancelled() {
        lock.withLock { cancelledCount += 1 }
    }
}

private actor ManualRuntimeSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                resumeSatisfiedCountWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilWaiterCount(_ count: Int) async {
        guard waiters.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func fireNext() {
        guard let id = waiters.keys.first,
              let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in countWaiters {
            if waiters.count >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        countWaiters = remaining
    }
}

private actor RuntimeExitGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor RuntimeExitRecorder {
    private(set) var values: [UUID] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ id: UUID) {
        values.append(id)
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func waitForValue() async {
        guard values.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RuntimeCancellationCleanupGate {
    private var cleanupStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func sleepUntilReleased() async throws {
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            cleanupStarted = true
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            throw error
        }
    }

    func waitUntilCancellationCleanupStarted() async {
        guard !cleanupStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
#endif
