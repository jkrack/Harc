import Foundation

/// One-slot serial mutex for background work. At most one `performOne`
/// body executes at a time across all producers. Forward-looking for the
/// semantic-search stage (§10 of the semantic-search spec) — Stage 3's
/// only tenant is `SummarizationQueue`, for which it's a pass-through.
///
/// Thread model: actor. Callers `await`. Cancellation of the caller's
/// `Task` propagates into the operation via structured concurrency.
public actor BackgroundWorkCoordinator {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func performOne<T>(_ op: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // Woken — the previous holder transferred the slot to us.
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()  // slot transfers — busy stays true
        } else {
            busy = false
        }
    }
}
