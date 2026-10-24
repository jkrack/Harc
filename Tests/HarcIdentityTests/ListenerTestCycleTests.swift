import Foundation
import HarcTestSupport
import Network
import Testing

@Suite("Bounded listener test lifecycle", .serialized, .processWideSystemResource)
struct ListenerTestCycleTests {
    @Test("A real plaintext listener reaches ready and then cancelled")
    func plaintextControl() async throws {
        try await ListenerTestCycle.run(NWListener(using: .tcp, on: .any))
    }

    @Test("Late and duplicate callbacks cannot complete the continuation twice")
    func duplicateCallbacks() async throws {
        let fixture = Fixture(states: [.ready, .cancelled, .failed(.posix(.EINVAL)), .cancelled])
        try await fixture.cycle.wait()
        #expect(fixture.cancellations == 1)
        #expect(fixture.cleanups == 1)
    }

    @Test("Cancellation before readiness is not a successful restart")
    func cancelledBeforeReady() async {
        let fixture = Fixture(states: [.cancelled])
        await #expect(throws: ListenerTestCycle.Failure.cancelledBeforeReady) {
            try await fixture.cycle.wait()
        }
        #expect(fixture.cancellations == 1)
        #expect(fixture.cleanups == 1)
    }

    @Test("Listener errors propagate rather than becoming known issues")
    func failure() async {
        let fixture = Fixture(states: [.failed(.posix(.EINVAL))])
        await #expect(throws: NWError.posix(.EINVAL)) {
            try await fixture.cycle.wait()
        }
        #expect(fixture.cancellations == 1)
        #expect(fixture.cleanups == 1)
    }

    @Test("Missing readiness or cancellation callbacks fail within the deadline", arguments: [false, true])
    func missingCallback(ready: Bool) async {
        let fixture = Fixture(states: ready ? [.ready] : [], timeout: 0.02)
        await #expect(throws: ListenerTestCycle.Failure.deadlineExceeded) {
            try await fixture.cycle.wait()
        }
        #expect(fixture.cancellations == 1)
        #expect(fixture.cleanups == 1)
    }

    @Test("Task cancellation completes even when the listener never calls back")
    func taskCancellation() async {
        let fixture = Fixture(states: [])
        let task = Task { try await fixture.cycle.wait() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.cancellations == 1)
        #expect(fixture.cleanups == 1)
    }

    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellationCount = 0
        private var cleanupCount = 0
        var cancellations: Int { lock.withLock { cancellationCount } }
        var cleanups: Int { lock.withLock { cleanupCount } }
        let states: [NWListener.State]
        let timeout: TimeInterval
        init(states: [NWListener.State], timeout: TimeInterval = 5) {
            self.states = states
            self.timeout = timeout
        }
        var cycle: ListenerTestCycle {
            ListenerTestCycle(
                timeout: timeout,
                start: { _, update in self.states.forEach(update) },
                cancel: { self.lock.withLock { self.cancellationCount += 1 } },
                clearHandlers: { self.lock.withLock { self.cleanupCount += 1 } }
            )
        }
    }
}
