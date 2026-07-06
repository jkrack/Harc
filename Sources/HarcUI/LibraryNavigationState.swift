import Foundation

enum LibrarySidebarSection: String, Codable, CaseIterable, Identifiable {
    case recordings
    case people

    var id: String { rawValue }

    static let defaultOrder: [LibrarySidebarSection] = [.recordings, .people]

    static func normalizedOrder(_ order: [LibrarySidebarSection]) -> [LibrarySidebarSection] {
        var seen: Set<LibrarySidebarSection> = []
        var result: [LibrarySidebarSection] = []
        for section in order + defaultOrder where !seen.contains(section) {
            seen.insert(section)
            result.append(section)
        }
        return result
    }
}

struct PersistedLibrarySelection: Codable, Equatable {
    enum Kind: String, Codable {
        case recording
        case person
    }

    var kind: Kind
    var value: String

    init(_ selection: LibrarySelection) {
        switch selection {
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

struct LibraryNavigationSnapshot: Codable, Equatable {
    var selection: PersistedLibrarySelection?
    var peopleExpanded: Bool
    var recordingsExpanded: Bool
    var sidebarSectionOrder: [LibrarySidebarSection]

    static let defaults = LibraryNavigationSnapshot(
        selection: nil,
        peopleExpanded: false,
        recordingsExpanded: true,
        sidebarSectionOrder: LibrarySidebarSection.defaultOrder
    )

    private enum CodingKeys: String, CodingKey {
        case selection
        case peopleExpanded
        case recordingsExpanded
        case sidebarSectionOrder
    }

    init(
        selection: PersistedLibrarySelection?,
        peopleExpanded: Bool,
        recordingsExpanded: Bool,
        sidebarSectionOrder: [LibrarySidebarSection]
    ) {
        self.selection = selection
        self.peopleExpanded = peopleExpanded
        self.recordingsExpanded = recordingsExpanded
        self.sidebarSectionOrder = LibrarySidebarSection.normalizedOrder(sidebarSectionOrder)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try container.decodeIfPresent(PersistedLibrarySelection.self, forKey: .selection)
        peopleExpanded = try container.decodeIfPresent(Bool.self, forKey: .peopleExpanded) ?? Self.defaults.peopleExpanded
        recordingsExpanded = try container.decodeIfPresent(Bool.self, forKey: .recordingsExpanded) ?? Self.defaults.recordingsExpanded
        sidebarSectionOrder = LibrarySidebarSection.normalizedOrder(
            try container.decodeIfPresent([LibrarySidebarSection].self, forKey: .sidebarSectionOrder) ?? Self.defaults.sidebarSectionOrder
        )
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
        case .recording(let wavPath):
            return recordingPaths.contains(wavPath)
        case .person(let id):
            return personIDs.contains(id)
        }
    }
}
