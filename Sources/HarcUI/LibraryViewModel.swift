import Foundation
import Combine
import HarcStore

/// Library-window view model. Debounces search queries and fetches results.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var searchText: String = ""
    @Published public private(set) var recordings: [Recording] = []

    public let store: RecordingStore
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init(store: RecordingStore) {
        self.store = store
    }

    public func start() {
        // Debounce search changes to 200ms.
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] value in
                self?.performSearch(value)
            }
            .store(in: &cancellables)

        // Baseline: observe the store when search is empty.
        observationTask = Task { [weak self, store] in
            guard let self else { return }
            for await list in store.observeAll(pinnedFirst: true) {
                await MainActor.run {
                    if self.searchText.isEmpty {
                        self.recordings = list
                    }
                }
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        searchTask?.cancel()
        cancellables.removeAll()
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task { [weak self, store] in
            guard let self else { return }
            do {
                if trimmed.isEmpty {
                    let all = try await store.fetchAll()
                    await MainActor.run { self.recordings = all }
                } else {
                    let results = try await store.search(query: trimmed)
                    await MainActor.run { self.recordings = results }
                }
            } catch {
                // Keep previous list on error.
            }
        }
    }

    // MARK: Actions (pass-through to store)

    public func rename(id: Int64, title: String?) async throws {
        try await store.rename(id: id, title: title)
    }

    public func togglePin(id: Int64, currentlyPinned: Bool) async throws {
        try await store.setPinned(id: id, pinned: !currentlyPinned)
    }

    public func delete(id: Int64) async throws {
        try await store.softDelete(id: id)
    }
}
