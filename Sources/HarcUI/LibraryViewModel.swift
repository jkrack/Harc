import Foundation
import Combine
import HarcStore

public enum LibraryFilter: Equatable, Sendable {
    case all
    case today
    case yesterday
    case thisWeek
    case pinned
    case day(Date)

    /// Whether a given recording matches this filter.
    public func matches(_ rec: Recording, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        switch self {
        case .all:
            return true
        case .today:
            return cal.isDate(rec.startedAt, inSameDayAs: now)
        case .yesterday:
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: now) else { return false }
            return cal.isDate(rec.startedAt, inSameDayAs: yesterday)
        case .thisWeek:
            return cal.isDate(rec.startedAt, equalTo: now, toGranularity: .weekOfYear)
        case .pinned:
            return rec.pinned
        case .day(let d):
            return cal.isDate(rec.startedAt, inSameDayAs: d)
        }
    }
}

/// Library-window view model. Debounces search queries and fetches results.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var searchText: String = ""
    @Published public private(set) var recordings: [Recording] = []
    @Published public var filter: LibraryFilter = .all {
        didSet { if oldValue != filter { applyCurrent() } }
    }
    @Published public private(set) var calendarMonth: Date = {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: comps) ?? Date()
    }()
    @Published public private(set) var daysWithRecordings: Set<Date> = []

    public let store: RecordingStore
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private var fullList: [Recording] = []

    public init(store: RecordingStore) {
        self.store = store
    }

    public func start() {
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] value in
                self?.performSearch(value)
            }
            .store(in: &cancellables)

        observationTask = Task { [weak self, store] in
            guard let self else { return }
            for await list in store.observeAll(pinnedFirst: true) {
                await MainActor.run {
                    self.fullList = list
                    if self.searchText.isEmpty {
                        self.recordings = self.apply(filter: self.filter, to: list)
                    }
                }
            }
        }

        Task { [weak self] in await self?.refreshDaysWithRecordings() }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        searchTask?.cancel()
        cancellables.removeAll()
    }

    public func advanceMonth(by delta: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .month, value: delta, to: calendarMonth) else { return }
        calendarMonth = next
        Task { [weak self] in await self?.refreshDaysWithRecordings() }
    }

    private func refreshDaysWithRecordings() async {
        do {
            let days = try await store.daysWithRecordings(inMonthContaining: calendarMonth)
            self.daysWithRecordings = days
        } catch {
            // Leave the previous set in place on error.
        }
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task { [weak self, store, filter] in
            guard let self else { return }
            do {
                if trimmed.isEmpty {
                    let all = try await store.fetchAll()
                    await MainActor.run {
                        self.fullList = all
                        self.recordings = self.apply(filter: filter, to: all)
                    }
                } else {
                    let results = try await store.search(query: trimmed)
                    await MainActor.run {
                        self.recordings = self.apply(filter: filter, to: results)
                    }
                }
            } catch {
                // Keep previous list on error.
            }
        }
    }

    private func applyCurrent() {
        recordings = apply(filter: filter, to: fullList)
    }

    private func apply(filter: LibraryFilter, to list: [Recording]) -> [Recording] {
        list.filter { filter.matches($0) }
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
