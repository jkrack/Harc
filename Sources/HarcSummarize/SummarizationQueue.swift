import Foundation

/// One event per state transition in the queue. The `@MainActor`
/// `SummarizationQueueStore` bridge forwards these into `@Published`
/// properties for SwiftUI views. `CancellationError` arrives in the
/// `.failure` payload distinctly from `SummarizerError.*`.
public enum SummarizationQueueEvent: Sendable {
    case enqueued(Int64)
    case started(Int64)
    /// A pending id removed before it ever started. Without this event the
    /// UI bridge kept showing the job as queued (wrong `isQueued`, wrong
    /// positions) until the whole queue drained.
    case cancelled(Int64)
    case finished(Int64, Result<Void, Error>)
    case queueDrained
}

/// FIFO summarization queue. Closure-driven — the perform body is injected
/// at init so the queue itself has no dep on HarcStore / HarcModels /
/// SummarizerService. At most one job runs at a time (enforced by the
/// worker task here AND by the shared `BackgroundWorkCoordinator`).
///
/// Thread model: actor. Events are published through a replay-free
/// `AsyncStream` per subscriber. No disk persistence — app quit drops
/// pending IDs; `AppDelegate` re-seeds on launch via
/// `RecordingStore.unsummarizedRecordings`.
public actor SummarizationQueue {
    public typealias Perform = @Sendable (Int64) async throws -> Void

    private let coordinator: BackgroundWorkCoordinator
    private let perform: Perform

    public private(set) var pending: [Int64] = []
    public private(set) var current: Int64? = nil

    private var worker: Task<Void, Never>? = nil
    private var currentTask: Task<Void, Error>? = nil
    private var subscribers: [UUID: AsyncStream<SummarizationQueueEvent>.Continuation] = [:]

    public init(
        coordinator: BackgroundWorkCoordinator,
        perform: @escaping Perform
    ) {
        self.coordinator = coordinator
        self.perform = perform
    }

    // MARK: - Control

    public func enqueue(_ id: Int64) {
        // Dedupe — both in-flight and queued.
        if current == id { return }
        if pending.contains(id) { return }
        pending.append(id)
        emit(.enqueued(id))
        startWorkerIfNeeded()
    }

    /// Cancel a specific id. If it's still in `pending`, drop it and emit
    /// `.cancelled` so observers stop displaying it as queued. If it's
    /// `current`, cancel the in-flight task — cancellation is cooperative:
    /// the `perform` closure must observe `Task.isCancelled` and throw
    /// `CancellationError` for `.finished(id, .failure(CancellationError))`
    /// to surface. A perform body that swallows cancellation silently will
    /// produce a `.finished(.success(()))` payload despite the cancel call.
    public func cancel(_ id: Int64) {
        if let idx = pending.firstIndex(of: id) {
            pending.remove(at: idx)
            emit(.cancelled(id))
            return
        }
        if current == id {
            currentTask?.cancel()
        }
    }

    public func cancelAll() {
        pending.removeAll()
        currentTask?.cancel()
    }

    // MARK: - Events

    /// Actor-isolated on purpose: subscription must be synchronous relative to
    /// the caller's `await` so that any `emit(...)` happening after this
    /// returns is seen by the subscriber. A nonisolated shape (kicking off
    /// `Task { await attach(...) }`) races — early events fire before the
    /// continuation is registered and are lost for that subscriber.
    public func events() -> AsyncStream<SummarizationQueueEvent> {
        AsyncStream { continuation in
            let token = UUID()
            self.subscribers[token] = continuation
            continuation.onTermination = { _ in
                Task { await self.detach(token: token) }
            }
        }
    }

    private func detach(token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func emit(_ event: SummarizationQueueEvent) {
        for (_, c) in subscribers { c.yield(event) }
    }

    // MARK: - Worker loop

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    private func run() async {
        while let id = popNext() {
            current = id
            emit(.started(id))
            let result: Result<Void, Error>
            let task = Task { [coordinator, perform] in
                try await coordinator.performOne { try await perform(id) }
            }
            currentTask = task
            do {
                try await task.value
                result = .success(())
            } catch {
                result = .failure(error)
            }
            currentTask = nil
            current = nil
            emit(.finished(id, result))
        }
        emit(.queueDrained)
        worker = nil
    }

    private func popNext() -> Int64? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
