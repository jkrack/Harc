import Foundation
import Testing
@testable import HarcUI

struct LibraryNavigationStateTests {
    @Test("default sidebar layout prioritizes capture and notes")
    func defaultsPrioritizeCaptureAndNotes() {
        let snapshot = LibraryNavigationSnapshot.defaults

        #expect(snapshot.recordingsExpanded)
        #expect(snapshot.notesExpanded)
        #expect(!snapshot.projectsExpanded)
        #expect(!snapshot.peopleExpanded)
    }

    @Test("snapshot persists mode selection and expansion state")
    func snapshotPersistsModeSelectionAndExpansionState() {
        let suiteName = "LibraryNavigationStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            LibraryNavigationStateStore.clear(defaults: defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let snapshot = LibraryNavigationSnapshot(
            modeRawValue: "Review",
            selection: PersistedLibrarySelection(.note(id: "note-1")),
            notesExpanded: false,
            projectsExpanded: true,
            peopleExpanded: false,
            recordingsExpanded: true,
            expandedNoteBuckets: ["recent", "pinned"],
            knownNoteBuckets: ["recent", "pinned", "2026-05"]
        )

        LibraryNavigationStateStore.save(snapshot, defaults: defaults)

        #expect(LibraryNavigationStateStore.load(defaults: defaults) == snapshot)
    }

    @Test("resolver restores valid selection")
    func resolverRestoresValidSelection() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/a.wav"),
            noteIDs: ["note-1"],
            recordingPaths: ["/tmp/a.wav"],
            personIDs: [1],
            projectNames: ["Harc"],
            fallbackNoteID: "note-1",
            fallbackRecordingPath: nil
        )

        #expect(resolved == .recording(wavPath: "/tmp/a.wav"))
    }

    @Test("resolver falls back when restored note is stale")
    func resolverFallsBackWhenRestoredNoteIsStale() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .note(id: "deleted-note"),
            noteIDs: ["recent-note"],
            recordingPaths: ["/tmp/a.wav"],
            personIDs: [],
            projectNames: [],
            fallbackNoteID: "recent-note",
            fallbackRecordingPath: "/tmp/a.wav"
        )

        #expect(resolved == .note(id: "recent-note"))
    }

    @Test("resolver does not restore stale recording when no fallback exists")
    func resolverDropsStaleRecordingWithoutFallback() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/deleted.wav"),
            noteIDs: [],
            recordingPaths: [],
            personIDs: [],
            projectNames: [],
            fallbackNoteID: nil,
            fallbackRecordingPath: nil
        )

        #expect(resolved == nil)
    }
}
