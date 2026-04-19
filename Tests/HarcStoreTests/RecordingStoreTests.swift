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
        #expect(results[0].recording.wavPath == "/tmp/a.wav")
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

    @Test("daysWithRecordings returns only days that have non-deleted rows in the month")
    func daysWithRecordingsInMonth() async throws {
        let store = try await RecordingStore.inMemory()
        let cal = Calendar.current
        let d1 = cal.date(from: DateComponents(year: 2026, month: 4, day: 5, hour: 10))!
        let d2 = cal.date(from: DateComponents(year: 2026, month: 4, day: 5, hour: 15))!  // same day
        let d3 = cal.date(from: DateComponents(year: 2026, month: 4, day: 12, hour: 9))!
        let d4 = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 9))!   // next month
        for (idx, d) in [d1, d2, d3, d4].enumerated() {
            _ = try await store.upsert(Recording(wavPath: "/tmp/day/\(idx).wav", startedAt: d))
        }
        // Soft-delete one on the 5th — remaining row that day still counts.
        let apr12Rec = try #require(try await store.fetchByWavPath("/tmp/day/2.wav"))
        try await store.softDelete(id: apr12Rec.id!)

        let april = cal.date(from: DateComponents(year: 2026, month: 4, day: 15))!
        let days = try await store.daysWithRecordings(inMonthContaining: april)
        let dayStarts = Set([d1].map { cal.startOfDay(for: $0) })
        #expect(days == dayStarts)
    }

    @Test("recordings(onDay:) returns rows for that local day, ordered pinned-first desc")
    func recordingsOnDay() async throws {
        let store = try await RecordingStore.inMemory()
        let cal = Calendar.current
        let morning = cal.date(from: DateComponents(year: 2026, month: 4, day: 17, hour: 9))!
        let evening = cal.date(from: DateComponents(year: 2026, month: 4, day: 17, hour: 21))!
        let otherDay = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 9))!

        let r1 = try await store.upsert(Recording(wavPath: "/tmp/d/a.wav", startedAt: morning))
        let r2 = try await store.upsert(Recording(wavPath: "/tmp/d/b.wav", startedAt: evening))
        _ = try await store.upsert(Recording(wavPath: "/tmp/d/c.wav", startedAt: otherDay))
        try await store.setPinned(id: r1.id!, pinned: true)

        let result = try await store.recordings(onDay: morning)
        #expect(result.map { $0.wavPath } == ["/tmp/d/a.wav", "/tmp/d/b.wav"])
        #expect(result[0].pinned == true)
        _ = r2
    }

    @Test("daysWithRecordings excludes rows in other months")
    func daysWithRecordingsRespectsMonthBounds() async throws {
        let store = try await RecordingStore.inMemory()
        let cal = Calendar.current
        let inMonth = cal.date(from: DateComponents(year: 2026, month: 4, day: 10))!
        let outOfMonth = cal.date(from: DateComponents(year: 2026, month: 3, day: 31))!
        _ = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: inMonth))
        _ = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: outOfMonth))
        let days = try await store.daysWithRecordings(inMonthContaining: inMonth)
        #expect(days.count == 1)
    }

    @Test("suggested_title survives round-trip and drives displayTitle fallback")
    func suggestedTitleRoundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(Recording(
            wavPath: "/tmp/st/a.wav",
            startedAt: Date(),
            suggestedTitle: "Sarah, Q3 roadmap"
        ))
        let fetched = try #require(try await store.fetchByWavPath("/tmp/st/a.wav"))
        #expect(fetched.suggestedTitle == "Sarah, Q3 roadmap")
        #expect(fetched.displayTitle.contains("Sarah, Q3 roadmap"))
        _ = rec
    }

    @Test("updateSuggestedTitle writes the column and is a no-op on missing id")
    func updateSuggestedTitleBasics() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(Recording(wavPath: "/tmp/upd/a.wav", startedAt: Date()))
        try await store.updateSuggestedTitle(id: rec.id!, title: "Sarah, Q3")
        let refreshed = try #require(try await store.fetchByWavPath("/tmp/upd/a.wav"))
        #expect(refreshed.suggestedTitle == "Sarah, Q3")

        // No-op on phantom id — no throw.
        try await store.updateSuggestedTitle(id: 999_999, title: "anything")
    }

    @Test("tags round-trip through the DB")
    func tagsRoundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(Recording(
            wavPath: "/tmp/tags/a.wav",
            startedAt: Date(),
            tags: ["Sarah", "Acme", "Q3"]
        ))
        let fetched = try #require(try await store.fetchByWavPath("/tmp/tags/a.wav"))
        #expect(fetched.tags == ["Sarah", "Acme", "Q3"])
    }

    @Test("empty tags array reads back as empty, not nil")
    func tagsEmptyDefault() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(Recording(wavPath: "/tmp/tags/b.wav", startedAt: Date()))
        let fetched = try #require(try await store.fetchByWavPath("/tmp/tags/b.wav"))
        #expect(fetched.tags == [])
    }

    @Test("updateTags writes the JSON-encoded array")
    func updateTagsBasics() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(Recording(wavPath: "/tmp/ut/a.wav", startedAt: Date()))
        try await store.updateTags(id: rec.id!, tags: ["Sarah", "Q3"])
        let refreshed = try #require(try await store.fetchByWavPath("/tmp/ut/a.wav"))
        #expect(refreshed.tags == ["Sarah", "Q3"])

        // Clearing — empty array round-trips to empty array.
        try await store.updateTags(id: rec.id!, tags: [])
        let cleared = try #require(try await store.fetchByWavPath("/tmp/ut/a.wav"))
        #expect(cleared.tags == [])
    }
}
