import Testing
import Foundation
@testable import HarcSummarize

@Suite("SummarizationQueue")
struct SummarizationQueueTests {

    /// Records the order + overlap of `perform` invocations.
    actor Recorder {
        private(set) var starts: [Int64] = []
        private(set) var active = 0
        private(set) var peakActive = 0
        private(set) var cancelled: [Int64] = []
        func enter(_ id: Int64) {
            starts.append(id)
            active += 1
            peakActive = max(peakActive, active)
        }
        func leave() { active -= 1 }
        func markCancelled(_ id: Int64) { cancelled.append(id) }
    }

    /// Wait for a closure to return true, polling every 5ms, up to
    /// `timeoutMs`. Fails the calling test on timeout.
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

    @Test("three enqueues execute sequentially (peak concurrency == 1)")
    func serializesThree() async throws {
        let recorder = Recorder()
        let coord = BackgroundWorkCoordinator()
        let queue = SummarizationQueue(coordinator: coord) { id in
            await recorder.enter(id)
            try await Task.sleep(nanoseconds: 30_000_000)
            await recorder.leave()
        }

        await queue.enqueue(1)
        await queue.enqueue(2)
        await queue.enqueue(3)

        await expectEventually { await recorder.starts == [1, 2, 3] }
        let peak = await recorder.peakActive
        #expect(peak == 1)
    }

    @Test("enqueueing the same id twice executes it once (dedupe)")
    func dedupeOnInsert() async throws {
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            await recorder.enter(id)
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.leave()
        }
        await queue.enqueue(7)
        await queue.enqueue(7)   // duplicate — should be dropped
        await queue.enqueue(7)   // duplicate — should be dropped

        // Give plenty of time for the first to start + finish.
        try await Task.sleep(nanoseconds: 100_000_000)
        let starts = await recorder.starts
        #expect(starts == [7])
    }

    @Test("cancel of a queued id removes it before perform runs")
    func cancelQueued() async throws {
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            await recorder.enter(id)
            try await Task.sleep(nanoseconds: 40_000_000)
            await recorder.leave()
        }
        await queue.enqueue(1)
        await queue.enqueue(2)   // will be in pending while 1 runs
        await queue.cancel(2)

        await expectEventually { await recorder.starts == [1] }
        // Give the worker time to drain; id 2 should never start.
        try await Task.sleep(nanoseconds: 60_000_000)
        let starts = await recorder.starts
        #expect(starts == [1])
    }

    @Test("cancel of the currently-running id surfaces CancellationError and advances")
    func cancelCurrent() async throws {
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            await recorder.enter(id)
            do {
                try await Task.sleep(nanoseconds: 500_000_000)  // 500 ms — plenty of time to cancel
            } catch is CancellationError {
                await recorder.markCancelled(id)
                await recorder.leave()
                throw CancellationError()
            }
            await recorder.leave()
        }

        await queue.enqueue(10)
        await queue.enqueue(11)

        // Wait until 10 is actually running before cancelling.
        await expectEventually { await recorder.starts == [10] }
        await queue.cancel(10)

        await expectEventually { await recorder.starts == [10, 11] }
        let cancelled = await recorder.cancelled
        #expect(cancelled == [10])
    }

    @Test("events stream yields enqueued/started/finished/queueDrained in order")
    func eventStreamOrdering() async throws {
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { _ in
            // Instant success.
        }
        let stream = await queue.events()
        var iter = stream.makeAsyncIterator()

        await queue.enqueue(5)

        // Consume up to drained.
        var observed: [String] = []
        for _ in 0..<4 {
            guard let ev = await iter.next() else { break }
            switch ev {
            case .enqueued(let i):    observed.append("enqueued(\(i))")
            case .started(let i):     observed.append("started(\(i))")
            case .cancelled(let i):   observed.append("cancelled(\(i))")
            case .finished(let i, let r):
                switch r {
                case .success: observed.append("finished(\(i), success)")
                case .failure: observed.append("finished(\(i), failure)")
                }
            case .queueDrained:       observed.append("queueDrained")
            }
        }
        #expect(observed == [
            "enqueued(5)",
            "started(5)",
            "finished(5, success)",
            "queueDrained",
        ])
    }

    @Test("failing perform yields finished(.failure) and queue advances")
    func failureAdvances() async throws {
        struct Boom: Error {}
        let recorder = Recorder()
        let queue = SummarizationQueue(coordinator: BackgroundWorkCoordinator()) { id in
            if id == 1 { throw Boom() }
            await recorder.enter(id)
            await recorder.leave()
        }
        await queue.enqueue(1)
        await queue.enqueue(2)
        await expectEventually { await recorder.starts == [2] }
    }
}
