import Foundation

/// Owns optional inference warmup without making capture wait for it.
@MainActor
public final class RecordingWarmupController {
    private(set) var task: Task<Void, Never>?
    private var generation: UUID?
    var isRunning: Bool { task != nil }

    public init() {}

    public func start(
        operation: @escaping @Sendable () async throws -> Void,
        onReady: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        cancel()
        let identity = UUID()
        generation = identity
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result: Result<Void, Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // Some operations return or throw a different error after being
            // cancelled. Ownership, not the error type, controls delivery.
            guard !Task.isCancelled, let self,
                  self.generation == identity else { return }
            self.task = nil
            self.generation = nil
            switch result {
            case .success: onReady()
            case .failure(let error):
                if !(error is CancellationError) { onFailure(error) }
            }
        }
    }

    public func cancel() {
        generation = nil
        task?.cancel()
        task = nil
    }
}
