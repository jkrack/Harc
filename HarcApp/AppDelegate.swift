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
import HarcMeetingDetect
import HarcModels
import HarcStore
import HarcUI
import HarcSummarize
import HarcVoiceprint
import IOKit.ps
import KeyboardShortcuts

/// Thrown by stopRecording's timeout race when session.stop() exceeds the cap.
private struct StopTimeoutError: Error {}

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
        bridge.onRevealStopRecovery = {
            NSWorkspace.shared.activateFileViewerSelecting([RecordingDestination.cacheDirectory()])
        }
        bridge.onRetryStopRecovery = { [weak self] in
            Task { await self?.retryStopRecovery() }
        }
        bridge.onDismissStopRecovery = { [weak self] in
            self?.bridge.clearStopRecovery()
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
        popover.contentSize = NSSize(width: 320, height: 260)
        popover.contentViewController = NSHostingController(
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
    private var recoveryQueue: RecoveryQueue?
    private var memoryObservation: SummarizerService.MemoryPressureObservation?
    private let postProcessingState = RecordingPostProcessingState()
    /// Retained so runIdentifySpeakers can call diarize() outside of a recording session.
    private var sttClient: HarcSTTClient?
    private var speakerReIDService: SpeakerReIDService?
    private var store: RecordingStore?
    /// Whole-library operations (re-transcribe, build search index). Created
    /// once the store exists; Settings observes it.
    private var maintenanceStore: LibraryMaintenanceStore?
    /// Always-on pre-roll ring, present only while the feature is enabled.
    private var preRollCapture: PreRollCapture?
    private var preRollTicker: Timer?
    private var recordingsVM: RecordingsViewModel?
    private var editorWindows: [String: TranscriptEditorWindowController] = [:]
    private var harcWindow: HarcWindowController?
    private var settingsWindow: NSWindowController?
    private var welcomeWindow: NSWindowController?
    /// Retained while the Welcome window is open so app activation can push a
    /// fresh permission read into it — the user grants in System Settings and
    /// comes back expecting the checkmarks to have moved.
    private var welcomeSetupModel: WelcomeSetupModel?
    private var previewTask: Task<Void, Never>?
    private var prefsObserver: AnyCancellable?
    private var modelPerformanceObserver: AnyCancellable?
    private var pendingSkipPaste = false
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
        observeMeetingDetectionPref()
        observeMeetingStateForPulse()
        observePostProcessingState()
        applyAutoStopConfigFromPrefs()
        updateMenuBarReadiness()
        observeAutoStopPrefs()
        observeAutoStopPhase()
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
        // A repair that has since been satisfied shouldn't keep nagging.
        if PermissionSnapshot.current().coreGrantsIntact {
            UserDefaults.standard.removeObject(forKey: RecordingPermissionRepair.pendingRepairKey)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let token = terminateToken {
            SystemWorkspace.shared.removeObserver(token)
            terminateToken = nil
        }
        detector?.stop()
        frontmostPoller?.invalidate()
        frontmostPoller = nil
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

    private func refreshActivationPolicy() {
        let desired: NSApplication.ActivationPolicy = managedWindowCount > 0 ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        if desired == .regular {
            installMainMenuIfNeeded()
            NSApp.setActivationPolicy(.regular)
            // accessory→regular while already the active app: the system keeps
            // the previous app's menu bar until our activation state visibly
            // changes. Bounce activation — deactivate now, re-activate on a
            // later runloop turn — so the menu bar picks us up.
            NSApp.deactivate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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

    private func toggleRecording() async {
        guard !bridge.recordingStopInFlight else { return }
        if state.isRecording {
            await stopRecording(autoStopReason: nil)
        } else {
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

    private func startRecording() async {
        guard session == nil else { return }

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
            let session = RecordingSession(
                mic: MicCapture(),
                systemAudio: SystemAudioCapture(),
                destination: RecordingDestination(baseDirectory: prefs.destinationURL),
                transcriber: transcriber
            )
            self.session = session

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
            let preRoll = await preRollCapture?.promote() ?? []
            preRollCapture = nil
            try await session.start(at: startedAt, preRoll: preRoll)
            state.markStarted(at: startedAt)
            bridge.setActiveCaptureStatus(ActiveCaptureStatus(
                sourceState: .micAndSystemAudio,
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
            if await session.systemAudioFellBack {
                bridge.captureReadinessText = "Mic only; system audio needs permission"
                bridge.captureReadinessWarning = true
                bridge.updateActiveCaptureSource(.micOnly)
                if !hasShownMicOnlyNotice {
                    hasShownMicOnlyNotice = true
                    presentMicOnlyFallbackNotification()
                }
            }
        } catch {
            // session.start may have brought up mic / system-audio captures
            // BEFORE the throw. Best-effort stop so a partial start doesn't
            // leave the mic running with no controller (state would show Idle
            // but the macOS mic indicator would stay on).
            _ = try? await self.session?.stop()
            self.session = nil
            presentError(error)
            resetUI()
        }
    }

    private func stopRecording(autoStopReason: AutoStopController.StopReason?) async {
        guard !bridge.recordingStopInFlight else { return }
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
        // Hard cap on how long session.stop() can block. session.stop() runs
        // the post-stop transcribe finalize + full-WAV diarize through the
        // daemon. Either can hang (no timeout on HarcSTTClient.roundTrip yet).
        // Without this cap, the UI stays "Recording" forever and ⌥V can't
        // toggle off. The mic + system-audio captures are stopped synchronously
        // at the top of session.stop(), so the macOS mic indicator turns off
        // immediately even when finalize hangs.
        let stopResult: RecordingResult?
        do {
            stopResult = try await withThrowingTaskGroup(of: RecordingResult.self) { group in
                group.addTask { try await session.stop() }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw StopTimeoutError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch is StopTimeoutError {
            // session.stop() didn't return in time. Free the UI; the leaked
            // session keeps trying to finalize in the background. The cache
            // WAV at ~/Library/Caches/Harc/recordings/<uuid>.wav remains as
            // a recovery artifact even if it never makes it to the public
            // destination.
            FileHandle.standardError.write(Data(
                "harc: session.stop() exceeded 30s; freeing UI, finalize continues in background\n".utf8
            ))
            self.session = nil
            state.markIdle()
            bridge.setActiveCaptureStatus(nil)
            presentStopTimeoutRecovery()
            resetUI()
            return
        } catch {
            self.session = nil
            presentError(error)
            resetUI()
            return
        }
        guard let result = stopResult else {
            self.session = nil
            state.markIdle()
            resetUI()
            return
        }
        state.markStopped(wavURL: result.wavURL, txtURL: result.txtURL, jsonURL: result.jsonURL)
            let transcriptText = result.txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let startedAt = result.wavURL.startedAtFromHarcPath() ?? Date()
            let rec = Recording(
                wavPath: result.wavURL.path,
                txtPath: result.txtURL?.path,
                jsonPath: result.jsonURL?.path,
                startedAt: startedAt,
                endedAt: Date(),
                transcriptText: transcriptText
            )
            var savedID: Int64? = nil
            savedID = await persistStoppedRecording(rec)
            if let transcriptText, let store = self.store {
                Task.detached { [store] in
                    let entities = TitleSuggester.extractEntities(from: transcriptText)
                    let suggestion = entities.isEmpty ? nil : Array(entities.prefix(2)).joined(separator: ", ")
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
            runAutoPaste(for: rec, shiftHeld: shiftHeldAtStopTrigger || skipFromOptionClick)
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
            await enqueueAutoSummaryAfterStop(recordingID: savedID)
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
        previewTask?.cancel()
        previewTask = nil
        resetUI()
    }

    private func resetUI() {
        session = nil
        state.markIdle()
        bridge.setActiveCaptureStatus(nil)
    }

    private func presentStopTimeoutRecovery() {
        let cacheDirectory = RecordingDestination.cacheDirectory()
        bridge.trayState.showOutcome(
            title: "Recovery needed",
            outcome: .recoveryNeeded(detail: "Audio capture stopped, but finalization timed out. Use Recovery to import preserved cache files.")
        )
        bridge.showStopRecovery(StopRecoveryInfo(
            title: "Finalization is still running",
            message: "Audio capture stopped, but Harc timed out while finishing the transcript. Recovery files are kept in the cache and can be imported again.",
            cacheDirectoryPath: cacheDirectory.path
        ))
    }

    private func retryStopRecovery() async {
        guard let store else {
            openSettings()
            return
        }

        let cacheDirectory = RecordingDestination.cacheDirectory()
        bridge.showStopRecovery(StopRecoveryInfo(
            title: "Retrying recovery",
            message: "Checking cached recording files and importing anything complete enough to recover.",
            cacheDirectoryPath: cacheDirectory.path,
            isRecovering: true
        ))

        do {
            let queue = recoveryQueue ?? RecoveryQueue(fileURL: RecoveryQueue.defaultURL(), store: store)
            recoveryQueue = queue
            try await queue.scanCache(cacheDirectory: cacheDirectory, destinationDirectory: prefs.destinationURL)
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
                bridge.showStopRecovery(StopRecoveryInfo(
                    title: "Recovered \(recoveredCount) recording\(recoveredCount == 1 ? "" : "s")",
                    message: "Recovered audio was moved into your recordings folder and added to the Library.",
                    cacheDirectoryPath: cacheDirectory.path
                ))
                openLibrary()
            } else {
                bridge.showStopRecovery(StopRecoveryInfo(
                    title: "No recoverable files yet",
                    message: "Finalization may still be running. You can try again, reveal the cache, or restart Harc to retry recovery automatically.",
                    cacheDirectoryPath: cacheDirectory.path
                ))
            }
        } catch {
            bridge.showStopRecovery(StopRecoveryInfo(
                title: "Recovery failed",
                message: error.localizedDescription,
                cacheDirectoryPath: cacheDirectory.path
            ))
        }
    }

    private func recoverRecoveryArtifact(id: String) async {
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
            isRecordingInProgress: { [weak self] in self?.state.isRecording ?? false }
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

    private func openEditor(for recording: Recording) {
        if let existing = editorWindows[recording.wavPath] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let vm = await TranscriptEditorViewModel(recording: recording, store: store)
            let controller = TranscriptEditorWindowController(
                vm: vm,
                store: store,
                onClose: { [weak self] in
                    self?.editorWindows.removeValue(forKey: recording.wavPath)
                }
            )
            self.editorWindows[recording.wavPath] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            self.trackManagedWindow(controller.window)
            NSApp.activate(ignoringOtherApps: true)
        }
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
    func importMediaFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !state.isRecording, !dictationState.isActive else {
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
            let transcriptText = rec.txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
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
            bridge.preRollBankedSeconds = nil
            return
        }
        let banked = await capture.bankedSeconds
        bridge.preRollBankedSeconds = banked
    }

    /// Start or stop the idle pre-roll ring to match preferences.
    ///
    /// Never runs while recording: the session owns the mic then, and the ring
    /// has already handed its contents over. Called on launch, when the
    /// preference changes, and after a recording ends.
    func syncPreRollCapture() {
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
            bridge.preRollBankedSeconds = nil
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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        window.makeKeyAndOrderFront(nil)
        trackManagedWindow(window)
        NSApp.activate(ignoringOtherApps: true)
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
        guard !PermissionSnapshot.current().coreGrantsIntact else { return }

        // A reset deliberately revokes everything, so the repair path must
        // appear no matter how many times the re-offer has already run. This
        // used to be gated purely per-build, which meant the one flow that
        // reliably needs guidance — right after the user asked us to wipe
        // their grants — was the one flow that silently got none.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: RecordingPermissionRepair.pendingRepairKey) {
            defaults.removeObject(forKey: RecordingPermissionRepair.pendingRepairKey)
            showWelcome(markAsFirstRun: false)
            return
        }

        // Otherwise: core grants look broken without the user having asked
        // for it — the classic delete-and-reinstall or re-signed-build case,
        // where prefs survive but the TCC identity changed underneath them.
        // Offer once per build so healthy installs and deliberate decliners
        // aren't nagged.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        guard UserDefaults.standard.string(forKey: Self.welcomeReofferKey) != build else { return }
        showWelcome(markAsFirstRun: false)
    }

    static let welcomeReofferKey = "harc.welcomeReofferedForBuild"

    private func showWelcome(markAsFirstRun: Bool) {
        if let controller = welcomeWindow, let window = controller.window {
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Live models/permissions state for the "Set up" step. The bridge's
        // honest STT readiness (poller-owned) is mirrored in so the step
        // shows the real download/ready state.
        let setup = WelcomeSetupModel(prefs: prefs, modelStore: modelStore)
        welcomeSetupModel = setup
        setup.sttReady = bridge.sttReady
        setup.sttText = bridge.sttReadinessText
        bridge.$sttReady
            .receive(on: DispatchQueue.main)
            .assign(to: \.sttReady, on: setup)
            .store(in: &cancellables)
        bridge.$sttReadinessText
            .receive(on: DispatchQueue.main)
            .assign(to: \.sttText, on: setup)
            .store(in: &cancellables)
        setup.sttProgress = bridge.sttDownloadProgress
        bridge.$sttDownloadProgress
            .receive(on: DispatchQueue.main)
            .assign(to: \.sttProgress, on: setup)
            .store(in: &cancellables)

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
                // Closing the window counts as answering the re-offer. The
                // key is written here rather than at show time so a flow the
                // user never actually saw through doesn't burn their one
                // chance for this build.
                self?.markWelcomeReofferSpent()
            }
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        trackManagedWindow(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeWelcomeFlow(openLibraryAfterClose: Bool) {
        prefs.completeWelcomeFlow()
        markWelcomeReofferSpent()
        welcomeWindow?.close()
        welcomeWindow = nil
        welcomeSetupModel = nil
        if openLibraryAfterClose {
            openLibrary()
        }
    }

    private func markWelcomeReofferSpent() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        UserDefaults.standard.set(build, forKey: Self.welcomeReofferKey)
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
            onEdit: { [weak self] rec in self?.openEditor(for: rec) },
            onDelete: { [weak self] rec in self?.deleteRecording(recording: rec) },
            onImportFiles: { [weak self] urls in self?.importMediaFiles(urls) },
            onCancelImport: { [weak self] in self?.cancelImport() }
        )
        harcWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        trackManagedWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bootstrapStore() async {
        do {
            let store = try await RecordingStore.onDisk(url: uiTestDatabaseURL ?? RecordingStore.defaultURL())
            self.store = store
            let recoveryQueue = RecoveryQueue(fileURL: uiTestRecoveryQueueURL ?? RecoveryQueue.defaultURL(), store: store)
            self.recoveryQueue = recoveryQueue

            // Keep interrupted cache artifacts visible until the user chooses
            // Recover or Discard from the recovery inbox.
            try? await recoveryQueue.scanCache(
                cacheDirectory: RecordingDestination.cacheDirectory(),
                destinationDirectory: prefs.destinationURL
            )
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
        } catch {
            FileHandle.standardError.write(Data(
                "harc: store init failed: \(error.localizedDescription)\n".utf8
            ))
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

    var uiTestRootURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["HARC_UI_TEST_ROOT"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    var uiTestDatabaseURL: URL? {
        uiTestRootURL?.appendingPathComponent("HarcUITest.db")
    }

    var uiTestRecoveryQueueURL: URL? {
        uiTestRootURL?.appendingPathComponent("recovery.json")
    }

    func applyUITestConfigurationIfNeeded() {
        guard isUITesting, let root = uiTestRootURL else { return }
        let recordingsURL = root.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)

        prefs.destinationPath = recordingsURL.path
        prefs.autoSummarizeEnabled = false
        prefs.meetingDetectionEnabled = false
        prefs.postStopNotificationEnabled = false
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
            preRollBankedSeconds: bridge.preRollBankedSeconds,
            onClearPreRoll: bridge.onClearPreRoll,
            onKeepRecording: bridge.onKeepRecording,
            onStopNow: bridge.onStopNow,
            onOpenSettings: bridge.onOpenSettings,
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
