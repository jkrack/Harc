import Foundation
import Testing
import HarcStore
@testable import HarcUI

@Suite("Library refresh publication")
@MainActor
struct LibraryRefreshPublicationTests {
    @Test("late empty refresh keeps the current filter and a newer observed rename", .timeLimit(.minutes(1)))
    func lateEmptyRefreshCannotOverwriteObservation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.library.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        defer { Task { await fixture.gate.release() } }
        fixture.library.filter = .day(fixture.older.startedAt)
        fixture.library.refreshAfterExternalChange()
        let stale = fixture.library.searchTask
        await fixture.gate.waitForCapture()
        try await fixture.store.rename(id: #require(fixture.today.id), title: "Renamed Customer Call")
        fixture.library.publishObservedRecordings(try await fixture.store.fetchAll(), totalBytes: 0)
        fixture.library.filter = .all
        #expect(fixture.library.recordings.first { $0.id == fixture.today.id }?.title == "Renamed Customer Call")
        await fixture.gate.release()
        await stale?.value
        #expect(fixture.library.filter == .all)
        #expect(fixture.library.recordings.count == 2)
        #expect(fixture.library.recordings.first { $0.id == fixture.today.id }?.title == "Renamed Customer Call")
    }

    @Test("cancelled empty refresh cannot clear the current query results", .timeLimit(.minutes(1)))
    func cancelledEmptyRefreshCannotClearSearchResults() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.library.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        defer { Task { await fixture.gate.release() } }
        fixture.library.refreshAfterExternalChange()
        let stale = fixture.library.searchTask
        await fixture.gate.waitForCapture()
        fixture.library.searchText = "pricing"
        fixture.library.refreshAfterExternalChange()
        await fixture.library.searchTask?.value
        #expect(fixture.library.hits.first?.recording.id == fixture.today.id)
        await fixture.gate.release()
        await stale?.value
        #expect(fixture.library.searchText == "pricing")
        #expect(fixture.library.hits.first?.recording.id == fixture.today.id)
    }

    private struct Fixture {
        let store: RecordingStore
        let library: LibraryViewModel
        let today: Recording
        let older: Recording
        let gate: PausedLibraryFetch
        let directory: URL

        @MainActor static func make() async throws -> Self {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarcLibraryRefresh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try await RecordingStore.inMemory()
            var today = Recording(wavPath: directory.appendingPathComponent("today.wav").path, startedAt: Date())
            today.title = "Today Customer Call"
            today.transcriptText = "pricing renewal"
            let savedToday = try await store.upsert(today)
            var older = Recording(wavPath: directory.appendingPathComponent("older.wav").path, startedAt: Date().addingTimeInterval(-864_000))
            older.title = "Last Week Call"
            let savedOlder = try await store.upsert(older)
            let gate = PausedLibraryFetch()
            let library = LibraryViewModel(store: store, fetchAllRecordings: {
                let snapshot = try await store.fetchAll()
                await gate.holdFirstSnapshot()
                return snapshot
            })
            library.publishObservedRecordings(try await store.fetchAll(), totalBytes: 0)
            return Self(store: store, library: library, today: savedToday, older: savedOlder, gate: gate, directory: directory)
        }
    }
}

private actor PausedLibraryFetch {
    private var captured = false
    private var released = false
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func holdFirstSnapshot() async {
        guard !captured else { return }
        captured = true
        captureWaiters.forEach { $0.resume() }
        captureWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForCapture() async {
        guard !captured else { return }
        await withCheckedContinuation { captureWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
