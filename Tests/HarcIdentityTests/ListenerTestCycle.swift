import Foundation
import Network

/// Test-only bridge: success requires ready followed by cancelled. Network
/// callbacks, the deadline, and task cancellation all resolve on one queue.
final class ListenerTestCycle: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case cancelledBeforeReady
        case deadlineExceeded
    }

    typealias Start = @Sendable (
        DispatchQueue, @escaping @Sendable (NWListener.State) -> Void
    ) -> Void

    private let queue = DispatchQueue(label: "harc.listener-test-cycle")
    private let start: Start
    private let cancel: @Sendable () -> Void
    private let clearHandlers: @Sendable () -> Void
    private let timeout: TimeInterval
    // Queue-confined state, including cancellation before continuation setup.
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: DispatchWorkItem?
    private var ready = false
    private var completed = false
    private var cancellationRequested = false
    private var cancelIssued = false

    init(
        timeout: TimeInterval,
        start: @escaping Start,
        cancel: @escaping @Sendable () -> Void,
        clearHandlers: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        self.start = start
        self.cancel = cancel
        self.clearHandlers = clearHandlers
    }

    static func run(_ listener: NWListener) async throws {
        let cycle = ListenerTestCycle(
            timeout: 5,
            start: { queue, update in
                listener.newConnectionHandler = { $0.cancel() }
                listener.stateUpdateHandler = update
                listener.start(queue: queue)
            },
            cancel: { listener.cancel() },
            clearHandlers: {
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
            }
        )
        try await cycle.wait()
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    self.continuation = continuation
                    if self.cancellationRequested {
                        self.finish(.failure(CancellationError()))
                        return
                    }
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(Failure.deadlineExceeded))
                    }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + self.timeout, execute: deadline)
                    self.start(self.queue) { [weak self] state in
                        guard let self else { return }
                        self.queue.async { self.received(state) }
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancellationRequested = true
                if self.continuation != nil {
                    self.finish(.failure(CancellationError()))
                }
            }
        }
    }

    private func received(_ state: NWListener.State) {
        guard !completed else { return }
        switch state {
        case .ready:
            ready = true
            requestCancel()
        case .cancelled:
            finish(ready ? .success(()) : .failure(Failure.cancelledBeforeReady))
        case .failed(let error):
            finish(.failure(error))
        default:
            break
        }
    }

    private func requestCancel() {
        guard !cancelIssued else { return }
        cancelIssued = true
        cancel()
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !completed, let continuation else { return }
        completed = true
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        clearHandlers()
        requestCancel()
        continuation.resume(with: result)
    }
}
