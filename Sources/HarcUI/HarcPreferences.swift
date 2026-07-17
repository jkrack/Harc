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
        static let pasteDenyListBundleIDs = "harc.pasteDenyListBundleIDs"
        static let vadEnabled = "harc.vadEnabled"
        static let autoStopEnabled = "harc.autoStopEnabled"
        static let silenceThresholdMinutes = "harc.silenceThresholdMinutes"
        static let hardCapEnabled = "harc.hardCapEnabled"
        static let hardCapMinutes = "harc.hardCapMinutes"
        static let postStopNotificationEnabled = "harc.postStopNotificationEnabled"
        static let activeSummarizerID = "harc.activeSummarizerID"
        static let speakerReIDEnabled = "harc.speakerReIDEnabled"
        static let speakerReIDAutoApply = "harc.speakerReIDAutoApply"
        static let autoSummarizeEnabled = "harc.autoSummarizeEnabled"
        static let autoSummarizeOnBatteryEnabled = "harc.autoSummarizeOnBatteryEnabled"
        static let includeSummaryInPrompt = "harc.includeSummaryInPrompt"
        static let appearance = "harc.appearance"
        static let welcomeFlowCompleted = "harc.welcomeFlowCompleted"
        static let modelPerformanceMode = "harc.modelPerformanceMode"
        static let dictationTriggerStyle = "harc.dictationTriggerStyle"
        static let activeDictationModeID = "harc.activeDictationModeID"
        static let keepDictationWarm = "harc.keepDictationWarm"
        static let keepDictationWarmWindow = "harc.keepDictationWarmWindow"
        static let dictationHistoryEnabled = "harc.dictationHistoryEnabled"
        static let dictationInsertsAtCursor = "harc.dictationInsertsAtCursor"
        static let restoreClipboardAfterInsert = "harc.restoreClipboardAfterInsert"
        static let dictationSoundsEnabled = "harc.dictationSoundsEnabled"
        static let updateChecksEnabled = "harc.updateChecksEnabled"
    }

    /// Override macOS appearance. `.system` (default) follows System Settings.
    public enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    /// How the dictation hotkey behaves.
    public enum DictationTriggerStyle: String, CaseIterable, Identifiable {
        /// Hold the hotkey to dictate; release to transcribe + insert.
        case pushToTalk
        /// Tap the hotkey to start, tap again to stop.
        case toggle

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .pushToTalk: return "Push to talk (hold)"
            case .toggle: return "Toggle (tap on / off)"
            }
        }
    }

    /// How long after the last dictation the keep-warm pinger holds the
    /// speech model resident. Maps to `DictationKeepWarmController`'s active
    /// window; `always` never lets the daemon idle out.
    public enum DictationKeepWarmWindow: String, CaseIterable, Identifiable {
        case oneHour
        case fourHours
        case always

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .oneHour: return "For 1 hour after use"
            case .fourHours: return "For 4 hours after use"
            case .always: return "Always"
            }
        }

        /// Seconds since the last dictation to keep pinging; nil = no limit.
        public var activeWindow: TimeInterval? {
            switch self {
            case .oneHour: return 60 * 60
            case .fourHours: return 4 * 60 * 60
            case .always: return nil
            }
        }
    }

    public enum ModelPerformanceMode: String, CaseIterable, Identifiable {
        case balanced
        case fastResponses
        case lowMemory

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .balanced: return "Balanced"
            case .fastResponses: return "Fast Responses"
            case .lowMemory: return "Low Memory"
            }
        }

        public var detail: String {
            switch self {
            case .balanced:
                return "Keep recently used models warm briefly, then release them."
            case .fastResponses:
                return "Keep recently used models warm longer for faster follow-up questions."
            case .lowMemory:
                return "Release models as soon as each job finishes."
            }
        }

        public var summarizerIdleUnloadDelay: TimeInterval {
            switch self {
            case .balanced: return 10 * 60
            case .fastResponses: return 30 * 60
            case .lowMemory: return 0
            }
        }
    }

    @Published public var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance) }
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

    @Published public var pasteDenyListBundleIDs: Set<String> {
        didSet { persistPasteDenyListBundleIDs() }
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

    /// Cross-recording speaker re-ID — extract per-speaker voice fingerprints
    /// after recording, cluster across the library, and suggest names in the
    /// speaker editor.
    ///
    /// **Defaults to `true` with WeSpeaker v2 on board.** User-set false
    /// values are preserved unchanged.
    @Published public var speakerReIDEnabled: Bool {
        didSet { UserDefaults.standard.set(speakerReIDEnabled, forKey: Key.speakerReIDEnabled) }
    }

    /// When true, single-match high-confidence suggestions apply silently
    /// without user confirmation. Off by default; suggestions are one click.
    @Published public var speakerReIDAutoApply: Bool {
        didSet { UserDefaults.standard.set(speakerReIDAutoApply, forKey: Key.speakerReIDAutoApply) }
    }

    /// Fire the summarization queue from `stopRecording` when the active
    /// summarizer is installed + power conditions allow. Default on.
    @Published public var autoSummarizeEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSummarizeEnabled, forKey: Key.autoSummarizeEnabled) }
    }

    /// Allow auto-summarize when the laptop is on battery. Default off
    /// — Gemma 4 is multi-GB resident and drains battery fast.
    @Published public var autoSummarizeOnBatteryEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSummarizeOnBatteryEnabled, forKey: Key.autoSummarizeOnBatteryEnabled) }
    }

    /// Prepend the summary + action items to prompt, Markdown, and DOCX
    /// exports when complete summary columns exist. Default on.
    @Published public var includeSummaryInPrompt: Bool {
        didSet { UserDefaults.standard.set(includeSummaryInPrompt, forKey: Key.includeSummaryInPrompt) }
    }

    @Published public var welcomeFlowCompleted: Bool {
        didSet { UserDefaults.standard.set(welcomeFlowCompleted, forKey: Key.welcomeFlowCompleted) }
    }

    @Published public var modelPerformanceMode: ModelPerformanceMode {
        didSet { UserDefaults.standard.set(modelPerformanceMode.rawValue, forKey: Key.modelPerformanceMode) }
    }

    @Published public var dictationTriggerStyle: DictationTriggerStyle {
        didSet { UserDefaults.standard.set(dictationTriggerStyle.rawValue, forKey: Key.dictationTriggerStyle) }
    }

    /// The dictation mode transcripts run through before insertion.
    /// A `DictationMode.id` — validated against the mode store by callers.
    @Published public var activeDictationModeID: String {
        didSet { UserDefaults.standard.set(activeDictationModeID, forKey: Key.activeDictationModeID) }
    }

    /// Periodically ping the STT daemon so the speech model stays resident
    /// and the first dictation after a break isn't slowed by a cold load.
    @Published public var keepDictationWarm: Bool {
        didSet { UserDefaults.standard.set(keepDictationWarm, forKey: Key.keepDictationWarm) }
    }

    /// Keep a short local history of recent dictations. When off, nothing
    /// is recorded or persisted.
    @Published public var dictationHistoryEnabled: Bool {
        didSet { UserDefaults.standard.set(dictationHistoryEnabled, forKey: Key.dictationHistoryEnabled) }
    }

    /// How long the keep-warm pinger holds the speech model after the last
    /// dictation. Only meaningful while `keepDictationWarm` is on.
    @Published public var keepDictationWarmWindow: DictationKeepWarmWindow {
        didSet { UserDefaults.standard.set(keepDictationWarmWindow.rawValue, forKey: Key.keepDictationWarmWindow) }
    }

    /// Insert dictated text at the cursor (paste). When off, dictations land
    /// on the clipboard only.
    @Published public var dictationInsertsAtCursor: Bool {
        didSet { UserDefaults.standard.set(dictationInsertsAtCursor, forKey: Key.dictationInsertsAtCursor) }
    }

    /// Put the user's previous clipboard contents back after a dictation
    /// paste lands.
    @Published public var restoreClipboardAfterInsert: Bool {
        didSet { UserDefaults.standard.set(restoreClipboardAfterInsert, forKey: Key.restoreClipboardAfterInsert) }
    }

    /// Subtle start/stop/success sounds around dictation.
    @Published public var dictationSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(dictationSoundsEnabled, forKey: Key.dictationSoundsEnabled) }
    }

    /// Daily check of GitHub releases for a newer Harc. The only network
    /// request Harc makes on its own; carries nothing about the user.
    @Published public var updateChecksEnabled: Bool {
        didSet { UserDefaults.standard.set(updateChecksEnabled, forKey: Key.updateChecksEnabled) }
    }

    public static let shared = HarcPreferences()

    public init() {
        let defaults = UserDefaults.standard
        self.destinationPath = defaults.string(forKey: Key.destinationPath)
            ?? Self.defaultDestinationPath
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
        let storedPasteDenyList = defaults.array(forKey: Key.pasteDenyListBundleIDs) as? [String]
        let normalizedPasteDenyList: Set<String>
        if let storedPasteDenyList {
            normalizedPasteDenyList = Set(storedPasteDenyList).union(PasteDenyList.lockedBundleIDs)
        } else {
            normalizedPasteDenyList = PasteDenyList.defaultBundleIDs
        }
        self.pasteDenyListBundleIDs = normalizedPasteDenyList
        let shouldPersistPasteDenyList = Set(storedPasteDenyList ?? []) != normalizedPasteDenyList
        self.vadEnabled = defaults.object(forKey: Key.vadEnabled) as? Bool ?? true
        self.autoStopEnabled = defaults.object(forKey: Key.autoStopEnabled) as? Bool ?? true
        let rawThreshold = defaults.object(forKey: Key.silenceThresholdMinutes) as? Int ?? 5
        self.silenceThresholdMinutes = [3, 5, 10, 15].contains(rawThreshold) ? rawThreshold : 5
        self.hardCapEnabled = defaults.object(forKey: Key.hardCapEnabled) as? Bool ?? true
        self.hardCapMinutes = defaults.object(forKey: Key.hardCapMinutes) as? Int ?? 180
        self.postStopNotificationEnabled = defaults.object(forKey: Key.postStopNotificationEnabled) as? Bool ?? true
        self.activeSummarizerID = defaults.string(forKey: Key.activeSummarizerID) ?? "gemma-4-e2b-it-4bit"
        self.speakerReIDEnabled = defaults.object(forKey: Key.speakerReIDEnabled) as? Bool ?? true
        self.speakerReIDAutoApply = defaults.object(forKey: Key.speakerReIDAutoApply) as? Bool ?? false
        self.autoSummarizeEnabled = defaults.object(forKey: Key.autoSummarizeEnabled) as? Bool ?? true
        self.autoSummarizeOnBatteryEnabled = defaults.object(forKey: Key.autoSummarizeOnBatteryEnabled) as? Bool ?? false
        self.includeSummaryInPrompt = defaults.object(forKey: Key.includeSummaryInPrompt) as? Bool ?? true
        self.welcomeFlowCompleted = defaults.object(forKey: Key.welcomeFlowCompleted) as? Bool ?? false
        let rawModelPerformanceMode = defaults.string(forKey: Key.modelPerformanceMode) ?? ModelPerformanceMode.balanced.rawValue
        self.modelPerformanceMode = ModelPerformanceMode(rawValue: rawModelPerformanceMode) ?? .balanced
        let rawDictationTriggerStyle = defaults.string(forKey: Key.dictationTriggerStyle) ?? DictationTriggerStyle.pushToTalk.rawValue
        self.dictationTriggerStyle = DictationTriggerStyle(rawValue: rawDictationTriggerStyle) ?? .pushToTalk
        self.activeDictationModeID = defaults.string(forKey: Key.activeDictationModeID) ?? DictationMode.rawID
        self.keepDictationWarm = defaults.object(forKey: Key.keepDictationWarm) as? Bool ?? true
        let rawKeepWarmWindow = defaults.string(forKey: Key.keepDictationWarmWindow) ?? DictationKeepWarmWindow.always.rawValue
        self.keepDictationWarmWindow = DictationKeepWarmWindow(rawValue: rawKeepWarmWindow) ?? .always
        self.dictationHistoryEnabled = defaults.object(forKey: Key.dictationHistoryEnabled) as? Bool ?? true
        self.dictationInsertsAtCursor = defaults.object(forKey: Key.dictationInsertsAtCursor) as? Bool ?? true
        self.restoreClipboardAfterInsert = defaults.object(forKey: Key.restoreClipboardAfterInsert) as? Bool ?? true
        self.dictationSoundsEnabled = defaults.object(forKey: Key.dictationSoundsEnabled) as? Bool ?? true
        self.updateChecksEnabled = defaults.object(forKey: Key.updateChecksEnabled) as? Bool ?? true
        let rawAppearance = defaults.string(forKey: Key.appearance) ?? Appearance.system.rawValue
        self.appearance = Appearance(rawValue: rawAppearance) ?? .system
        if shouldPersistPasteDenyList {
            persistPasteDenyListBundleIDs()
        }
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

    /// True iff the persisted destination path resolves to an existing
    /// directory. Cheap synchronous stat — safe to call from the main
    /// thread on launch, on Settings open, and at recording start.
    /// Returns false for missing paths, paths to plain files, and paths
    /// on unmounted external volumes.
    public func destinationFolderExists() -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: destinationPath,
            isDirectory: &isDir
        )
        return exists && isDir.boolValue
    }

    public func addPasteDenyListBundleID(_ bundleID: String) {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var copy = pasteDenyListBundleIDs
        copy.insert(normalized)
        pasteDenyListBundleIDs = copy
    }

    public func removePasteDenyListBundleID(_ bundleID: String) {
        guard !PasteDenyList.lockedBundleIDs.contains(bundleID) else { return }
        var copy = pasteDenyListBundleIDs
        copy.remove(bundleID)
        pasteDenyListBundleIDs = copy.union(PasteDenyList.lockedBundleIDs)
    }

    public func completeWelcomeFlow() {
        welcomeFlowCompleted = true
    }

    /// The default destination — `~/Documents/Harc`. Available as a
    /// fallback when the persisted destination becomes unreachable.
    public static var defaultDestinationPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc").path
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

    private func persistPasteDenyListBundleIDs() {
        UserDefaults.standard.set(pasteDenyListBundleIDs.sorted(), forKey: Key.pasteDenyListBundleIDs)
    }
}
