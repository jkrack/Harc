import Foundation

// Supporting value types for `HarcWindowRootView`. Extracted from the view
// file to keep that file focused on view code. These were `private` to the
// view file; they are `internal` here and used only within HarcUI.

// MARK: - LibrarySelection

/// Discriminated union for the sidebar selection. Either a recording (keyed
/// by wav path) or a Person row (keyed by DB id). Phase 6 wires the
/// person-detail pane; for now selecting a Person leaves the detail pane
/// in its empty state.
public enum LibrarySelection: Hashable {
    case note(id: String)
    case recording(wavPath: String)
    case person(id: Int64)
    case project(name: String)
}

enum HarcLibraryMode: String, CaseIterable, Identifiable {
    case library = "Library"
    case wiki = "Wiki"
    case review = "Review"

    var id: String { rawValue }
}

enum ContextPackScope: String, CaseIterable, Identifiable {
    case topResults = "Top"
    case visibleResults = "Visible"
    case selectedResult = "Selected"

    var id: String { rawValue }
}

enum ContextScopeError: LocalizedError {
    case noSelectedSource

    var errorDescription: String? {
        "Select a note or recording before using Selected scope."
    }
}

@MainActor
final class NoteDraftSession {
    var body: String = ""
    var generation: Int = 0
    var autosaveTask: Task<Void, Never>?

    func load(body: String) {
        self.body = body
        generation += 1
    }

    func edit(body: String) {
        self.body = body
        generation += 1
    }

    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }
}

struct ResolvedWikilink: Identifiable {
    enum Target {
        case note(id: String)
        case recording(wavPath: String)
        case unresolved
    }

    let id: String
    let title: String
    let target: Target

    var isResolved: Bool {
        if case .unresolved = target { return false }
        return true
    }

    var iconName: String {
        switch target {
        case .note: return "note.text"
        case .recording: return "waveform"
        case .unresolved: return "questionmark.circle"
        }
    }

    var helpText: String {
        switch target {
        case .note: return "Open linked note"
        case .recording: return "Open linked recording"
        case .unresolved: return "No matching note or recording"
        }
    }
}

struct ProjectMention {
    let name: String
}
