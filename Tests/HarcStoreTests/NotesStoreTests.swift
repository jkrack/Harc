import Testing
import Foundation
@testable import HarcStore

/// Notes semantics for recordings and sessions: replace vs append, and the
/// OKF `## Notes` projection.
@Suite("RecordingStore notes")
struct NotesStoreTests {

    private func makeDayDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-notes-tests-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/2026-07-31")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        return day
    }

    @discardableResult
    private func seed(store: RecordingStore, dayDir: URL, time: String) async throws -> Recording {
        let wav = dayDir.appendingPathComponent("\(time).wav")
        return try await store.upsert(Recording(
            wavPath: wav.path,
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(600),
            title: "T \(time)",
            transcriptText: "words"
        ))
    }

    @Test("updateNotes replaces, clears on empty, and projects ## Notes")
    func updateNotesRoundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let rec = try await seed(store: store, dayDir: day, time: "10-00-00")

        try await store.updateNotes(id: rec.id!, markdown: "context from the user")
        #expect(try await store.fetch(id: rec.id!)?.notesMarkdown == "context from the user")

        let mdURL = day.appendingPathComponent("10-00-00.md")
        let md = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(md.contains("## Notes\n\ncontext from the user"))
        // Notes render before the transcript, after summary/actions.
        let notesPos = md.range(of: "## Notes")!.lowerBound
        let transcriptPos = md.range(of: "## Transcript")!.lowerBound
        #expect(notesPos < transcriptPos)

        try await store.updateNotes(id: rec.id!, markdown: "   ")
        #expect(try await store.fetch(id: rec.id!)?.notesMarkdown == nil)
        let cleared = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(!cleared.contains("## Notes"))
    }

    @Test("appendNote stacks blocks without touching prior content")
    func appendNoteStacks() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let rec = try await seed(store: store, dayDir: day, time: "10-00-00")

        try await store.updateNotes(id: rec.id!, markdown: "user wrote this first")
        try await store.appendNote(id: rec.id!, block: "agent added this\n\n*— agent, Aug 1, 2026*")

        let notes = try await store.fetch(id: rec.id!)?.notesMarkdown
        #expect(notes == "user wrote this first\n\nagent added this\n\n*— agent, Aug 1, 2026*")

        // Appending to empty notes needs no leading separator.
        let rec2 = try await seed(store: store, dayDir: day, time: "11-00-00")
        try await store.appendNote(id: rec2.id!, block: "solo note")
        #expect(try await store.fetch(id: rec2.id!)?.notesMarkdown == "solo note")

        // Blank blocks are ignored; missing rows throw.
        try await store.appendNote(id: rec2.id!, block: "  \n ")
        #expect(try await store.fetch(id: rec2.id!)?.notesMarkdown == "solo note")
        await #expect(throws: StoreError.notFound) {
            try await store.appendNote(id: 999, block: "x")
        }
    }

    @Test("session notes round-trip and project into session-*.md")
    func sessionNotes() async throws {
        let store = try await RecordingStore.inMemory()
        let day = try makeDayDir()
        let a = try await seed(store: store, dayDir: day, time: "10-00-00")
        let b = try await seed(store: store, dayDir: day, time: "11-00-00")
        let sid = try await store.createSession(recordingIDs: [a.id!, b.id!], title: "Day")

        try await store.updateSessionNotes(id: sid, markdown: "session-level context")
        try await store.appendSessionNote(id: sid, block: "and an agent follow-up")

        let session = try await store.session(id: sid)
        #expect(session?.notesMarkdown == "session-level context\n\nand an agent follow-up")

        let md = try String(
            contentsOf: day.appendingPathComponent("session-10-00-00.md"), encoding: .utf8
        )
        #expect(md.contains("## Notes\n\nsession-level context\n\nand an agent follow-up"))
    }
}
