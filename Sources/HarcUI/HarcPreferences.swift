import Foundation
import Combine
import SwiftUI
import HarcCore
import HarcMeetingDetect

/// App-wide preferences backed by UserDefaults. SwiftUI views observe.
@MainActor
public final class HarcPreferences: ObservableObject {
    private enum Key {
        static let destinationPath = "harc.destinationPath"
        static let diarize = "harc.diarize"
        static let chunkDurationSeconds = "harc.chunkDurationSeconds"
        static let vocabulary = "harc.vocabulary"
        static let meetingDetectionEnabled = "harc.meetingDetectionEnabled"
        static let meetingAppEnabled = "harc.meetingAppEnabled"
        static let autoPasteEnabled = "harc.autoPasteEnabled"
        static let vadEnabled = "harc.vadEnabled"
        static let autoStopEnabled = "harc.autoStopEnabled"
        static let silenceThresholdMinutes = "harc.silenceThresholdMinutes"
        static let hardCapEnabled = "harc.hardCapEnabled"
        static let hardCapMinutes = "harc.hardCapMinutes"
        static let postStopNotificationEnabled = "harc.postStopNotificationEnabled"
        static let activeSummarizerID = "harc.activeSummarizerID"
        static let activeEmbedderID = "harc.activeEmbedderID"
    }

    @Published public var destinationPath: String {
        didSet { UserDefaults.standard.set(destinationPath, forKey: Key.destinationPath) }
    }

    @Published public var diarize: Bool {
        didSet { UserDefaults.standard.set(diarize, forKey: Key.diarize) }
    }

    @Published public var chunkDurationSeconds: Double {
        didSet { UserDefaults.standard.set(chunkDurationSeconds, forKey: Key.chunkDurationSeconds) }
    }

    @Published public var vocabulary: Vocabulary {
        didSet { persistVocabulary() }
    }

    @Published public var meetingDetectionEnabled: Bool {
        didSet { UserDefaults.standard.set(meetingDetectionEnabled, forKey: Key.meetingDetectionEnabled) }
    }

    @Published public var meetingAppEnabled: [String: Bool] {
        didSet {
            if let data = try? JSONEncoder().encode(meetingAppEnabled) {
                UserDefaults.standard.set(data, forKey: Key.meetingAppEnabled)
            }
        }
    }

    @Published public var autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: Key.autoPasteEnabled) }
    }

    @Published public var vadEnabled: Bool {
        didSet { UserDefaults.standard.set(vadEnabled, forKey: Key.vadEnabled) }
    }

    /// Auto-stop when both mic + system-audio have been silent for
    /// `silenceThresholdMinutes`. Warns 60 s before stopping.
    @Published public var autoStopEnabled: Bool {
        didSet { UserDefaults.standard.set(autoStopEnabled, forKey: Key.autoStopEnabled) }
    }

    /// Allowed values: 3, 5, 10, 15.
    @Published public var silenceThresholdMinutes: Int {
        didSet { UserDefaults.standard.set(silenceThresholdMinutes, forKey: Key.silenceThresholdMinutes) }
    }

    /// Hard ceiling on recording length regardless of silence.
    @Published public var hardCapEnabled: Bool {
        didSet { UserDefaults.standard.set(hardCapEnabled, forKey: Key.hardCapEnabled) }
    }

    @Published public var hardCapMinutes: Int {
        didSet { UserDefaults.standard.set(hardCapMinutes, forKey: Key.hardCapMinutes) }
    }

    /// Additive macOS notification after auto-stop — the tray banner is always shown.
    @Published public var postStopNotificationEnabled: Bool {
        didSet { UserDefaults.standard.set(postStopNotificationEnabled, forKey: Key.postStopNotificationEnabled) }
    }

    /// Which summarizer model the user has selected. Value is a model id
    /// from `ModelCatalog.v1`; callers verify installation via `ModelManager`.
    /// Default: the lightweight `gemma-4-e2b-it-4bit` (nothing is installed
    /// until the user asks — the preference is just which tier they want).
    @Published public var activeSummarizerID: String {
        didSet { UserDefaults.standard.set(activeSummarizerID, forKey: Key.activeSummarizerID) }
    }

    /// Active text embedder. Singleton today (`bge-small-en-v1.5`).
    @Published public var activeEmbedderID: String {
        didSet { UserDefaults.standard.set(activeEmbedderID, forKey: Key.activeEmbedderID) }
    }

    public static let shared = HarcPreferences()

    public init() {
        let defaults = UserDefaults.standard
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc").path
        self.destinationPath = defaults.string(forKey: Key.destinationPath) ?? defaultPath
        self.diarize = defaults.object(forKey: Key.diarize) as? Bool ?? true
        self.chunkDurationSeconds = defaults.object(forKey: Key.chunkDurationSeconds) as? Double ?? 60.0
        if let data = defaults.data(forKey: Key.vocabulary),
           let decoded = try? JSONDecoder().decode(Vocabulary.self, from: data) {
            self.vocabulary = decoded
        } else {
            self.vocabulary = .empty
        }
        self.meetingDetectionEnabled = defaults.object(forKey: Key.meetingDetectionEnabled) as? Bool ?? false
        if let data = defaults.data(forKey: Key.meetingAppEnabled),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.meetingAppEnabled = decoded
        } else {
            self.meetingAppEnabled = [
                "us.zoom.xos": true,
                "com.microsoft.teams2": true,
                "com.tinyspeck.slackmacgap": false,
            ]
        }
        self.autoPasteEnabled = defaults.object(forKey: Key.autoPasteEnabled) as? Bool ?? true
        self.vadEnabled = defaults.object(forKey: Key.vadEnabled) as? Bool ?? true
        self.autoStopEnabled = defaults.object(forKey: Key.autoStopEnabled) as? Bool ?? true
        let rawThreshold = defaults.object(forKey: Key.silenceThresholdMinutes) as? Int ?? 5
        self.silenceThresholdMinutes = [3, 5, 10, 15].contains(rawThreshold) ? rawThreshold : 5
        self.hardCapEnabled = defaults.object(forKey: Key.hardCapEnabled) as? Bool ?? true
        self.hardCapMinutes = defaults.object(forKey: Key.hardCapMinutes) as? Int ?? 180
        self.postStopNotificationEnabled = defaults.object(forKey: Key.postStopNotificationEnabled) as? Bool ?? true
        self.activeSummarizerID = defaults.string(forKey: Key.activeSummarizerID) ?? "gemma-4-e2b-it-4bit"
        self.activeEmbedderID = defaults.string(forKey: Key.activeEmbedderID) ?? "bge-small-en-v1.5"
    }

    public func meetingAppBinding(for app: MeetingApp) -> Binding<Bool> {
        Binding(
            get: { self.meetingAppEnabled[app.id] ?? true },
            set: { newValue in
                var copy = self.meetingAppEnabled
                copy[app.id] = newValue
                self.meetingAppEnabled = copy
            }
        )
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath, isDirectory: true)
    }

    public func addEntry(from: String, to: String) {
        var v = vocabulary
        v.entries.append(VocabularyEntry(from: from, to: to))
        vocabulary = v
    }

    public func updateEntry(
        id: VocabularyEntry.ID,
        from: String? = nil,
        to: String? = nil,
        enabled: Bool? = nil
    ) {
        var v = vocabulary
        guard let idx = v.entries.firstIndex(where: { $0.id == id }) else { return }
        if let from { v.entries[idx].from = from }
        if let to { v.entries[idx].to = to }
        if let enabled { v.entries[idx].enabled = enabled }
        vocabulary = v
    }

    public func toggleEntry(id: VocabularyEntry.ID) {
        var v = vocabulary
        guard let idx = v.entries.firstIndex(where: { $0.id == id }) else { return }
        v.entries[idx].enabled.toggle()
        vocabulary = v
    }

    public func deleteEntries(ids: Set<VocabularyEntry.ID>) {
        var v = vocabulary
        v.entries.removeAll { ids.contains($0.id) }
        vocabulary = v
    }

    public func moveEntries(fromOffsets source: IndexSet, toOffset destination: Int) {
        var v = vocabulary
        v.entries.move(fromOffsets: source, toOffset: destination)
        vocabulary = v
    }

    private func persistVocabulary() {
        if let data = try? JSONEncoder().encode(vocabulary) {
            UserDefaults.standard.set(data, forKey: Key.vocabulary)
        }
    }
}
