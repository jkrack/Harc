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
    @Published public private(set) var lastFailures: [Int64: String] = [:]
    /// Throughput of the in-flight job, fed by the perform closure via
    /// `updateLiveStats`. Cleared when the job finishes.
    @Published public private(set) var liveStats: GenerationStats? = nil

    /// Called (on any thread) by the summarization perform closure with
    /// interim throughput snapshots for the current job.
    public nonisolated func updateLiveStats(_ stats: GenerationStats) {
        Task { @MainActor in self.liveStats = stats }
    }

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

    /// Remove a failure entry — the UI's Dismiss action on the `.failed`
    /// card state calls this to clear the banner without re-enqueuing.
    public func dismissFailure(_ id: Int64) {
        lastFailures.removeValue(forKey: id)
    }

    // MARK: - Internals

    private func apply(_ event: SummarizationQueueEvent) {
        switch event {
        case .enqueued(let id):
            // Retrying (re-enqueuing an id with a prior failure) clears the
            // banner so the card shows .queued / .inFlight instead of stale
            // .failed. Also handles the plain "first enqueue" case where
            // lastFailures[id] is already nil.
            lastFailures.removeValue(forKey: id)
            if current != id, !pending.contains(id) {
                pending.append(id)
            }
        case .started(let id):
            if let idx = pending.firstIndex(of: id) { pending.remove(at: idx) }
            current = id
            liveStats = nil
        case .finished(let id, let result):
            if current == id { current = nil }
            liveStats = nil
            if case .failure(let error) = result {
                // CancellationError is user-initiated — don't surface as a
                // failure in the UI; the card returns to .empty / .summary
                // based on summaryMarkdown presence.
                if !(error is CancellationError) {
                    lastFailures[id] = error.localizedDescription
                }
            }
        case .queueDrained:
            current = nil
            pending.removeAll()
        }
    }
}
