import Foundation

struct PersistedLibrarySelection: Codable, Equatable {
    enum Kind: String, Codable {
        case recording
        case person
    }

    var kind: Kind
    var value: String

    /// Nil for `.live`: the in-progress recording is a session-scoped fact,
    /// and persisting it would restore a selection with nothing behind it on
    /// the next launch.
    init?(_ selection: LibrarySelection) {
        switch selection {
        case .live:
            return nil
        case .recording(let wavPath):
            kind = .recording
            value = wavPath
        case .person(let id):
            kind = .person
            value = String(id)
        }
    }

    var librarySelection: LibrarySelection? {
        switch kind {
        case .recording:
            return .recording(wavPath: value)
        case .person:
            guard let id = Int64(value) else { return nil }
            return .person(id: id)
        }
    }
}

/// What survives a relaunch: the selection, nothing else. Expansion state
/// died with the disclosure groups, and the section order died with the
/// reorder mechanism — drag-to-reorder plus three context-menu commands
/// plus persistence, to arrange a two-item list. The UserDefaults key is
/// unchanged: Codable ignores the legacy fields on decode, so old blobs
/// load and new writes simply omit them.
struct LibraryNavigationSnapshot: Codable, Equatable {
    var selection: PersistedLibrarySelection?

    static let defaults = LibraryNavigationSnapshot(selection: nil)

    private enum CodingKeys: String, CodingKey {
        case selection
    }

    init(selection: PersistedLibrarySelection?) {
        self.selection = selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try container.decodeIfPresent(PersistedLibrarySelection.self, forKey: .selection)
    }
}

enum LibraryNavigationStateStore {
    private static let key = "harc.libraryNavigationState.v1"

    static func load(defaults: UserDefaults = .standard) -> LibraryNavigationSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(LibraryNavigationSnapshot.self, from: data)
        else {
            return .defaults
        }
        return snapshot
    }

    static func save(_ snapshot: LibraryNavigationSnapshot, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

enum LibraryNavigationResolver {
    static func resolvedSelection(
        restored: LibrarySelection?,
        recordingPaths: Set<String>,
        personIDs: Set<Int64>,
        fallbackRecordingPath: String?
    ) -> LibrarySelection? {
        if let restored, isValid(
            restored,
            recordingPaths: recordingPaths,
            personIDs: personIDs
        ) {
            return restored
        }
        if let fallbackRecordingPath {
            return .recording(wavPath: fallbackRecordingPath)
        }
        return nil
    }

    static func isValid(
        _ selection: LibrarySelection,
        recordingPaths: Set<String>,
        personIDs: Set<Int64>
    ) -> Bool {
        switch selection {
        case .live:
            // Never restorable: `PersistedLibrarySelection` refuses to encode
            // it, and validating it as a *restored* value would resurrect a
            // recording that ended with the last session.
            return false
        case .recording(let wavPath):
            return recordingPaths.contains(wavPath)
        case .person(let id):
            return personIDs.contains(id)
        }
    }
}
