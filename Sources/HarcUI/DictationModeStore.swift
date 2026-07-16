import Foundation
import Combine

/// Owns the dictation-mode list: seeded built-ins plus user-created modes,
/// persisted as JSON in Application Support (modes are small config, not
/// library data — no GRDB). Built-ins can be edited (and reset) but never
/// deleted. The active mode id lives in `HarcPreferences`.
@MainActor
public final class DictationModeStore: ObservableObject {
    @Published public private(set) var modes: [DictationMode] = []

    private let fileURL: URL
    private let prefs: HarcPreferences

    /// Default persistence location: `~/Library/Application Support/Harc/dictation-modes.json`.
    public static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Harc/dictation-modes.json")
    }

    public init(fileURL: URL = DictationModeStore.defaultFileURL(), prefs: HarcPreferences) {
        self.fileURL = fileURL
        self.prefs = prefs
        self.modes = Self.load(from: fileURL)
    }

    /// The mode dictation runs with right now. Falls back to Raw when the
    /// persisted selection no longer exists.
    public var activeMode: DictationMode {
        modes.first { $0.id == prefs.activeDictationModeID }
            ?? modes.first { $0.id == DictationMode.rawID }
            ?? DictationMode.builtIns[0]
    }

    public func setActiveMode(id: String) {
        guard modes.contains(where: { $0.id == id }) else { return }
        prefs.activeDictationModeID = id
    }

    // MARK: - CRUD

    public func add(_ mode: DictationMode) {
        var mode = mode
        mode.isBuiltIn = false
        guard !modes.contains(where: { $0.id == mode.id }) else { return }
        modes.append(mode)
        persist()
    }

    public func update(_ mode: DictationMode) {
        guard let idx = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        var mode = mode
        // Built-in identity is immutable — an edit can't demote or promote it.
        mode.isBuiltIn = modes[idx].isBuiltIn
        modes[idx] = mode
        persist()
    }

    /// Built-ins can't be deleted. Deleting the active mode falls back to Raw.
    public func delete(id: String) {
        guard let idx = modes.firstIndex(where: { $0.id == id }) else { return }
        guard !modes[idx].isBuiltIn else { return }
        modes.remove(at: idx)
        if prefs.activeDictationModeID == id {
            prefs.activeDictationModeID = DictationMode.rawID
        }
        persist()
    }

    /// Restore a built-in mode's seeded definition.
    public func resetBuiltIn(id: String) {
        guard let seeded = DictationMode.builtIn(id: id),
              let idx = modes.firstIndex(where: { $0.id == id }) else { return }
        modes[idx] = seeded
        persist()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [DictationMode] {
        var loaded: [DictationMode] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DictationMode].self, from: data) {
            loaded = decoded
        }
        // Merge: every built-in must exist (persisted edits win); user modes
        // follow in their stored order.
        var merged: [DictationMode] = []
        for builtIn in DictationMode.builtIns {
            merged.append(loaded.first { $0.id == builtIn.id && $0.isBuiltIn } ?? builtIn)
        }
        merged.append(contentsOf: loaded.filter { !$0.isBuiltIn })
        return merged
    }

    private func persist() {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(modes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal — modes stay usable in-memory.
        }
    }
}
