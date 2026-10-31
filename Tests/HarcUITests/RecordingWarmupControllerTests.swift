import Foundation
import Testing
@testable import HarcUI

private actor DeferredRecordingWarmup {
    private var operation: CheckedContinuation<Void, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            operation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if operation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<Void, Error>) {
        operation?.resume(with: result)
        operation = nil
    }
}

@Suite("Recording warmup ownership")
@MainActor
struct RecordingWarmupControllerTests {
    private enum Failure: Error { case unavailable }

    @Test("a replaced failure cannot notify or clear its successor")
    func replacedFailure() async throws {
        let controller = RecordingWarmupController()
        let old = DeferredRecordingWarmup()
        let next = DeferredRecordingWarmup()
        var events: [String] = []
        controller.start(operation: { try await old.run() },
                         onReady: { events.append("old ready") },
                         onFailure: { _ in events.append("old failure") })
        await old.waitUntilStarted()
        let oldTask = try #require(controller.task)
        controller.start(operation: { try await next.run() },
                         onReady: { events.append("new ready") },
                         onFailure: { _ in events.append("new failure") })
        await next.waitUntilStarted()
        let nextTask = try #require(controller.task)
        await old.finish(.failure(Failure.unavailable))
        await oldTask.value
        #expect(events.isEmpty)
        #expect(controller.isRunning)
        await next.finish(.success(()))
        await nextTask.value
        #expect(events == ["new ready"])
        #expect(!controller.isRunning)
    }

    @Test("cancelled operations cannot deliver late success or failure", arguments: [false, true])
    func cancelledCompletion(fails: Bool) async throws {
        let controller = RecordingWarmupController()
        let deferred = DeferredRecordingWarmup()
        var events: [String] = []
        controller.start(operation: { try await deferred.run() },
                         onReady: { events.append("ready") },
                         onFailure: { _ in events.append("failure") })
        await deferred.waitUntilStarted()
        let task = try #require(controller.task)
        controller.cancel()
        await deferred.finish(fails ? .failure(Failure.unavailable) : .success(()))
        await task.value
        #expect(events.isEmpty)
        #expect(!controller.isRunning)
    }

    @Test("the current failure reports once and releases ownership")
    func currentFailure() async throws {
        let controller = RecordingWarmupController()
        var failures = 0
        controller.start(operation: { throw Failure.unavailable },
                         onReady: { Issue.record("failed operation reported ready") },
                         onFailure: { _ in failures += 1 })
        let task = try #require(controller.task)
        await task.value
        #expect(failures == 1)
        #expect(!controller.isRunning)
    }
}
