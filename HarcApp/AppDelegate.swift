import AppKit
import Combine
import SwiftUI
import UserNotifications
import HarcAudio
import HarcClient
import HarcExport
import HarcMeetingDetect
import HarcStore
import HarcUI
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, MeetingDetector.Delegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var session: RecordingSession?
    private let launcher = DaemonLauncher()
    private let state = RecordingState()
    private let prefs = HarcPreferences.shared
    private var settingsWindow: SettingsWindowController?
    private var store: RecordingStore?
    private var recordingsVM: RecordingsViewModel?
    private var detailWindows: [String: TranscriptionDetailWindowController] = [:]
    private var editorWindows: [String: TranscriptEditorWindowController] = [:]
    private var libraryWindow: LibraryWindowController?
    private var libraryVM: LibraryViewModel?
    private var previewTask: Task<Void, Never>?
    private var prefsObserver: AnyCancellable?
    private var menuBarTicker: Timer?
    private let menuBarFlash = MenuBarFlash()
    private var accessibilityPromptShown = false
    private var pendingSkipPaste = false

    private let meetingState = MeetingDetectionState()
    private let notificationPresenter = MeetingNotificationPresenter()
    private var detector: MeetingDetector?
    private var terminateToken: NSObjectProtocol?
    private var pulseTimer: Timer?
    private var pulseOn = false
    private var cancellables: Set<AnyCancellable> = []
    private var managedWindowCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak self] in
            await self?.bootstrapStore()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(recording: false, on: item)

        if let button = item.button {
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self

        pop.contentSize = NSSize(width: 400, height: 400)

        self.statusItem = item
        self.popover = pop

        // Pre-launch the daemon in the background so ⌘R doesn't have to wait for
        // model load. Failure is logged and retried lazily on next recording start.
        Task { [launcher] in
            do {
                _ = try await launcher.ensureRunning()
            } catch {
                FileHandle.standardError.write(Data(
                    "harc: background daemon launch failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            Task { await self?.toggleRecording() }
        }

        notificationPresenter.registerCategory()
        UNUserNotificationCenter.current().delegate = self
        setupMeetingDetector()
        registerTerminateWatchdog()
        observeMeetingDetectionPref()
        observeMeetingStateForPulse()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let token = terminateToken {
            SystemWorkspace.shared.removeObserver(token)
            terminateToken = nil
        }
        detector?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemMenu()
            return
        }
        // ⌥-left-click while recording → stop without auto-paste.
        if state.isRecording,
           NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            pendingSkipPaste = true
            Task { await stopRecording() }
            return
        }
        togglePopover(sender)
    }

    private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showStatusItemMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let library = NSMenuItem(title: "Open Library…", action: #selector(openLibrary), keyEquivalent: "l")
        library.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(library)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Harc",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        // Temporarily attach the menu so right-click shows it; clear it after
        // so subsequent left-clicks still invoke handleStatusItemClick.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func toggleRecording() async {
        if state.isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard session == nil else { return }

        meetingState.clearAll()
        updateMenuBarIcon(recording: true)
        state.markStarted(at: Date())

        do {
            _ = try await launcher.ensureRunning()
            let client = HarcSTTClient()
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: prefs.diarize,
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
                    }
                }
            }

            try await session.start(at: state.recordingStartedAt ?? Date())
        } catch {
            presentError(error)
            resetUI()
        }
    }

    private func stopRecording() async {
        // Sample modifier state NOW, before any await — by the time session.stop()
        // resolves (seconds later), the user may have released Shift. Also consume
        // the ⌥-click escape-hatch flag unconditionally so it can't leak into a
        // subsequent stop if session.stop() throws.
        let shiftHeldAtStopTrigger = NSEvent.modifierFlags.contains(.shift)
        let skipFromOptionClick = pendingSkipPaste
        pendingSkipPaste = false
        guard let session else { return }
        do {
            let result = try await session.stop()
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
            if let store = self.store {
                _ = try? await store.upsert(rec)
            }
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
            runAutoPaste(for: rec, shiftHeld: shiftHeldAtStopTrigger || skipFromOptionClick)
        } catch {
            presentError(error)
        }
        previewTask?.cancel()
        previewTask = nil
        resetUI()
    }

    private func resetUI() {
        session = nil
        updateMenuBarIcon(recording: false)
    }

    private func updateMenuBarIcon(recording: Bool, on item: NSStatusItem? = nil) {
        let target = item ?? statusItem
        guard let button = target?.button else { return }
        let label = recording ? "Harc — recording" : "Harc"
        let image: NSImage?
        if recording {
            image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: label)
        } else if let asset = NSImage(named: "MenuBarIcon") {
            asset.isTemplate = true
            asset.accessibilityDescription = label
            image = asset
        } else {
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: label)
        }
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
        if recording {
            updateMenuBarElapsed()
            menuBarTicker?.invalidate()
            menuBarTicker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMenuBarElapsed() }
            }
        } else {
            menuBarTicker?.invalidate()
            menuBarTicker = nil
            // Reserve the elapsed-label width with a transparent placeholder so
            // the status item stays a constant width across idle → recording.
            // Otherwise the macOS mic indicator + the " 00:00" label appearing
            // at once yanks the popover anchor left the moment recording starts.
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize(for: .small),
                weight: .regular
            )
            button.title = ""
            button.attributedTitle = NSAttributedString(
                string: " 00:00",
                attributes: [.font: font, .foregroundColor: NSColor.clear]
            )
            applyPulse()
        }
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
            .sink { [weak self] _ in self?.applyPulse() }
            .store(in: &cancellables)
    }

    private func applyPulse() {
        guard let button = statusItem?.button else { return }
        guard meetingState.isPulsing, !state.isRecording else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseOn = false
            if !state.isRecording { button.contentTintColor = nil }
            return
        }
        if pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickPulse() }
            }
        }
    }

    private func tickPulse() {
        guard let button = statusItem?.button else { return }
        guard meetingState.isPulsing, !state.isRecording else {
            applyPulse()
            return
        }
        pulseOn.toggle()
        button.contentTintColor = pulseOn ? NSColor(HarcDesign.tertiary) : nil
    }

    private func updateMenuBarElapsed() {
        guard let button = statusItem?.button, let start = state.recordingStartedAt else { return }
        let total = Int(Date().timeIntervalSince(start))
        // Pad minutes to 2 digits AND use a monospaced-digit font so the title's
        // pixel width is constant from 00:00 through 99:59. Without both, the
        // variableLength status item reflows every tick and drags the anchored
        // popover with it. (Beyond 99:59 the title grows once more — acceptable.)
        let m = min(99, total / 60)
        let s = total % 60
        let text = String(format: " %02d:%02d", m, s)
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small),
            weight: .regular
        )
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
    }

private func openDetail(for recording: Recording) {
        if let existing = detailWindows[recording.wavPath] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = TranscriptionDetailWindowController(
            recording: recording,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(recording: recording)
            },
            onRename: { [weak self] newTitle in
                guard let id = recording.id else { return }
                Task { try? await self?.store?.rename(id: id, title: newTitle) }
            },
            onSpeakerNamesChanged: { [weak self] names in
                guard let id = recording.id else { return }
                Task { try? await self?.store?.updateSpeakerNames(id: id, names: names) }
            }
        )
        detailWindows[recording.wavPath] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        trackManagedWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
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

    private func deleteRecording(recording: Recording) {
        guard let id = recording.id, let vm = recordingsVM else { return }
        Task {
            try? await vm.delete(id: id)
        }
        // Also trash the files on disk.
        let fm = FileManager.default
        let paths = [recording.wavPath, recording.txtPath, recording.jsonPath].compactMap { $0 }
        for path in paths {
            try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        detailWindows[recording.wavPath]?.close()
        detailWindows.removeValue(forKey: recording.wavPath)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording error"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @MainActor
    private func runAutoPaste(for rec: Recording, shiftHeld: Bool) {
        let blob = ExportService.promptString(for: rec)

        // Per spec §3: clipboard always holds the prompt blob, regardless
        // of decision. copyAndPaste (below, on the .paste branch) re-writes
        // the same bytes — harmless duplication.
        FrontmostAppPaster.copyOnly(blob)

        let decision = AutoPasteGuard.decide(
            enabled: prefs.autoPasteEnabled,
            shiftHeld: shiftHeld,
            frontmostBundleID: FrontmostAppPaster.frontmostBundleID()
        )

        guard let statusItem else { return }
        let restore: @MainActor () -> Void = { [weak self] in
            guard let self, !self.state.isRecording else { return }
            self.updateMenuBarIcon(recording: false)
        }

        switch decision {
        case .skipDisabled, .skipModifierHeld:
            return
        case .skipUnsafeTarget(let id):
            menuBarFlash.flashSkipped(
                on: statusItem,
                tooltip: "Auto-paste skipped — \(appDisplayName(for: id))",
                restore: restore
            )
        case .paste:
            do {
                try FrontmostAppPaster.copyAndPaste(blob)
                menuBarFlash.flashSuccess(on: statusItem, restore: restore)
            } catch FrontmostAppPaster.PasteError.accessibilityDenied {
                menuBarFlash.flashFailure(on: statusItem, restore: restore)
                if !accessibilityPromptShown {
                    accessibilityPromptShown = true
                    presentAccessibilityPrompt()
                }
            } catch {
                menuBarFlash.flashFailure(on: statusItem, restore: restore)
            }
        }
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

    @objc private func openSettings() {
        if let existing = settingsWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsWindowController(prefs: prefs)
        settingsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        trackManagedWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLibrary() {
        if let existing = libraryWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store else { return }
        let vm = LibraryViewModel(store: store)
        libraryVM = vm
        let controller = LibraryWindowController(
            vm: vm,
            onOpen: { [weak self] rec in self?.openDetail(for: rec) },
            onOpenInEditor: { [weak self] rec in self?.openEditor(for: rec) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        libraryWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        trackManagedWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bootstrapStore() async {
        do {
            let store = try await RecordingStore.onDisk()
            self.store = store

            // Ingest existing filesystem recordings.
            let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
            _ = try? await ingestor.ingestAll()

            let vm = RecordingsViewModel(store: store)
            vm.start()
            self.recordingsVM = vm

            observeDestinationChanges()

            // Mount into SwiftUI environment.
            await refreshPopoverRoot()
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
        Task { @MainActor in
            if let bundleID {
                self.meetingState.clear(bundleID: bundleID)
                self.detector?.markHandled(bundleID: bundleID)
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

    private func refreshPopoverRoot() async {
        guard let vm = recordingsVM, let pop = popover else { return }
        let root = PopoverRootView(
            onToggle: { [weak self] in
                Task { await self?.toggleRecording() }
            },
            onOpen: { [weak self] rec in
                self?.openDetail(for: rec)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onOpenLibrary: { [weak self] in
                self?.openLibrary()
            }
        )
        .environmentObject(state)
        .environmentObject(vm)
        .environmentObject(prefs)

        pop.contentViewController = NSHostingController(rootView: root)
    }
}
