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

        // Eventually: one is current, one is pending.
        await expectEventually {
            await MainActor.run {
                (store.current == 1 && store.pending == [2])
                || (store.current == 2 && store.pending == [])
            }
        }

        // After drain both are clear.
        await expectEventually {
            await MainActor.run {
                store.current == nil && store.pending.isEmpty
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
}
