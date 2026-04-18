import Foundation
import Combine
import HarcStore

/// View model surfacing the current list of recordings from `RecordingStore`.
/// Plan 5's `RecordingsIndex` is superseded by this class.
@MainActor
public final class RecordingsViewModel: ObservableObject {
    @Published public private(set) var recordings: [Recording] = []

    public let store: RecordingStore
    private var observationTask: Task<Void, Never>?

    public init(store: RecordingStore) {
        self.store = store
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self, store] in
            guard let self else { return }
            for await list in store.observeAll(pinnedFirst: true) {
                await MainActor.run { self.recordings = list }
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Non-observed one-shot refresh — useful after a direct DB mutation that should
    /// surface immediately without waiting for the ValueObservation callback.
    public func refresh() async {
        do {
            let latest = try await store.fetchAll()
            self.recordings = latest
        } catch {
            // Keep the previous list on error.
        }
    }

    public func delete(id: Int64) async throws {
        try await store.softDelete(id: id)
    }

    public func rename(id: Int64, title: String?) async throws {
        try await store.rename(id: id, title: title)
    }

    public func togglePin(id: Int64, currentlyPinned: Bool) async throws {
        try await store.setPinned(id: id, pinned: !currentlyPinned)
    }
}
