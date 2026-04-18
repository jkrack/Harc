import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("RecordingStore")
struct RecordingStoreTests {
    private func makeInMemoryStore() async throws -> RecordingStore {
        try await RecordingStore.inMemory()
    }

    private func sampleRecording(wavPath: String = "/tmp/a.wav", title: String? = nil) -> Recording {
        Recording(
            wavPath: wavPath,
            txtPath: wavPath.replacingOccurrences(of: ".wav", with: ".txt"),
            jsonPath: wavPath.replacingOccurrences(of: ".wav", with: ".json"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            title: title,
            transcriptText: "hello world"
        )
    }

    @Test("upsert inserts a new recording and returns it with id")
    func upsertInsert() async throws {
        let store = try await makeInMemoryStore()
        let inserted = try await store.upsert(sampleRecording())
        #expect(inserted.id != nil)
        #expect(inserted.wavPath == "/tmp/a.wav")
    }

    @Test("upsert of the same wavPath updates the existing row")
    func upsertUpdate() async throws {
        let store = try await makeInMemoryStore()
        var rec = sampleRecording()
        rec = try await store.upsert(rec)
        let originalId = rec.id
        rec.title = "Renamed"
        rec = try await store.upsert(rec)
        #expect(rec.id == originalId)
        #expect(rec.title == "Renamed")
        let all = try await store.fetchAll()
        #expect(all.count == 1)
    }

    @Test("fetchAll excludes soft-deleted by default, includes them on request")
    func fetchAllFiltering() async throws {
        let store = try await makeInMemoryStore()
        let a = try await store.upsert(sampleRecording(wavPath: "/tmp/a.wav"))
        _ = try await store.upsert(sampleRecording(wavPath: "/tmp/b.wav"))
        try await store.softDelete(id: a.id!)

        let visible = try await store.fetchAll()
        #expect(visible.count == 1)
        #expect(visible[0].wavPath == "/tmp/b.wav")

        let withDeleted = try await store.fetchAll(includeDeleted: true)
        #expect(withDeleted.count == 2)
    }

    @Test("fetchAll with pinnedFirst puts pinned above unpinned, ordered by startedAt desc within groups")
    func pinnedFirstOrdering() async throws {
        let store = try await makeInMemoryStore()
        var older = sampleRecording(wavPath: "/tmp/old.wav")
        older.startedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = sampleRecording(wavPath: "/tmp/new.wav")
        _ = try await store.upsert(older)
        let n = try await store.upsert(newer)

        try await store.setPinned(id: n.id!, pinned: false)
        try await store.setPinned(id: (try await store.fetchByWavPath("/tmp/old.wav"))!.id!, pinned: true)

        let ordered = try await store.fetchAll(pinnedFirst: true)
        #expect(ordered[0].wavPath == "/tmp/old.wav", "pinned should come first")
        #expect(ordered[1].wavPath == "/tmp/new.wav")
    }

    @Test("rename updates title and leaves other fields alone")
    func rename() async throws {
        let store = try await makeInMemoryStore()
        let r = try await store.upsert(sampleRecording())
        try await store.rename(id: r.id!, title: "My rename")
        let fetched = try await store.fetchByWavPath(r.wavPath)
        #expect(fetched?.title == "My rename")
    }

    @Test("search finds recordings by transcript text via FTS")
    func searchFTS() async throws {
        let store = try await makeInMemoryStore()
        _ = try await store.upsert(sampleRecording(wavPath: "/tmp/a.wav"))  // "hello world"
        var other = sampleRecording(wavPath: "/tmp/b.wav")
        other.transcriptText = "completely different content"
        _ = try await store.upsert(other)

        let results = try await store.search(query: "hello")
        #expect(results.count == 1)
        #expect(results[0].wavPath == "/tmp/a.wav")
    }

    @Test("search matches against the title field too")
    func searchByTitle() async throws {
        let store = try await makeInMemoryStore()
        var rec = sampleRecording()
        rec.title = "Standup meeting"
        _ = try await store.upsert(rec)

        let results = try await store.search(query: "standup")
        #expect(results.count == 1)
    }

    @Test("softDelete sets deletedAt; restore clears it")
    func softDeleteAndRestore() async throws {
        let store = try await makeInMemoryStore()
        let r = try await store.upsert(sampleRecording())
        try await store.softDelete(id: r.id!)
        let deleted = try await store.fetchByWavPath(r.wavPath)
        #expect(deleted?.deletedAt != nil)

        try await store.restore(id: r.id!)
        let restored = try await store.fetchByWavPath(r.wavPath)
        #expect(restored?.deletedAt == nil)
    }
}
