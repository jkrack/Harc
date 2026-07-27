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
    @Published public private(set) var totalBytes: Int64 = 0
    /// Populated only when `searchText` is non-empty. BM25-ranked.
    @Published public private(set) var hits: [TranscriptHit] = []
    @Published public private(set) var searchError: String?
    @Published public var filter: LibraryFilter = .all {
        didSet { if oldValue != filter { applyCurrent() } }
    }
    @Published public private(set) var calendarMonth: Date = {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: comps) ?? Date()
    }()
    @Published public private(set) var daysWithRecordings: Set<Date> = []
    /// Set once the user navigates months themselves, so the automatic jump
    /// to the newest recording's month never fights their choice.
    private var hasUserChosenMonth = false

    public let store: RecordingStore
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private var fullList: [Recording] = []

    /// Embedder used to blend chunk-level vector hits into search. Nil keeps
    /// search purely lexical — which is also the behaviour when the library has
    /// never been indexed, since hybridSearch falls back on its own.
    public var searchEmbedder: (any TextEmbedder)?

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
                let totalBytes = await Self.storageBytes(for: list)
                await MainActor.run {
                    self.fullList = list
                    self.totalBytes = totalBytes
                    if self.searchText.isEmpty {
                        self.recordings = self.apply(filter: self.filter, to: list)
                    }
                    self.alignCalendarToNewestRecordingIfNeeded(list)
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

    /// Open the calendar on the newest recording's month when the current
    /// month has none.
    ///
    /// The calendar starts on today, but a library whose most recent
    /// recording is weeks old then opens on a blank grid with no dots — the
    /// one view whose whole job is showing where the recordings are shows
    /// none of them. Only runs before the user navigates: once they pick a
    /// month, it's theirs.
    private func alignCalendarToNewestRecordingIfNeeded(_ list: [Recording]) {
        guard !hasUserChosenMonth, !list.isEmpty else { return }
        let cal = Calendar.current
        let newest = list
            .map { $0.startedAt }
            .max()
        guard let newest else { return }
        guard !cal.isDate(newest, equalTo: calendarMonth, toGranularity: .month) else { return }
        let comps = cal.dateComponents([.year, .month], from: newest)
        guard let month = cal.date(from: comps) else { return }
        calendarMonth = month
        Task { [weak self] in await self?.refreshDaysWithRecordings() }
    }

    /// Called when the date-scope popover is about to present. The grid now
    /// exists only while it is open, so "open on the month that has the
    /// recordings" has to happen at presentation time rather than at load.
    public func alignCalendarForPresentation() {
        alignCalendarToNewestRecordingIfNeeded(recordings.isEmpty ? fullList : recordings)
        Task { [weak self] in await self?.refreshDaysWithRecordings() }
    }

    public func advanceMonth(by delta: Int) {
        hasUserChosenMonth = true
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
                    let totalBytes = await Self.storageBytes(for: all)
                    await MainActor.run {
                        self.fullList = all
                        self.totalBytes = totalBytes
                        self.recordings = self.apply(filter: filter, to: all)
                        self.hits = []
                        self.searchError = nil
                    }
                } else {
                    // Hybrid when an embedder is configured: keyword and vector
                    // hits fused by rank. Falls back to keyword-only inside
                    // hybridSearch when nothing is indexed, so an un-indexed
                    // library behaves exactly as it always has.
                    let embedder = await MainActor.run { self.searchEmbedder }
                    let results: [TranscriptHit]
                    if let embedder {
                        results = try await store.hybridSearch(query: trimmed, embedder: embedder)
                    } else {
                        results = try await store.search(query: trimmed)
                    }
                    await MainActor.run {
                        self.hits = results
                        self.searchError = nil
                        // `recordings` stays populated with the unfiltered list so
                        // the detail pane can still look up full Recording data
                        // by wavPath. The main view branches on searchText.isEmpty
                        // to pick which list to render.
                    }
                }
            } catch {
                await MainActor.run {
                    self.hits = []
                    self.searchError = Self.searchErrorMessage(from: error)
                }
            }
        }
    }

    private static func searchErrorMessage(from error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "Search index unavailable." }
        return "Search index unavailable: \(message)"
    }

    nonisolated private static func storageBytes(for recordings: [Recording]) async -> Int64 {
        recordings.reduce(Int64(0)) { total, recording in
            let url = URL(fileURLWithPath: recording.wavPath)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return total
            }
            return total + Int64(size)
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

    public func delete(recording: Recording) async throws {
        try await RecordingDeletionService(store: store).delete(recording: recording)
    }
}
