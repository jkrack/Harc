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

    @Test("setPinned persists pin state and fetchAll ordering")
    func setPinnedPersistsAndOrders() async throws {
        let store = try makeStore()
        let first = try await store.create(title: "First", body: "Older")
        let second = try await store.create(title: "Second", body: "Newer")

        try await store.setPinned(id: first.id, pinned: true)

        var notes = try await store.fetchAll()
        #expect(notes.map(\.id).first == first.id)
        #expect(notes.first?.pinned == true)
        let pinnedRaw = try String(contentsOf: first.fileURL, encoding: .utf8)
        #expect(pinnedRaw.contains("pinned: true"))

        try await store.setPinned(id: first.id, pinned: false)

        notes = try await store.fetchAll()
        #expect(notes.first(where: { $0.id == first.id })?.pinned == false)
        let unpinnedRaw = try String(contentsOf: first.fileURL, encoding: .utf8)
        #expect(unpinnedRaw.contains("pinned: false"))
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

    @Test("attachImage writes note-owned asset and sidecar metadata")
    func attachImageWritesAssetAndMetadata() async throws {
        let store = try makeStore()
        let note = try await store.create(title: "Slide review")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

        let result = try await store.attachImage(
            toNoteID: note.id,
            data: png,
            mimeType: "image/png",
            preferredFilename: "Quarterly Slide.png"
        )

        #expect(result.attachment.mimeType == "image/png")
        #expect(result.attachment.relativePath.hasPrefix("\(note.id).assets/"))
        #expect(result.markdown.contains("](./\(result.attachment.relativePath))"))

        let assetURL = note.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(result.attachment.relativePath)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))

        let refetched = try await store.fetch(id: note.id)
        #expect(refetched?.attachments.count == 1)
        #expect(refetched?.attachments.first?.altText == "quarterly slide")
        #expect(refetched?.body.contains("![quarterly slide](./\(result.attachment.relativePath))") == true)
    }

    @Test("fetch repairs existing sidecar-only image attachments into visible markdown blocks")
    func fetchRepairsSidecarOnlyAttachmentReferences() async throws {
        let store = try makeStore()
        let note = try await store.create(title: "Broken paste", body: "Test")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let result = try await store.attachImage(
            toNoteID: note.id,
            data: png,
            mimeType: "image/png",
            preferredFilename: "Window.png"
        )

        let rawBeforeRepair = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(!rawBeforeRepair.contains(result.attachment.relativePath))

        let repaired = try #require(try await store.fetch(id: note.id))
        #expect(repaired.body == """
        Test

        ![window](./\(result.attachment.relativePath))
        """)

        let rawAfterRepair = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(rawAfterRepair.contains("](./\(result.attachment.relativePath))"))
    }

    @Test("attachment repair is idempotent")
    func attachmentRepairIsIdempotent() async throws {
        let store = try makeStore()
        let note = try await store.create(title: "One image")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result = try await store.attachImage(
            toNoteID: note.id,
            data: png,
            mimeType: "image/png",
            preferredFilename: "Only.png"
        )

        _ = try await store.fetch(id: note.id)
        let repairedAgain = try #require(try await store.fetch(id: note.id))

        #expect(repairedAgain.body.components(separatedBy: result.attachment.relativePath).count - 1 == 1)
        #expect(repairedAgain.attachments.count == 1)
    }

    @Test("search matches attachment captions")
    func searchMatchesAttachmentCaptions() async throws {
        let store = try makeStore()
        let note = try await store.create(title: "Board meeting")
        let jpg = Data([0xFF, 0xD8, 0xFF, 0x00])
        let result = try await store.attachImage(
            toNoteID: note.id,
            data: jpg,
            mimeType: "image/jpeg",
            preferredFilename: "Pipeline.jpg"
        )
        _ = try await store.updateAttachmentCaption(
            noteID: note.id,
            attachmentID: result.attachment.id,
            caption: "Slide shows enterprise pipeline risk and renewal dates.",
            status: .captioned,
            modelID: "test-vision"
        )

        let hits = try await store.search(query: "enterprise renewal")

        #expect(hits.map(\.id) == [note.id])
    }

    @Test("removeAttachment deletes note-owned file and markdown reference")
    func removeAttachmentDeletesFileAndMarkdownReference() async throws {
        let store = try makeStore()
        var note = try await store.create(title: "Design review")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let result = try await store.attachImage(
            toNoteID: note.id,
            data: png,
            mimeType: "image/png",
            preferredFilename: "Slide.png"
        )
        note = result.note
        note.body = "Before\n\n\(result.markdown)\n\nAfter"
        note = try await store.update(note)
        let assetURL = note.fileURL.deletingLastPathComponent().appendingPathComponent(result.attachment.relativePath)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))

        let saved = try await store.removeAttachment(noteID: note.id, attachmentID: result.attachment.id)

        #expect(saved.attachments.isEmpty)
        #expect(!saved.body.contains(result.attachment.relativePath))
        #expect(!FileManager.default.fileExists(atPath: assetURL.path))
    }

    @Test("update repairs attachment metadata when markdown reference is deleted")
    func updateRepairsAttachmentWhenMarkdownReferenceDeleted() async throws {
        let store = try makeStore()
        var note = try await store.create(title: "Repair image")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result = try await store.attachImage(
            toNoteID: note.id,
            data: png,
            mimeType: "image/png",
            preferredFilename: "Slide.png"
        )
        note = result.note
        note.body = result.markdown
        note = try await store.update(note)
        note.body = "Image removed from the note."

        let saved = try await store.update(note)

        #expect(saved.attachments.count == 1)
        #expect(saved.body.contains("Image removed from the note."))
        #expect(saved.body.contains("](./\(result.attachment.relativePath))"))
    }

    @Test("caption updates replace the visible caption line")
    func captionUpdatesReplaceVisibleCaptionLine() async throws {
        let store = try makeStore()
        var note = try await store.create(title: "Caption repair")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result = try await store.attachImage(
            toNoteID: note.id,
            data: png,
            mimeType: "image/png",
            preferredFilename: "Caption.png"
        )
        note = result.note
        note.attachments[0].captionStatus = .pending
        note.body = "Notes"
        note = try await store.update(note)
        #expect(note.body.contains("*Caption: Caption pending...*"))

        let saved = try await store.updateAttachmentCaption(
            noteID: note.id,
            attachmentID: result.attachment.id,
            caption: "A launch dashboard with owners and dates.",
            status: .captioned,
            modelID: "test-vision"
        )

        #expect(saved.body.contains("](./\(result.attachment.relativePath))"))
        #expect(saved.body.contains("*Caption: A launch dashboard with owners and dates.*"))
        #expect(!saved.body.contains("Caption pending"))
    }

    @Test("attachImage rejects unsupported image data")
    func attachImageRejectsUnsupportedData() async throws {
        let store = try makeStore()
        let note = try await store.create(title: "Bad image")

        await #expect(throws: StoreError.invalidData("Only PNG and JPEG note images are supported.")) {
            _ = try await store.attachImage(
                toNoteID: note.id,
                data: Data("not an image".utf8),
                mimeType: "image/gif"
            )
        }
    }
}
