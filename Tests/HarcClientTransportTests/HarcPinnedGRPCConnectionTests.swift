#if canImport(Network)
import Foundation
import Testing
@testable import HarcClientTransport

@Suite("Pinned gRPC connection ownership")
struct HarcPinnedGRPCConnectionTests {
    @Test("graceful shutdown is idempotent and drains the connection task")
    func gracefulShutdown() async throws {
        let run = ControlledConnectionRun()
        let probe = GracefulShutdownProbe()
        let owner = HarcClientConnectionTaskOwner(
            beginGracefulShutdown: {
                Task {
                    await probe.recordCall()
                    await run.finish()
                }
            }
        )
        await owner.start {
            try await run.run()
        }
        await run.waitUntilStarted()

        try await owner.shutdownGracefully()
        #expect(await owner.status() == .stoppedGracefully)
        #expect(await probe.callCount() == 1)

        try await owner.shutdownGracefully()
        try await owner.waitForTermination()
        #expect(await probe.callCount() == 1)
    }

    @Test("graceful shutdown immediately after start crosses the run-entry barrier")
    func gracefulShutdownImmediatelyAfterStart() async throws {
        let run = ControlledConnectionRun()
        let owner = HarcClientConnectionTaskOwner(
            beginGracefulShutdown: {
                Task {
                    await run.finish()
                }
            }
        )
        await owner.start {
            try await run.run()
        }

        try await owner.shutdownGracefully()
        #expect(await owner.status() == .stoppedGracefully)
    }

    @Test("immediate shutdown cancels the connection task")
    func immediateShutdown() async {
        let run = ControlledConnectionRun()
        let probe = GracefulShutdownProbe()
        let owner = HarcClientConnectionTaskOwner(
            beginGracefulShutdown: {
                Task {
                    await probe.recordCall()
                }
            }
        )
        await owner.start {
            try await run.run()
        }
        await run.waitUntilStarted()

        await owner.shutdownImmediately()
        #expect(await owner.status() == .stoppedImmediately)
        #expect(await run.cancellationWasObserved())
        #expect(await probe.callCount() == 0)

        await owner.shutdownImmediately()
        #expect(await owner.status() == .stoppedImmediately)
    }

    @Test("an unexpected runConnections failure is observable")
    func unexpectedFailure() async {
        let owner = HarcClientConnectionTaskOwner(
            beginGracefulShutdown: {}
        )
        await owner.start {
            throw InjectedConnectionFailure()
        }

        await #expect(throws: HarcPinnedGRPCConnectionError
            .unexpectedTermination("injected connection failure")) {
            try await owner.waitForTermination()
        }
        #expect(
            await owner.status()
                == .failed("injected connection failure")
        )
    }

    @Test("an unexpected clean runConnections return is observable")
    func unexpectedReturn() async {
        let owner = HarcClientConnectionTaskOwner(
            beginGracefulShutdown: {}
        )
        await owner.start {}

        await #expect(throws: HarcPinnedGRPCConnectionError
            .unexpectedTermination("runConnections returned unexpectedly")) {
            try await owner.waitForTermination()
        }
        #expect(
            await owner.status()
                == .failed("runConnections returned unexpectedly")
        )
    }
}

private struct InjectedConnectionFailure: Error, CustomStringConvertible {
    var description: String { "injected connection failure" }
}

private actor GracefulShutdownProbe {
    private var calls = 0

    func recordCall() {
        calls += 1
    }

    func callCount() -> Int {
        calls
    }
}

private actor ControlledConnectionRun {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var finishRequested = false
    private var cancellationRequested = false
    private var observedCancellation = false

    func run() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                started = true
                if finishRequested {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                if cancellationRequested {
                    releaseContinuation?.resume()
                    releaseContinuation = nil
                }
            }
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishRequested = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func cancellationWasObserved() -> Bool {
        observedCancellation
    }

    private func cancel() {
        cancellationRequested = true
        observedCancellation = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
#endif
