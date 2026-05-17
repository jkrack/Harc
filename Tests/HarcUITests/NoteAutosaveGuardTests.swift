import Foundation
import HarcStore
import Testing
@testable import HarcUI

@Suite("NoteAutosaveGuard")
struct NoteAutosaveGuardTests {
    @Test("rapid edits make older selected autosave stale")
    func rapidEditsMakeOlderAutosaveStale() {
        let request = NoteSaveRequest(
            id: "note-1",
            title: "Old title",
            body: "Old body",
            generation: 1,
            baseUpdatedAt: Date(timeIntervalSince1970: 10),
            updateDraftIfSelected: true
        )

        let decision = NoteAutosaveGuard.shouldSave(
            request: request,
            currentGeneration: 2,
            selectedNoteID: "note-1",
            diskNote: note(updatedAt: Date(timeIntervalSince1970: 10))
        )

        #expect(decision == .stale)
    }

    @Test("selection-change flush can save without updating the current draft")
    func selectionChangeFlushCanSaveOldNote() {
        let request = NoteSaveRequest(
            id: "old-note",
            title: "Outgoing",
            body: "Draft",
            generation: 1,
            baseUpdatedAt: Date(timeIntervalSince1970: 10),
            updateDraftIfSelected: false
        )

        let decision = NoteAutosaveGuard.shouldSave(
            request: request,
            currentGeneration: 2,
            selectedNoteID: "new-note",
            diskNote: note(id: "old-note", updatedAt: Date(timeIntervalSince1970: 10))
        )

        #expect(decision == .save)
    }

    @Test("external disk change creates conflict unless overwrite is allowed")
    func externalChangeCreatesConflict() {
        let base = Date(timeIntervalSince1970: 10)
        let disk = note(title: "Disk title", body: "Disk body", updatedAt: Date(timeIntervalSince1970: 20))
        let request = NoteSaveRequest(
            id: "note-1",
            title: "Draft title",
            body: "Draft body",
            generation: 3,
            baseUpdatedAt: base,
            updateDraftIfSelected: true
        )

        let decision = NoteAutosaveGuard.shouldSave(
            request: request,
            currentGeneration: 3,
            selectedNoteID: "note-1",
            diskNote: disk
        )
        let overwrite = NoteAutosaveGuard.shouldSave(
            request: request,
            currentGeneration: 3,
            selectedNoteID: "note-1",
            diskNote: disk,
            allowOverwrite: true
        )

        if case .conflict(let conflict) = decision {
            #expect(conflict.diskTitle == "Disk title")
            #expect(conflict.draftTitle == "Draft title")
        } else {
            Issue.record("Expected conflict")
        }
        #expect(overwrite == .save)
    }

    private func note(
        id: String = "note-1",
        title: String = "Title",
        body: String = "Body",
        updatedAt: Date
    ) -> Note {
        Note(
            id: id,
            title: title,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: updatedAt,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).md")
        )
    }
}
