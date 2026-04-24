import Foundation
import Combine

/// `@MainActor`-bound bridge from `SummarizationQueue`'s async events to
/// Combine `@Published` properties so SwiftUI views can `@EnvironmentObject`
/// and render queue state without managing their own Tasks. Mirrors the
/// `ModelManagerStore` pattern used for the Model Manager.
@MainActor
public final class SummarizationQueueStore: ObservableObject {

    @Published public private(set) var pending: [Int64] = []
    @Published public private(set) var current: Int64? = nil

    public let queue: SummarizationQueue
    private var observer: Task<Void, Never>? = nil

    /// Init is `async` because the subscription must be registered with the
    /// queue actor synchronously relative to the caller's `await`. If the
    /// subscription were deferred (i.e. `await queue.events()` inside a
    /// detached Task), events emitted by any `queue.enqueue(...)` the caller
    /// makes immediately after init could fire before the subscriber is
    /// registered and be lost.
    public init(queue: SummarizationQueue) async {
        self.queue = queue
        let stream = await queue.events()
        self.observer = Task { [weak self] in
            for await event in stream {
                await MainActor.run { self?.apply(event) }
            }
        }
    }

    deinit {
        observer?.cancel()
    }

    /// True when `id` is either currently running or waiting in the queue.
    public func isQueued(_ id: Int64) -> Bool {
        current == id || pending.contains(id)
    }

    /// 1-based position — 1 if currently running, 2+ if pending.
    /// Returns nil if the id is not tracked.
    public func position(_ id: Int64) -> Int? {
        if current == id { return 1 }
        if let idx = pending.firstIndex(of: id) {
            return idx + (current == nil ? 1 : 2)
        }
        return nil
    }

    /// Total jobs on the clock — pending + (current != nil ? 1 : 0).
    public var totalInFlight: Int {
        pending.count + (current == nil ? 0 : 1)
    }

    // MARK: - Internals

    private func apply(_ event: SummarizationQueueEvent) {
        switch event {
        case .enqueued(let id):
            if current != id, !pending.contains(id) {
                pending.append(id)
            }
        case .started(let id):
            if let idx = pending.firstIndex(of: id) { pending.remove(at: idx) }
            current = id
        case .finished(let id, _):
            if current == id { current = nil }
        case .queueDrained:
            current = nil
            pending.removeAll()
        }
    }
}
