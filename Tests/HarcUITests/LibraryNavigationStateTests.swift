import Foundation
import Testing
@testable import HarcUI

struct LibraryNavigationStateTests {
    @Test("default sidebar layout prioritizes capture")
    func defaultsPrioritizeCapture() {
        let snapshot = LibraryNavigationSnapshot.defaults

        #expect(snapshot.recordingsExpanded)
        #expect(!snapshot.peopleExpanded)
        #expect(snapshot.sidebarSectionOrder == [.recordings, .people])
    }

    @Test("snapshot persists selection and expansion state")
    func snapshotPersistsSelectionAndExpansionState() {
        let suiteName = "LibraryNavigationStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            LibraryNavigationStateStore.clear(defaults: defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let snapshot = LibraryNavigationSnapshot(
            selection: PersistedLibrarySelection(.recording(wavPath: "/tmp/a.wav")),
            peopleExpanded: true,
            recordingsExpanded: true,
            sidebarSectionOrder: [.people, .recordings]
        )

        LibraryNavigationStateStore.save(snapshot, defaults: defaults)

        #expect(LibraryNavigationStateStore.load(defaults: defaults) == snapshot)
    }

    @Test("snapshot normalizes missing sidebar sections")
    func snapshotNormalizesMissingSidebarSections() {
        let snapshot = LibraryNavigationSnapshot(
            selection: nil,
            peopleExpanded: false,
            recordingsExpanded: true,
            sidebarSectionOrder: [.people]
        )

        #expect(snapshot.sidebarSectionOrder == [.people, .recordings])
    }

    @Test("snapshot decodes old state without sidebar order")
    func snapshotDecodesOldStateWithoutSidebarOrder() throws {
        let data = Data("""
        {
          "recordingsExpanded": true,
          "peopleExpanded": false
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(LibraryNavigationSnapshot.self, from: data)

        #expect(snapshot.sidebarSectionOrder == LibrarySidebarSection.defaultOrder)
    }

    @Test("resolver restores valid selection")
    func resolverRestoresValidSelection() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/a.wav"),
            recordingPaths: ["/tmp/a.wav"],
            personIDs: [1],
            fallbackRecordingPath: nil
        )

        #expect(resolved == .recording(wavPath: "/tmp/a.wav"))
    }

    @Test("resolver falls back when restored recording is stale")
    func resolverFallsBackWhenRestoredRecordingIsStale() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/deleted.wav"),
            recordingPaths: ["/tmp/a.wav"],
            personIDs: [],
            fallbackRecordingPath: "/tmp/a.wav"
        )

        #expect(resolved == .recording(wavPath: "/tmp/a.wav"))
    }

    @Test("resolver does not restore stale recording when no fallback exists")
    func resolverDropsStaleRecordingWithoutFallback() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/deleted.wav"),
            recordingPaths: [],
            personIDs: [],
            fallbackRecordingPath: nil
        )

        #expect(resolved == nil)
    }

    /// The in-progress recording is session-scoped. It must neither persist
    /// nor restore: encoding refuses it, and the resolver treats a restored
    /// `.live` as invalid so launch always lands on a real row.
    @Test("live selection is never persisted or restored")
    func liveSelectionExcludedFromPersistence() {
        #expect(PersistedLibrarySelection(.live) == nil)

        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .live,
            recordingPaths: ["/tmp/a.wav"],
            personIDs: [],
            fallbackRecordingPath: "/tmp/a.wav"
        )
        #expect(resolved == .recording(wavPath: "/tmp/a.wav"))
    }
}
