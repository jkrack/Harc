import Testing
import Foundation
@testable import HarcSummarize

@Suite("SummarizationQueueStore")
struct SummarizationQueueStoreTests {

    private func expectEventually(
        timeoutMs: Int = 2000,
        _ check: @Sendable () async -> Bool,
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("expectEventually timed out", sourceLocation: sourceLocation)
    }

    @Test("store mirrors queue state: pending grows, current is set, drained leaves both empty")
    @MainActor
    func mirrorsQueueState() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(1)
        await queue.enqueue(2)

        // Eventually: one is current, one is pending. totalInFlight
        // counts both simultaneously.
        await expectEventually {
            await MainActor.run {
                ((store.current == 1 && store.pending == [2])
                 || (store.current == 2 && store.pending == []))
                && store.totalInFlight >= 1
            }
        }

        // After drain both are clear and totalInFlight == 0.
        await expectEventually {
            await MainActor.run {
                store.current == nil
                && store.pending.isEmpty
                && store.totalInFlight == 0
            }
        }
    }

    @Test("isQueued and position reflect both current and pending")
    @MainActor
    func isQueuedAndPosition() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(10)
        await queue.enqueue(11)
        await queue.enqueue(12)

        await expectEventually {
            await MainActor.run {
                store.isQueued(10) && store.isQueued(11) && store.isQueued(12)
                && store.position(10) != nil && store.position(12) != nil
            }
        }

        // Clean up so the test doesn't hang on outstanding sleeps.
        await queue.cancelAll()
    }

    @Test("store captures non-cancellation .finished(.failure) into lastFailures keyed by id")
    @MainActor
    func capturesNonCancellationFailures() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            throw Boom()
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(42)
        await expectEventually {
            await MainActor.run { store.lastFailures[42] == "boom" }
        }
    }

    @Test("store swallows CancellationError — lastFailures stays nil when cancellation lands")
    @MainActor
    func swallowsCancellationError() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            // Cooperate with cancellation.
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(77)
        // Wait for it to become current, then cancel.
        await expectEventually { await MainActor.run { store.current == 77 } }
        await queue.cancel(77)
        await expectEventually { await MainActor.run { store.current == nil } }

        // Give the event-apply loop one more hop.
        try await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            #expect(store.lastFailures[77] == nil)
        }
    }

    @Test("enqueue clears a prior failure entry for the same id")
    @MainActor
    func enqueueClearsPriorFailure() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() -> Int {
                lock.withLock { count += 1; return count }
            }
        }
        let counter = Counter()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            if counter.increment() == 1 {
                throw Boom()
            }
            // Second run succeeds.
        }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(5)
        await expectEventually { await MainActor.run { store.lastFailures[5] == "boom" } }

        await queue.enqueue(5)
        // On enqueue, the failure should be cleared immediately (before the next run).
        await expectEventually { await MainActor.run { store.lastFailures[5] == nil } }
    }

    @Test("dismissFailure(id) removes the entry")
    @MainActor
    func dismissFailure() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in throw Boom() }
        let store = await SummarizationQueueStore(queue: queue)

        await queue.enqueue(8)
        await expectEventually { await MainActor.run { store.lastFailures[8] == "boom" } }

        store.dismissFailure(8)
        #expect(store.lastFailures[8] == nil)
    }
}
