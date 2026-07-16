import Foundation
import Combine

/// One completed dictation. These are ephemeral snippets, not library data —
/// they live in a small rolling JSON file, never GRDB.
public struct DictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Delivery: String, Codable, Sendable {
        /// Inserted at the cursor in the target app.
        case pasted
        /// Left on the clipboard (deny-listed target or paste failure).
        case copied
    }

    public var id: String
    /// The text that was delivered (post-mode-transform when one ran).
    public var text: String
    /// The raw transcript when a mode transformed it; nil when text IS raw.
    public var rawText: String?
    public var modeName: String
    /// Localized name of the app the text was delivered to, when known.
    public var targetAppName: String?
    public var delivery: Delivery
    public var date: Date

    public init(
        id: String = UUID().uuidString,
        text: String,
        rawText: String? = nil,
        modeName: String,
        targetAppName: String? = nil,
        delivery: Delivery,
        date: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.modeName = modeName
        self.targetAppName = targetAppName
        self.delivery = delivery
        self.date = date
    }
}

/// Rolling history of recent dictations, persisted as JSON in Application
/// Support (same idiom as `DictationModeStore`). Recording is gated on
/// `prefs.dictationHistoryEnabled` — when off, nothing is written.
@MainActor
public final class DictationHistoryStore: ObservableObject {
    @Published public private(set) var entries: [DictationHistoryEntry] = []

    public static let maxEntries = 50

    private let fileURL: URL
    private let prefs: HarcPreferences

    /// Default persistence location: `~/Library/Application Support/Harc/dictation-history.json`.
    public static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Harc/dictation-history.json")
    }

    public init(fileURL: URL = DictationHistoryStore.defaultFileURL(), prefs: HarcPreferences) {
        self.fileURL = fileURL
        self.prefs = prefs
        if prefs.dictationHistoryEnabled,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) {
            entries = Array(decoded.prefix(Self.maxEntries))
        }
    }

    /// Prepend an entry (newest first), capped at `maxEntries`. No-op when
    /// history is disabled.
    public func record(_ entry: DictationHistoryEntry) {
        guard prefs.dictationHistoryEnabled else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        persist()
    }

    /// Drop all entries and delete the file on disk.
    public func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal — history stays usable in-memory.
        }
    }
}
