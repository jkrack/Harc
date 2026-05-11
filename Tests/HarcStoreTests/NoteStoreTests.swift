import Foundation
import Testing
@testable import HarcStore

@Suite("NoteStore")
struct NoteStoreTests {
    private func makeStore() throws -> NoteStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-note-store-\(UUID().uuidString)", isDirectory: true)
        return NoteStore(rootURL: root)
    }

    @Test("create writes a markdown note with frontmatter")
    func createWritesMarkdown() async throws {
        let store = try makeStore()
        let note = try await store.create(
            title: "Planning",
            body: "## Agenda\n\nDiscuss launch.",
            recordings: ["rec_123"]
        )

        #expect(note.id.count == 26)
        #expect(note.fileURL.pathExtension == "md")
        #expect(note.folderPath?.range(of: #"^\d{4}/\d{2}/\d{2}$"#, options: .regularExpression) != nil)
        #expect(note.fileURL.deletingLastPathComponent().path.hasSuffix(note.folderPath ?? ""))

        let raw = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(raw.contains("title: Planning"))
        #expect(raw.contains("folder_path: \(note.folderPath ?? "")"))
        #expect(raw.contains("recordings:\n  - rec_123"))
        #expect(raw.contains("## Agenda"))
    }

    @Test("blank notes default to a timestamp title")
    func blankNotesUseTimestampTitle() async throws {
        let store = try makeStore()
        let note = try await store.create()

        #expect(note.title.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil)

        let raw = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(raw.contains("title: \(note.title)"))
    }

    @Test("fetchAll reads notes recursively from dated folders and legacy root files")
    func fetchAllReadsRecursiveAndLegacyFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-note-store-\(UUID().uuidString)", isDirectory: true)
        let store = NoteStore(rootURL: root)
        let dated = try await store.create(title: "Dated")
        let legacyURL = root.appendingPathComponent("legacy.md")
        try """
        ---
        id: legacy
        title: Legacy
        created_at: 2026-05-10T00:00:00Z
        updated_at: 2026-05-10T00:00:00Z
        pinned: false
        archived: false
        folder_path: 
        derived_from: 
        tags:
        recordings:
        people:
        ---
        Old root note.
        """.write(to: legacyURL, atomically: true, encoding: .utf8)

        let notes = try await store.fetchAll()
        #expect(Set(notes.map(\.title)) == ["Dated", "Legacy"])
        #expect(notes.first(where: { $0.id == dated.id })?.folderPath == dated.folderPath)
        #expect(notes.first(where: { $0.id == "legacy" })?.folderPath == nil)
    }

    @Test("fetchAll round-trips note metadata and orders pinned first")
    func fetchAllRoundTripsAndOrders() async throws {
        let store = try makeStore()
        var first = try await store.create(title: "First", body: "Older")
        var second = try await store.create(title: "Second", body: "Newer")
        first.pinned = true
        first.tags = ["sales", "launch"]
        first = try await store.update(first)
        second = try await store.update(second)

        let notes = try await store.fetchAll()
        #expect(notes.map(\.id).first == first.id)
        #expect(notes.first?.tags == ["sales", "launch"])
        #expect(notes.first?.preview == "Older")
        _ = second
    }

    @Test("archived notes are hidden by default")
    func archiveHidesByDefault() async throws {
        let store = try makeStore()
        let note = try await store.create(title: "Archive me")
        try await store.archive(id: note.id)

        let visible = try await store.fetchAll()
        let all = try await store.fetchAll(includeArchived: true)
        #expect(visible.isEmpty)
        #expect(all.count == 1)
        #expect(all[0].archived)
    }

    @Test("recordings can have linked notes")
    func recordingsCanHaveLinkedNotes() async throws {
        let store = try makeStore()
        let recording = Recording(
            id: 42,
            wavPath: "/tmp/recording.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Roadmap sync"
        )
        let linked = try await store.create(for: recording, body: "Follow up with Michelle.")
        _ = try await store.create(title: "Unlinked")

        let notes = try await store.fetchLinked(to: recording)
        #expect(notes.map(\.id) == [linked.id])
        #expect(notes[0].recordings == ["recording:42"])
    }

    @Test("linking a recording can append its transcript to the note")
    func linkingRecordingCanAppendTranscript() async throws {
        let store = try makeStore()
        let note = try await store.create(title: "Mothers Day", body: "* Breakfast")
        let recording = Recording(
            id: 42,
            wavPath: "/tmp/mothers-day.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Forest Park walk"
        )

        let linked = try await store.link(
            recording: recording,
            toNoteID: note.id,
            transcriptText: "Speaker 1: We took a hike in Forest Park."
        )

        #expect(linked.recordings == ["recording:42"])
        #expect(linked.body.contains("* Breakfast"))
        #expect(linked.body.contains("## Recording: [[Forest Park walk]]"))
        #expect(linked.body.contains("Speaker 1: We took a hike in Forest Park."))
    }

    @Test("search matches note title body tags and excludes archive")
    func searchNotes() async throws {
        let store = try makeStore()
        var launch = try await store.create(title: "Launch plan", body: "Follow up on pricing.")
        launch.tags = ["customer"]
        _ = try await store.update(launch)
        _ = try await store.create(title: "Random", body: "No matching content.")
        let archived = try await store.create(title: "Launch archive", body: "pricing")
        try await store.archive(id: archived.id)

        let titleHits = try await store.search(query: "launch")
        #expect(titleHits.count == 1)
        #expect(titleHits[0].title == "Launch plan")

        let bodyHits = try await store.search(query: "pricing customer")
        #expect(bodyHits.map(\.title) == ["Launch plan"])
    }

    @Test("search matches project tags")
    func searchMatchesProjectTags() async throws {
        let store = try makeStore()
        var atlas = try await store.create(title: "Migration notes", body: "Neal wants a staged rollout.")
        atlas.tags = ["project:Atlas"]
        _ = try await store.update(atlas)

        let hits = try await store.search(query: "Atlas Neal")

        #expect(hits.map(\.title) == ["Migration notes"])
    }
}
