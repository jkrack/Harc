import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Sparkle
import SwiftUI
import UserNotifications
import HarcAudio
import HarcClient
import HarcCore
import HarcExport
import HarcHost
import HarcHostTransport
import HarcMeetingDetect
import HarcModels
import HarcStore
import HarcUI
import HarcSummarize
import HarcVoiceprint
import IOKit.ps
import KeyboardShortcuts

/// Thrown by stopRecording's timeout race when session.stop() exceeds the cap.
/// First-resume-wins gate for racing unstructured tasks onto one continuation.
private final class ResumeOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

/// Internal-invariant fallback: still let `RecordingSession.stop()` close a
/// durable master, then fail publication without consuming it. This path
/// should never be selected in production, but it must be recovery-safe if
/// session/committer bookkeeping is ever corrupted.
private struct MissingRecordingCommitter: RecordingCommitter {
    struct CommitterMissingError: LocalizedError, Sendable {
        var errorDescription: String? {
            "The recording publisher was not initialized. The cache master was preserved for Recovery."
        }
    }

    func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome {
        throw CommitterMissingError()
    }
}

/// Publishes Sparkle's discovered updates onto the bridge so HarcUI stays
/// Sparkle-free. Delegate callbacks arrive off the main actor — primitives
/// are extracted before hopping.
final class HarcUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var bridge: HarcAppBridge?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let url = item.infoURL ?? URL(string: "https://github.com/jkrack/Harc/releases/latest")!
        let bridge = bridge
        Task { @MainActor in
            bridge?.availableUpdate = AvailableUpdate(version: version, url: url)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        let bridge = bridge
        Task { @MainActor in
            bridge?.availableUpdate = nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MeetingDetector.Delegate, UNUserNotificationCenterDelegate {
    private var session: RecordingSession?
    /// Frozen alongside `session` so changing the destination preference while
    /// a recording is live cannot publish that recording somewhere other than
    /// the destination that was validated when capture began.
    private var sessionCommitter: (any RecordingCommitter)?
    private let launcher = DaemonLauncher()
    let state = RecordingState()
    let prefs = HarcPreferences.shared

    // MARK: - Menu bar bridge
    let bridge: HarcAppBridge
    private let trayState = PostStopTrayState()
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?

    // MARK: - Dictation
    let dictationState = DictationState()
    lazy var dictationModeStore = DictationModeStore(prefs: prefs)
    lazy var dictationHistoryStore = DictationHistoryStore(prefs: prefs)
    private var dictationController: DictationController?
    private var dictationHUD: DictationHUDPanel?
    private var recordingIsland: RecordingIslandPanel?
    private let recordingIslandModel = RecordingIslandModel()
    private var quickCapturePanel: QuickCapturePanel?
    private var islandObservers: [AnyCancellable] = []
    private let dictationHUDPresentation = DictationHUDPresentationModel()
    /// Set by the idle pill's ✕ — keeps the pill hidden until the next
    /// dictation runs (not persisted; a fresh launch shows the pill again).
    private var pillHiddenUntilNextDictation = false
    private var dictationEscMonitor: DictationEscMonitor?
    private var dictationHistoryWindow: DictationHistoryWindowController?
    private var dictationKeepWarm: DictationKeepWarmController?
    /// Polls the daemon for honest speech-model readiness (fast until ready,
    /// slow heartbeat after). Owns `bridge.sttReady`/`sttReadinessText`.
    private var sttReadinessTask: Task<Void, Never>?
    /// Set once the model has been observed loaded on this Mac — later
    /// daemon idle-exits then read as "starts on demand", not "missing".
    private static let sttModelVerifiedKey = "harc.sttModelVerified"
    private var hudDismissTask: Task<Void, Never>?
    private var lastDictationPhase: DictationState.Phase = .idle
    /// Mode ids that already have per-mode hotkey handlers registered.
    /// KeyboardShortcuts has no per-name handler removal, so handlers are
    /// registered once per id and no-op when the mode no longer exists.
    private var registeredModeHotkeyIDs: Set<String> = []

    // MARK: - Media import
    let importState = MediaImportState()
    /// Serializes imports — one file converts/transcribes at a time so the
    /// daemon isn't juggling parallel chunk streams. Files picked/dropped
    /// while a batch runs are appended here and drained by the same task.
    private var importTask: Task<Void, Never>?
    private var pendingImports: [URL] = []

    override init() {
        bridge = HarcAppBridge(
            recordingState: state,
            trayState: trayState
        )
        super.init()
        bridge.onStartStop = { [weak self] in
            Task { await self?.toggleRecording() }
        }
        bridge.onDiscardRecording = { [weak self] in
            Task { await self?.discardRecording() }
        }
        bridge.onUndoDiscard = { [weak self] in
            self?.undoDiscard()
        }
        bridge.onOpenWindow = { [weak self] in
            self?.openLibrary()
        }
        bridge.onCopyLastTranscript = { [weak self] in
            self?.copyLastTranscriptToPasteboard()
        }
        bridge.onPasteIntoFrontmost = { [weak self] in
            self?.pasteLastTranscriptIntoFrontmost()
        }
        bridge.onOpenLastRecording = { [weak self] in
            Task { await self?.openLastRecordingFromTray() }
        }
        bridge.onClearPreRoll = { [weak self] in
            self?.clearPreRollBuffer()
        }
        bridge.onKeepRecording = { [weak self] in
            self?.autoStop.keepRecording()
        }
        bridge.onStopNow = { [weak self] in
            self?.autoStop.stopNow()
        }
        bridge.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        bridge.onOpenActivity = { [weak self] in
            self?.statusPopover?.performClose(nil)
            self?.openLibrary()
            NotificationCenter.default.post(name: .harcLibraryShowActivity, object: nil)
        }
        bridge.onRevealStopRecovery = {
            NSWorkspace.shared.activateFileViewerSelecting([RecordingDestination.cacheDirectory()])
        }
        bridge.onRetryStopRecovery = { [weak self] in
            Task { await self?.retryStopRecovery() }
        }
        bridge.onDismissStopRecovery = { [weak self] in
            self?.clearStopRecovery()
        }
        bridge.onRecoverRecoveryArtifact = { [weak self] id in
            Task { await self?.recoverRecoveryArtifact(id: id) }
        }
        bridge.onRevealRecoveryArtifact = { [weak self] id in
            self?.revealRecoveryArtifact(id: id)
        }
        bridge.onDiscardRecoveryArtifact = { [weak self] id in
            Task { await self?.discardRecoveryArtifact(id: id) }
        }
    }

    private func applyAppearance(_ pref: HarcPreferences.Appearance) {
        switch pref {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func copyLastTranscriptToPasteboard() {
        guard let text = trayState.lastTranscript, !text.isEmpty else { return }
        FrontmostAppPaster.copyOnly(text)
    }

    private func pasteLastTranscriptIntoFrontmost() {
        guard let text = trayState.lastTranscript, !text.isEmpty else { return }
        pastePromptString(text, shiftHeld: false)
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = PanelHostingController(
            rootView: StatusPopoverRoot(
                bridge: bridge,
                dictationState: dictationState,
                dictationModeStore: dictationModeStore,
                dictationHistoryStore: dictationHistoryStore,
                onStopDictation: { [weak self] in
                    Task { await self?.dictationController?.stopAndInsert() }
                },
                onCancelDictation: { [weak self] in
                    Task { await self?.dictationController?.cancel() }
                },
                onOpenDictationHistory: { [weak self] in
                    self?.statusPopover?.performClose(nil)
                    self?.openDictationHistoryWindow()
                }
            )
                .environmentObject(prefs)
        )
        // Let the SwiftUI content drive the popover's height. The size used to
        // be pinned at 320×260, which silently overrode the panel's own
        // `.frame(maxHeight: 480)`: rows were sliced in half at the bottom
        // edge with no scroll indicator, so a scrollable panel looked like a
        // broken one, and everything past the readiness list — including the
        // retroactive-record row — sat below the fold.
        hosting.sizingOptions = [.preferredContentSize]
        hosting.onCancel = { [weak self] in self?.statusPopover?.performClose(nil) }
        popover.contentViewController = hosting
        statusPopover = popover
        updateStatusIcon()
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickModeMenu()
            return
        }

        toggleStatusPopover(sender)
    }

    /// Right-click on the status item: quick mode switch + start dictation,
    /// without opening the full panel (mirrors SuperWhisper's mini-window
    /// context menu).
    private func showQuickModeMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        for mode in dictationModeStore.modes {
            let entry = NSMenuItem(
                title: mode.name,
                action: #selector(quickMenuSelectMode(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = mode.id
            entry.state = mode.id == dictationModeStore.activeMode.id ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let dictate = NSMenuItem(
            title: "Start Dictation",
            action: #selector(quickMenuStartDictation(_:)),
            keyEquivalent: ""
        )
        dictate.target = self
        menu.addItem(dictate)
        let history = NSMenuItem(
            title: "Dictation History…",
            action: #selector(quickMenuOpenHistory(_:)),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(quickMenuOpenSettings(_:)),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        // Assign-click-clear is the standard trick for a right-click-only
        // NSStatusItem menu alongside a left-click action.
        item.menu = menu
        item.button?.performClick(nil)
        DispatchQueue.main.async { [weak item] in item?.menu = nil }
    }

    @objc private func quickMenuSelectMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dictationModeStore.setActiveMode(id: id)
    }

    @objc private func quickMenuStartDictation(_ sender: NSMenuItem) {
        Task { await dictationController?.start() }
    }

    @objc private func quickMenuOpenHistory(_ sender: NSMenuItem) {
        openDictationHistoryWindow()
    }

    @objc private func quickMenuOpenSettings(_ sender: NSMenuItem) {
        bridge.onOpenSettings()
    }

    private func toggleStatusPopover(_ sender: Any?) {
        guard let button = statusItem?.button, let statusPopover else { return }
        if statusPopover.isShown {
            statusPopover.performClose(sender)
        } else {
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            statusPopover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let isRecording = bridge.iconState.isRecording
        let pasteFlash = bridge.iconState.pasteFlash
        button.image = menuBarHummingbirdImage()
        button.imagePosition = .imageOnly
        button.contentTintColor = statusIconTint(isRecording: isRecording, pasteFlash: pasteFlash)
        button.toolTip = statusIconToolTip(isRecording: isRecording)
    }

    private func statusIconToolTip(isRecording: Bool) -> String {
        switch dictationState.phase {
        case .listening: return "Harc is listening — dictation in progress."
        case .requestingMic, .loadingModel, .loadingTransformModel, .transcribing,
             .transforming, .inserting:
            return "Harc is processing your dictation."
        case .idle, .done, .error:
            return isRecording ? "Harc is recording. Click for controls." : "Harc. Click to record, right-click for modes."
        }
    }

    private func menuBarHummingbirdImage() -> NSImage {
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            return image
        }

        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Harc") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    private func statusIconTint(isRecording: Bool, pasteFlash: PasteFlash?) -> NSColor? {
        if let pasteFlash {
            switch pasteFlash {
            case .success: return .systemGreen
            case .skipped: return .systemYellow
            case .failure: return .systemRed
            }
        }
        // Dictation mirrors SuperWhisper's menu-bar state colors: red while
        // listening, blue while processing, a green beat on success.
        switch dictationState.phase {
        case .listening: return .systemRed
        case .requestingMic, .loadingModel, .loadingTransformModel: return .systemYellow
        case .transcribing, .transforming, .inserting: return .systemBlue
        case .done(let outcome): return outcome.kind == .inserted ? .systemGreen : .systemYellow
        case .error: return .systemOrange
        case .idle: break
        }
        return isRecording ? .systemRed : nil
    }

    private let autoStop = AutoStopController()
    private var autoStopPhaseObserver: AnyCancellable?
    private var autoStopConfigObserver: AnyCancellable?
    private var stoppedFlashTask: Task<Void, Never>?
    private let modelManager = ModelManager()
    lazy var modelStore = ModelManagerStore(manager: modelManager)
    private var summarizerService: SummarizerService?
    private var summarizationQueue: SummarizationQueue?
    private var summarizationQueueStore: SummarizationQueueStore?
    /// Second queue instance for session (multi-recording) summaries. Shares
    /// the recording queue's `BackgroundWorkCoordinator`, so the one resident
    /// model never runs two jobs at once.
    private var sessionSummarizationQueue: SummarizationQueue?
    private var recoveryQueue: RecoveryQueue?
    private var memoryObservation: SummarizerService.MemoryPressureObservation?
    private let postProcessingState = RecordingPostProcessingState()
    /// Retained so runIdentifySpeakers can call diarize() outside of a recording session.
    private var sttClient: HarcSTTClient?
    private var speakerReIDService: SpeakerReIDService?
    private var store: RecordingStore?
    /// Present only in Host role. It owns the canonical store above; no second
    /// RecordingStore is opened while this runtime is resident.
    private var hostRuntime: HarcResidentHostRuntimeV1?
    private var hostProcessingWorker: HarcHostProcessingWorker?
    private var hostWakeToken: NSObjectProtocol?
    private var hostTerminationInFlight = false
    /// Whole-library operations (re-transcribe, build search index). Created
    /// once the store exists; Settings observes it.
    private var maintenanceStore: LibraryMaintenanceStore?
    /// Always-on pre-roll ring, present only while the feature is enabled.
    private var preRollCapture: PreRollCapture?
    private var preRollTicker: Timer?
    private var recordingsVM: RecordingsViewModel?
    private var harcWindow: HarcWindowController?
    private var settingsWindow: NSWindowController?
    private var welcomeWindow: NSWindowController?
    /// Retained while the Welcome window is open so app activation can push a
    /// fresh permission read into it — the user grants in System Settings and
    /// comes back expecting the checkmarks to have moved.
    private var welcomeSetupModel: WelcomeSetupModel?
    /// Welcome-window-scoped subscriptions; cleared on close so the setup
    /// model can actually deallocate (see showWelcome).
    private var welcomeCancellables = Set<AnyCancellable>()
    private var previewTask: Task<Void, Never>?
    private var prefsObserver: AnyCancellable?
    private var modelPerformanceObserver: AnyCancellable?
    private var pendingSkipPaste = false
    /// Set when Stop arrives while startRecording is still awaiting daemon
    /// launch / engine spin-up; honored the moment the session is fully up.
    private var stopRequestedDuringStart = false
    /// Recovery imports delete their cache source after making a canonical
    /// copy. Keep one token per stop pipeline so a timed-out stop can coexist
    /// safely with a newer recording while its late finalization/publication
    /// still owns the old cache master.
    private var cacheRecoveryProtectionTokens: Set<UUID> = []
    /// Monotonic owner for the recovery card. A late completion may clear only
    /// the timeout card it created, never a newer recording's failure UI.
    private var stopRecoveryPresentationGeneration: UInt64 = 0
    /// Launch-time recovery is best effort. If capture wins the startup race,
    /// defer the scan until the protected capture/publication pipeline drains.
    private var bootstrapRecoveryScanDeferred = false
    private var uiTestRecordingStartedAt: Date?
    private var frontmostPoller: Timer?
    private var hasShownMicOnlyNotice = false

    private let meetingState = MeetingDetectionState()
    private let notificationPresenter = MeetingNotificationPresenter()
    private var detector: MeetingDetector?
    private var terminateToken: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    /// Sparkle. Held for the app's lifetime; nil under UI testing.
    private var updaterController: SPUStandardUpdaterController?
    private let updaterDelegate = HarcUpdaterDelegate()
    private var managedWindowCount = 0
    private var mainMenuInstalled = false

    /// Minimum transcript word count to actually call the summarizer.
    /// Below this, the prompt is too thin to constrain the model and
    /// it hallucinates plausible-but-fake meetings. Tuned conservatively;
    /// a real meeting will easily clear this in seconds.
    private static let minWordsToSummarize = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A UI-test run that was killed rather than terminated never got to
        // put the user's preferences back. Replay the stash on the next
        // ordinary launch so a crashed test doesn't leave auto-summarize and
        // meeting detection switched off for good.
        if !isUITesting, UITestPreferenceRestore.hasPendingRestore() {
            UITestPreferenceRestore.restore(prefs)
        }
        applyUITestConfigurationIfNeeded()
        installStatusItem()

        // A fresh install must be able to record immediately — create the
        // default destination folder if it's missing (never a custom one).
        prefs.ensureDefaultDestinationExists()

        Task { [weak self] in
            await self?.bootstrapStore()
        }

        // Pre-launch the daemon in the background so ⌘R doesn't have to wait for
        // model load. Failure is logged and retried lazily on next recording start.
        if !isUITesting {
            Task { [launcher] in
                do {
                    _ = try await launcher.ensureRunning()
                } catch {
                    FileHandle.standardError.write(Data(
                        "harc: background daemon launch failed: \(error.localizedDescription)\n".utf8
                    ))
                }
            }
            startSTTReadinessPolling()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            Task { await self?.toggleRecording() }
        }

        setupDictation()

        // Dictation clips are disposable — sweep orphans left by a crash
        // mid-dictation. Never routed into the recording recovery inbox.
        Task.detached(priority: .utility) {
            _ = DictationCacheCleaner.cleanOrphans()
        }

        notificationPresenter.registerCategory()
        UNUserNotificationCenter.current().delegate = self
        AutoStopNotification.registerCategory()
        setupMeetingDetector()
        registerTerminateWatchdog()
        registerHostWakeObserver()
        observeMeetingDetectionPref()
        observeMeetingStateForPulse()
        observePostProcessingState()
        applyAutoStopConfigFromPrefs()
        updateMenuBarReadiness()
        observeAutoStopPrefs()
        observeAutoStopPhase()
        setupRecordingIsland()
        registerQuickCaptureHotkey()
        autoStop.onAutoStop = { [weak self] reason in
            Task { @MainActor in
                await self?.stopRecording(autoStopReason: reason)
            }
        }

        // Seed install state from disk. Safe to call before any UI is shown;
        // the actor bootstrap is cheap (just reads a handful of dotfiles).
        Task { await modelManager.bootstrap() }

        // Apply persisted appearance pref to NSApp so AppKit-hosted windows
        // (HarcWindowController, etc.) follow Light/Dark/System the way SwiftUI
        // scenes already do via .preferredColorScheme.
        applyAppearance(prefs.appearance)
        prefs.$appearance
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] new in
                self?.applyAppearance(new)
            }
            .store(in: &cancellables)

        // Forward AutoStopController's rolling amplitude history to the bridge
        // so the MenuBarExtra panel re-renders on each tick.
        autoStop.$amplitudeHistory
            .receive(on: DispatchQueue.main)
            .assign(to: \.amplitudeHistory, on: bridge)
            .store(in: &cancellables)
        autoStop.$lastMicDb
            .receive(on: DispatchQueue.main)
            .assign(to: \.autoStopMicDb, on: bridge)
            .store(in: &cancellables)
        autoStop.$lastSystemDb
            .receive(on: DispatchQueue.main)
            .assign(to: \.autoStopSystemDb, on: bridge)
            .store(in: &cancellables)

        // Mirror RecordingState.isRecording to bridge.iconState so the
        // always-visible menu-bar label updates on start/stop without
        // observing the high-frequency amplitudeHistory feed.
        state.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.bridge.iconState.isRecording = isRecording
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        bridge.iconState.$pasteFlash
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        prefs.$destinationPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarReadiness() }
            .store(in: &cancellables)
        prefs.$activeSummarizerID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarReadiness() }
            .store(in: &cancellables)
        prefs.$autoSummarizeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarReadiness() }
            .store(in: &cancellables)
        prefs.$speakerReIDEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarReadiness() }
            .store(in: &cancellables)
        prefs.$postStopNotificationEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarReadiness() }
            .store(in: &cancellables)
        // Pre-roll holds the mic open, so it must follow the preference
        // immediately — a user switching it off expects the orange indicator
        // to go out, not to wait for the next launch.
        prefs.$preRollEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPreRollCapture() }
            .store(in: &cancellables)
        prefs.$preRollMinutes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPreRollCapture() }
            .store(in: &cancellables)
        // Release the mic the moment dictation wants it, and take it back when
        // dictation returns to idle.
        dictationState.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPreRollCapture() }
            .store(in: &cancellables)
        modelStore.$states
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarReadiness() }
            .store(in: &cancellables)

        if !isUITesting {
            syncPreRollCapture()
            startFrontmostPolling()
        }

        // Sparkle auto-updates. The updater delegate publishes discovered
        // updates onto the bridge for the panel/About rows; the pref is the
        // single user-facing switch for scheduled checks. System profiling
        // is off — checks send nothing about the user.
        if !isUITesting {
            updaterDelegate.bridge = bridge
            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: updaterDelegate,
                userDriverDelegate: nil
            )
            controller.updater.automaticallyChecksForUpdates = prefs.updateChecksEnabled
            prefs.$updateChecksEnabled
                .receive(on: DispatchQueue.main)
                .sink { [weak controller] enabled in
                    controller?.updater.automaticallyChecksForUpdates = enabled
                }
                .store(in: &cancellables)
            controller.startUpdater()
            updaterController = controller
            let check: () -> Void = { [weak controller] in
                NSApp.activate(ignoringOtherApps: true)
                controller?.checkForUpdates(nil)
            }
            bridge.onCheckForUpdates = check
            bridge.onInstallUpdate = check
        }

        observePermissionChanges()
        showWelcomeIfNeeded()
    }

    /// Permissions are granted in System Settings, in another process. The
    /// moment the user switches back to Harc is exactly when every cached
    /// grant we display is most likely to be wrong — and until this existed,
    /// nothing re-read them, so granting a permission appeared to do nothing
    /// and the app looked broken to a user who had just fixed it.
    private func observePermissionChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidBecomeActive()
            }
        }
    }

    private func handleDidBecomeActive() {
        updateMenuBarReadiness()
        welcomeSetupModel?.refreshPermissions()
        let snapshot = PermissionSnapshot.current()
        // A repair that has since been satisfied shouldn't keep nagging.
        if snapshot.coreGrantsIntact {
            UserDefaults.standard.removeObject(forKey: RecordingPermissionRepair.pendingRepairKey)
        }
        CoreGrantHistory.noteGranted(snapshot)
    }

    private func registerHostWakeObserver() {
        hostWakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let runtime = self?.hostRuntime else { return }
                await runtime.handleSystemWake()
            }
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let runtime = hostRuntime else { return .terminateNow }
        guard !hostTerminationInFlight else { return .terminateLater }
        hostTerminationInFlight = true
        Task { [weak sender, weak self] in
            await self?.hostProcessingWorker?.waitUntilIdle()
            await runtime.shutdown()
            await MainActor.run {
                self?.hostRuntime = nil
                sender?.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let token = terminateToken {
            SystemWorkspace.shared.removeObserver(token)
            terminateToken = nil
        }
        if let token = hostWakeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            hostWakeToken = nil
        }
        detector?.stop()
        frontmostPoller?.invalidate()
        frontmostPoller = nil
        restoreUITestPreferencesIfNeeded()
    }

    /// Disabled. Harc is menu-bar-resident — the Library, TranscriptEditor,
    /// and Settings windows all open on demand. Restoration would auto-pop a
    /// stale window (commonly Settings, since it's the most-recently-opened
    /// scene macOS knows about) every time the app launches.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openLibrary() }
        return true
    }

    private func trackManagedWindow(_ window: NSWindow?) {
        guard let window else { return }
        managedWindowCount += 1
        refreshActivationPolicy()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.managedWindowCount = max(0, self.managedWindowCount - 1)
                self.refreshActivationPolicy()
            }
        }
    }

    /// Bring a managed window to the user without fighting macOS 26's
    /// cooperative activation. Active app: normal key-and-front + activate.
    /// Background (e.g. the post-stop Land path): activation may be DENIED —
    /// and makeKeyAndOrderFront from a denied app never draws the window at
    /// all. orderFrontRegardless is the sanctioned background move: the
    /// window appears above the user's app, focus and menu bar stay where
    /// the user is, and the first click on the window activates Harc
    /// normally (policy is already .regular by then, so the menu follows).
    private func orderManagedWindowFront(_ window: NSWindow) {
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSRunningApplication.current.activate(
                options: [.activateAllWindows, .activateIgnoringOtherApps]
            )
            window.makeKeyAndOrderFront(nil)
            // Activation is asynchronous and may still be denied; regardless,
            // the window itself must appear.
            window.orderFrontRegardless()
        }
    }

    private func refreshActivationPolicy() {
        let desired: NSApplication.ActivationPolicy = managedWindowCount > 0 ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        if desired == .regular {
            installMainMenuIfNeeded()
            NSApp.setActivationPolicy(.regular)
            if NSApp.isActive {
                // accessory→regular while already the active app: the system
                // keeps the previous app's menu bar until our activation state
                // visibly changes. Bounce activation — deactivate now,
                // re-activate on a later runloop turn — so the menu bar picks
                // us up.
                NSApp.deactivate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?
                        .makeKeyAndOrderFront(nil)
                }
            } else {
                // Promoted from the background (the post-stop Land path).
                // Never call deactivate() here: deactivating an app that
                // isn't active marks it user-deactivated, and macOS 26's
                // cooperative activation then DENIES the activate() that
                // follows — the library window ends up floating over the
                // previous app with that app's menu bar still installed.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?
                    .makeKeyAndOrderFront(nil)
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// The app runs as an accessory (LSUIElement) with only a MenuBarExtra-style
    /// UI, so SwiftUI never builds a main menu. When a real window promotes us
    /// to `.regular`, the menu bar would be empty without one — including the
    /// Edit menu, whose absence breaks ⌘C/⌘V in the transcript editor.
    private func installMainMenuIfNeeded() {
        guard !mainMenuInstalled else { return }
        mainMenuInstalled = true

        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Harc",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(harcShowSettingsWindow(_:)),
                                           keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Harc",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Harc",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appItem = main.addItem(withTitle: "Harc", action: nil, keyEquivalent: "")
        main.setSubmenu(appMenu, for: appItem)

        let fileMenu = NSMenu(title: "File")
        // Import moved here from the Library toolbar — a rare action's
        // proper home. The empty state carries the discoverable button.
        let importItem = fileMenu.addItem(withTitle: "Import Audio or Video…",
                                          action: #selector(presentImportOpenPanel(_:)),
                                          keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        let fileItem = main.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        main.setSubmenu(fileMenu, for: fileItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        main.setSubmenu(editMenu, for: editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        let windowItem = main.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
        main.setSubmenu(windowMenu, for: windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func stopRecordingFromMenu() {
        Task { await stopRecording(autoStopReason: nil) }
    }

    /// When the last hotkey-triggered start began. Toggle events inside the
    /// debounce window after it are dropped, not treated as stops.
    private var lastStartAttemptAt: Date?

    private func toggleRecording() async {
        guard !bridge.recordingStopInFlight else { return }
        if state.isActiveOrPreparing {
            // Debounce, then "never mind". Carbon global hotkeys deliver key
            // auto-repeats while the app is inactive, and a cold daemon start
            // leaves a ~2s feedback-free window that invites a second press —
            // both used to read as "stop the recording I just asked for":
            // the island appeared and the recording died in the same breath,
            // with Land opening the Library over the two-second corpse. A
            // toggle this soon after a start is the same press echoing, not a
            // change of heart; a deliberate stop comes later than 1.5s.
            if let at = lastStartAttemptAt, Date().timeIntervalSince(at) < 1.5 {
                return
            }
            await stopRecording(autoStopReason: nil)
        } else {
            lastStartAttemptAt = Date()
            await startRecording()
        }
    }

    // MARK: - Dictation setup

    private func setupDictation() {
        let controller = DictationController(
            state: dictationState,
            recordingState: state,
            prefs: prefs,
            recorderFactory: { MicDictationRecorder() },
            transcribe: { path in
                try await HarcSTTClient().dictate(audioPath: path)
            },
            paster: SystemDictationPaster(restoreClipboard: { [weak self] in
                self?.prefs.restoreClipboardAfterInsert ?? true
            }),
            activeMode: { [weak self] in
                self?.dictationModeStore.activeMode ?? DictationMode.builtIns[0]
            },
            transform: { [weak self] text, mode, contextBlock in
                guard let self else { throw DictationTransformError.unavailable }
                return try await self.transformDictation(
                    text: text, mode: mode, contextBlock: contextBlock
                )
            },
            ruleMode: { [weak self] bundleID in
                self?.dictationModeStore.mode(activatedBy: bundleID)
            },
            transformColdModelName: { [weak self] mode in
                await self?.dictationColdModelName(for: mode)
            },
            preloadTransformModel: { [weak self] mode in
                await self?.preloadDictationModel(for: mode)
            },
            ensureDaemonReady: { [launcher] onColdStart in
                // Cold daemon → let the UI show "Loading speech model…".
                var warm = false
                if FileManager.default.fileExists(atPath: HarcSTTClient.defaultSocketPath) {
                    warm = (try? await HarcSTTClient().status()) != nil
                }
                if !warm { onColdStart() }
                _ = try await launcher.ensureRunning()
            }
        )
        controller.onBlockedByRecording = { [weak self] in
            self?.bridge.reportPaste(.skipped, message: "Stop the recording to dictate")
        }
        controller.onDelivered = { [weak self] entry in
            self?.dictationHistoryStore.record(entry)
            self?.dictationKeepWarm?.noteActivity()
        }
        controller.onNeedsAccessibility = { [weak self] in
            self?.presentAccessibilityPrompt()
        }
        self.dictationController = controller

        // Settings "Test" button for mode instructions.
        bridge.testDictationTransform = { [weak self] mode, sample in
            guard let self else { throw DictationTransformError.unavailable }
            return try await self.transformDictation(text: sample, mode: mode)
        }

        // Keep the speech model resident so the first dictation after a
        // break isn't slowed by the daemon's 30-min idle shutdown. Pings
        // only an already-running daemon — never launches one.
        let keepWarm = DictationKeepWarmController(
            activeWindow: prefs.keepDictationWarmWindow.activeWindow,
            isDaemonRunning: {
                guard FileManager.default.fileExists(atPath: HarcSTTClient.defaultSocketPath) else {
                    return false
                }
                return (try? await HarcSTTClient().status()) != nil
            },
            ping: { _ = try? await HarcSTTClient().status() }
        )
        keepWarm.setEnabled(prefs.keepDictationWarm)
        prefs.$keepDictationWarm
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak keepWarm] enabled in keepWarm?.setEnabled(enabled) }
            .store(in: &cancellables)
        prefs.$keepDictationWarmWindow
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak keepWarm] window in keepWarm?.setActiveWindow(window.activeWindow) }
            .store(in: &cancellables)
        self.dictationKeepWarm = keepWarm

        // Per-mode hotkeys: dictate straight into a mode as a one-shot
        // override. Re-synced whenever the mode list changes.
        syncModeHotkeys(for: dictationModeStore.modes)
        dictationModeStore.$modes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] modes in self?.syncModeHotkeys(for: modes) }
            .store(in: &cancellables)

        self.dictationHUD = DictationHUDPanel(
            state: dictationState,
            modeStore: dictationModeStore,
            presentationModel: dictationHUDPresentation,
            onStop: { [weak self] in Task { await self?.dictationController?.stopAndInsert() } },
            onCancel: { [weak self] in Task { await self?.dictationController?.cancel() } },
            onDismiss: { [weak self] in self?.dictationController?.dismissAfterglow() },
            onFixAccessibility: { [weak self] in
                self?.dictationController?.dismissAfterglow()
                self?.presentAccessibilityPrompt()
            },
            onStartDictation: { [weak self] in Task { await self?.dictationController?.start() } },
            onHidePill: { [weak self] in
                self?.pillHiddenUntilNextDictation = true
                self?.applyDictationHUDPresentation()
            },
            onConfirmDeepLink: { [weak self] in
                self?.dictationController?.confirmPendingDeepLink()
            },
            onDismissDeepLink: { [weak self] in
                self?.dictationController?.dismissPendingDeepLink()
            }
        )

        // The idle pill follows the pref live, and tints/disables while a
        // meeting recording owns the mic.
        prefs.$persistentDictationHUD
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDictationHUDPresentation() }
            .store(in: &cancellables)
        state.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDictationHUDPresentation() }
            .store(in: &cancellables)
        dictationState.$pendingDeepLink
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDictationHUDPresentation() }
            .store(in: &cancellables)

        // Esc cancels a listening dictation — a consuming tap, so the key
        // never leaks into the frontmost app (which would dismiss dialogs).
        let escMonitor = DictationEscMonitor(onCancel: { [weak self] in
            Task { await self?.dictationController?.cancel() }
        })
        self.dictationEscMonitor = escMonitor

        dictationState.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.playDictationSound(from: self.lastDictationPhase, to: phase)
                self.lastDictationPhase = phase
                self.updateDictationHUD(for: phase)
                self.updateStatusIcon()
                if case .listening = phase {
                    self.dictationEscMonitor?.setListening(true)
                } else {
                    self.dictationEscMonitor?.setListening(false)
                }
            }
            .store(in: &cancellables)

        bridge.onStartDictation = { [weak self] in
            Task { await self?.dictationController?.start() }
        }

        // KeyboardShortcuts fires handlers on the main thread; assumeIsolated
        // keeps keyDown/keyUp strictly ordered (a Task hop could reorder them
        // and break push-to-talk).
        KeyboardShortcuts.onKeyDown(for: .pushToTalkDictation) { [weak self] in
            MainActor.assumeIsolated {
                self?.dictationController?.handleHotkey(.keyDown)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalkDictation) { [weak self] in
            MainActor.assumeIsolated {
                self?.dictationController?.handleHotkey(.keyUp)
            }
        }
    }

    /// Register hotkey handlers for new modes and clear recorded shortcuts
    /// for deleted ones. Handlers resolve the mode at fire time, so edits
    /// apply immediately and stale handlers no-op.
    private func syncModeHotkeys(for modes: [DictationMode]) {
        let currentIDs = Set(modes.map(\.id))
        for id in currentIDs.subtracting(registeredModeHotkeyIDs) {
            registeredModeHotkeyIDs.insert(id)
            let name = KeyboardShortcuts.Name.dictationMode(id)
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let mode = self.dictationModeStore.modes.first(where: { $0.id == id })
                    else { return }
                    self.dictationController?.handleModeHotkey(.keyDown, mode: mode)
                }
            }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let mode = self.dictationModeStore.modes.first(where: { $0.id == id })
                    else { return }
                    self.dictationController?.handleModeHotkey(.keyUp, mode: mode)
                }
            }
        }
        // A deleted mode's recorded shortcut shouldn't linger in UserDefaults
        // (its handler no-ops, but the key stays globally reserved).
        for id in registeredModeHotkeyIDs.subtracting(currentIDs) {
            KeyboardShortcuts.reset(.dictationMode(id))
        }
    }

    /// Run a dictation-mode LLM transform on the shared summarizer service.
    /// Throws when the service or model isn't available — the controller
    /// falls back to inserting the raw transcript.
    private func transformDictation(
        text: String,
        mode: DictationMode,
        contextBlock: String? = nil
    ) async throws -> String {
        guard let service = summarizerService else {
            throw DictationTransformError.unavailable
        }
        let modelID = mode.modelID ?? prefs.activeSummarizerID
        guard let descriptor = await modelManager.descriptor(for: modelID) else {
            throw DictationTransformError.unknownModel(modelID)
        }
        // Never block dictation on a download — but tell the controller
        // WHY the transform can't run so its fallback notice points the
        // user at Settings → Models instead of a generic "unavailable".
        let directory: URL
        do {
            directory = try await modelManager.requireInstalled(modelID)
        } catch {
            throw DictationTransformFailure.modelNotInstalled(descriptor.tierDisplayName)
        }
        return try await service.transform(
            text: text,
            instruction: mode.instruction,
            systemPrompt: mode.systemPrompt,
            contextBlock: contextBlock,
            modelID: modelID,
            modelDirectory: directory
        )
    }

    private enum DictationTransformError: Error {
        case unavailable
        case unknownModel(String)
    }

    /// The display name of the mode's transform model when it still needs a
    /// load — nil when warm or unresolvable (failures surface at transform).
    private func dictationColdModelName(for mode: DictationMode) async -> String? {
        guard let service = summarizerService else { return nil }
        let modelID = mode.modelID ?? prefs.activeSummarizerID
        guard let descriptor = await modelManager.descriptor(for: modelID),
              (try? await modelManager.requireInstalled(modelID)) != nil
        else { return nil }
        guard await service.loadedModelID != modelID else { return nil }
        return descriptor.displayName
    }

    /// Preload the mode's transform model so the HUD's loading phase covers
    /// the load, not the generation. Errors are deliberately swallowed — the
    /// transform call reports them via the raw-text fallback.
    private func preloadDictationModel(for mode: DictationMode) async {
        guard let service = summarizerService else { return }
        let modelID = mode.modelID ?? prefs.activeSummarizerID
        guard let directory = try? await modelManager.requireInstalled(modelID) else { return }
        try? await service.preload(modelID: modelID, modelDirectory: directory)
    }

    /// Show (or re-show) the dictation history window.
    func openDictationHistoryWindow() {
        if dictationHistoryWindow == nil {
            dictationHistoryWindow = DictationHistoryWindowController(
                historyStore: dictationHistoryStore,
                modeStore: dictationModeStore,
                reprocess: { [weak self] text, mode in
                    guard let self else { throw DictationTransformError.unavailable }
                    return try await self.transformDictation(text: text, mode: mode)
                },
                onClose: { [weak self] in self?.dictationHistoryWindow = nil }
            )
        }
        dictationHistoryWindow?.showWindow(nil)
        dictationHistoryWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Deep links (harc://)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = DictationDeepLink.parse(url) else {
                FileHandle.standardError.write(Data(
                    "harc: ignoring unrecognized deep link \(url.absoluteString)\n".utf8
                ))
                continue
            }
            switch link {
            case .dictate(let modeRef):
                // Confirm-first: the mic never opens on a bare URL. The
                // controller surfaces a Start/Cancel prompt on the HUD
                // (unless Harc itself is frontmost), refuses to insert into
                // the requesting app, and treats a second link as cancel.
                let mode = modeRef.flatMap {
                    DictationDeepLink.resolveMode($0, in: dictationModeStore.modes)
                }
                dictationController?.requestDeepLinkDictation(oneShot: mode)
            case .switchMode(let modeRef):
                if let mode = DictationDeepLink.resolveMode(modeRef, in: dictationModeStore.modes) {
                    dictationModeStore.setActiveMode(id: mode.id)
                    // A silent mode swap could reroute future dictations —
                    // make it visible with a brief HUD flash.
                    if !dictationState.isActive {
                        dictationState.setPhase(.done(DictationDeliveryOutcome(
                            kind: .notice,
                            message: "Active mode switched to \(mode.name) via link"
                        )))
                    }
                }
            case .openHistory:
                openDictationHistoryWindow()
            }
        }
    }

    private func updateDictationHUD(for phase: DictationState.Phase) {
        hudDismissTask?.cancel()
        hudDismissTask = nil
        switch phase {
        case .idle:
            break
        case .requestingMic, .loadingModel, .loadingTransformModel, .listening,
             .transcribing, .transforming, .inserting:
            // Real dictation activity un-hides a temporarily hidden pill.
            pillHiddenUntilNextDictation = false
        case .done:
            pillHiddenUntilNextDictation = false
            // Success beat: linger long enough to read the outcome, then fade.
            hudDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard let self, !Task.isCancelled else { return }
                if case .done = self.dictationState.phase {
                    self.dictationState.setPhase(.idle)
                }
            }
        case .error:
            pillHiddenUntilNextDictation = false
            // Errors stay readable — 6s, or dismissed from the HUD's ✕.
            hudDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled else { return }
                if case .error = self.dictationState.phase {
                    self.dictationState.setPhase(.idle)
                }
            }
        }
        applyDictationHUDPresentation(for: phase)
    }

    /// Recompute what the dictation panel should render (hidden / idle pill
    /// / live HUD) from the pure policy and hand it to the panel. Called on
    /// phase changes, pref flips, recording start/stop, and pill hide.
    private func applyDictationHUDPresentation(for phase: DictationState.Phase? = nil) {
        let presentation = DictationHUDPresentation.from(
            phase: phase ?? dictationState.phase,
            persistent: prefs.persistentDictationHUD,
            temporarilyHidden: pillHiddenUntilNextDictation,
            isRecording: state.isRecording,
            pendingDeepLink: dictationState.pendingDeepLink != nil
        )
        dictationHUD?.apply(presentation)
    }

    /// Subtle audio cues around dictation (pref-gated): start, stop, and a
    /// success tone when text lands.
    private func playDictationSound(from oldPhase: DictationState.Phase, to newPhase: DictationState.Phase) {
        guard prefs.dictationSoundsEnabled else { return }
        func play(_ name: String, volume: Float = 0.35) {
            guard let sound = NSSound(named: name) else { return }
            sound.volume = volume
            sound.play()
        }
        switch (oldPhase, newPhase) {
        case (_, .listening):
            play("Pop")
        case (.listening, .transcribing), (.listening, .loadingModel):
            play("Tink")
        case (_, .done(let outcome)) where outcome.kind == .inserted:
            play("Glass", volume: 0.25)
        default:
            break
        }
    }

    private func applyAutoStopConfigFromPrefs() {
        autoStop.config = .from(
            silenceEnabled: prefs.autoStopEnabled,
            silenceThresholdMinutes: prefs.silenceThresholdMinutes,
            hardCapEnabled: prefs.hardCapEnabled,
            hardCapMinutes: prefs.hardCapMinutes
        )
        bridge.autoStopWarningSeconds = autoStop.config.warningSeconds
        bridge.autoStopThresholdMinutes = prefs.silenceThresholdMinutes
        updateMenuBarReadiness()
    }

    /// Poll the daemon for real speech-model state — fast (2s) until the
    /// model is confirmed loaded, then a slow heartbeat (60s) to catch idle
    /// exits and failures. Replaces the old hardcoded "Local STT ready".
    private func startSTTReadinessPolling() {
        sttReadinessTask?.cancel()
        sttReadinessTask = Task { [weak self] in
            var verified = UserDefaults.standard.bool(forKey: Self.sttModelVerifiedKey)
                || STTModelDiskProbe.modelPresent()
            while !Task.isCancelled {
                let socket = FileManager.default.fileExists(atPath: HarcSTTClient.defaultSocketPath)
                var status: DaemonStatus?
                if socket {
                    status = try? await HarcSTTClient().status()
                }
                let readiness = STTReadiness.from(.init(
                    socketExists: socket,
                    statusModelLoaded: status?.modelLoaded,
                    modelVerifiedBefore: verified,
                    modelState: status?.modelState,
                    downloadProgress: status?.downloadProgress,
                    errorMessage: status?.errorMessage
                ))
                if readiness == .ready, !verified {
                    verified = true
                    UserDefaults.standard.set(true, forKey: Self.sttModelVerifiedKey)
                }
                guard let self, !Task.isCancelled else { return }
                self.bridge.sttReady = readiness.isReady
                self.bridge.sttReadinessText = readiness.displayText
                self.bridge.sttDownloadProgress = readiness.progress
                try? await Task.sleep(for: .seconds(readiness.isReady ? 60 : 2))
            }
        }
    }

    private func updateMenuBarReadiness() {
        bridge.destinationReady = prefs.destinationFolderExists()
        bridge.destinationPath = prefs.destinationPath

        let activeSummarizer = ModelCatalog.descriptor(for: prefs.activeSummarizerID)
        let summarizerName = activeSummarizer?.tierDisplayName ?? activeSummarizer?.displayName ?? "Summarizer"
        let summarizerInstalled = modelStore.state(of: prefs.activeSummarizerID).isInstalled
        bridge.summarizerReady = summarizerInstalled && prefs.autoSummarizeEnabled
        bridge.summarizerInstalled = summarizerInstalled
        if !prefs.autoSummarizeEnabled {
            bridge.summarizerReadinessText = "\(summarizerName) · auto-summary off"
        } else if summarizerInstalled {
            bridge.summarizerReadinessText = "\(summarizerName) · auto-summary on"
        } else {
            bridge.summarizerReadinessText = "\(summarizerName) not installed"
        }

        bridge.speakerIDReady = prefs.speakerReIDEnabled
        bridge.speakerIDReadinessText = prefs.speakerReIDEnabled ? "Speaker ID enabled" : "Speaker ID disabled"

        bridge.notificationsReady = prefs.postStopNotificationEnabled
        bridge.notificationsReadinessText = prefs.postStopNotificationEnabled ? "Post-stop notifications enabled" : "Post-stop notifications off"

        bridge.accessibilityReady = AXIsProcessTrusted()
        bridge.accessibilityReadinessText = bridge.accessibilityReady ? "Paste permission granted" : "Paste needs Accessibility permission"

        updateCaptureReadiness()
    }

    /// Report whether capture can actually happen, not just whether it is
    /// permitted.
    ///
    /// The mic row was a constant — "Mic + system audio", never a warning —
    /// unless a live recording fell back mid-session. On a Mac with no input
    /// device (a Mac mini has no built-in microphone) that read "Capture
    /// ready" right up until recording failed. Permission granted and no
    /// hardware present are different answers and the panel has to tell them
    /// apart. Skipped while recording so this can't stomp the mic-only
    /// fallback notice that path sets.
    private func updateCaptureReadiness() {
        guard !state.isRecording else { return }

        guard RecordingPermissionService.microphone.isGranted else {
            bridge.captureReadinessText = "Microphone permission needed"
            bridge.captureReadinessWarning = true
            return
        }
        guard AudioInputAvailability.hasInputDevice else {
            bridge.captureReadinessText = "No microphone connected"
            bridge.captureReadinessWarning = true
            return
        }
        bridge.captureReadinessText = "Mic + system audio"
        bridge.captureReadinessWarning = false
    }

    private func observeAutoStopPrefs() {
        // Republish on any change to the four auto-stop prefs.
        let combined = Publishers.CombineLatest4(
            prefs.$autoStopEnabled,
            prefs.$silenceThresholdMinutes,
            prefs.$hardCapEnabled,
            prefs.$hardCapMinutes
        )
        autoStopConfigObserver = combined
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAutoStopConfigFromPrefs()
            }
    }

    private func observeAutoStopPhase() {
        autoStopPhaseObserver = autoStop.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.bridge.autoStopPhase = phase
            }
    }

    /// Polls `NSWorkspace.frontmostApplication` once per second and forwards
    /// the display name to the bridge for the "Paste → [App]" button label.
    private func startFrontmostPolling() {
        frontmostPoller?.invalidate()
        frontmostPoller = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(updateFrontmostAppStatus),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func updateFrontmostAppStatus() {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName
        let denied = PasteDenyList.isDenied(app?.bundleIdentifier, in: prefs.pasteDenyListBundleIDs)
        if bridge.frontmostAppName != name {
            bridge.frontmostAppName = name
        }
        if bridge.frontmostPasteDenied != denied {
            bridge.frontmostPasteDenied = denied
        }
    }

    /// Title chosen in Quick Capture before the recording exists. Applied to
    /// the row at ingest; `displayTitle` prefers it over the async suggested
    /// title, so there is no race with the post-stop suggester.
    private var pendingCaptureTitle: String?
    /// True while a Discard's 10-second undo window is open: the stop result
    /// is ingested normally (the audio is held one beat longer than the user
    /// thinks), but paste/tray/summary side effects are suppressed and the
    /// countdown decides whether the row survives.
    private var pendingDiscard = false
    private var discardCountdownTask: Task<Void, Never>?

    private func startRecording(title: String? = nil, includePreRoll: Bool = true) async {
        // `isPreparing` closes the re-entrancy window: this method suspends
        // for seconds (daemon launch, engine spin-up) before `session` is
        // assigned, and a second trigger (hotkey double-press, meeting
        // detection, deep link) entering during that window used to start a
        // second session that overwrote the first — leaving an orphaned live
        // mic with no owner.
        guard session == nil, !state.isPreparing else { return }

        // Mutual exclusion: dictation and meeting capture share the mic and the
        // STT daemon; only one may hold the mic at a time.
        guard !dictationState.isActive else {
            bridge.reportPaste(.skipped, message: "Finish dictation before recording")
            return
        }

        // Guard: destination must resolve to an existing directory before
        // spinning up the session. Saves the user from a silent failure
        // when the destination has been deleted, renamed, or sits on an
        // unmounted external drive.
        guard prefs.destinationFolderExists() else {
            presentDestinationMissingAlert()
            return
        }

        state.markPreparing()
        stopRequestedDuringStart = false
        pendingCaptureTitle = title?.harcTrimmedNonEmpty
        pendingDiscard = false

        meetingState.clearAll()
        autoStop.resetPostStop()
        bridge.autoStopLastDurationText = nil
        stoppedFlashTask?.cancel()
        stoppedFlashTask = nil
        let startedAt = Date()

        if shouldUseUITestRecordingLoop {
            await startUITestRecording(at: startedAt)
            return
        }

        do {
            _ = try await launcher.ensureRunning()
            let client = HarcSTTClient()
            self.sttClient = client
            let transcriber = ChunkedTranscriber(
                client: client,
                diarizer: prefs.diarize ? client : nil,
                vadEnabled: prefs.vadEnabled,
                chunkDurationSeconds: prefs.chunkDurationSeconds,
                vocabulary: prefs.vocabulary
            )
            // System audio is a per-install choice now (Quick Capture exposes
            // it): when off, a disabled source declines permission and the
            // session's tested mic-only fallback path takes over — minus the
            // "needs permission" nag, which would be wrong for a choice.
            let systemAudioOn = prefs.systemAudioEnabled
            let systemSource: any SystemAudioCaptureSource = systemAudioOn
                ? SystemAudioCapture()
                : DisabledSystemAudioCapture()
            // Freeze publication at capture start. In particular, a custom
            // destination can disappear or the preference can change during a
            // long meeting; this recording still belongs to the destination
            // whose readiness check allowed it to start.
            let committer = StandaloneRecordingCommitter(
                destination: RecordingDestination(baseDirectory: prefs.destinationURL)
            )
            let session = RecordingSession(
                mic: MicCapture(),
                systemAudio: systemSource,
                transcriber: transcriber,
                onWriteFailure: { [weak self] message in
                    Task { @MainActor in await self?.handleRecordingWriteFailure(message) }
                }
            )
            self.session = session
            self.sessionCommitter = committer

            // Pipe transcript updates into the UI.
            self.previewTask?.cancel()
            self.previewTask = Task { [weak self, transcriber] in
                for await update in await transcriber.updates {
                    await MainActor.run {
                        self?.state.appendPreview(update.joinedTextSoFar)
                        self?.bridge.markActiveTranscriptUpdate()
                    }
                }
            }

            // Hand the pre-roll ring over, if it has been listening. This both
            // stops the idle mic tap (the session is about to take the mic) and
            // clears the ring, so the same seconds can never be prepended twice.
            // Quick Capture can decline the banked audio; the ring is cleared
            // either way so those seconds can't resurface on a later start.
            let preRoll: [Int16]
            if includePreRoll {
                preRoll = await preRollCapture?.promote() ?? []
            } else {
                await preRollCapture?.clear()
                preRoll = []
            }
            preRollCapture = nil
            try await session.start(at: startedAt, preRoll: preRoll)
            state.markStarted(at: startedAt)
            bridge.activeCaptureTitle = pendingCaptureTitle
            bridge.setActiveCaptureStatus(ActiveCaptureStatus(
                sourceState: systemAudioOn ? .micAndSystemAudio : .micOnly,
                cachePath: RecordingDestination.cacheDirectory().path,
                destinationPath: prefs.destinationPath,
                startedAt: startedAt
            ))
            autoStop.begin(
                session: session,
                startedAt: startedAt
            )
            // If system audio fell back to mic-only, surface a one-time
            // notice so the user knows other meeting participants will be
            // missing from the transcript. Gated to once per app session
            // (no nagging on every recording).
            if systemAudioOn, await session.systemAudioFellBack {
                bridge.captureReadinessText = "Mic only; system audio needs permission"
                bridge.captureReadinessWarning = true
                bridge.updateActiveCaptureSource(.micOnly)
                if !hasShownMicOnlyNotice {
                    hasShownMicOnlyNotice = true
                    presentMicOnlyFallbackNotification()
                }
            }
            // A Stop that arrived mid-start was queued, not dropped: honor
            // it now that the session is fully up and can stop cleanly.
            if stopRequestedDuringStart {
                stopRequestedDuringStart = false
                await stopRecording(autoStopReason: nil)
            }
        } catch {
            // session.start may have brought up mic / system-audio captures
            // BEFORE the throw. Abort (not stop) so a partial start doesn't
            // leave the mic running with no controller — and doesn't move a
            // near-empty junk WAV into the user's destination folder, where
            // launch-time ingest would resurrect it as a phantom row.
            stopRequestedDuringStart = false
            await self.session?.abort()
            self.session = nil
            self.sessionCommitter = nil
            presentError(error)
            resetUI()
        }
    }

    private func stopRecording(autoStopReason: AutoStopController.StopReason?) async {
        guard !bridge.recordingStopInFlight else { return }
        // Stop pressed while the start is still in flight: stopping now
        // would interleave with `session.start()` at its suspension points
        // and close the writer under the live session — the UI would show
        // a recording that persists nothing. Queue the intent instead;
        // startRecording honors it the moment the session is fully up.
        if state.isPreparing, !state.isRecording {
            stopRequestedDuringStart = true
            return
        }
        bridge.beginRecordingStop()
        defer {
            bridge.endRecordingStop()
            // Every exit path, not just the happy one. stopRecording returns
            // early on a stop timeout, a thrown error, and a nil result; if
            // pre-roll only resumed on success, one failed stop would silently
            // switch off a feature the user had enabled until the next launch.
            syncPreRollCapture()
        }

        // Sample modifier state NOW, before any await — by the time session.stop()
        // resolves (seconds later), the user may have released Shift. Also consume
        // the ⌥-click escape-hatch flag unconditionally so it can't leak into a
        // subsequent stop if session.stop() throws.
        let shiftHeldAtStopTrigger = NSEvent.modifierFlags.contains(.shift)
        let skipFromOptionClick = pendingSkipPaste
        pendingSkipPaste = false
        guard let session else {
            if shouldUseUITestRecordingLoop, state.isRecording {
                await stopUITestRecording(startedAt: uiTestRecordingStartedAt, autoStopReason: autoStopReason)
            }
            return
        }
        let committer: any RecordingCommitter = sessionCommitter ?? MissingRecordingCommitter()
        // Everything below is scoped to this exact recording. The timeout path
        // deliberately frees `self.session` so a new capture can begin while
        // this one finishes late; retaining shared title/discard/destination
        // state would let the two recordings corrupt one another's outcome.
        let captureTitle = pendingCaptureTitle
        let discarding = pendingDiscard
        self.sessionCommitter = nil
        let recoveryProtection = beginCacheRecoveryProtection()
        var protectionTransferredToLateTask = false
        defer {
            if !protectionTransferredToLateTask {
                endCacheRecoveryProtection(recoveryProtection)
            }
        }
        // Dead-man cap on how long stopRecording waits for capture finalization
        // and standalone publication. Publication used to live inside
        // `session.stop()`; keeping the whole stop -> commit pipeline inside
        // the race preserves that bound now that the responsibilities are
        // explicitly separated.
        // Finalize legitimately takes minutes on a long meeting (retry drain
        // is budgeted at 180 s, the full-WAV diarize IPC timeout at 300 s),
        // so the cap must sit above their sum — a 30 s cap used to route
        // perfectly healthy hour-long recordings into "Recovery needed" and
        // discard the finished result. The cap only trips on a genuine hang;
        // IPC-level hangs are already bounded by HarcSTTClient's kernel
        // receive timeouts, and mic + system-audio captures are stopped
        // synchronously at the top of session.stop(), so the macOS mic
        // indicator turns off immediately either way.
        //
        // Structure note: this is a first-resume-wins continuation, NOT a
        // racing throwing task group — a task group awaits all children
        // before returning, so a group can never actually unblock the UI
        // while stop is stuck (and `Task.value` awaits are not
        // cancellation-responsive either). On timeout the stop task keeps
        // running unstructured; if it completes later, its published result is
        // ingested then — never discarded.
        let publicationTask = Task {
            let captured = try await session.stop()
            return try await committer.commit(captured)
        }
        enum StopOutcome {
            case finished(RecordingCommitOutcome)
            case failed(Error)
            case timedOut
        }
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<StopOutcome, Never>) in
            let resumed = ResumeOnceGate()
            Task {
                do {
                    let r = try await publicationTask.value
                    if resumed.claim() { cont.resume(returning: .finished(r)) }
                } catch {
                    if resumed.claim() { cont.resume(returning: .failed(error)) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.stopFinalizeCapSeconds))
                if resumed.claim() { cont.resume(returning: .timedOut) }
            }
        }

        let commitOutcome: RecordingCommitOutcome
        switch outcome {
        case .finished(let published):
            commitOutcome = published
        case .timedOut:
            // Finalize/publication didn't return within the cap — a genuine
            // hang, not an ordinary long finalize. Free the UI; the pipeline
            // keeps running in the background and retains exclusive recovery
            // ownership of the cache master. If it eventually finishes,
            // ingest the result then: audio that survived is never discarded.
            FileHandle.standardError.write(Data(
                "harc: stop publication exceeded \(Self.stopFinalizeCapSeconds)s; freeing UI, work continues in background\n".utf8
            ))
            self.session = nil
            state.markIdle()
            bridge.setActiveCaptureStatus(nil)
            // Capture sources stop synchronously at the front of the composed
            // task. Retire this generation's controller before allowing a new
            // recording; its eventual late ingest must never end the newer
            // generation's silence/hard-cap monitoring.
            autoStop.end(autoStopReason: autoStopReason)
            let timeoutRecoveryGeneration = presentStopTimeoutRecovery()
            resetUI()
            let lateShiftHeld = shiftHeldAtStopTrigger || skipFromOptionClick
            protectionTransferredToLateTask = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.endCacheRecoveryProtection(recoveryProtection) }
                do {
                    let outcome = try await publicationTask.value
                    self.clearStopRecovery(ifGeneration: timeoutRecoveryGeneration)
                    await self.handleRecordingCommitOutcome(
                        outcome,
                        captureTitle: captureTitle,
                        discarding: discarding,
                        shiftHeld: lateShiftHeld,
                        autoStopReason: autoStopReason,
                        late: true
                    )
                } catch {
                    self.presentCaptureRecovery(
                        title: "Recording completion failed",
                        message: "Harc could not finish or publish the recording, but its cache master was preserved.",
                        error: error
                    )
                }
            }
            return
        case .failed(let error):
            self.session = nil
            autoStop.end(autoStopReason: autoStopReason)
            presentError(error)
            presentCaptureRecovery(
                title: "Recording completion failed",
                message: "Harc could not finish or publish the recording, but any completed cache audio was preserved.",
                error: error
            )
            resetUI()
            return
        }
        await handleRecordingCommitOutcome(
            commitOutcome,
            captureTitle: captureTitle,
            discarding: discarding,
            shiftHeld: shiftHeldAtStopTrigger || skipFromOptionClick,
            autoStopReason: autoStopReason,
            late: false
        )
        previewTask?.cancel()
        previewTask = nil
        resetUI()
    }

    /// Mode-neutral handoff after a committer has accepted a capture.
    /// Standalone publication deliberately retains the mature local ingest
    /// pipeline. Deferred publication has transferred durable ownership to an
    /// outbox and must not masquerade as a row in this Mac's canonical library.
    private func handleRecordingCommitOutcome(
        _ outcome: RecordingCommitOutcome,
        captureTitle: String?,
        discarding: Bool,
        shiftHeld: Bool,
        autoStopReason: AutoStopController.StopReason?,
        late: Bool
    ) async {
        switch outcome {
        case .standalonePublished(let capture, let result):
            await ingestStopResult(
                result,
                capturedStartedAt: capture.startedAt,
                capturedEndedAt: capture.endedAt,
                captureTitle: captureTitle,
                discarding: discarding,
                shiftHeld: shiftHeld,
                autoStopReason: autoStopReason,
                late: late
            )
        case .acceptedForDeferredPublication:
            // The accepting committer owns all durable outbox/UI state. In
            // particular, do not persist a local canonical row, run local
            // projections, paste, summarize, or show a "saved locally" tray.
            if !late {
                state.markDeferredStop()
                autoStop.end(autoStopReason: autoStopReason)
            }
        }
    }

    /// How long stopRecording waits before declaring finalize/publication
    /// hung. Must
    /// exceed the worst *healthy* finalize: tail-chunk transcribe (≤60 s) +
    /// finalize retry drain (≤180 s) + full-WAV diarize (≤300 s IPC timeout).
    private static let stopFinalizeCapSeconds = 600

    /// Everything that happens to a successfully stopped recording: state,
    /// library row, title/tags, embeddings, auto-paste, tray, auto-summary.
    /// `late: true` means the result arrived after the stop cap already
    /// reset the UI — persist and surface it, but don't touch live recording
    /// state and never synthesize a paste into whatever app is now frontmost.
    private func ingestStopResult(
        _ result: RecordingResult,
        capturedStartedAt: Date,
        capturedEndedAt: Date,
        captureTitle: String?,
        discarding: Bool,
        shiftHeld: Bool,
        autoStopReason: AutoStopController.StopReason?,
        late: Bool
    ) async {
        if !late {
            state.markStopped(wavURL: result.wavURL, txtURL: result.txtURL, jsonURL: result.jsonURL)
        }
            let transcriptText = result.txtURL.flatMap { Self.transcriptBody(ofSidecarAt: $0) }
            let rec = Recording(
                wavPath: result.wavURL.path,
                txtPath: result.txtURL?.path,
                jsonPath: result.jsonURL?.path,
                startedAt: capturedStartedAt,
                endedAt: capturedEndedAt,
                title: captureTitle,
                transcriptText: transcriptText
            )
            var savedID: Int64? = nil
            savedID = await persistStoppedRecording(rec)
            if let transcriptText, let store = self.store {
                Task.detached { [store] in
                    let entities = TitleSuggester.extractEntities(from: transcriptText)
                    let suggestion = TitleSuggester.suggest(from: transcriptText)
                    guard suggestion != nil || !entities.isEmpty else { return }
                    guard let persisted = try? await store.fetchByWavPath(result.wavURL.path),
                          let id = persisted.id else { return }
                    if let suggestion { try? await store.updateSuggestedTitle(id: id, title: suggestion) }
                    if !entities.isEmpty { try? await store.updateTags(id: id, tags: entities) }
                }
            }

            // Persist speaker embeddings produced by the post-stop diarize pass
            // (already completed inside RecordingSession.stop / ChunkedTranscriber.finalize).
            // We defer begin() until after persistStoppedRecording so we have the
            // recording row ID. The status indicator appears a beat after stop — fine
            // for the post-stop UX window.
            if let id = savedID, let store = self.store {
                postProcessingState.begin(recordingID: id)
                let embeddings = result.speakerEmbeddings
                let diarizeErr = result.diarizationError
                Task.detached { [store, postProcessingState = self.postProcessingState] in
                    if !embeddings.isEmpty {
                        let dbRows: [RecordingStore.SpeakerEmbeddingRow] = embeddings.map {
                            RecordingStore.SpeakerEmbeddingRow(
                                recordingID: id,
                                speakerIndex: $0.speakerIndex,
                                embedding: EmbeddingBlob.encode($0.vector),
                                segmentCount: $0.segmentCount,
                                totalMs: $0.totalMs,
                                embedderKind: EmbedderKind.wespeakerV2
                            )
                        }
                        do {
                            try await store.upsertSpeakerEmbeddings(recordingID: id, rows: dbRows)
                            await postProcessingState.succeed(recordingID: id, speakerCount: embeddings.count)
                            // Best-effort, non-blocking: surface speaker match suggestions.
                            Task.detached { [store] in
                                let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
                                try? await engine.suggestForRecording(recordingID: id)
                            }
                        } catch {
                            await postProcessingState.fail(recordingID: id, message: error.localizedDescription)
                        }
                    } else if let err = diarizeErr {
                        await postProcessingState.fail(recordingID: id, message: err)
                    } else {
                        // Diarize returned no speakers (e.g. diarize was disabled or
                        // the recording had no speech). Collapse immediately.
                        await postProcessingState.succeed(recordingID: id, speakerCount: 0)
                    }
                }
            }
            // A pending Discard still ingests (the audio is held for the undo
            // window), but none of the outward side effects fire — no paste
            // into the frontmost app, no tray, no summary spend.
            if discarding {
                if late {
                    scheduleLateDiscard(recordingID: savedID, wavPath: rec.wavPath)
                } else {
                    let duration = rec.endedAt.map {
                        formatAutoStopDuration($0.timeIntervalSince(rec.startedAt))
                    } ?? "recording"
                    startDiscardCountdown(
                        recordingID: savedID,
                        wavPath: rec.wavPath,
                        durationText: duration
                    )
                    autoStop.end(autoStopReason: autoStopReason)
                }
                return
            }
            if !late {
                runAutoPaste(for: rec, shiftHeld: shiftHeld)
            }
            // Show the post-stop outcome for every durable save. Copy/Paste
            // actions remain available only when transcript text exists.
            do {
                let trayBlob = ExportService.promptString(
                    for: rec,
                    includeSummary: prefs.includeSummaryInPrompt
                )
                bridge.trayState.show(
                    title: rec.displayTitle,
                    transcript: (transcriptText?.isEmpty == false) ? trayBlob : "",
                    recordingID: savedID,
                    wavPath: rec.wavPath,
                    outcome: .savedSafely(title: rec.displayTitle, wavPath: rec.wavPath)
                )
            }
            // Step 3 · Land: the library comes forward with the new
            // recording. Only for user-triggered stops of a real recording —
            // auto-stop fires when the user walked away, and yanking a window
            // over whatever they're doing then would be hostile.
            if !late, autoStopReason == nil {
                openLibrary()
            }
            await enqueueAutoSummaryAfterStop(recordingID: savedID)
            if !late {
                bridge.autoStopLastDurationText = rec.endedAt.map { formatAutoStopDuration($0.timeIntervalSince(rec.startedAt)) }
                autoStop.end(autoStopReason: autoStopReason)
                if let autoStopReason, prefs.postStopNotificationEnabled {
                    AutoStopNotification.post(
                        reason: autoStopReason,
                        duration: rec.endedAt.map { $0.timeIntervalSince(rec.startedAt) },
                        thresholdMinutes: prefs.silenceThresholdMinutes,
                        previewText: transcriptText
                    )
                }
            }
    }

    private func resetUI() {
        session = nil
        sessionCommitter = nil
        pendingCaptureTitle = nil
        pendingDiscard = false
        state.markIdle()
        bridge.setActiveCaptureStatus(nil)
        bridge.activeCaptureTitle = nil
        resumeDeferredBootstrapRecoveryScanIfPossible()
    }

    // MARK: - Recording island

    /// The island exists exactly while a recording (or its save/discard
    /// tail) does. Visibility follows three published signals; size follows
    /// the pill's hover state.
    private func setupRecordingIsland() {
        guard !isUITesting else { return }
        let island = RecordingIslandPanel(
            rootView: RecordingIslandView(
                bridge: bridge,
                recordingState: state,
                model: recordingIslandModel
            ),
            isLibraryFrontmost: { [weak self] in
                self?.harcWindow?.window?.isKeyWindow ?? false
            }
        )
        recordingIsland = island

        state.$isRecording
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncIslandVisibility() }
            .store(in: &islandObservers)
        state.$isPreparing
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncIslandVisibility() }
            .store(in: &islandObservers)
        bridge.$recordingStopInFlight
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncIslandVisibility() }
            .store(in: &islandObservers)
        bridge.$discardCountdown
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncIslandVisibility() }
            .store(in: &islandObservers)
        recordingIslandModel.$expanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recordingIsland?.refit() }
            .store(in: &islandObservers)
    }

    private func syncIslandVisibility() {
        // Deferred AND re-read: the Combine sinks fire on willSet, when the
        // published properties still hold their old values — a verdict
        // computed in the sink is one transition stale (the island hid on
        // start and showed on stop). Deciding inside the deferred Task reads
        // settled state, and also lets SwiftUI swap the pill content before
        // the panel measures its fitting size.
        Task { @MainActor [weak self] in
            guard let self, let island = self.recordingIsland else { return }
            let shouldShow = self.state.isRecording
                || self.state.isPreparing
                || self.bridge.recordingStopInFlight
                || self.bridge.discardCountdown != nil
            FileHandle.standardError.write(Data(
                "harc-island: sync shouldShow=\(shouldShow) rec=\(self.state.isRecording) prep=\(self.state.isPreparing) stop=\(self.bridge.recordingStopInFlight)\n".utf8
            ))
            if shouldShow {
                island.show()
                island.refit()
            } else {
                self.recordingIslandModel.expanded = false
                island.hide()
            }
        }
    }

    // MARK: - Quick Capture

    private func registerQuickCaptureHotkey() {
        KeyboardShortcuts.onKeyDown(for: .quickCapture) { [weak self] in
            Task { @MainActor in self?.toggleQuickCapture() }
        }
    }

    private func toggleQuickCapture() {
        // Quick Capture is about starting; while a recording runs the island
        // owns the screen. The instant path (⌃⌥R) still stops as always.
        guard !state.isActiveOrPreparing else { return }
        if quickCapturePanel?.isVisible == true {
            dismissQuickCapture()
            return
        }
        let banked = bridge.preRollStatus.flatMap { status -> String? in
            guard case .listening(let seconds) = status, seconds >= 1 else { return nil }
            return MenuBarPanelView.formatBanked(seconds)
        }
        let panel = QuickCapturePanel(
            rootView: QuickCaptureView(
                prefs: prefs,
                bankedText: banked,
                onStart: { [weak self] title, includePreRoll in
                    guard let self else { return }
                    self.dismissQuickCapture()
                    Task { await self.startRecording(title: title, includePreRoll: includePreRoll) }
                },
                onCancel: { [weak self] in self?.dismissQuickCapture() }
            )
            .environmentObject(prefs),
            onDismiss: { [weak self] in self?.dismissQuickCapture() }
        )
        quickCapturePanel = panel
        panel.show()
    }

    private func dismissQuickCapture() {
        quickCapturePanel?.hide()
        quickCapturePanel = nil
    }

    // MARK: - Discard with undo

    /// Discard the running recording. Not an abort: the stop path runs and
    /// the audio is ingested (held one beat longer than the user thinks),
    /// but outward side effects are suppressed and a 10-second undo window
    /// on the island decides whether the row survives. Undo costs nothing;
    /// expiry routes through the tested deletion service.
    private func discardRecording() async {
        guard state.isActiveOrPreparing, !pendingDiscard else { return }
        pendingDiscard = true
        await stopRecording(autoStopReason: nil)
    }

    private func startDiscardCountdown(recordingID: Int64?, wavPath: String, durationText: String) {
        discardCountdownTask?.cancel()
        bridge.discardCountdown = DiscardCountdown(durationText: durationText, secondsRemaining: 10)
        discardCountdownTask = Task { [weak self] in
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if remaining > 0 {
                    self.bridge.discardCountdown?.secondsRemaining = remaining
                } else {
                    self.bridge.discardCountdown = nil
                    await self.finalizeDiscard(recordingID: recordingID, wavPath: wavPath)
                }
            }
        }
    }

    /// A result that arrives after the stop timeout belongs to an older capture
    /// generation. Honor its pending discard without replacing the visible
    /// undo countdown (or cancellation task) of a newer recording.
    private func scheduleLateDiscard(recordingID: Int64?, wavPath: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            await self.finalizeDiscard(recordingID: recordingID, wavPath: wavPath)
        }
    }

    private func undoDiscard() {
        discardCountdownTask?.cancel()
        discardCountdownTask = nil
        guard bridge.discardCountdown != nil else { return }
        bridge.discardCountdown = nil
        // The row already exists with side effects suppressed — surviving is
        // just not deleting. Summaries catch up via the launch scan.
    }

    private func finalizeDiscard(recordingID: Int64?, wavPath: String) async {
        guard let store else { return }
        let rec: Recording?
        if let recordingID {
            rec = try? await store.fetch(id: recordingID)
        } else {
            rec = try? await store.fetchByWavPath(wavPath)
        }
        guard let rec else { return }
        try? await RecordingDeletionService(store: store).delete(recording: rec)
    }

    /// First live-audio write failure (disk full, cache volume vanished).
    /// Stop immediately — every further minute would be silently dropped —
    /// then say what happened over the stop tray's "Saved safely", because
    /// only the audio captured *before* the failure was saved.
    private func handleRecordingWriteFailure(_ message: String) async {
        guard state.isActiveOrPreparing else { return }
        FileHandle.standardError.write(Data(
            "harc: stopping recording after write failure: \(message)\n".utf8
        ))
        let recoveryGenerationBeforeStop = stopRecoveryPresentationGeneration
        await stopRecording(autoStopReason: nil)
        // A finalize/publication failure already surfaced the truthful
        // Recovery-needed outcome. Do not overwrite it with "saved" merely
        // because this stop originated from a live write failure.
        guard recoveryGenerationBeforeStop == stopRecoveryPresentationGeneration else { return }
        bridge.trayState.showOutcome(
            title: "Recording stopped early",
            outcome: StopOutcome(
                kind: .savedWithWarnings,
                title: "Recording stopped early",
                detail: "Harc couldn't keep writing audio (\(message)). Audio captured before the failure was saved. Check free disk space."
            )
        )
    }

    @discardableResult
    private func beginCacheRecoveryProtection() -> UUID {
        let token = UUID()
        cacheRecoveryProtectionTokens.insert(token)
        return token
    }

    private func endCacheRecoveryProtection(_ token: UUID) {
        cacheRecoveryProtectionTokens.remove(token)
        resumeDeferredBootstrapRecoveryScanIfPossible()
    }

    private var isCacheRecoveryProtected: Bool {
        state.isActiveOrPreparing || !cacheRecoveryProtectionTokens.isEmpty
    }

    @discardableResult
    private func showStopRecovery(_ info: StopRecoveryInfo) -> UInt64 {
        stopRecoveryPresentationGeneration &+= 1
        bridge.showStopRecovery(info)
        return stopRecoveryPresentationGeneration
    }

    private func clearStopRecovery(ifGeneration expectedGeneration: UInt64? = nil) {
        if let expectedGeneration,
           expectedGeneration != stopRecoveryPresentationGeneration {
            return
        }
        // Clearing is itself a new generation so a second late task retaining
        // the old value cannot clear a card presented afterward.
        stopRecoveryPresentationGeneration &+= 1
        bridge.clearStopRecovery()
    }

    private func presentRecoveryBusy() {
        // A timeout already owns a more useful recovery card and generation.
        // Replacing it merely because the user pressed Retry would prevent the
        // eventual late success from clearing its own card.
        guard cacheRecoveryProtectionTokens.isEmpty else { return }
        let captureIsLive = state.isActiveOrPreparing
        showStopRecovery(StopRecoveryInfo(
            title: captureIsLive ? "Recording in progress" : "Finalization still running",
            message: captureIsLive
                ? "Recovery scans the cache folder, and the current recording lives there until it finishes. Stop the recording, then try again."
                : "Harc is still finalizing or publishing a recording from the cache. Wait for it to finish before starting recovery.",
            cacheDirectoryPath: RecordingDestination.cacheDirectory().path
        ))
    }

    private func presentCaptureRecovery(title: String, message: String, error: Error) {
        let detail = "\(message) \(error.localizedDescription)"
        FileHandle.standardError.write(Data(
            "harc: \(title.lowercased()): \(error.localizedDescription)\n".utf8
        ))
        bridge.trayState.showOutcome(
            title: "Recovery needed",
            outcome: .recoveryNeeded(detail: detail)
        )
        showStopRecovery(StopRecoveryInfo(
            title: title,
            message: detail,
            cacheDirectoryPath: RecordingDestination.cacheDirectory().path
        ))
    }

    private func resumeDeferredBootstrapRecoveryScanIfPossible() {
        guard bootstrapRecoveryScanDeferred,
              !isCacheRecoveryProtected,
              let recoveryQueue else { return }
        bootstrapRecoveryScanDeferred = false
        Task { @MainActor [weak self, recoveryQueue] in
            guard let self else { return }
            // Capture may have restarted between scheduling and execution.
            guard !self.isCacheRecoveryProtected else {
                self.bootstrapRecoveryScanDeferred = true
                return
            }
            try? await recoveryQueue.scanCache(
                cacheDirectory: RecordingDestination.cacheDirectory(),
                destinationDirectory: self.prefs.destinationURL
            )
            await self.refreshRecoveryArtifacts()
        }
    }

    @discardableResult
    private func presentStopTimeoutRecovery() -> UInt64 {
        let cacheDirectory = RecordingDestination.cacheDirectory()
        bridge.trayState.showOutcome(
            title: "Recovery needed",
            outcome: .recoveryNeeded(detail: "Audio capture stopped, but finishing or publishing timed out. The cache master remains protected while Harc keeps trying.")
        )
        return showStopRecovery(StopRecoveryInfo(
            title: "Recording completion is still running",
            message: "Audio capture stopped, but Harc timed out while finishing or publishing it. The cache master remains protected until that work exits.",
            cacheDirectoryPath: cacheDirectory.path
        ))
    }

    private func retryStopRecovery() async {
        guard let store else {
            openSettings()
            return
        }

        // Never scan the cache while a recording is live or starting: the
        // in-progress rolling WAV has no DB row yet, so the scan would
        // classify it as an interrupted recording — and recovery *deletes
        // the source WAV* after copying, killing the live session's file
        // out from under the writer.
        guard !isCacheRecoveryProtected else {
            presentRecoveryBusy()
            return
        }

        let cacheDirectory = RecordingDestination.cacheDirectory()
        showStopRecovery(StopRecoveryInfo(
            title: "Retrying recovery",
            message: "Checking cached recording files and importing anything complete enough to recover.",
            cacheDirectoryPath: cacheDirectory.path,
            isRecovering: true
        ))

        do {
            let queue = recoveryQueue ?? RecoveryQueue(fileURL: RecoveryQueue.defaultURL(), store: store)
            recoveryQueue = queue
            try await queue.scanCache(cacheDirectory: cacheDirectory, destinationDirectory: prefs.destinationURL)
            // A recording may have entered stop/finalize while the scan actor
            // was suspended. Scanning only queues metadata; never cross into
            // the destructive recover step once a cache owner is protected.
            guard !isCacheRecoveryProtected else {
                presentRecoveryBusy()
                await refreshRecoveryArtifacts()
                return
            }
            let pending = try await queue.fetchAll().filter { artifact in
                artifact.status == .pending || artifact.status == .failed || artifact.status == .skipped
            }
            var recoveredCount = 0
            for artifact in pending {
                let recovered = try await queue.recover(id: artifact.id)
                if recovered.status == .recovered {
                    recoveredCount += 1
                }
            }
            await refreshRecoveryArtifacts()
            let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
            _ = try? await ingestor.ingestAll()
            if recoveredCount > 0 {
                showStopRecovery(StopRecoveryInfo(
                    title: "Recovered \(recoveredCount) recording\(recoveredCount == 1 ? "" : "s")",
                    message: "Recovered audio was moved into your recordings folder and added to the Library.",
                    cacheDirectoryPath: cacheDirectory.path
                ))
                openLibrary()
            } else {
                showStopRecovery(StopRecoveryInfo(
                    title: "No recoverable files yet",
                    message: "Finalization may still be running. You can try again, reveal the cache, or restart Harc to retry recovery automatically.",
                    cacheDirectoryPath: cacheDirectory.path
                ))
            }
        } catch {
            showStopRecovery(StopRecoveryInfo(
                title: "Recovery failed",
                message: error.localizedDescription,
                cacheDirectoryPath: cacheDirectory.path
            ))
        }
    }

    private func recoverRecoveryArtifact(id: String) async {
        guard !isCacheRecoveryProtected else {
            presentRecoveryBusy()
            return
        }
        guard let queue = recoveryQueue else { return }
        _ = try? await queue.recover(id: id)
        await refreshRecoveryArtifacts()
        openLibrary()
    }

    private func discardRecoveryArtifact(id: String) async {
        guard let queue = recoveryQueue else { return }
        _ = try? await queue.discard(id: id)
        await refreshRecoveryArtifacts()
    }

    private func revealRecoveryArtifact(id: String) {
        guard let artifact = bridge.recoveryArtifacts.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([artifact.sourceURL])
    }

    private func refreshRecoveryArtifacts() async {
        guard let recoveryQueue else { return }
        let artifacts = (try? await recoveryQueue.fetchAll()) ?? []
        bridge.setRecoveryArtifacts(artifacts)
    }

    // MARK: - Meeting detection

    private func setupMeetingDetector() {
        guard prefs.meetingDetectionEnabled else { return }
        guard detector == nil else { return }
        let d = MeetingDetector(
            workspace: SystemWorkspace.shared,
            isGloballyEnabled: { [weak self] in self?.prefs.meetingDetectionEnabled ?? false },
            isAppEnabled: { [weak self] app in self?.prefs.meetingAppEnabled[app.id] ?? true },
            isRecordingInProgress: { [weak self] in self?.state.isActiveOrPreparing ?? false }
        )
        d.delegate = self
        d.start()
        detector = d
    }

    private func tearDownMeetingDetector() {
        detector?.stop()
        detector = nil
        meetingState.clearAll()
        for app in MeetingCatalog.builtIn {
            notificationPresenter.withdraw(bundleID: app.bundleID)
            for alias in app.aliasBundleIDs { notificationPresenter.withdraw(bundleID: alias) }
        }
    }

    private func registerTerminateWatchdog() {
        terminateToken = SystemWorkspace.shared.addDidTerminateObserver { [weak self] bundleID in
            Task { @MainActor in
                self?.meetingState.clear(bundleID: bundleID)
                self?.notificationPresenter.withdraw(bundleID: bundleID)
            }
        }
    }

    private func observeMeetingDetectionPref() {
        prefs.$meetingDetectionEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.setupMeetingDetector() } else { self.tearDownMeetingDetector() }
            }
            .store(in: &cancellables)
    }

    private func observeMeetingStateForPulse() {
        meetingState.$pendingBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { _ in
                // Pulse state is reflected by the SwiftUI MenuBarExtra label.
            }
            .store(in: &cancellables)
    }

    /// Observes post-processing state for side-effects (future: could drive
    /// a badge or notification). The SwiftUI MenuBarExtra label drives the
    /// visual indicator now.
    private func observePostProcessingState() {
        postProcessingState.$current
            .receive(on: DispatchQueue.main)
            .sink { _ in
                // Post-processing state is reflected by the SwiftUI MenuBarExtra label.
            }
            .store(in: &cancellables)
    }

    /// Builds a `SuggestionsProvider` closure scoped to this recording —
    /// returns the top matches for a given speaker index, or an empty array
    /// when the re-ID feature is off or no embedding was stored.
    private func reIDSuggestionsProvider(
        for recording: Recording
    ) -> SpeakerNameEditor.SuggestionsProvider? {
        guard prefs.speakerReIDEnabled,
              let service = speakerReIDService,
              let store = store,
              let recordingID = recording.id else {
            return nil
        }
        return { speakerIndex in
            // Read embeddingDim inside the async closure so the actor hop is valid.
            let embeddingDim = await service.embeddingDim
            guard let row = try? await store.speakerEmbedding(
                recordingID: recordingID,
                speakerIndex: speakerIndex
            ) else { return [] }
            guard let query = EmbeddingBlob.decode(row.embedding, expectedDim: embeddingDim) else {
                return []
            }
            return (try? await service.suggestions(
                for: query,
                excludingRecording: recordingID
            )) ?? []
        }
    }

    private func openDetail(for recording: Recording) {
        // Detail is shown inline in HarcWindowRootView; opening the library window
        // is sufficient until HarcWindowRootView gains a selection API.
        _ = recording
        openLibrary()
    }

    private func openLastRecordingFromTray() async {
        guard let store else {
            openLibrary()
            return
        }

        if let id = trayState.lastRecordingID,
           let recording = try? await store.fetch(id: id) {
            openDetail(for: recording)
            return
        }

        if let wavPath = trayState.lastWavPath,
           let recording = try? await store.fetchByWavPath(wavPath) {
            openDetail(for: recording)
            return
        }

        openLibrary()
    }


    /// Called by the "Identify speakers" / "Retry" buttons in the inspector panel
    /// and the panel post-stop tray. Runs a fresh full-WAV diarize pass against
    /// the recording's on-disk WAV, persists embeddings, and updates postProcessingState.
    func runIdentifySpeakers(recordingID: Int64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let store = self.store else {
                postProcessingState.fail(recordingID: recordingID, message: "Recording database is not available")
                return
            }
            guard let recording = try? await store.fetch(id: recordingID) else {
                postProcessingState.fail(recordingID: recordingID, message: "Recording not found")
                return
            }
            // Ensure the daemon is running before making an IPC call.
            _ = try? await launcher.ensureRunning()
            let client = self.sttClient ?? HarcSTTClient()
            self.sttClient = client
            postProcessingState.begin(recordingID: recordingID)
            do {
                let result = try await client.diarize(audioPath: recording.wavPath)
                let dbRows: [RecordingStore.SpeakerEmbeddingRow] = result.speakers.map {
                    RecordingStore.SpeakerEmbeddingRow(
                        recordingID: recordingID,
                        speakerIndex: $0.speakerIndex,
                        embedding: EmbeddingBlob.encode($0.vector),
                        segmentCount: $0.segmentCount,
                        totalMs: $0.totalMs,
                        embedderKind: EmbedderKind.wespeakerV2
                    )
                }
                try await store.upsertSpeakerEmbeddings(recordingID: recordingID, rows: dbRows)
                postProcessingState.succeed(recordingID: recordingID, speakerCount: result.speakers.count)
                // Best-effort, non-blocking: surface speaker match suggestions.
                Task.detached { [store] in
                    let engine = SpeakerSuggestionEngine(store: store, embedderKind: EmbedderKind.wespeakerV2)
                    try? await engine.suggestForRecording(recordingID: recordingID)
                }
            } catch {
                postProcessingState.fail(recordingID: recordingID, message: error.localizedDescription)
            }
        }
    }

    private func deleteRecording(recording: Recording) {
        guard let vm = recordingsVM else { return }
        Task { @MainActor [weak self] in
            do {
                try await vm.delete(recording: recording)
            } catch {
                self?.presentDeleteFailure(recording: recording, error: error)
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording error"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func presentDeleteFailure(recording: Recording, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not delete recording"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reveal File")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
        }
    }

    private func presentLibraryUnavailable(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Library is not ready"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Media import

    /// Import audio/video files: convert → transcribe (diarized) → library.
    /// Files process sequentially; a live recording or dictation blocks the
    /// whole batch (they'd compete for the STT daemon and confuse readiness).
    /// The transcript body from a sidecar, without the OKF wrapper.
    ///
    /// The sidecar used to be a plain `.txt` of the transcript, so both ingest
    /// paths read it whole and stored it. Since `.md` became the canonical
    /// artifact that same read stores an entire OKF document — YAML
    /// frontmatter, `## Summary`, `## Action Items` and all — into
    /// `transcript_text`. The detail pane then rendered `type: Meeting
    /// Transcript` and `resource: ./…wav` as if they were speech, search
    /// indexed the frontmatter, and the row stopped being the source the
    /// document is projected from and became a copy of it.
    ///
    /// Falls back to the raw contents so a pre-OKF `.txt` still ingests.
    static func transcriptBody(ofSidecarAt url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return OKFMarkdown.extractTranscript(from: raw) ?? raw
    }

    /// File › Import…: the app-level entry to media import, replacing the
    /// Library toolbar button. Opens the Library first so progress and the
    /// resulting row have somewhere to land.
    @objc private func presentImportOpenPanel(_ sender: Any?) {
        openLibrary()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImportService.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Choose audio or video files to transcribe"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importMediaFiles(panel.urls)
        }
    }

    func importMediaFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !state.isActiveOrPreparing, !dictationState.isActive else {
            // Don't clobber a running import's banner with the rejection.
            if importState.current == nil {
                importState.fail(message: "Finish recording or dictation before importing files.")
            } else {
                NSSound.beep()
            }
            return
        }
        guard prefs.destinationFolderExists() else {
            presentDestinationMissingAlert()
            return
        }

        // New files join the queue; a running batch picks them up.
        pendingImports.append(contentsOf: urls)
        guard importTask == nil else { return }

        importTask = Task { [weak self] in
            defer { self?.importTask = nil }
            while let next = self?.dequeueImport() {
                await self?.importOneMediaFile(next.url, queuedAfter: next.remaining)
            }
            self?.importState.allDone()
        }
    }

    private func dequeueImport() -> (url: URL, remaining: Int)? {
        guard !pendingImports.isEmpty else { return nil }
        let url = pendingImports.removeFirst()
        return (url, pendingImports.count)
    }

    /// Cancel the in-flight import batch: the current file stops at its next
    /// cancellation point (partial artifacts cleaned up), queued files drop.
    func cancelImport() {
        pendingImports.removeAll()
        importTask?.cancel()
        importState.cancelAll()
    }

    private func importOneMediaFile(_ source: URL, queuedAfter: Int) async {
        importState.begin(filename: source.lastPathComponent, queued: queuedAfter)
        do {
            _ = try await launcher.ensureRunning()
            let client = HarcSTTClient()
            let service = MediaImportService(
                client: client,
                diarizer: prefs.diarize ? client : nil,
                destination: RecordingDestination(baseDirectory: prefs.destinationURL)
            )
            let importState = self.importState
            let result = try await service.importFile(
                source: source,
                options: MediaImportService.Options(
                    diarize: prefs.diarize,
                    vadEnabled: prefs.vadEnabled,
                    chunkDurationSeconds: prefs.chunkDurationSeconds,
                    vocabulary: prefs.vocabulary
                ),
                progress: { progress in
                    Task { @MainActor in
                        importState.update(
                            phaseText: progress.phase.rawValue,
                            fraction: progress.fraction
                        )
                    }
                }
            )

            // Same ingest shape as stopRecording: library row keyed by the
            // final WAV path; title = the original filename.
            let rec = result.recording
            let transcriptText = rec.txtURL.flatMap { Self.transcriptBody(ofSidecarAt: $0) }
            let startedAt = rec.wavURL.startedAtFromHarcPath() ?? Date()
            var row = Recording(
                wavPath: rec.wavURL.path,
                txtPath: rec.txtURL?.path,
                jsonPath: rec.jsonURL?.path,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(result.durationSeconds),
                transcriptText: transcriptText
            )
            row.title = result.originalTitle
            let savedID = await persistStoppedRecording(row)

            // Same post-ingest extras a live recording gets.
            if let id = savedID, let store = self.store, !rec.speakerEmbeddings.isEmpty {
                let embeddings = rec.speakerEmbeddings
                Task.detached { [store] in
                    let dbRows: [RecordingStore.SpeakerEmbeddingRow] = embeddings.map {
                        RecordingStore.SpeakerEmbeddingRow(
                            recordingID: id,
                            speakerIndex: $0.speakerIndex,
                            embedding: EmbeddingBlob.encode($0.vector),
                            segmentCount: $0.segmentCount,
                            totalMs: $0.totalMs,
                            embedderKind: EmbedderKind.wespeakerV2
                        )
                    }
                    try? await store.upsertSpeakerEmbeddings(recordingID: id, rows: dbRows)
                }
            }
            await enqueueAutoSummaryAfterStop(recordingID: savedID)
            importState.finish()
        } catch is CancellationError {
            // User-cancelled — cancelImport() already reset the banner.
        } catch {
            importState.fail(
                message: "\(source.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// Post-save bookkeeping for a freshly captured recording: stamp which
    /// engine transcribed it, and index it for search.
    ///
    /// The provenance stamp matters as much as the index — without it every new
    /// recording would immediately look stale to the archive reprocessor and a
    /// re-transcribe run would redo work that was already current.
    private func finishNewRecording(id: Int64, recording: Recording) async {
        guard let store else { return }
        let modelID = DaemonArchiveTranscriber(
            engineVersion: HarcVersion.sttEngineVersion,
            diarize: prefs.diarize,
            vad: prefs.vadEnabled
        ).modelID
        try? await store.setTranscriptionProvenance(recordingID: id, modelID: modelID)

        if let text = recording.transcriptText, !text.isEmpty {
            let durationMs = recording.endedAt.map {
                Int($0.timeIntervalSince(recording.startedAt) * 1000)
            }
            ensureMaintenanceStore().indexNewRecording(
                id: id,
                text: text,
                durationMs: durationMs
            )
        }
    }

    private func startPreRollTicker() {
        preRollTicker?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshPreRollBanked() }
        }
        RunLoop.main.add(timer, forMode: .common)
        preRollTicker = timer
    }

    /// Wipe the banked window without stopping capture — the privacy escape
    /// hatch for "I just said something I don't want kept".
    private func clearPreRollBuffer() {
        guard let capture = preRollCapture else { return }
        Task { [weak self] in
            await capture.clear()
            await self?.refreshPreRollBanked()
        }
    }

    /// Publish how much is banked so the menu bar can show it. Polled rather
    /// than streamed: the ring updates ~24×/sec and the panel only needs a
    /// number that looks alive.
    private func refreshPreRollBanked() async {
        guard let capture = preRollCapture else {
            bridge.preRollStatus = nil
            return
        }
        // Report the ring's actual state, not just its fill level. A capture
        // that failed to open the mic banks 0s forever, which is
        // indistinguishable from a healthy ring that just started unless the
        // failure travels with the number.
        switch await capture.state {
        case .listening:
            bridge.preRollStatus = .listening(banked: await capture.bankedSeconds)
        case .failed(let reason):
            bridge.preRollStatus = .failed(reason: reason)
        case .stopped:
            bridge.preRollStatus = nil
        }
    }

    /// Start or stop the idle pre-roll ring to match preferences.
    ///
    /// Never runs while recording: the session owns the mic then, and the ring
    /// has already handed its contents over. Called on launch, when the
    /// preference changes, and after a recording ends.
    func syncPreRollCapture() {
        // Freeze during the start window: the in-flight start owns the ring
        // and will consume it via `promote()`. Tearing it down here would
        // discard the banked retroactive audio; starting a fresh one here
        // (e.g. a dictation afterglow resetting to idle mid-start) used to
        // leave a ring running through the whole meeting, which then
        // prepended that meeting to the *next* recording.
        if state.isPreparing { return }

        // Dictation is the third consumer of a single-user resource. The mic
        // can't be held by an idle pre-roll tap while dictation wants it, and
        // banking dictation audio into the retroactive ring would be a quiet
        // privacy surprise on top of the conflict.
        let shouldRun = prefs.preRollEnabled
            && !state.isRecording
            && !dictationState.isActive

        guard shouldRun else {
            preRollTicker?.invalidate()
            preRollTicker = nil
            bridge.preRollStatus = nil
            if let capture = preRollCapture {
                preRollCapture = nil
                Task { await capture.stop() }
            }
            return
        }

        // Window changes need a fresh ring — capacity is fixed at construction.
        let desiredSeconds = TimeInterval(prefs.preRollMinutes * 60)
        if let existing = preRollCapture {
            Task { [weak self] in
                let current = await existing.windowSeconds
                guard current != desiredSeconds else { return }
                await existing.stop()
                await MainActor.run { self?.preRollCapture = nil; self?.syncPreRollCapture() }
            }
            return
        }

        let capture = PreRollCapture(mic: MicCapture(), windowSeconds: desiredSeconds)
        preRollCapture = capture
        Task { [weak self] in
            await capture.start()
            await self?.refreshPreRollBanked()
        }
        startPreRollTicker()
    }

    private func persistStoppedRecording(_ recording: Recording) async -> Int64? {
        guard let store = self.store else {
            presentRecordingPersistenceFailure(
                recording: recording,
                errorDescription: "The recording database is not available."
            )
            return nil
        }

        do {
            let id = try await store.upsert(recording).id
            if let id { await finishNewRecording(id: id, recording: recording) }
            return id
        } catch {
            FileHandle.standardError.write(Data(
                "harc: failed to persist recording \(recording.wavPath): \(error.localizedDescription)\n".utf8
            ))

            if let recoveredID = await recoverFinalizedRecording(recording, store: store) {
                FileHandle.standardError.write(Data(
                    "harc: recovered recording row after persistence failure: \(recording.wavPath)\n".utf8
                ))
                await finishNewRecording(id: recoveredID, recording: recording)
                return recoveredID
            }

            presentRecordingPersistenceFailure(
                recording: recording,
                errorDescription: error.localizedDescription
            )
            return nil
        }
    }

    private func recoverFinalizedRecording(_ recording: Recording, store: RecordingStore) async -> Int64? {
        if let existing = try? await store.fetchByWavPath(recording.wavPath),
           let id = existing.id {
            return id
        }

        let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
        _ = try? await ingestor.ingestAll()
        return (try? await store.fetchByWavPath(recording.wavPath))?.id
    }

    private func presentRecordingPersistenceFailure(recording: Recording, errorDescription: String) {
        let alert = NSAlert()
        alert.messageText = "Recording saved, but not added to Library"
        alert.informativeText = """
        Harc saved the audio file, but could not create the Library entry.

        \(errorDescription)

        File:
        \(recording.wavPath)

        Restarting Harc will retry importing completed recordings from your destination folder.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reveal File")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
        }
    }

    @MainActor
    private func runAutoPaste(for rec: Recording, shiftHeld: Bool) {
        let blob = ExportService.promptString(for: rec, includeSummary: prefs.includeSummaryInPrompt)
        pastePromptString(blob, shiftHeld: shiftHeld)
    }

    @MainActor
    private func pastePromptString(_ blob: String, shiftHeld: Bool) {
        // Per spec §3: clipboard always holds the prompt blob, regardless
        // of decision. copyAndPaste (below, on the .paste branch) re-writes
        // the same bytes — harmless duplication.
        FrontmostAppPaster.copyOnly(blob)

        let frontmostBundleID = FrontmostAppPaster.frontmostBundleID()
        let decision = AutoPasteGuard.decide(
            enabled: prefs.autoPasteEnabled,
            shiftHeld: shiftHeld,
            frontmostBundleID: frontmostBundleID,
            deniedBundleIDs: prefs.pasteDenyListBundleIDs
        )

        switch decision {
        case .skipDisabled:
            bridge.reportPaste(.skipped, message: "Copied. Auto-paste is off.")
            return
        case .skipModifierHeld:
            bridge.reportPaste(.skipped, message: "Copied. Paste skipped.")
            return
        case .skipUnsafeTarget:
            let target = bridge.frontmostAppName ?? "this app"
            bridge.reportPaste(.skipped, message: "Copied. Paste blocked for \(target).")
            return
        case .paste:
            // Meeting transcripts deliberately never restore the clipboard —
            // "prompt blob on the clipboard" is the product behaviour.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await FrontmostAppPaster.copyAndPaste(blob)
                    self.bridge.reportPaste(.success, message: "Pasted into \(self.bridge.frontmostAppName ?? "frontmost app").")
                } catch FrontmostAppPaster.PasteError.accessibilityDenied {
                    self.bridge.reportPaste(.failure, message: "Copied. Enable Accessibility to paste.")
                    // Re-prompt every paste failure: the prompt itself notes that
                    // the transcript is already on the clipboard, so re-showing it
                    // is informative rather than annoying. A user who chose
                    // "Later" once may want to act the next time auto-paste
                    // silently failed.
                    self.presentAccessibilityPrompt()
                } catch {
                    self.bridge.reportPaste(.failure, message: "Copied. Paste failed.")
                }
            }
        }
    }

    @MainActor
    private func presentDestinationMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Can't start recording"
        alert.informativeText = "The destination folder isn't available:\n\n\(prefs.destinationPath)\n\nChoose a new location in Settings, or restore the missing folder, then try again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSettings()
        }
    }

    @MainActor
    private func presentMicOnlyFallbackNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Recording mic only"
        content.body = "Screen Recording isn't enabled, so other meeting participants won't be in the transcript. Open System Settings to grant it."
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "com.harc.mic-only-fallback",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @MainActor
    private func presentAccessibilityPrompt() {
        let alert = NSAlert()
        alert.messageText = "Harc needs Accessibility permission"
        alert.informativeText = "Auto-paste synthesises ⌘V into the frontmost app. macOS requires Accessibility permission for that. Your transcript is still on the clipboard — you can paste it manually with ⌘V."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func formatAutoStopDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let remainingSeconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds) }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    /// Lazily build the library-maintenance store once the DB is open.
    ///
    /// The transcriber is supplied as a closure rather than captured, because
    /// the engine's identity depends on live preferences (diarization, VAD):
    /// changing either genuinely changes the transcript, so it has to change
    /// what counts as "already current" too.
    func ensureMaintenanceStore() -> LibraryMaintenanceStore {
        if let maintenanceStore { return maintenanceStore }
        let created = LibraryMaintenanceStore(
            store: store,
            transcriberProvider: { [weak self] in
                guard let self else { return nil }
                return DaemonArchiveTranscriber(
                    engineVersion: HarcVersion.sttEngineVersion,
                    diarize: self.prefs.diarize,
                    vad: self.prefs.vadEnabled
                )
            }
        )
        maintenanceStore = created
        return created
    }

    @objc private func openSettings() {
        if let controller = settingsWindow, let window = controller.window {
            controller.showWindow(nil)
            orderManagedWindowFront(window)
            return
        }

        let root = HarcSettingsForm()
            .harcSettingsEnvironment(
                prefs: prefs,
                modelStore: modelStore,
                bridge: bridge,
                dictationModes: dictationModeStore,
                maintenance: ensureMaintenanceStore()
            )
            .preferredColorScheme(prefs.appearance.colorScheme)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Harc Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 720))
        window.minSize = NSSize(width: 640, height: 560)
        window.isReleasedWhenClosed = false
        positionSettingsWindow(window)

        let controller = NSWindowController(window: window)
        settingsWindow = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settingsWindow = nil
            }
        }

        controller.showWindow(nil)
        trackManagedWindow(window)
        orderManagedWindowFront(window)
    }

    /// A brand-new NSWindow lands wherever AppKit's cascade left it — for a
    /// menu-bar app that reads as a random corner. Settings belongs with the
    /// window the user is working in: centered over the library when it's
    /// open, centered on screen otherwise. Only runs at creation; re-showing
    /// an open Settings window must not teleport a window the user placed.
    private func positionSettingsWindow(_ window: NSWindow) {
        guard let library = harcWindow?.window, library.isVisible else {
            window.center()
            return
        }
        let size = window.frame.size
        var origin = NSPoint(
            x: library.frame.midX - size.width / 2,
            y: library.frame.midY - size.height / 2
        )
        // Keep it fully on the library's screen — a library dragged half
        // off-screen must not take Settings with it.
        if let visible = (library.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.maxX - size.width, visible.minX))
            origin.y = min(max(origin.y, visible.minY), max(visible.maxY - size.height, visible.minY))
        }
        window.setFrameOrigin(origin)
    }

    @objc private func showWelcomeWindow(_ sender: Any?) {
        showWelcome(markAsFirstRun: false)
    }

    /// Nil-targeted actions from HarcUI (summary card, panel Settings row) and
    /// the main-menu item land here via the responder chain. Deliberately NOT
    /// named `showSettingsWindow:` — the SwiftUI Settings scene claims that
    /// selector on NSApp and swallows programmatic sends without opening
    /// anything (macOS 14+ insists on SettingsLink).
    @objc func harcShowSettingsWindow(_ sender: Any?) {
        openSettings()
    }

    private func showWelcomeIfNeeded() {
        guard !isUITesting else { return }
        guard prefs.welcomeFlowCompleted else {
            showWelcome(markAsFirstRun: true)
            return
        }
        let snapshot = PermissionSnapshot.current()
        guard !snapshot.coreGrantsIntact else {
            CoreGrantHistory.record(snapshot)
            return
        }

        // A reset deliberately revokes everything, so the repair path must
        // appear no matter what the grant history says — right after the
        // user asked us to wipe their grants is the one flow that reliably
        // needs guidance.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: RecordingPermissionRepair.pendingRepairKey) {
            defaults.removeObject(forKey: RecordingPermissionRepair.pendingRepairKey)
            showWelcome(markAsFirstRun: false)
            return
        }

        // Otherwise: re-offer only when a grant this install has actually
        // seen granted has gone missing — the delete-and-reinstall or
        // re-signed-build case, where prefs survive but the TCC identity
        // changed underneath them. "Never granted" is a standing choice, not
        // breakage: the old once-per-build gate re-nagged deliberate
        // decliners on every Sparkle update, because each update mints a
        // fresh build number.
        guard CoreGrantHistory.revocationDetected(current: snapshot) else {
            CoreGrantHistory.record(snapshot)
            return
        }
        // Deliberately NOT recording here — the welcome window's close
        // observer records the baseline, so a flow the user never actually
        // saw (crash, quit) doesn't consume the revocation evidence.
        showWelcome(markAsFirstRun: false)
    }

    private func showWelcome(markAsFirstRun: Bool) {
        if let controller = welcomeWindow, let window = controller.window {
            controller.showWindow(nil)
            orderManagedWindowFront(window)
            return
        }

        // Live models/permissions state for the "Set up" step. The bridge's
        // honest STT readiness (poller-owned) is mirrored in so the step
        // shows the real download/ready state.
        let setup = WelcomeSetupModel(prefs: prefs, modelStore: modelStore)
        welcomeSetupModel = setup
        setup.sttReady = bridge.sttReady
        setup.sttText = bridge.sttReadinessText
        setup.sttProgress = bridge.sttDownloadProgress
        // Weak sinks in a per-window bag — `assign(to:on:)` retains its
        // target, and storing those in the app-lifetime `cancellables` made
        // every welcome model immortal: each reopen added three more
        // permanent subscriptions writing readiness into dead models.
        welcomeCancellables.removeAll()
        bridge.$sttReady
            .receive(on: DispatchQueue.main)
            .sink { [weak setup] in setup?.sttReady = $0 }
            .store(in: &welcomeCancellables)
        bridge.$sttReadinessText
            .receive(on: DispatchQueue.main)
            .sink { [weak setup] in setup?.sttText = $0 }
            .store(in: &welcomeCancellables)
        bridge.$sttDownloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak setup] in setup?.sttProgress = $0 }
            .store(in: &welcomeCancellables)

        let root = WelcomeFlowView(
            onFinish: { [weak self] in
                self?.completeWelcomeFlow(openLibraryAfterClose: true)
            },
            onSkip: { [weak self] in
                self?.completeWelcomeFlow(openLibraryAfterClose: false)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onEnableAccessibility: { [weak self] in
                self?.presentAccessibilityPrompt()
            },
            setup: setup
        )
        .preferredColorScheme(prefs.appearance.colorScheme)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = markAsFirstRun ? "Welcome to Harc" : "Harc Welcome"
        // Resizable on purpose: step content varies in height, and a fixed
        // window with no way to scroll or resize is how the setup step became
        // impossible to advance past. The ScrollView in WelcomeFlowView is the
        // real guard; this is the second one.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 780, height: 480)
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        welcomeWindow = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.welcomeWindow = nil
                self?.welcomeSetupModel = nil
                self?.welcomeCancellables.removeAll()
                // Closing the window counts as answering the re-offer. The
                // baseline is written here rather than at show time so a
                // flow the user never actually saw through doesn't consume
                // the revocation evidence that summoned it.
                CoreGrantHistory.record(PermissionSnapshot.current())
            }
        }

        controller.showWindow(nil)
        trackManagedWindow(window)
        orderManagedWindowFront(window)
    }

    private func completeWelcomeFlow(openLibraryAfterClose: Bool) {
        prefs.completeWelcomeFlow()
        // The window's willClose observer records the new grant baseline.
        welcomeWindow?.close()
        welcomeWindow = nil
        welcomeSetupModel = nil
        welcomeCancellables.removeAll()
        if openLibraryAfterClose {
            openLibrary()
        }
    }

    @objc private func openLibrary() {
        if let existing = harcWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store else {
            presentLibraryUnavailable("The recording database has not finished opening yet. Try again in a moment.")
            return
        }
        guard let reIDService = speakerReIDService else {
            presentLibraryUnavailable("Speaker identity services have not finished starting yet. Try again in a moment.")
            return
        }
        guard let queueStore = summarizationQueueStore else {
            presentLibraryUnavailable("Summarization services have not finished starting yet. Try again in a moment.")
            return
        }
        guard let summarizerService else {
            presentLibraryUnavailable("The local model service has not finished starting yet. Try again in a moment.")
            return
        }
        let libraryVM = LibraryViewModel(store: store)
        // Hybrid retrieval when the user wants it; nil keeps search lexical.
        libraryVM.searchEmbedder = prefs.semanticSearchEnabled
            ? ensureMaintenanceStore().searchEmbedder
            : nil
        let controller = HarcWindowController(
            libraryVM: libraryVM,
            recordingState: state,
            bridge: bridge,
            store: store,
            reIDService: reIDService,
            summarizerService: summarizerService,
            prefs: prefs,
            postProcessingState: postProcessingState,
            queueStore: queueStore,
            modelStore: modelStore,
            importState: importState,
            onDelete: { [weak self] rec in self?.deleteRecording(recording: rec) },
            onImportFiles: { [weak self] urls in self?.importMediaFiles(urls) },
            onCancelImport: { [weak self] in self?.cancelImport() },
            onSummarizeSession: { [weak self] id in self?.enqueueSessionSummary(sessionID: id) }
        )
        harcWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        trackManagedWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bootstrapStore() async {
        do {
            let store = try await makeApplicationStore()
            try await finishStoreBootstrap(store)
        } catch {
            FileHandle.standardError.write(Data(
                "harc: store init failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    private func makeApplicationStore() async throws -> RecordingStore {
        let databaseURL = uiTestDatabaseURL ?? RecordingStore.defaultURL()
        guard !isUITesting else {
            return try await RecordingStore.onDisk(url: databaseURL)
        }

        switch prefs.runtimeRole {
        case .standalone:
            return try await RecordingStore.onDisk(url: databaseURL)
        case .client:
            throw HarcHostApplicationRuntimeError.clientModeNotImplemented
        case .host:
            let configuration = try HarcHostRuntimeConfigurationFactory.make(
                canonicalDatabaseURL: databaseURL,
                canonicalAudioRoot: prefs.destinationURL
            )
            let workerBox = HarcHostProcessingWorkerBox()
            let launcher = launcher
            let diarize = prefs.diarize
            let vad = prefs.vadEnabled
            let runtime = try await HarcResidentHostRuntimeV1.start(
                configuration: configuration,
                makeProcessingScheduler: { storage in
                    let worker = HarcHostProcessingWorker(
                        store: storage.recordingStore,
                        launcher: launcher,
                        diarize: diarize,
                        vad: vad
                    )
                    try await workerBox.install(worker)
                    return HarcCanonicalLibraryProcessingScheduler(
                        store: storage.recordingStore,
                        wakeHandler: { request in
                            await worker.signal(request)
                        }
                    )
                }
            )
            let worker = try await workerBox.requireWorker()
            hostRuntime = runtime
            hostProcessingWorker = worker

            // `processing` journal rows are already durably handed off and do
            // not replay the scheduler during publication recovery. Rebuild
            // their exact path/inode-bound requests from HostDB explicitly.
            let backlog = try await runtime.storageRuntime.recordingStore
                .hostProcessingBacklog()
            for recording in backlog {
                do {
                    let request = try await runtime.validatedProcessingRequest(
                        canonicalRecordingID: recording.canonicalID
                    )
                    await worker.signal(request)
                } catch {
                    FileHandle.standardError.write(Data(
                        "harc-host: processing recovery failed for \(recording.canonicalID): \(error.localizedDescription)\n".utf8
                    ))
                }
            }
            return runtime.storageRuntime.recordingStore
        }
    }

    private func finishStoreBootstrap(_ store: RecordingStore) async throws {
            self.store = store
            let recoveryQueue = RecoveryQueue(fileURL: uiTestRecoveryQueueURL ?? RecoveryQueue.defaultURL(), store: store)
            self.recoveryQueue = recoveryQueue

            // Keep interrupted cache artifacts visible until the user chooses
            // Recover or Discard from the recovery inbox. A user can begin a
            // capture before store bootstrap finishes; never classify that
            // live (or late-finalizing) cache master as interrupted.
            if isCacheRecoveryProtected {
                bootstrapRecoveryScanDeferred = true
            } else {
                try? await recoveryQueue.scanCache(
                    cacheDirectory: RecordingDestination.cacheDirectory(),
                    destinationDirectory: prefs.destinationURL
                )
            }
            await refreshRecoveryArtifacts()

            // Ingest existing filesystem recordings.
            let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
            _ = try? await ingestor.ingestAll()
            if isUITesting {
                try? await seedUITestLibraryIfNeeded(store: store)
            }

            let vm = RecordingsViewModel(store: store)
            vm.start()
            self.recordingsVM = vm

            // Cross-recording speaker re-ID service. Cheap to construct; the
            // expensive linear scan runs only when the editor asks.
            // embeddingDim defaults to 256 (WeSpeaker v2 centroid dimension).
            let nameResolver = StoreSpeakerNameResolver(store: store)
            self.speakerReIDService = SpeakerReIDService(
                store: store,
                nameResolver: nameResolver
            )

            // Stage 3 summarization graph. Owned by AppDelegate for app
            // lifetime; queue survives panel re-renders.
            let coordinator = BackgroundWorkCoordinator()
            let service = SummarizerService(loader: SummarizerService.defaultLoader)
            await service.setIdleUnloadDelay(prefs.modelPerformanceMode.summarizerIdleUnloadDelay)
            self.memoryObservation = service.startObservingMemoryPressure()
            let queue = SummarizationQueue(coordinator: coordinator, perform: { [weak self] id in
                guard let self else { return }
                try await self.performSummarization(id: id)
            })
            self.summarizerService = service
            self.summarizationQueue = queue
            self.summarizationQueueStore = await SummarizationQueueStore(queue: queue)
            self.sessionSummarizationQueue = SummarizationQueue(
                coordinator: coordinator,
                perform: { [weak self] id in
                    guard let self else { return }
                    try await self.performSessionSummarization(id: id)
                }
            )
            observeModelPerformanceMode()

            // Failure surfaces now live on `summarizationQueueStore.lastFailures`
            // (Stage 4) — consumed by `SummaryCardView.failed` state.

            // On-launch catch-up: enqueue the N newest un-summarized rows
            // so a fresh install (or a crash recovery) picks up where it
            // left off. Gated by the same prefs + install checks the
            // stopRecording trigger uses.
            //
            // Explicitly await modelManager.bootstrap() first so the
            // install-state gate below reads a seeded value. Without it,
            // the fire-and-forget bootstrap Task kicked off in
            // applicationDidFinishLaunching races with this check —
            // first-launch after a clean install could see `.absent`
            // for an already-installed model and silently skip. Second
            // call is idempotent (re-reads disk markers).
            await modelManager.bootstrap()
            if prefs.autoSummarizeEnabled,
               shouldSummarizeGivenPower(),
               await modelManager.state(of: prefs.activeSummarizerID).isInstalled {
                let rows = (try? await store.unsummarizedRecordings(limit: 20)) ?? []
                for rec in rows { if let id = rec.id { await queue.enqueue(id) } }
            }

            observeDestinationChanges()
            if shouldOpenLibraryForUITest {
                openLibrary()
            }
    }

    private func observeDestinationChanges() {
        prefsObserver = prefs.$destinationPath
            .removeDuplicates()
            .dropFirst()  // skip initial value
            .sink { [weak self] _ in
                Task { await self?.reingestForNewDestination() }
            }
    }

    private func reingestForNewDestination() async {
        guard let store = store else { return }
        let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
        _ = try? await ingestor.ingestAll()
    }

    private func observeModelPerformanceMode() {
        modelPerformanceObserver = prefs.$modelPerformanceMode
            .removeDuplicates()
            .sink { [weak self] mode in
                guard let self else { return }
                Task {
                    await self.summarizerService?.setIdleUnloadDelay(mode.summarizerIdleUnloadDelay)
                }
            }
    }

    // MARK: - Summarization

    private func enqueueAutoSummaryAfterStop(recordingID: Int64?) async {
        guard let id = recordingID else { return }
        guard let store else { return }

        func skip(_ message: String) async {
            try? await store.updateSummaryStatus(id: id, kind: .skipped, message: message)
        }

        guard prefs.autoSummarizeEnabled else {
            await skip("Auto-summarize is turned off in Settings.")
            return
        }
        guard shouldSummarizeGivenPower() else {
            await skip("Auto-summarize is paused while this Mac is on battery power.")
            return
        }
        guard modelStore.state(of: prefs.activeSummarizerID).isInstalled else {
            await skip("The active summarizer is not installed.")
            return
        }
        guard let queue = self.summarizationQueue else {
            await skip("The summarization queue is not available yet.")
            return
        }

        try? await store.clearSummaryStatus(id: id)
        await queue.enqueue(id)
    }

    /// The `SummarizationQueue` perform closure. Pulls the recording and
    /// its JSON sidecar, builds the prompt transcript, resolves the active
    /// summarizer's directory + context window, runs the summary, and
    /// persists the result. Errors propagate — the queue's `.finished`
    /// event carries them up to whatever's listening.
    private func performSummarization(id: Int64) async throws {
        guard let store = self.store else { return }
        guard let service = self.summarizerService else {
            try? await store.updateSummaryStatus(
                id: id,
                kind: .failed,
                message: "The summarization service is not available."
            )
            return
        }
        do {
            try await performSummarizationBody(id: id, store: store, service: service)
        } catch {
            if !(error is CancellationError) {
                try? await store.updateSummaryStatus(
                    id: id,
                    kind: .failed,
                    message: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func performSummarizationBody(
        id: Int64,
        store: RecordingStore,
        service: SummarizerService
    ) async throws {
        guard let rec = try await store.fetch(id: id),
              let jsonPath = rec.jsonPath else {
            // No sidecar = nothing structured to summarize. Losing speaker
            // segments would silently degrade the summary, so we skip
            // rather than fall back to plain transcriptText. The queue
            // advances as success.
            try? await store.updateSummaryStatus(
                id: id,
                kind: .skipped,
                message: "No transcript sidecar was found for this recording."
            )
            return
        }

        let session: SessionTranscript = try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(SessionTranscript.self, from: data)
        }.value

        // Guard against summarizing empty / trivially-short transcripts.
        // LLMs given an empty prompt happily fabricate a meeting from
        // nothing — Sarah/David/Q3 review style hallucinations. Skip when
        // there's not enough transcribed content for a meaningful summary.
        let transcriptWordCount = session.joinedText.split(whereSeparator: { $0.isWhitespace }).count
        guard transcriptWordCount >= Self.minWordsToSummarize else {
            try? await store.updateSummaryStatus(
                id: id,
                kind: .skipped,
                message: transcriptWordCount == 0
                    ? "Recording contained no transcribable speech."
                    : "Recording is too short to summarize (\(transcriptWordCount) words)."
            )
            return
        }

        let promptTranscript = PromptTranscriptAdapter.make(
            joinedText: session.joinedText,
            words: session.words,
            speakers: session.speakers,
            speakerNameOverrides: rec.speakerNames
        )

        let modelID = prefs.activeSummarizerID
        guard let descriptor = await modelManager.descriptor(for: modelID) else {
            try? await store.updateSummaryStatus(
                id: id,
                kind: .skipped,
                message: "The active summarizer model is unknown."
            )
            return
        }
        let directory = try await modelManager.requireInstalled(modelID)
        let budgetWords = SummaryPrompt.budgetWords(contextTokens: descriptor.contextTokens)

        let queueStore = summarizationQueueStore
        let result = try await service.summarize(
            transcript: promptTranscript,
            modelID: modelID,
            modelDirectory: directory,
            budgetWords: budgetWords,
            onStats: { stats in
                queueStore?.updateLiveStats(stats)
                if stats.isFinal {
                    MeasuredModelSpeed.record(
                        modelID: modelID,
                        tokensPerSecond: stats.tokensPerSecond
                    )
                }
            }
        )

        // sourceWordCount must match the field isStale() will read against
        // (recording.transcriptText, mirrored from the .txt sidecar) — NOT
        // session.joinedText (the .json sidecar's prose). The two differ
        // because the .txt includes speaker labels / line breaks. Comparing
        // mismatched counts triggered the "older transcript" banner on
        // brand-new summaries. Fall back to joinedText only if the cached
        // field is missing.
        let staleSource = rec.transcriptText ?? session.joinedText
        let wordCount = staleSource.split(whereSeparator: { $0.isWhitespace }).count

        try await store.updateSummary(
            id: id,
            markdown: result.summary,
            actionItemsMarkdown: ActionItemsMarkdown.render(result.actionItems),
            modelID: modelID,
            generatedAt: Date(),
            sourceWordCount: wordCount
        )

        // Title the recording from the summary's first clause. Writes only
        // suggested_title — a user's rename always wins via displayTitle's
        // tiering — and upgrades the entity-based suggestion made at stop
        // time, because "The team reviewed the onboarding drop-off" beats
        // "Michelle, Acme" as a row identity. Best-effort: a failed title
        // write must not fail the summarization it rides on.
        if let derived = TitleSuggester.fromSummary(result.summary) {
            try? await store.updateSuggestedTitle(id: id, title: derived)
        }
    }

    // MARK: - Session summarization

    /// Public entry for the session detail pane's Summarize button and the
    /// create-session auto-trigger. Clears stale status, then enqueues.
    func enqueueSessionSummary(sessionID: Int64) {
        Task {
            guard let queue = sessionSummarizationQueue else {
                try? await store?.updateSessionSummaryStatus(
                    id: sessionID,
                    kind: .failed,
                    message: "The summarization queue is not available yet."
                )
                return
            }
            await queue.enqueue(sessionID)
        }
    }

    /// The session queue's perform closure. Mirrors `performSummarization`
    /// but assembles one combined prompt from every member recording's JSON
    /// sidecar, with speaker labels resolved through People so the same
    /// person reads as one speaker across sittings.
    private func performSessionSummarization(id: Int64) async throws {
        guard let store = self.store else { return }
        guard let service = self.summarizerService else {
            try? await store.updateSessionSummaryStatus(
                id: id,
                kind: .failed,
                message: "The summarization service is not available."
            )
            return
        }
        do {
            try await performSessionSummarizationBody(id: id, store: store, service: service)
        } catch {
            if !(error is CancellationError) {
                try? await store.updateSessionSummaryStatus(
                    id: id,
                    kind: .failed,
                    message: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func performSessionSummarizationBody(
        id: Int64,
        store: RecordingStore,
        service: SummarizerService
    ) async throws {
        guard try await store.session(id: id) != nil else { return }
        let members = try await store.recordings(inSession: id)

        var parts: [SessionPromptAssembler.Part] = []
        for member in members {
            guard let memberID = member.id, let jsonPath = member.jsonPath else { continue }
            guard let transcript: SessionTranscript = try? await Task.detached(priority: .utility, operation: {
                let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try decoder.decode(SessionTranscript.self, from: data)
            }).value else { continue }

            // Resolve each diarization index through People > overrides >
            // default. This is what unifies "Speaker 1 at 10am" and
            // "Speaker 2 at 2pm" into one label when both link to a Person.
            var names: [Int: String] = [:]
            for index in Set(transcript.speakers.map(\.speaker)) {
                names[index] = try? await store.resolvedSpeakerName(
                    recordingID: memberID,
                    speakerIndex: index
                )
            }

            parts.append(.init(
                joinedText: transcript.joinedText,
                words: transcript.words,
                speakers: transcript.speakers,
                speakerNames: names.compactMapValues { $0 },
                startedAt: member.startedAt
            ))
        }

        guard !parts.isEmpty else {
            try? await store.updateSessionSummaryStatus(
                id: id,
                kind: .skipped,
                message: "No transcript sidecars were found for this session's recordings."
            )
            return
        }

        let promptTranscript = SessionPromptAssembler.make(parts: parts)
        let sourceWordCount = parts
            .map { $0.joinedText.split(whereSeparator: { $0.isWhitespace }).count }
            .reduce(0, +)
        guard sourceWordCount >= Self.minWordsToSummarize else {
            try? await store.updateSessionSummaryStatus(
                id: id,
                kind: .skipped,
                message: sourceWordCount == 0
                    ? "The session's recordings contained no transcribable speech."
                    : "The session is too short to summarize (\(sourceWordCount) words)."
            )
            return
        }

        let modelID = prefs.activeSummarizerID
        guard let descriptor = await modelManager.descriptor(for: modelID) else {
            try? await store.updateSessionSummaryStatus(
                id: id,
                kind: .skipped,
                message: "The active summarizer model is unknown."
            )
            return
        }
        let directory = try await modelManager.requireInstalled(modelID)
        let budgetWords = SummaryPrompt.budgetWords(contextTokens: descriptor.contextTokens)

        let result = try await service.summarize(
            transcript: promptTranscript,
            modelID: modelID,
            modelDirectory: directory,
            budgetWords: budgetWords
        )

        try await store.updateSessionSummary(
            id: id,
            markdown: result.summary,
            actionItemsMarkdown: ActionItemsMarkdown.render(result.actionItems),
            modelID: modelID,
            generatedAt: Date(),
            sourceWordCount: sourceWordCount
        )
    }

    /// Private helper — returns true when auto-summarize should fire. The
    /// only skip condition is "on battery AND the user didn't opt into
    /// battery-time summarization". Desktop Macs with no battery report
    /// AC-or-unknown and always summarize.
    private func shouldSummarizeGivenPower() -> Bool {
        if prefs.autoSummarizeOnBatteryEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return true
        }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return type != kIOPSBatteryPowerValue
    }

    // MARK: - MeetingDetector.Delegate / UNUserNotificationCenterDelegate

    nonisolated func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp) {
        Task { @MainActor in
            self.meetingState.add(bundleID: app.bundleID, displayName: app.displayName)
            await self.notificationPresenter.present(app: app)
            // 2-minute pulse/banner timeout — if the user never reacts, clean up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.meetingState.clear(bundleID: app.bundleID)
                self?.notificationPresenter.withdraw(bundleID: app.bundleID)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let bundleID = info[MeetingNotification.bundleIDUserInfoKey] as? String
        let actionID = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            if let bundleID {
                self.meetingState.clear(bundleID: bundleID)
                self.detector?.markHandled(bundleID: bundleID)
            }

            if category == AutoStopNotification.categoryID {
                switch actionID {
                case AutoStopNotification.resumeActionID, UNNotificationDefaultActionIdentifier:
                    self.autoStop.resetPostStop()
                    if !self.state.isRecording { await self.startRecording() }
                case AutoStopNotification.openActionID:
                    self.autoStop.resetPostStop()
                    if let rec = self.recordingsVM?.recordings.first {
                        self.openDetail(for: rec)
                    }
                default:
                    break
                }
                return
            }

            switch actionID {
            case MeetingNotification.recordActionID, UNNotificationDefaultActionIdentifier:
                if !self.state.isRecording { await self.startRecording() }
            default:
                break
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when the app is frontmost.
        completionHandler([.banner, .list])
    }
}

#if DEBUG
private extension AppDelegate {
    var isUITesting: Bool {
        ProcessInfo.processInfo.environment["HARC_UI_TESTING"] == "1"
    }

    var shouldOpenLibraryForUITest: Bool {
        ProcessInfo.processInfo.environment["HARC_UI_TEST_OPEN_LIBRARY"] == "1"
    }

    var shouldUseUITestRecordingLoop: Bool {
        ProcessInfo.processInfo.environment["HARC_UI_TEST_FAKE_RECORDING"] == "1"
    }

    /// Where a UI-test run keeps its library, recordings and recovery queue.
    ///
    /// Never nil while UI testing. It used to return nil when the harness
    /// didn't pass `HARC_UI_TEST_ROOT`, and every caller fell back to the real
    /// path — so a run without that variable opened the user's actual library
    /// and left recordings in it (empty titles, one-character transcripts)
    /// plus permanently-unrecoverable entries in their recovery inbox
    /// pointing at a deleted xctrunner container. A test harness must not be
    /// one missing environment variable away from writing to real user data.
    var uiTestRootURL: URL? {
        guard isUITesting else { return nil }
        if let raw = ProcessInfo.processInfo.environment["HARC_UI_TEST_ROOT"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("harc-ui-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    var uiTestDatabaseURL: URL? {
        uiTestRootURL?.appendingPathComponent("HarcUITest.db")
    }

    var uiTestRecoveryQueueURL: URL? {
        uiTestRootURL?.appendingPathComponent("recovery.json")
    }

    func applyUITestConfigurationIfNeeded() {
        guard isUITesting, let root = uiTestRootURL else { return }
        // These assignments land in the user's real UserDefaults domain — the
        // app shares one suite. Record what was there so a test run doesn't
        // silently leave auto-summarize and meeting detection switched off.
        UITestPreferenceRestore.capture(prefs)
        let recordingsURL = root.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)

        prefs.destinationPath = recordingsURL.path
        prefs.autoSummarizeEnabled = false
        prefs.meetingDetectionEnabled = false
        prefs.postStopNotificationEnabled = false
    }

    func restoreUITestPreferencesIfNeeded() {
        guard isUITesting else { return }
        UITestPreferenceRestore.restore(prefs)
    }

    func startUITestRecording(at startedAt: Date) async {
        uiTestRecordingStartedAt = startedAt
        state.markStarted(at: startedAt)
        bridge.setActiveCaptureStatus(ActiveCaptureStatus(
            sourceState: .micAndSystemAudio,
            cachePath: RecordingDestination.cacheDirectory().path,
            destinationPath: prefs.destinationPath,
            startedAt: startedAt
        ))
        state.appendPreview(uiTestRecordingTranscript)
        bridge.markActiveTranscriptUpdate(at: startedAt.addingTimeInterval(1))
    }

    func stopUITestRecording(
        startedAt: Date?,
        autoStopReason: AutoStopController.StopReason?
    ) async {
        let startedAt = startedAt ?? Date()
        let endedAt = Date()

        do {
            let destination = RecordingDestination(baseDirectory: prefs.destinationURL)
            let wavURL = try destination.publicPath(for: startedAt)
            try FileManager.default.createDirectory(
                at: wavURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 42, count: 4096).write(to: wavURL, options: .atomic)

            let transcript = uiTestRecordingTranscript
            let sessionTranscript = SessionTranscript(
                startedAt: startedAt,
                endedAt: endedAt,
                audioPath: wavURL.path,
                joinedText: transcript,
                words: uiTestWords(for: transcript),
                speakers: [
                    SpeakerSegment(speaker: 0, startMs: 0, endMs: 4_000),
                    SpeakerSegment(speaker: 1, startMs: 4_000, endMs: 9_000),
                ],
                chunks: [
                    ChunkResult(
                        startMs: 0,
                        endMs: 9_000,
                        text: transcript,
                        words: uiTestWords(for: transcript),
                        speakers: [
                            SpeakerSegment(speaker: 0, startMs: 0, endMs: 4_000),
                            SpeakerSegment(speaker: 1, startMs: 4_000, endMs: 9_000),
                        ],
                        processingMs: 12
                    ),
                ]
            )
            try TranscriptWriter.writeSiblings(transcript: sessionTranscript, nextTo: wavURL)
            let txtURL = wavURL.deletingPathExtension().appendingPathExtension("md")
            let jsonURL = wavURL.deletingPathExtension().appendingPathExtension("json")

            state.markStopped(wavURL: wavURL, txtURL: txtURL, jsonURL: jsonURL)
            let recording = Recording(
                wavPath: wavURL.path,
                txtPath: txtURL.path,
                jsonPath: jsonURL.path,
                startedAt: startedAt,
                endedAt: endedAt,
                title: uiTestRecordingTitle,
                transcriptText: transcript,
                tags: ["ui-test", "live-loop"],
                speakerNames: [0: "Alyssa", 1: "Marco"]
            )
            let savedID = await persistStoppedRecording(recording)
            if let savedID, let store {
                postProcessingState.begin(recordingID: savedID)
                postProcessingState.succeed(recordingID: savedID, speakerCount: 0)
                if let persisted = try? await store.fetch(id: savedID) {
                    bridge.trayState.show(
                        title: persisted.displayTitle,
                        transcript: persisted.transcriptText ?? "",
                        recordingID: savedID,
                        wavPath: persisted.wavPath,
                        outcome: .savedSafely(title: persisted.displayTitle, wavPath: persisted.wavPath)
                    )
                } else {
                    bridge.trayState.show(
                        title: uiTestRecordingTitle,
                        transcript: transcript,
                        recordingID: savedID,
                        wavPath: wavURL.path,
                        outcome: .savedSafely(title: uiTestRecordingTitle, wavPath: wavURL.path)
                    )
                }
            }
            autoStop.end(autoStopReason: autoStopReason)
            // The session has released the mic; resume banking if enabled.
            syncPreRollCapture()
        } catch {
            presentError(error)
        }

        uiTestRecordingStartedAt = nil
        previewTask?.cancel()
        previewTask = nil
        resetUI()
    }

    func seedUITestLibraryIfNeeded(store: RecordingStore) async throws {
        guard ProcessInfo.processInfo.environment["HARC_UI_TEST_SEED_LIBRARY"] == "1",
              let root = uiTestRootURL else {
            return
        }
        if !(try await store.fetchAll(includeDeleted: true)).isEmpty {
            return
        }

        let recordingsURL = root.appendingPathComponent("Recordings", isDirectory: true)
        let startedAt = Date(timeIntervalSince1970: 1_779_032_400)
        let dayURL = recordingsURL
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("2026-05-18", isDirectory: true)
        try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)

        let wavURL = dayURL.appendingPathComponent("09-00-00.wav")
        let txtURL = dayURL.appendingPathComponent("09-00-00.md")
        let jsonURL = dayURL.appendingPathComponent("09-00-00.json")
        let transcript = "Amy: The customer renewal is healthy, but pricing risk is still open. Jason: Send the renewal plan by Friday."
        try Data(repeating: 12, count: 512).write(to: wavURL, options: .atomic)
        try OKFMarkdown.render(OKFMarkdown.Fields(
            title: "UI Test Customer Renewal",
            startedAt: startedAt,
            wavFileName: wavURL.lastPathComponent,
            transcript: transcript
        )).write(to: txtURL, atomically: true, encoding: .utf8)
        try uiTestTranscriptJSON(
            audioPath: wavURL.path,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            text: transcript
        )
        .write(to: jsonURL, atomically: true, encoding: .utf8)

        let recording = try await store.upsert(Recording(
            wavPath: wavURL.path,
            txtPath: txtURL.path,
            jsonPath: jsonURL.path,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            title: "UI Test Customer Renewal",
            transcriptText: transcript,
            tags: ["customer", "renewal"],
            speakerNames: [0: "Amy", 1: "Jason"],
            summaryMarkdown: "The customer renewal is healthy, but pricing risk remains open.",
            actionItemsMarkdown: "- [ ] Jason: send the renewal plan by Friday",
            summaryModelID: "ui-test-model",
            summaryGeneratedAt: startedAt.addingTimeInterval(120),
            summarySourceWordCount: 18
        ))
        _ = recording
    }

    func uiTestTranscriptJSON(audioPath: String, startedAt: Date, endedAt: Date, text: String) -> String {
        let escapedAudioPath = audioPath.replacingOccurrences(of: #"""#, with: #"\""#)
        let escapedText = text.replacingOccurrences(of: #"""#, with: #"\""#)
        return """
        {
          "audioPath": "\(escapedAudioPath)",
          "chunks": [],
          "endedAt": \(Int(endedAt.timeIntervalSince1970)),
          "joinedText": "\(escapedText)",
          "speakers": [
            {"endMs": 45000, "speaker": 0, "startMs": 0},
            {"endMs": 90000, "speaker": 1, "startMs": 45000}
          ],
          "startedAt": \(Int(startedAt.timeIntervalSince1970)),
          "words": [
            {"endMs": 500, "startMs": 0, "text": "Amy"},
            {"endMs": 1000, "startMs": 500, "text": "customer"},
            {"endMs": 1500, "startMs": 1000, "text": "renewal"},
            {"endMs": 45500, "startMs": 45000, "text": "Jason"},
            {"endMs": 46000, "startMs": 45500, "text": "Friday"}
          ]
        }
        """
    }

    var uiTestRecordingTitle: String {
        ProcessInfo.processInfo.environment["HARC_UI_TEST_RECORDING_TITLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "UI Test Live Pipeline Review"
    }

    var uiTestRecordingTranscript: String {
        ProcessInfo.processInfo.environment["HARC_UI_TEST_RECORDING_TRANSCRIPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "Alyssa: Budget owner confirmed the launch checklist is complete. Marco: Send the customer recap by Friday and keep the renewal risk visible."
    }

    func uiTestWords(for transcript: String) -> [Word] {
        transcript
            .split(separator: " ")
            .enumerated()
            .map { index, word in
                Word(
                    text: String(word).trimmingCharacters(in: .punctuationCharacters),
                    startMs: index * 400,
                    endMs: (index + 1) * 400
                )
            }
    }
}
#else
private extension AppDelegate {
    var isUITesting: Bool { false }
    var shouldOpenLibraryForUITest: Bool { false }
    var shouldUseUITestRecordingLoop: Bool { false }
    var uiTestDatabaseURL: URL? { nil }
    var uiTestRecoveryQueueURL: URL? { nil }
    func applyUITestConfigurationIfNeeded() {}
    func restoreUITestPreferencesIfNeeded() {}
    func startUITestRecording(at startedAt: Date) async {}
    func stopUITestRecording(startedAt: Date?, autoStopReason: AutoStopController.StopReason?) async {}
    func seedUITestLibraryIfNeeded(store: RecordingStore) async throws {}
}
#endif

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct StatusPopoverRoot: View {
    @ObservedObject var bridge: HarcAppBridge
    @ObservedObject var dictationState: DictationState
    @ObservedObject var dictationModeStore: DictationModeStore
    @ObservedObject var dictationHistoryStore: DictationHistoryStore
    let onStopDictation: () -> Void
    let onCancelDictation: () -> Void
    let onOpenDictationHistory: () -> Void
    @EnvironmentObject private var prefs: HarcPreferences

    private var dictationStatusText: String? {
        switch dictationState.phase {
        case .idle: return nil
        case .requestingMic: return "Waiting for microphone access…"
        case .loadingModel: return "Loading speech model…"
        case .loadingTransformModel(let name): return "Loading \(name)…"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .transforming:
            return "\((dictationState.sessionModeOverride ?? dictationModeStore.activeMode).name)…"
        case .inserting: return "Inserting…"
        case .done(let outcome): return outcome.message
        case .error(let message): return message
        }
    }

    var body: some View {
        MenuBarPanelView(
            recordingState: bridge.recordingState,
            trayState: bridge.trayState,
            amplitudeHistory: bridge.amplitudeHistory,
            onStartStop: bridge.onStartStop,
            onOpenWindow: bridge.onOpenWindow,
            onCopy: bridge.onCopyLastTranscript,
            onPasteIntoFrontmost: bridge.onPasteIntoFrontmost,
            onOpenLastRecording: bridge.onOpenLastRecording,
            frontmostAppName: bridge.frontmostAppName,
            frontmostPasteDenied: bridge.frontmostPasteDenied,
            pasteStatusMessage: bridge.pasteStatusMessage,
            autoStopPhase: bridge.autoStopPhase,
            autoStopWarningSeconds: bridge.autoStopWarningSeconds,
            autoStopThresholdMinutes: bridge.autoStopThresholdMinutes,
            autoStopMicDb: bridge.autoStopMicDb,
            autoStopSystemDb: bridge.autoStopSystemDb,
            autoStopLastDurationText: bridge.autoStopLastDurationText,
            stopRecovery: bridge.stopRecovery,
            activeCaptureStatus: bridge.activeCaptureStatus,
            preRollStatus: bridge.preRollStatus,
            onClearPreRoll: bridge.onClearPreRoll,
            onKeepRecording: bridge.onKeepRecording,
            onStopNow: bridge.onStopNow,
            onOpenSettings: bridge.onOpenSettings,
            onOpenActivity: bridge.onOpenActivity,
            onRevealStopRecovery: bridge.onRevealStopRecovery,
            onRetryStopRecovery: bridge.onRetryStopRecovery,
            onDismissStopRecovery: bridge.onDismissStopRecovery,
            destinationReady: bridge.destinationReady,
            destinationPath: bridge.destinationPath,
            captureReadinessText: bridge.captureReadinessText,
            captureReadinessWarning: bridge.captureReadinessWarning,
            sttReadinessText: bridge.sttReadinessText,
            sttReady: bridge.sttReady,
            summarizerReadinessText: bridge.summarizerReadinessText,
            summarizerReady: bridge.summarizerReady,
            summarizerInstalled: bridge.summarizerInstalled,
            speakerIDReadinessText: bridge.speakerIDReadinessText,
            speakerIDReady: bridge.speakerIDReady,
            notificationsReadinessText: bridge.notificationsReadinessText,
            notificationsReady: bridge.notificationsReady,
            accessibilityReadinessText: bridge.accessibilityReadinessText,
            accessibilityReady: bridge.accessibilityReady,
            recoveryArtifacts: bridge.recoveryArtifacts,
            onRecoverRecoveryArtifact: bridge.onRecoverRecoveryArtifact,
            onRevealRecoveryArtifact: bridge.onRevealRecoveryArtifact,
            onDiscardRecoveryArtifact: bridge.onDiscardRecoveryArtifact,
            dictationActive: dictationState.isActive,
            dictationStatusText: dictationStatusText,
            onStartDictation: bridge.onStartDictation,
            onStopDictation: onStopDictation,
            onCancelDictation: onCancelDictation,
            dictationModes: dictationModeStore.modes,
            activeDictationModeID: dictationModeStore.activeMode.id,
            onSelectDictationMode: { dictationModeStore.setActiveMode(id: $0) },
            dictationHistory: dictationHistoryStore.entries,
            onCopyDictationHistoryEntry: { FrontmostAppPaster.copyOnly($0.text) },
            onClearDictationHistory: { dictationHistoryStore.clear() },
            onOpenDictationHistory: onOpenDictationHistory,
            availableUpdate: bridge.availableUpdate,
            onInstallUpdate: bridge.onInstallUpdate
        )
        .preferredColorScheme(prefs.appearance.colorScheme)
    }
}

/// Hosting controller for the menu-bar panel.
///
/// SwiftUI content inside an `NSPopover` never sees Escape: `.transient` only
/// covers clicks outside, so the panel could be dismissed by clicking its
/// menu-bar icon again and by essentially nothing else. `cancelOperation` is
/// the AppKit hook for the Escape key, and it reaches here through the
/// responder chain.
final class PanelHostingController<Content: View>: NSHostingController<Content> {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
