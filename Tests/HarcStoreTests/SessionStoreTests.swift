import Testing
import Foundation
import GRDB
@testable import HarcStore

/// Store semantics for virtual day sessions. Uses an in-memory DB with wav
/// paths pointed into a per-test temp day directory so the best-effort OKF
/// session projection can be asserted alongside the row mutations.
@Suite("RecordingStore sessions")
struct SessionStoreTests {

    /// A temp `<root>/2026/2026-07-31`-style day directory.
    private func makeDayDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-session-tests-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/2026-07-31")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        return day
    }

    /// Seed a recording whose wav lives in `dayDir` at `HH-mm-ss`. The
    /// startedAt is that time-of-day on a fixed day so same-day validation
    /// and position ordering are deterministic.
    @discardableResult
    private func seedRecording(
        store: RecordingStore,
        dayDir: URL,
        time: String,          // "10-00-00"
        title: String? = nil,
        dayOffset: Int = 0
    ) async throws -> Recording {
        let cal = Calendar.current
        let parts = time.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 31 + dayOffset
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = parts[2]
        let startedAt = cal.date(from: comps)!
        let wav = dayDir.appendingPathComponent("\(time).wav")
        return try await store.upsert(Recording(
            wavPath: wav.path,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1800),
            title: title,
            transcriptText: "words for \(time)"
        ))
    }

    // MARK: - Creation

    @Test("createSession orders members by startedAt and returns the id")
    func createOrdersMembers() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let late = try await seedRecording(store: store, dayDir: day, time: "14-30-00", title: "Afternoon")
        let early = try await seedRecording(store: store, dayDir: day, time: "10-00-00", title: "Morning")

        // Pass ids out of order — positions must follow startedAt.
        let sid = try await store.createSession(recordingIDs: [late.id!, early.id!], title: "Offsite")
        let members = try await store.recordings(inSession: sid)
        #expect(members.map(\.title) == ["Morning", "Afternoon"])

        let session = try await store.session(id: sid)
        #expect(session?.title == "Offsite")
        #expect(session?.day == "2026-07-31")
        #expect(try await store.sessionID(forRecording: early.id!) == sid)
    }

    @Test("createSession rejects fewer than two recordings")
    func createRejectsSingleton() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let only = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        await #expect(throws: StoreError.self) {
            try await store.createSession(recordingIDs: [only.id!])
        }
    }

    @Test("createSession rejects members on different days")
    func createRejectsCrossDay() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00", dayOffset: 1)
        await #expect(throws: StoreError.self) {
            try await store.createSession(recordingIDs: [a.id!, b.id!])
        }
    }

    @Test("createSession rejects members already in a session")
    func createRejectsDoubleMembership() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00")
        let c = try await seedRecording(store: store, dayDir: day, time: "12-00-00")
        _ = try await store.createSession(recordingIDs: [a.id!, b.id!])
        await #expect(throws: StoreError.self) {
            try await store.createSession(recordingIDs: [b.id!, c.id!])
        }
    }

    @Test("createSession rejects soft-deleted members")
    func createRejectsDeleted() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00")
        try await store.softDelete(id: b.id!)
        await #expect(throws: StoreError.self) {
            try await store.createSession(recordingIDs: [a.id!, b.id!])
        }
    }

    // MARK: - Summary

    @Test("updateSessionSummary writes fields and clears status")
    func summaryRoundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00")
        let sid = try await store.createSession(recordingIDs: [a.id!, b.id!])

        try await store.updateSessionSummaryStatus(id: sid, kind: .failed, message: "model missing")
        var session = try await store.session(id: sid)
        #expect(session?.summaryStatusKind == .failed)

        try await store.updateSessionSummary(
            id: sid,
            markdown: "- combined",
            actionItemsMarkdown: "- do the thing",
            modelID: "test-model",
            generatedAt: Date(),
            sourceWordCount: 42
        )
        session = try await store.session(id: sid)
        #expect(session?.summaryMarkdown == "- combined")
        #expect(session?.actionItemsMarkdown == "- do the thing")
        #expect(session?.summaryModelID == "test-model")
        #expect(session?.summarySourceWordCount == 42)
        #expect(session?.summaryStatusKind == nil)

        try await store.clearSessionSummary(id: sid)
        session = try await store.session(id: sid)
        #expect(session?.summaryMarkdown == nil)
    }

    @Test("session mutators throw notFound for unknown ids")
    func mutatorsThrowNotFound() async throws {
        let store = try await RecordingStore.inMemory()
        await #expect(throws: StoreError.notFound) {
            try await store.updateSessionTitle(id: 999, title: "x")
        }
        await #expect(throws: StoreError.notFound) {
            try await store.deleteSession(id: 999)
        }
    }

    // MARK: - Membership changes

    @Test("removeRecording keeps a 3-member session alive, dissolves at <2")
    func removeMemberDissolve() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00")
        let c = try await seedRecording(store: store, dayDir: day, time: "12-00-00")
        let sid = try await store.createSession(recordingIDs: [a.id!, b.id!, c.id!])

        try await store.removeRecording(fromSession: sid, recordingID: c.id!)
        #expect(try await store.session(id: sid) != nil)
        #expect(try await store.recordings(inSession: sid).count == 2)
        #expect(try await store.sessionID(forRecording: c.id!) == nil)

        try await store.removeRecording(fromSession: sid, recordingID: b.id!)
        #expect(try await store.session(id: sid) == nil)
        #expect(try await store.sessionID(forRecording: a.id!) == nil)
    }

    @Test("deleteSession removes the grouping but not the recordings")
    func deleteSessionKeepsRecordings() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00")
        let sid = try await store.createSession(recordingIDs: [a.id!, b.id!])

        try await store.deleteSession(id: sid)
        #expect(try await store.session(id: sid) == nil)
        #expect(try await store.fetch(id: a.id!) != nil)
        #expect(try await store.fetch(id: b.id!) != nil)
    }

    @Test("pruneSessionIfNeeded dissolves after a member soft-delete leaves <2 active")
    func pruneAfterSoftDelete() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00")
        let c = try await seedRecording(store: store, dayDir: day, time: "12-00-00")
        let sid = try await store.createSession(recordingIDs: [a.id!, b.id!, c.id!])

        try await store.softDelete(id: c.id!)
        await store.pruneSessionIfNeeded(afterMemberChange: c.id!)
        #expect(try await store.session(id: sid) != nil)
        #expect(try await store.recordings(inSession: sid).count == 2)

        try await store.softDelete(id: b.id!)
        await store.pruneSessionIfNeeded(afterMemberChange: b.id!)
        #expect(try await store.session(id: sid) == nil)
    }

    // MARK: - OKF projection

    @Test("createSession projects a session-*.md anchored to the first member")
    func projectionWritesSessionDoc() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00", title: "Standup")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00", title: "Planning")
        let sid = try await store.createSession(recordingIDs: [a.id!, b.id!], title: "Sprint day")

        let mdURL = day.appendingPathComponent("session-10-00-00.md")
        let content = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(content.contains("type: Session"))
        #expect(content.contains("title: \"Sprint day\""))
        #expect(content.contains("- [Standup](./10-00-00.md)"))
        #expect(content.contains("- [Planning](./11-00-00.md)"))
        #expect(!content.contains("## Transcript"))

        // Member rename cascades into the session doc's link list.
        try await store.rename(id: a.id!, title: "Morning standup")
        let renamed = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(renamed.contains("- [Morning standup](./10-00-00.md)"))

        // Dissolving removes the doc.
        try await store.deleteSession(id: sid)
        #expect(!FileManager.default.fileExists(atPath: mdURL.path))
    }

    @Test("removing the anchor member relocates the session doc")
    func projectionAnchorMoves() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00")
        let c = try await seedRecording(store: store, dayDir: day, time: "12-00-00")
        _ = try await store.createSession(recordingIDs: [a.id!, b.id!, c.id!])

        let oldURL = day.appendingPathComponent("session-10-00-00.md")
        #expect(FileManager.default.fileExists(atPath: oldURL.path))

        let sid = try await store.sessionID(forRecording: a.id!)
        try await store.removeRecording(fromSession: sid!, recordingID: a.id!)

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        let newURL = day.appendingPathComponent("session-11-00-00.md")
        #expect(FileManager.default.fileExists(atPath: newURL.path))
    }

    @Test("day index lists the session doc after the member docs")
    func dayIndexOrdering() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seedRecording(store: store, dayDir: day, time: "10-00-00", title: "First")
        let b = try await seedRecording(store: store, dayDir: day, time: "11-00-00", title: "Second")
        _ = try await store.createSession(recordingIDs: [a.id!, b.id!], title: "Combined")

        let index = try String(contentsOf: day.appendingPathComponent("index.md"), encoding: .utf8)
        let sessionPos = index.range(of: "session-10-00-00.md")
        #expect(sessionPos != nil)
        // Member docs are only projected on their own mutations here, but the
        // session doc must sort last among whatever .md files exist.
        if let last = index.split(separator: "\n").last(where: { $0.hasPrefix("- [") }) {
            #expect(last.contains("session-10-00-00.md"))
        }
    }
}
