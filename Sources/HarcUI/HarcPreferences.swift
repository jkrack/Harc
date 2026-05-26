import Foundation
import Combine
import SwiftUI
import HarcCore
import HarcMeetingDetect
import HarcContext

/// App-wide preferences backed by UserDefaults. SwiftUI views observe.
@MainActor
public final class HarcPreferences: ObservableObject {
    private enum Key {
        static let destinationPath = "harc.destinationPath"
        static let notesPath = "harc.notesPath"
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
        static let activeEmbedderID = "harc.activeEmbedderID"
        static let speakerReIDEnabled = "harc.speakerReIDEnabled"
        static let speakerReIDAutoApply = "harc.speakerReIDAutoApply"
        static let autoSummarizeEnabled = "harc.autoSummarizeEnabled"
        static let autoSummarizeOnBatteryEnabled = "harc.autoSummarizeOnBatteryEnabled"
        static let includeSummaryInPrompt = "harc.includeSummaryInPrompt"
        static let appearance = "harc.appearance"
        static let sourceRoots = "harc.sourceRoots"
        static let sourceScanLimit = "harc.sourceScanLimit"
        static let welcomeFlowCompleted = "harc.welcomeFlowCompleted"
        static let modelPerformanceMode = "harc.modelPerformanceMode"
        static let markdownFormattingRibbonEnabled = "harc.markdownFormattingRibbonEnabled"
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

        public var embedderIdleUnloadDelay: TimeInterval {
            switch self {
            case .balanced: return 30 * 60
            case .fastResponses: return 60 * 60
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

    @Published public var notesPath: String {
        didSet { UserDefaults.standard.set(notesPath, forKey: Key.notesPath) }
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

    /// Active text embedder. Singleton today (`bge-small-en-v1.5`).
    @Published public var activeEmbedderID: String {
        didSet { UserDefaults.standard.set(activeEmbedderID, forKey: Key.activeEmbedderID) }
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

    @Published public var sourceRoots: [LocalSourceRoot] {
        didSet { persistSourceRoots() }
    }

    @Published public var sourceScanLimit: Int {
        didSet {
            let clamped = Self.clampedSourceScanLimit(sourceScanLimit)
            if sourceScanLimit != clamped {
                sourceScanLimit = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Key.sourceScanLimit)
        }
    }

    @Published public var welcomeFlowCompleted: Bool {
        didSet { UserDefaults.standard.set(welcomeFlowCompleted, forKey: Key.welcomeFlowCompleted) }
    }

    @Published public var modelPerformanceMode: ModelPerformanceMode {
        didSet { UserDefaults.standard.set(modelPerformanceMode.rawValue, forKey: Key.modelPerformanceMode) }
    }

    @Published public var markdownFormattingRibbonEnabled: Bool {
        didSet { UserDefaults.standard.set(markdownFormattingRibbonEnabled, forKey: Key.markdownFormattingRibbonEnabled) }
    }

    public static let shared = HarcPreferences()
    public static let defaultSourceScanLimit = 40
    public static let sourceScanLimitRange = 10...500

    public init() {
        let defaults = UserDefaults.standard
        self.destinationPath = defaults.string(forKey: Key.destinationPath)
            ?? Self.defaultDestinationPath
        let storedNotesPath = defaults.string(forKey: Key.notesPath)
        let resolvedNotesPath = Self.resolvedNotesPath(storedNotesPath)
        self.notesPath = resolvedNotesPath
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
        self.activeEmbedderID = defaults.string(forKey: Key.activeEmbedderID) ?? "bge-small-en-v1.5"
        self.speakerReIDEnabled = defaults.object(forKey: Key.speakerReIDEnabled) as? Bool ?? true
        self.speakerReIDAutoApply = defaults.object(forKey: Key.speakerReIDAutoApply) as? Bool ?? false
        self.autoSummarizeEnabled = defaults.object(forKey: Key.autoSummarizeEnabled) as? Bool ?? true
        self.autoSummarizeOnBatteryEnabled = defaults.object(forKey: Key.autoSummarizeOnBatteryEnabled) as? Bool ?? false
        self.includeSummaryInPrompt = defaults.object(forKey: Key.includeSummaryInPrompt) as? Bool ?? true
        let rawSourceScanLimit = defaults.object(forKey: Key.sourceScanLimit) as? Int ?? Self.defaultSourceScanLimit
        self.sourceScanLimit = Self.clampedSourceScanLimit(rawSourceScanLimit)
        if let data = defaults.data(forKey: Key.sourceRoots),
           let decoded = try? JSONDecoder().decode([LocalSourceRoot].self, from: data) {
            self.sourceRoots = decoded
        } else {
            self.sourceRoots = []
        }
        self.welcomeFlowCompleted = defaults.object(forKey: Key.welcomeFlowCompleted) as? Bool ?? false
        let rawModelPerformanceMode = defaults.string(forKey: Key.modelPerformanceMode) ?? ModelPerformanceMode.balanced.rawValue
        self.modelPerformanceMode = ModelPerformanceMode(rawValue: rawModelPerformanceMode) ?? .balanced
        self.markdownFormattingRibbonEnabled = defaults.object(forKey: Key.markdownFormattingRibbonEnabled) as? Bool ?? true
        let rawAppearance = defaults.string(forKey: Key.appearance) ?? Appearance.system.rawValue
        self.appearance = Appearance(rawValue: rawAppearance) ?? .system
        if shouldPersistPasteDenyList {
            persistPasteDenyListBundleIDs()
        }
        if storedNotesPath != nil, storedNotesPath != resolvedNotesPath {
            defaults.set(resolvedNotesPath, forKey: Key.notesPath)
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

    public var notesURL: URL {
        URL(fileURLWithPath: notesPath, isDirectory: true)
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

    public func notesFolderExists() -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: notesPath,
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

    public static var defaultNotesPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc/Notes").path
    }

    public static func resolvedNotesPath(_ storedPath: String?) -> String {
        guard let storedPath, !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultNotesPath
        }
        guard !isLeakedUITestNotesPath(storedPath) else {
            return defaultNotesPath
        }
        return storedPath
    }

    public static func isLeakedUITestNotesPath(_ path: String) -> Bool {
        path.contains("HarcAppUITests.xctrunner") || path.contains("/harc-app-ui-")
    }

    public static func clampedSourceScanLimit(_ value: Int) -> Int {
        min(sourceScanLimitRange.upperBound, max(sourceScanLimitRange.lowerBound, value))
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

    private func persistSourceRoots() {
        if let data = try? JSONEncoder().encode(sourceRoots) {
            UserDefaults.standard.set(data, forKey: Key.sourceRoots)
        }
    }

    private func persistPasteDenyListBundleIDs() {
        UserDefaults.standard.set(pasteDenyListBundleIDs.sorted(), forKey: Key.pasteDenyListBundleIDs)
    }
}
