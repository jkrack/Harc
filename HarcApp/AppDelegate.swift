import AppKit
import Combine
import SwiftUI
import UserNotifications
import HarcAudio
import HarcClient
import HarcExport
import HarcMeetingDetect
import HarcModels
import HarcStore
import HarcUI
import HarcSummarize
import HarcVoiceprint
import IOKit.ps
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, MeetingDetector.Delegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var session: RecordingSession?
    private let launcher = DaemonLauncher()
    private let state = RecordingState()
    let prefs = HarcPreferences.shared
    private let autoStop = AutoStopController()
    private var autoStopPhaseObserver: AnyCancellable?
    private var autoStopConfigObserver: AnyCancellable?
    private var stoppedFlashTask: Task<Void, Never>?
    private let modelManager = ModelManager()
    lazy var modelStore = ModelManagerStore(manager: modelManager)
    private var summarizerService: SummarizerService?
    private var summarizationQueue: SummarizationQueue?
    private var summarizationQueueStore: SummarizationQueueStore?
    private var memoryObservation: SummarizerService.MemoryPressureObservation?
    private let postProcessingState = RecordingPostProcessingState()
    /// Retained so runIdentifySpeakers can call diarize() outside of a recording session.
    private var sttClient: HarcSTTClient?
    private var speakerReIDService: SpeakerReIDService?
    private var store: RecordingStore?
    private var recordingsVM: RecordingsViewModel?
    private var editorWindows: [String: TranscriptEditorWindowController] = [:]
    private var harcWindow: HarcWindowController?
    private var previewTask: Task<Void, Never>?
    private var prefsObserver: AnyCancellable?
    private var menuBarTicker: Timer?
    private let menuBarFlash = MenuBarFlash()
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
        updateMenuBarIcon(on: item)

        if let button = item.button {
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self

        pop.contentSize = NSSize(width: 400, height: 560)

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
        AutoStopNotification.registerCategory()
        setupMeetingDetector()
        registerTerminateWatchdog()
        observeMeetingDetectionPref()
        observeMeetingStateForPulse()
        observePostProcessingState()
        applyAutoStopConfigFromPrefs()
        observeAutoStopPrefs()
        observeAutoStopPhase()
        observeAutoStopFFTBins()
        autoStop.onAutoStop = { [weak self] reason in
            Task { @MainActor in
                await self?.stopRecording(autoStopReason: reason)
            }
        }

        // Seed install state from disk. Safe to call before any UI is shown;
        // the actor bootstrap is cheap (just reads a handful of dotfiles).
        Task { await modelManager.bootstrap() }
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
            Task { await stopRecording(autoStopReason: nil) }
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
        if session != nil {
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingFromMenu), keyEquivalent: ".")
            stop.keyEquivalentModifierMask = [.command]
            menu.addItem(stop)
            menu.addItem(NSMenuItem.separator())
        }
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

    @objc private func stopRecordingFromMenu() {
        Task { await stopRecording(autoStopReason: nil) }
    }

    private func toggleRecording() async {
        if state.isRecording {
            await stopRecording(autoStopReason: nil)
        } else {
            await startRecording()
        }
    }

    private func applyAutoStopConfigFromPrefs() {
        autoStop.config = .from(
            silenceEnabled: prefs.autoStopEnabled,
            silenceThresholdMinutes: prefs.silenceThresholdMinutes,
            hardCapEnabled: prefs.hardCapEnabled,
            hardCapMinutes: prefs.hardCapMinutes
        )
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
            .sink { [weak self] _ in
                self?.updateMenuBarIcon()
            }
    }

    /// Per-tick FFT-driven icon refresh. Only fires while the bars state
    /// applies (recording / warning); in any other state the icon is a static
    /// symbol set by `updateMenuBarIcon()`.
    private var autoStopFFTObserver: AnyCancellable?
    private func observeAutoStopFFTBins() {
        autoStopFFTObserver = autoStop.$fftBins
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bins in
                self?.redrawMenuBarBars(bins)
            }
    }

    private func redrawMenuBarBars(_ bins: [Float]) {
        guard let button = statusItem?.button else { return }
        let state = currentMenuBarState()
        guard state == .recording || state == .warning else { return }
        let label = state == .warning ? "Harc — about to auto-stop" : "Harc — recording"
        let image = MenuBarBarsIcon.image(for: bins)
        // Belt-and-braces: if we somehow got a zero-sized image back, keep the
        // current button image rather than replacing it with something invisible.
        if image.size.width <= 0 || image.size.height <= 0 { return }
        image.accessibilityDescription = label
        button.image = image
    }

    private func startRecording() async {
        guard session == nil else { return }

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
        stoppedFlashTask?.cancel()
        stoppedFlashTask = nil
        let startedAt = Date()

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
                    }
                }
            }

            try await session.start(at: startedAt)
            state.markStarted(at: startedAt)
            updateMenuBarIcon()
            autoStop.begin(
                session: session,
                startedAt: startedAt
            )
        } catch {
            self.session = nil
            presentError(error)
            resetUI()
        }
    }

    private func stopRecording(autoStopReason: AutoStopController.StopReason?) async {
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
            await enqueueAutoSummaryAfterStop(recordingID: savedID)
            autoStop.end(autoStopReason: autoStopReason)
            if let autoStopReason, prefs.postStopNotificationEnabled {
                AutoStopNotification.post(
                    reason: autoStopReason,
                    duration: rec.endedAt.map { $0.timeIntervalSince(rec.startedAt) },
                    thresholdMinutes: prefs.silenceThresholdMinutes,
                    previewText: transcriptText
                )
            }
            if autoStopReason != nil {
                flashStoppedIcon()
            }
        } catch {
            presentError(error)
            autoStop.end()
        }
        previewTask?.cancel()
        previewTask = nil
        resetUI()
    }

    private func resetUI() {
        session = nil
        state.markIdle()
        updateMenuBarIcon()
    }

    /// Menu bar icon state — per the Auto-Stop Safety UX design:
    /// `idle` · waveform (dim),
    /// `recording` · waveform + red dot,
    /// `warning` · waveform + amber badge (about to auto-stop),
    /// `stoppedFlash` · green checkmark shown for ~3 s after an auto-stop.
    private enum MenuBarIconState { case idle, recording, warning, stoppedFlash }

    private func currentMenuBarState() -> MenuBarIconState {
        if stoppedFlashTask != nil { return .stoppedFlash }
        if state.isRecording {
            if case .warning = autoStop.phase { return .warning }
            return .recording
        }
        return .idle
    }

    private func updateMenuBarIcon(on item: NSStatusItem? = nil) {
        let target = item ?? statusItem
        guard let button = target?.button else { return }
        let iconState = currentMenuBarState()
        let label: String
        let image: NSImage?
        let tint: NSColor?

        switch iconState {
        case .idle:
            label = "Harc"
            // Idle uses the asset/symbol that was shipping before the FFT
            // work — the dynamic bars template only runs while recording so
            // a rendering bug in it can't hide the status item.
            if let asset = NSImage(named: "MenuBarIcon") {
                asset.isTemplate = true
                asset.accessibilityDescription = label
                image = asset
            } else {
                image = NSImage(systemSymbolName: "waveform", accessibilityDescription: label)
            }
            tint = nil
        case .recording:
            label = "Harc — recording"
            let bars = MenuBarBarsIcon.image(for: autoStop.fftBins)
            bars.accessibilityDescription = label
            image = bars
            tint = nil
        case .warning:
            label = "Harc — about to auto-stop"
            let bars = MenuBarBarsIcon.image(for: autoStop.fftBins)
            bars.accessibilityDescription = label
            image = bars
            tint = .systemOrange
        case .stoppedFlash:
            label = "Harc — stopped"
            image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: label)
            tint = .systemGreen
        }

        button.image = image
        button.contentTintColor = tint

        if iconState == .recording || iconState == .warning {
            updateMenuBarElapsed()
            if menuBarTicker == nil {
                menuBarTicker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateMenuBarElapsed() }
                }
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

    /// Flash a green check in the menu bar for ~3 s, then fall back to the
    /// resolved icon state. Used after an auto-stop so the user has a visible
    /// confirmation even if the popover isn't open.
    private func flashStoppedIcon() {
        stoppedFlashTask?.cancel()
        stoppedFlashTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateMenuBarIcon()
            try? await Task.sleep(for: .seconds(3))
            self.stoppedFlashTask = nil
            self.updateMenuBarIcon()
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

    /// Overlays a spinner glyph while diarization is in-flight, and a brief
    /// tooltip when it fails. Only fires when not recording — the recording
    /// indicator takes visual priority while a session is active.
    private func observePostProcessingState() {
        postProcessingState.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                guard let self, !self.state.isRecording else { return }
                switch entry?.phase {
                case .identifying:
                    self.statusItem?.button?.image = NSImage(
                        systemSymbolName: "ellipsis.circle",
                        accessibilityDescription: "Identifying speakers…"
                    )
                    self.statusItem?.button?.toolTip = "Identifying speakers…"
                case .failed:
                    self.updateMenuBarIcon()
                    self.statusItem?.button?.toolTip = "Couldn't identify speakers — open recording to retry"
                case .done, .idle, nil:
                    self.updateMenuBarIcon()
                    self.statusItem?.button?.toolTip = nil
                }
            }
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
        button.contentTintColor = pulseOn ? NSColor(Color.purple) : nil
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
        // TODO(Phase 4.3): navigate HarcWindowRootView to the selected recording.
        // Detail is now shown inline in HarcWindowRootView; opening the window is
        // sufficient until HarcWindowRootView gains a selection API.
        _ = recording
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
    /// and the popover post-stop tray. Runs a fresh full-WAV diarize pass against
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

    private func persistStoppedRecording(_ recording: Recording) async -> Int64? {
        guard let store = self.store else {
            presentRecordingPersistenceFailure(
                recording: recording,
                errorDescription: "The recording database is not available."
            )
            return nil
        }

        do {
            return try await store.upsert(recording).id
        } catch {
            FileHandle.standardError.write(Data(
                "harc: failed to persist recording \(recording.wavPath): \(error.localizedDescription)\n".utf8
            ))

            if let recoveredID = await recoverFinalizedRecording(recording, store: store) {
                FileHandle.standardError.write(Data(
                    "harc: recovered recording row after persistence failure: \(recording.wavPath)\n".utf8
                ))
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
            self.updateMenuBarIcon()
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
                // Re-prompt every paste failure: the prompt itself notes that
                // the transcript is already on the clipboard, so re-showing it
                // is informative rather than annoying. A user who chose
                // "Later" once may want to act the next time auto-paste
                // silently failed.
                presentAccessibilityPrompt()
            } catch {
                menuBarFlash.flashFailure(on: statusItem, restore: restore)
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLibrary() {
        if let existing = harcWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store, let reIDService = speakerReIDService,
              let queueStore = summarizationQueueStore else { return }
        let libraryVM = LibraryViewModel(store: store)
        let controller = HarcWindowController(
            libraryVM: libraryVM,
            recordingState: state,
            store: store,
            reIDService: reIDService,
            prefs: prefs,
            postProcessingState: postProcessingState,
            queueStore: queueStore,
            modelStore: modelStore,
            onEdit: { [weak self] rec in self?.openEditor(for: rec) },
            onExport: { rec in
                // TODO Task 3.5: wire export sheet once ExportService gains a panel entry-point.
                _ = rec
            },
            onDelete: { [weak self] rec in self?.deleteRecording(recording: rec) }
        )
        harcWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        trackManagedWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bootstrapStore() async {
        do {
            let store = try await RecordingStore.onDisk()
            self.store = store

            // Recover recordings that were interrupted before RecordingSession
            // could finalize and move them out of the cache directory.
            let recovery = RecordingCacheRecovery(
                cacheDirectory: RecordingDestination.cacheDirectory(),
                destinationDirectory: prefs.destinationURL,
                store: store
            )
            if let recovered = try? await recovery.recoverAll(), recovered.recovered > 0 {
                FileHandle.standardError.write(Data(
                    "harc: recovered \(recovered.recovered) interrupted recording(s)\n".utf8
                ))
            }

            // Ingest existing filesystem recordings.
            let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
            _ = try? await ingestor.ingestAll()

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
            // lifetime; queue survives popover re-renders.
            let coordinator = BackgroundWorkCoordinator()
            let service = SummarizerService(loader: SummarizerService.defaultLoader)
            self.memoryObservation = service.startObservingMemoryPressure()
            let queue = SummarizationQueue(coordinator: coordinator, perform: { [weak self] id in
                guard let self else { return }
                try await self.performSummarization(id: id)
            })
            self.summarizerService = service
            self.summarizationQueue = queue
            self.summarizationQueueStore = await SummarizationQueueStore(queue: queue)

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

        let result = try await service.summarize(
            transcript: promptTranscript,
            modelID: modelID,
            modelDirectory: directory,
            budgetWords: budgetWords
        )

        let wordCount = session.joinedText.split(whereSeparator: { $0.isWhitespace }).count

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

    private func refreshPopoverRoot() async {
        guard let vm = recordingsVM,
              let pop = popover,
              let queueStore = summarizationQueueStore else { return }
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
            },
            onOpenLibraryAndSearch: { [weak self] in
                self?.openLibrary()
                // Defer one runloop tick so SwiftUI finishes mounting the
                // search field on first open. Existing-window case is also
                // safe — the field is already mounted and will receive
                // the notification immediately.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .harcLibraryFocusSearch, object: nil
                    )
                }
            },
            onResumeAutoStopped: { [weak self] in
                guard let self else { return }
                self.autoStop.resetPostStop()
                if !self.state.isRecording {
                    Task { await self.startRecording() }
                }
            },
            onRetryDiarize: { [weak self] recordingID in
                self?.runIdentifySpeakers(recordingID: recordingID)
            }
        )
        .environmentObject(state)
        .environmentObject(vm)
        .environmentObject(prefs)
        .environmentObject(autoStop)
        .environmentObject(modelStore)
        .environmentObject(queueStore)
        .environmentObject(postProcessingState)

        pop.contentViewController = NSHostingController(rootView: root)
    }
}
