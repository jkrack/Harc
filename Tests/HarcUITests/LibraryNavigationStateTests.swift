import Foundation
import Testing
@testable import HarcUI

struct LibraryNavigationStateTests {
    @Test("snapshot persists the selection")
    func snapshotPersistsSelection() throws {
        let suiteName = "harc.tests.navstate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = LibraryNavigationSnapshot(
            selection: PersistedLibrarySelection(.recording(wavPath: "/tmp/x.wav"))
        )
        LibraryNavigationStateStore.save(snapshot, defaults: defaults)
        let loaded = LibraryNavigationStateStore.load(defaults: defaults)

        #expect(loaded.selection?.librarySelection == .recording(wavPath: "/tmp/x.wav"))
    }

    /// The v1 key is unchanged from before the reorder mechanism and the
    /// disclosure groups were deleted. A blob written by that version carries
    /// `sidebarSectionOrder` and the expansion booleans; decoding must ignore
    /// them and keep the selection.
    @Test("a legacy v1 blob with dead fields still decodes")
    func legacyBlobDecodes() throws {
        let suiteName = "harc.tests.navstate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyJSON = """
        {"selection":{"kind":"person","value":"42"},
         "peopleExpanded":true,"recordingsExpanded":false,
         "sidebarSectionOrder":["people","recordings"]}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "harc.libraryNavigationState.v1")

        let loaded = LibraryNavigationStateStore.load(defaults: defaults)
        #expect(loaded.selection?.librarySelection == .person(id: 42))
    }

    @Test("resolver restores valid selection")
    func resolverRestoresValid() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/a.wav"),
            recordingPaths: ["/tmp/a.wav", "/tmp/b.wav"],
            personIDs: [],
            fallbackRecordingPath: "/tmp/b.wav"
        )
        #expect(resolved == .recording(wavPath: "/tmp/a.wav"))
    }

    @Test("resolver falls back when restored recording is stale")
    func resolverFallsBack() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/gone.wav"),
            recordingPaths: ["/tmp/b.wav"],
            personIDs: [],
            fallbackRecordingPath: "/tmp/b.wav"
        )
        #expect(resolved == .recording(wavPath: "/tmp/b.wav"))
    }

    @Test("resolver does not restore stale recording when no fallback exists")
    func resolverNilWithoutFallback() {
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: .recording(wavPath: "/tmp/gone.wav"),
            recordingPaths: [],
            personIDs: [],
            fallbackRecordingPath: nil
        )
        #expect(resolved == nil)
    }

    @Test("session selection persists and restores when the session exists")
    func sessionSelectionRoundTrip() throws {
        let suiteName = "harc.tests.navstate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = LibraryNavigationSnapshot(
            selection: PersistedLibrarySelection(.session(id: 7))
        )
        LibraryNavigationStateStore.save(snapshot, defaults: defaults)
        let loaded = LibraryNavigationStateStore.load(defaults: defaults)
        #expect(loaded.selection?.librarySelection == .session(id: 7))

        let valid = LibraryNavigationResolver.resolvedSelection(
            restored: .session(id: 7),
            recordingPaths: [],
            personIDs: [],
            sessionIDs: [7],
            fallbackRecordingPath: nil
        )
        #expect(valid == .session(id: 7))

        // A dissolved session falls back like a stale recording does.
        let stale = LibraryNavigationResolver.resolvedSelection(
            restored: .session(id: 7),
            recordingPaths: ["/tmp/a.wav"],
            personIDs: [],
            sessionIDs: [],
            fallbackRecordingPath: "/tmp/a.wav"
        )
        #expect(stale == .recording(wavPath: "/tmp/a.wav"))
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
