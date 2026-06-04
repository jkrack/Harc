import Foundation

enum LibrarySidebarSection: String, Codable, CaseIterable, Identifiable {
    case recordings
    case notes
    case projects
    case people

    var id: String { rawValue }

    static let defaultOrder: [LibrarySidebarSection] = [.recordings, .notes, .projects, .people]

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
        case note
        case recording
        case person
        case project
    }

    var kind: Kind
    var value: String

    init(_ selection: LibrarySelection) {
        switch selection {
        case .note(let id):
            kind = .note
            value = id
        case .recording(let wavPath):
            kind = .recording
            value = wavPath
        case .person(let id):
            kind = .person
            value = String(id)
        case .project(let name):
            kind = .project
            value = name
        }
    }

    var librarySelection: LibrarySelection? {
        switch kind {
        case .note:
            return .note(id: value)
        case .recording:
            return .recording(wavPath: value)
        case .person:
            guard let id = Int64(value) else { return nil }
            return .person(id: id)
        case .project:
            return .project(name: value)
        }
    }
}

struct LibraryNavigationSnapshot: Codable, Equatable {
    var modeRawValue: String
    var selection: PersistedLibrarySelection?
    var notesExpanded: Bool
    var projectsExpanded: Bool
    var peopleExpanded: Bool
    var recordingsExpanded: Bool
    var sidebarSectionOrder: [LibrarySidebarSection]
    var expandedNoteBuckets: [String]
    var knownNoteBuckets: [String]

    static let defaults = LibraryNavigationSnapshot(
        modeRawValue: "Library",
        selection: nil,
        notesExpanded: true,
        projectsExpanded: false,
        peopleExpanded: false,
        recordingsExpanded: true,
        sidebarSectionOrder: LibrarySidebarSection.defaultOrder,
        expandedNoteBuckets: [],
        knownNoteBuckets: []
    )

    private enum CodingKeys: String, CodingKey {
        case modeRawValue
        case selection
        case notesExpanded
        case projectsExpanded
        case peopleExpanded
        case recordingsExpanded
        case sidebarSectionOrder
        case expandedNoteBuckets
        case knownNoteBuckets
    }

    init(
        modeRawValue: String,
        selection: PersistedLibrarySelection?,
        notesExpanded: Bool,
        projectsExpanded: Bool,
        peopleExpanded: Bool,
        recordingsExpanded: Bool,
        sidebarSectionOrder: [LibrarySidebarSection],
        expandedNoteBuckets: [String],
        knownNoteBuckets: [String]
    ) {
        self.modeRawValue = modeRawValue
        self.selection = selection
        self.notesExpanded = notesExpanded
        self.projectsExpanded = projectsExpanded
        self.peopleExpanded = peopleExpanded
        self.recordingsExpanded = recordingsExpanded
        self.sidebarSectionOrder = LibrarySidebarSection.normalizedOrder(sidebarSectionOrder)
        self.expandedNoteBuckets = expandedNoteBuckets
        self.knownNoteBuckets = knownNoteBuckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modeRawValue = try container.decodeIfPresent(String.self, forKey: .modeRawValue) ?? Self.defaults.modeRawValue
        selection = try container.decodeIfPresent(PersistedLibrarySelection.self, forKey: .selection)
        notesExpanded = try container.decodeIfPresent(Bool.self, forKey: .notesExpanded) ?? Self.defaults.notesExpanded
        projectsExpanded = try container.decodeIfPresent(Bool.self, forKey: .projectsExpanded) ?? Self.defaults.projectsExpanded
        peopleExpanded = try container.decodeIfPresent(Bool.self, forKey: .peopleExpanded) ?? Self.defaults.peopleExpanded
        recordingsExpanded = try container.decodeIfPresent(Bool.self, forKey: .recordingsExpanded) ?? Self.defaults.recordingsExpanded
        sidebarSectionOrder = LibrarySidebarSection.normalizedOrder(
            try container.decodeIfPresent([LibrarySidebarSection].self, forKey: .sidebarSectionOrder) ?? Self.defaults.sidebarSectionOrder
        )
        expandedNoteBuckets = try container.decodeIfPresent([String].self, forKey: .expandedNoteBuckets) ?? []
        knownNoteBuckets = try container.decodeIfPresent([String].self, forKey: .knownNoteBuckets) ?? []
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
        noteIDs: Set<String>,
        recordingPaths: Set<String>,
        personIDs: Set<Int64>,
        projectNames: Set<String>,
        fallbackNoteID: String?,
        fallbackRecordingPath: String?
    ) -> LibrarySelection? {
        if let restored, isValid(
            restored,
            noteIDs: noteIDs,
            recordingPaths: recordingPaths,
            personIDs: personIDs,
            projectNames: projectNames
        ) {
            return restored
        }
        if let fallbackNoteID {
            return .note(id: fallbackNoteID)
        }
        if let fallbackRecordingPath {
            return .recording(wavPath: fallbackRecordingPath)
        }
        return nil
    }

    static func isValid(
        _ selection: LibrarySelection,
        noteIDs: Set<String>,
        recordingPaths: Set<String>,
        personIDs: Set<Int64>,
        projectNames: Set<String>
    ) -> Bool {
        switch selection {
        case .note(let id):
            return noteIDs.contains(id)
        case .recording(let wavPath):
            return recordingPaths.contains(wavPath)
        case .person(let id):
            return personIDs.contains(id)
        case .project(let name):
            return projectNames.contains(name)
        }
    }
}
