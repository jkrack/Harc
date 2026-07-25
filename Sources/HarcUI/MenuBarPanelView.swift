import SwiftUI
import AppKit
import KeyboardShortcuts
import HarcCore
import HarcStore

/// Slim MenuBarExtra panel: recording state + level bars + Start/Stop + Open + post-stop tray.
/// Replaces the 520-line PopoverRootView.
public struct MenuBarPanelView: View {
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var trayState: PostStopTrayState
    let amplitudeHistory: [Float]
    let onStartStop: () -> Void
    let onOpenWindow: () -> Void
    let onCopy: () -> Void
    let onPasteIntoFrontmost: () -> Void
    let onOpenLastRecording: () -> Void
    let frontmostAppName: String?
    let frontmostPasteDenied: Bool
    let pasteStatusMessage: String?
    let autoStopPhase: AutoStopController.Phase
    let autoStopWarningSeconds: Int
    let autoStopThresholdMinutes: Int
    let autoStopMicDb: Float
    let autoStopSystemDb: Float
    let autoStopLastDurationText: String?
    let stopRecovery: StopRecoveryInfo?
    let activeCaptureStatus: ActiveCaptureStatus?
    /// State of the idle pre-roll ring, or nil when the feature is off.
    /// Non-nil means Harc is holding the mic open while it sits idle — or
    /// meant to and couldn't, which the row has to say out loud.
    let preRollStatus: PreRollStatus?
    let onClearPreRoll: (() -> Void)?
    let onKeepRecording: () -> Void
    let onStopNow: () -> Void
    let onOpenSettings: () -> Void
    let onRevealStopRecovery: () -> Void
    let onRetryStopRecovery: () -> Void
    let onDismissStopRecovery: () -> Void
    let destinationReady: Bool
    let destinationPath: String
    let captureReadinessText: String
    let captureReadinessWarning: Bool
    let sttReadinessText: String
    let sttReady: Bool
    let summarizerReadinessText: String
    let summarizerReady: Bool
    let summarizerInstalled: Bool
    let speakerIDReadinessText: String
    let speakerIDReady: Bool
    let notificationsReadinessText: String
    let notificationsReady: Bool
    let accessibilityReadinessText: String
    let accessibilityReady: Bool
    let recoveryArtifacts: [RecoveryArtifact]
    let onRecoverRecoveryArtifact: (String) -> Void
    let onRevealRecoveryArtifact: (String) -> Void
    let onDiscardRecoveryArtifact: (String) -> Void
    let dictationActive: Bool
    let dictationStatusText: String?
    let onStartDictation: (() -> Void)?
    let onStopDictation: (() -> Void)?
    let onCancelDictation: (() -> Void)?
    let dictationModes: [DictationMode]
    let activeDictationModeID: String?
    let onSelectDictationMode: ((String) -> Void)?
    let dictationHistory: [DictationHistoryEntry]
    let onCopyDictationHistoryEntry: ((DictationHistoryEntry) -> Void)?
    let onClearDictationHistory: (() -> Void)?
    let onOpenDictationHistory: (() -> Void)?
    let availableUpdate: AvailableUpdate?
    /// Hand the click off to Sparkle's install flow; nil falls back to
    /// opening the release page in the browser.
    let onInstallUpdate: (() -> Void)?

    @State private var elapsedText: String = "0:00"
    @State private var ticker: Timer?
    @State private var modePickerHovering = false
    @State private var readinessExpanded = false
    @State private var readinessSummaryHovering = false

    public init(
        recordingState: RecordingState,
        trayState: PostStopTrayState,
        amplitudeHistory: [Float] = [],
        onStartStop: @escaping () -> Void,
        onOpenWindow: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onPasteIntoFrontmost: @escaping () -> Void,
        onOpenLastRecording: @escaping () -> Void,
        frontmostAppName: String?,
        frontmostPasteDenied: Bool = false,
        pasteStatusMessage: String? = nil,
        autoStopPhase: AutoStopController.Phase = .idle,
        autoStopWarningSeconds: Int = AutoStopController.Config.defaults.warningSeconds,
        autoStopThresholdMinutes: Int = 5,
        autoStopMicDb: Float = -.infinity,
        autoStopSystemDb: Float = -.infinity,
        autoStopLastDurationText: String? = nil,
        stopRecovery: StopRecoveryInfo? = nil,
        activeCaptureStatus: ActiveCaptureStatus? = nil,
        preRollStatus: PreRollStatus? = nil,
        onClearPreRoll: (() -> Void)? = nil,
        onKeepRecording: @escaping () -> Void = {},
        onStopNow: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onRevealStopRecovery: @escaping () -> Void = {},
        onRetryStopRecovery: @escaping () -> Void = {},
        onDismissStopRecovery: @escaping () -> Void = {},
        destinationReady: Bool = true,
        destinationPath: String = "",
        captureReadinessText: String = "Mic + system audio",
        captureReadinessWarning: Bool = false,
        sttReadinessText: String = "Local STT ready",
        sttReady: Bool = true,
        summarizerReadinessText: String = "Summary unavailable",
        summarizerReady: Bool = false,
        summarizerInstalled: Bool = true,
        speakerIDReadinessText: String = "Speaker ID ready",
        speakerIDReady: Bool = true,
        notificationsReadinessText: String = "Notifications off",
        notificationsReady: Bool = false,
        accessibilityReadinessText: String = "Paste permission unknown",
        accessibilityReady: Bool = false,
        recoveryArtifacts: [RecoveryArtifact] = [],
        onRecoverRecoveryArtifact: @escaping (String) -> Void = { _ in },
        onRevealRecoveryArtifact: @escaping (String) -> Void = { _ in },
        onDiscardRecoveryArtifact: @escaping (String) -> Void = { _ in },
        dictationActive: Bool = false,
        dictationStatusText: String? = nil,
        onStartDictation: (() -> Void)? = nil,
        onStopDictation: (() -> Void)? = nil,
        onCancelDictation: (() -> Void)? = nil,
        dictationModes: [DictationMode] = [],
        activeDictationModeID: String? = nil,
        onSelectDictationMode: ((String) -> Void)? = nil,
        dictationHistory: [DictationHistoryEntry] = [],
        onCopyDictationHistoryEntry: ((DictationHistoryEntry) -> Void)? = nil,
        onClearDictationHistory: (() -> Void)? = nil,
        onOpenDictationHistory: (() -> Void)? = nil,
        availableUpdate: AvailableUpdate? = nil,
        onInstallUpdate: (() -> Void)? = nil
    ) {
        self.recordingState = recordingState
        self.trayState = trayState
        self.amplitudeHistory = amplitudeHistory
        self.onStartStop = onStartStop
        self.onOpenWindow = onOpenWindow
        self.onCopy = onCopy
        self.onPasteIntoFrontmost = onPasteIntoFrontmost
        self.onOpenLastRecording = onOpenLastRecording
        self.frontmostAppName = frontmostAppName
        self.frontmostPasteDenied = frontmostPasteDenied
        self.pasteStatusMessage = pasteStatusMessage
        self.autoStopPhase = autoStopPhase
        self.autoStopWarningSeconds = autoStopWarningSeconds
        self.autoStopThresholdMinutes = autoStopThresholdMinutes
        self.autoStopMicDb = autoStopMicDb
        self.autoStopSystemDb = autoStopSystemDb
        self.autoStopLastDurationText = autoStopLastDurationText
        self.stopRecovery = stopRecovery
        self.activeCaptureStatus = activeCaptureStatus
        self.preRollStatus = preRollStatus
        self.onClearPreRoll = onClearPreRoll
        self.onKeepRecording = onKeepRecording
        self.onStopNow = onStopNow
        self.onOpenSettings = onOpenSettings
        self.onRevealStopRecovery = onRevealStopRecovery
        self.onRetryStopRecovery = onRetryStopRecovery
        self.onDismissStopRecovery = onDismissStopRecovery
        self.destinationReady = destinationReady
        self.destinationPath = destinationPath
        self.captureReadinessText = captureReadinessText
        self.captureReadinessWarning = captureReadinessWarning
        self.sttReadinessText = sttReadinessText
        self.sttReady = sttReady
        self.summarizerReadinessText = summarizerReadinessText
        self.summarizerReady = summarizerReady
        self.summarizerInstalled = summarizerInstalled
        self.speakerIDReadinessText = speakerIDReadinessText
        self.speakerIDReady = speakerIDReady
        self.notificationsReadinessText = notificationsReadinessText
        self.notificationsReady = notificationsReady
        self.accessibilityReadinessText = accessibilityReadinessText
        self.accessibilityReady = accessibilityReady
        self.recoveryArtifacts = recoveryArtifacts
        self.onRecoverRecoveryArtifact = onRecoverRecoveryArtifact
        self.onRevealRecoveryArtifact = onRevealRecoveryArtifact
        self.onDiscardRecoveryArtifact = onDiscardRecoveryArtifact
        self.dictationActive = dictationActive
        self.dictationStatusText = dictationStatusText
        self.onStartDictation = onStartDictation
        self.onStopDictation = onStopDictation
        self.onCancelDictation = onCancelDictation
        self.dictationModes = dictationModes
        self.activeDictationModeID = activeDictationModeID
        self.onSelectDictationMode = onSelectDictationMode
        self.dictationHistory = dictationHistory
        self.onCopyDictationHistoryEntry = onCopyDictationHistoryEntry
        self.onClearDictationHistory = onClearDictationHistory
        self.onOpenDictationHistory = onOpenDictationHistory
        self.availableUpdate = availableUpdate
        self.onInstallUpdate = onInstallUpdate
    }

    /// The panel's two jobs, given the panel's two biggest targets:
    /// equal-width Record/Stop and Dictate buttons.
    private var primaryControls: some View {
        HStack(spacing: 8) {
            Button {
                onStartStop()
            } label: {
                Label(recordingState.isRecording ? "Stop" : "Record",
                      systemImage: recordingState.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(recordingState.isRecording ? HarcBrand.live : .accentColor)
            .controlSize(.large)

            if let onStartDictation {
                Button {
                    onStartDictation()
                } label: {
                    Label("Dictate", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(recordingState.isRecording || dictationActive)
            }
        }
    }

    /// Live dictation status: shown for any non-idle phase — including the
    /// done/error afterglow, which isn't "active".
    private var dictationStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(dictationActive ? HarcBrand.live : .secondary)
            Text(dictationStatusText ?? "Dictation")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if dictationActive {
                if let onCancelDictation {
                    Button("Cancel") { onCancelDictation() }
                        .buttonStyle(.bordered)
                }
                if let onStopDictation {
                    Button("Stop") { onStopDictation() }
                        .buttonStyle(.borderedProminent)
                        .tint(HarcBrand.live)
                }
            }
        }
        .frame(minHeight: 28)
    }

    /// Idle secondary row: library, dictation mode, and recent history —
    /// each with a full-size hover-highlighted target.
    private var secondaryControlsRow: some View {
        HStack(spacing: 6) {
            MenuPanelRowButton(
                icon: "books.vertical",
                title: "Library",
                detail: "⌘L"
            ) {
                onOpenWindow()
            }
            .keyboardShortcut("l", modifiers: .command)
            .frame(maxWidth: .infinity)

            if let onSelectDictationMode, !dictationModes.isEmpty {
                dictationModePicker(onSelectDictationMode)
            }
            if let onCopyDictationHistoryEntry, !dictationHistory.isEmpty {
                dictationHistoryMenu(onCopyDictationHistoryEntry)
            }
        }
    }

    private func dictationModePicker(_ onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(dictationModes) { mode in
                Button {
                    onSelect(mode.id)
                } label: {
                    if mode.id == activeDictationModeID {
                        Label(DictationHUDView.menuTitle(for: mode), systemImage: "checkmark")
                    } else {
                        Label(DictationHUDView.menuTitle(for: mode), systemImage: mode.symbolName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                Text(dictationModes.first { $0.id == activeDictationModeID }?.name ?? "Raw")
                    .font(.callout)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(modePickerHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { modePickerHovering = $0 }
        .help("Dictation mode")
    }

    /// Recent dictations quick list (last 5) — click an entry to copy it back
    /// to the clipboard; the full window has search / re-process / delete.
    private func dictationHistoryMenu(_ onCopy: @escaping (DictationHistoryEntry) -> Void) -> some View {
        HoverIconButton(icon: "clock.arrow.circlepath", help: "Recent dictations — click to copy") {
            ForEach(dictationHistory.prefix(5)) { entry in
                Button {
                    onCopy(entry)
                } label: {
                    Text(Self.historyLabel(for: entry))
                        // Voice-vs-AI peek: raw transcript when a mode
                        // transformed the delivered text.
                        .help(entry.rawText.map { "Raw transcript: \($0)" } ?? "")
                }
            }
            Divider()
            if let onOpenDictationHistory {
                Button("Open History…") { onOpenDictationHistory() }
            }
            if let onClearDictationHistory {
                Button("Clear History", role: .destructive) {
                    onClearDictationHistory()
                }
            }
        }
    }

    static func historyLabel(for entry: DictationHistoryEntry) -> String {
        let preview = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = preview.count > 44 ? String(preview.prefix(44)) + "…" : preview
        let time = entry.date.formatted(.relative(presentation: .named))
        return "\(clipped) — \(entry.modeName), \(time)"
    }

    /// Idle pre-roll status. Present whenever the ring is running, because the
    /// mic being open is a fact the user should be able to see without opening
    /// Settings — and "Clear" is the escape hatch for the moment they say
    /// something they don't want kept.
    @ViewBuilder
    private func preRollRow(_ status: PreRollStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.isFailed ? "exclamationmark.triangle.fill" : "backward.circle")
                .foregroundStyle(status.isFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                switch status {
                case .listening(let banked):
                    Text("Ready to capture the last \(Self.formatBanked(banked))")
                        .font(.caption.weight(.medium))
                    Text("Held in memory only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text("Retroactive record isn't running")
                        .font(.caption.weight(.medium))
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            // Nothing is banked when the ring is dead, so Clear would be a
            // button that does nothing to reassure the user about audio that
            // was never captured.
            if case .listening = status, let onClearPreRoll {
                Button("Clear", action: onClearPreRoll)
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func formatBanked(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        let remainder = whole % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Hero: state + waveform + the two primary actions.
                VStack(alignment: .leading, spacing: 10) {
                    stateLine
                    LiveWaveformView(history: amplitudeHistory, size: .panel, isActive: recordingState.isRecording)
                        .frame(height: 28)
                    primaryControls
                    if onStartDictation != nil, dictationActive || dictationStatusText != nil {
                        dictationStatusRow
                    }
                    if !dictationActive {
                        secondaryControlsRow
                    }
                }

                readinessSection

                if recordingState.isRecording, let activeCaptureStatus {
                    activeCaptureStatusView(activeCaptureStatus)
                }

                if !recordingState.isRecording, let preRollStatus {
                    preRollRow(preRollStatus)
                }

                if showsAutoStopSurface {
                    autoStopSurface
                }

                if let stopRecovery {
                    stopRecoveryBanner(stopRecovery)
                }

                if showsRecoveryInbox {
                    recoveryInboxBanner
                }

                if hasLastCapture {
                    Divider()
                    if trayState.isVisible {
                        tray
                            .transition(.opacity)
                    } else {
                        compactLastCapture
                            .transition(.opacity)
                    }
                }

                Divider()
                footer
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .animation(.easeInOut(duration: 0.2), value: trayState.isVisible)
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
        .onChange(of: recordingState.isRecording) { _, isRecording in
            if isRecording {
                startTicker()
            } else {
                stopTicker()
                elapsedText = "0:00"
            }
        }
    }

    // MARK: - Sub-views

    private var stateLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recordingState.isRecording ? HarcBrand.live : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(recordingState.isRecording ? "Recording" : "Idle")
                .font(.subheadline)
            Spacer()
            if recordingState.isRecording {
                Text(elapsedText)
                    .font(.system(.subheadline, design: .monospaced))
                    .monospacedDigit()
            }
        }
    }

    private func activeCaptureStatusView(_ status: ActiveCaptureStatus) -> some View {
        NativeStatusCallout(intent: status.sourceState == .micOnly ? .warning : .success) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: status.sourceState == .micOnly ? "mic.fill.badge.exclamationmark" : "waveform")
                        .foregroundStyle(status.sourceState == .micOnly ? Color.orange : Color.green)
                        .frame(width: 14)
                    Text(status.sourceState.displayText)
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                if let warningText = status.sourceState.warningText {
                    Text(warningText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                activeCapturePathRow(label: "Writing", path: status.cachePath)
                activeCapturePathRow(label: "Saves to", path: status.destinationPath)
                Text(status.transcriptAgeText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeCapturePathRow(label: String, path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Footer as proper menu rows: every action a full-width,
    /// hover-highlighted target — no more bare text links.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let availableUpdate {
                MenuPanelRowButton(
                    icon: "arrow.down.circle.fill",
                    title: "Update available — Harc \(availableUpdate.version)",
                    tint: .accentColor
                ) {
                    if let onInstallUpdate {
                        onInstallUpdate()
                    } else {
                        NSWorkspace.shared.open(availableUpdate.url)
                    }
                }
                .help(onInstallUpdate != nil ? "Download and install the update" : "Open the release page on GitHub")
            }
            MenuPanelRowButton(icon: "gearshape", title: "Settings…", detail: "⌘,") {
                NSApp.sendAction(Selector(("harcShowSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
            MenuPanelRowButton(icon: "hand.wave", title: "Welcome Guide") {
                NSApp.sendAction(Selector(("showWelcomeWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuPanelRowButton(icon: "power", title: "Quit Harc", detail: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)

            Text(appVersionText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
    }

    private var appVersionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return Self.versionDisplayText(build: build)
    }

    static func versionDisplayText(build: String?) -> String {
        if let build, !build.isEmpty {
            return "Harc v\(HarcVersion.current) (\(build))"
        }
        return "Harc v\(HarcVersion.current)"
    }

    /// Readiness collapses to a one-line summary while everything is
    /// healthy — seven green rows are noise; problems auto-expand.
    @ViewBuilder
    private var readinessSection: some View {
        let items = LocalStackHealthModel.items(for: localStackInput)
        let hasIssues = items.contains { $0.state == .warning }
        if hasIssues || readinessExpanded {
            VStack(alignment: .leading, spacing: 4) {
                LocalStackHealthView(
                    items: items,
                    compact: true,
                    onFix: { item in fixReadinessItem(item) }
                )
                if !hasIssues {
                    HoverPillButton(title: "Hide details", tint: .secondary) {
                        withAnimation(.easeInOut(duration: 0.15)) { readinessExpanded = false }
                    }
                }
            }
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { readinessExpanded = true }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(LocalStackHealthModel.summary(for: items))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .frame(maxWidth: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(readinessSummaryHovering ? Color.primary.opacity(0.06) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { readinessSummaryHovering = $0 }
            .help("Show local stack details")
        }
    }

    /// Route each readiness fix to its actual remedy — the system privacy
    /// pane that's wrong, or Settings — instead of a generic Settings open.
    private func fixReadinessItem(_ item: LocalStackHealthItem) {
        switch item.id {
        case .capture:
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .systemAudio:
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility, .dictation:
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .notifications:
            openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .destination, .stt, .summarizer, .speakerID, .recovery:
            onOpenSettings()
        }
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private var localStackInput: LocalStackHealthInput {
        LocalStackHealthInput(
            destinationReady: destinationReady,
            destinationText: destinationReady ? destinationDisplayText : "Destination missing",
            captureReady: !captureReadinessWarning,
            captureText: captureReadinessText,
            sttReady: sttReady,
            sttText: sttReadinessText,
            summarizerReady: summarizerReady,
            summarizerInstalled: summarizerInstalled,
            summarizerText: summarizerReadinessText,
            speakerIDReady: speakerIDReady,
            speakerIDText: speakerIDReadinessText,
            notificationsReady: notificationsReady,
            notificationsText: notificationsReadinessText,
            accessibilityReady: accessibilityReady,
            accessibilityText: accessibilityReadinessText,
            dictationHotkeySet: KeyboardShortcuts.getShortcut(for: .pushToTalkDictation) != nil,
            // Zero here suppresses the Local Stack's "Recovery — N pending /
            // Open recovery" row whenever the recovery card is already on
            // screen a few pixels below it, with the artifacts listed and
            // Recover/Reveal/Discard on each. Stating the same problem twice
            // in one panel — once as a pointer to a surface that is already
            // open — made a handled situation look like two.
            pendingRecoveryCount: showsRecoveryInbox
                ? 0
                : RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts)
        )
    }

    private var showsRecoveryInbox: Bool {
        RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts) > 0
    }

    private func readinessRow(
        icon: String,
        text: String,
        status: ReadinessStatus,
        help: String? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(status.color)
                .frame(width: 14)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(status.textStyle)
            Spacer(minLength: 0)
        }
        .help(help ?? text)
    }

    private var tray: some View {
        NativeStatusCallout(intent: trayIntent) {
            VStack(alignment: .leading, spacing: 8) {
                if let outcome = trayState.lastOutcome {
                    stopOutcomeView(outcome)
                }
                Text(trayState.lastTitle ?? "Last recording")
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    if canOpenLastRecording {
                        Button("Open") { onOpenLastRecording() }
                            .buttonStyle(.bordered)
                    }
                    Button("Copy") { onCopy() }
                        .buttonStyle(.bordered)
                        .disabled((trayState.lastTranscript ?? "").isEmpty)
                    if let frontmostAppName {
                        Button {
                            onPasteIntoFrontmost()
                        } label: {
                            Text("Paste")
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(frontmostPasteDenied || (trayState.lastTranscript ?? "").isEmpty)
                        .help(pasteHelpText(for: frontmostAppName))
                    }
                }
                if let pasteStatusMessage {
                    pasteStatus(pasteStatusMessage)
                } else if frontmostPasteDenied, let frontmostAppName {
                    pasteStatus("Paste blocked for \(frontmostAppName). Use Copy instead.")
                }
            }
        }
    }

    private var trayIntent: NativeStatusIntent {
        switch trayState.lastOutcome?.kind {
        case .savedSafely: return .success
        case .savedWithWarnings, .recoveryNeeded: return .warning
        case .transcriptPending, .summaryQueued, .speakerIDPending, .none: return .info
        }
    }

    @ViewBuilder
    private var autoStopSurface: some View {
        switch autoStopPhase {
        case .warning(let secondsLeft, let reason):
            CountdownWarningPanel(
                secondsLeft: secondsLeft,
                totalSeconds: autoStopWarningSeconds,
                reason: reason,
                thresholdMinutes: autoStopThresholdMinutes,
                micDb: autoStopMicDb,
                systemDb: autoStopSystemDb,
                onKeepRecording: onKeepRecording,
                onStopNow: onStopNow,
                onOpenSettings: onOpenSettings
            )
        case .stoppedBanner(let reason, let at):
            autoStoppedBanner(reason: reason, at: at)
        case .idle, .watching:
            EmptyView()
        }
    }

    private func autoStoppedBanner(reason: AutoStopController.StopReason, at: Date) -> some View {
        NativeStatusCallout(intent: .warning) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(Color.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-stopped")
                        .font(.subheadline.weight(.semibold))
                    Text(autoStopSummary(reason: reason, at: at))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                Button("Open") { onOpenLastRecording() }
                    .buttonStyle(.bordered)
                Button("Resume") { onStartStop() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func stopRecoveryBanner(_ recovery: StopRecoveryInfo) -> some View {
        NativeStatusCallout(intent: recovery.isRecovering ? .info : .warning) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: recovery.isRecovering ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                        .foregroundStyle(recovery.isRecovering ? Color.accentColor : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recovery.title)
                            .font(.subheadline.weight(.semibold))
                        Text(recovery.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(recovery.cacheDirectoryPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                HStack(spacing: 8) {
                    Button("Reveal") { onRevealStopRecovery() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(recovery.isRecovering ? "Retrying..." : "Retry") { onRetryStopRecovery() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(recovery.isRecovering)
                    Button("Settings") { onOpenSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Dismiss") { onDismissStopRecovery() }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                }
            }
        }
    }

    private var recoveryInboxBanner: some View {
        let rows = Array(RecoveryInboxModel.rows(for: recoveryArtifacts).prefix(2))
        return NativeStatusCallout(intent: .warning) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recovery needed")
                            .font(.subheadline.weight(.semibold))
                        Text("\(RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts)) recording artifact\(RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts) == 1 ? "" : "s") need attention.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(row.statusText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(row.sourcePath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // `RecoveryInboxRow.detail` already resolves to the
                        // artifact's last error, and the panel never showed
                        // it. An item that can never succeed — a truncated
                        // WAV that isn't decodable PCM — then sits in the
                        // inbox as an unexplained orange warning forever, with
                        // a Recover button that fails the same way each time.
                        if !row.detail.isEmpty, row.detail != row.title {
                            Text(row.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            Button("Recover") { onRecoverRecoveryArtifact(row.id) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!row.canRecover)
                            Button("Reveal") { onRevealRecoveryArtifact(row.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!row.canReveal)
                            Button("Discard") { onDiscardRecoveryArtifact(row.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!row.canDiscard)
                        }
                    }
                    .padding(.top, 2)
                }

                if RecoveryInboxModel.rows(for: recoveryArtifacts).count > rows.count {
                    Button("Open Settings") { onOpenSettings() }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
            }
        }
    }

    private var compactLastCapture: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last capture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(trayState.lastTitle ?? "Last recording")
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if canOpenLastRecording {
                    Button("Open") { onOpenLastRecording() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Copy") { onCopy() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled((trayState.lastTranscript ?? "").isEmpty)
                if let frontmostAppName {
                    Button("Paste") { onPasteIntoFrontmost() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(frontmostPasteDenied || (trayState.lastTranscript ?? "").isEmpty)
                        .help(pasteHelpText(for: frontmostAppName))
                }
            }
            if let pasteStatusMessage {
                pasteStatus(pasteStatusMessage)
            } else if frontmostPasteDenied, let frontmostAppName {
                pasteStatus("Paste blocked for \(frontmostAppName). Use Copy instead.")
            }
        }
        .help("Last capture actions remain available after the expanded tray collapses.")
    }

    private func pasteStatus(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stopOutcomeView(_ outcome: StopOutcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: stopOutcomeIcon(outcome.kind))
                .foregroundStyle(stopOutcomeColor(outcome.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title)
                    .font(.subheadline.weight(.semibold))
                Text(outcome.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func stopOutcomeIcon(_ kind: StopOutcome.Kind) -> String {
        switch kind {
        case .savedSafely: return "checkmark.circle.fill"
        case .transcriptPending, .summaryQueued, .speakerIDPending: return "clock.badge.checkmark"
        case .savedWithWarnings: return "exclamationmark.triangle.fill"
        case .recoveryNeeded: return "externaldrive.badge.exclamationmark"
        }
    }

    private func stopOutcomeColor(_ kind: StopOutcome.Kind) -> Color {
        switch kind {
        case .savedSafely: return .green
        case .transcriptPending, .summaryQueued, .speakerIDPending: return .accentColor
        case .savedWithWarnings, .recoveryNeeded: return .orange
        }
    }

    private var hasLastCapture: Bool {
        trayState.lastOutcome != nil || trayState.lastTranscript?.isEmpty == false
    }

    private var canOpenLastRecording: Bool {
        trayState.lastRecordingID != nil || trayState.lastWavPath != nil
    }

    private var destinationDisplayText: String {
        guard !destinationPath.isEmpty else { return "Destination ready" }
        return "Saving to \(URL(fileURLWithPath: destinationPath).lastPathComponent)"
    }

    private var showsAutoStopSurface: Bool {
        switch autoStopPhase {
        case .warning, .stoppedBanner:
            return true
        case .idle, .watching:
            return false
        }
    }

    private func pasteHelpText(for appName: String) -> String {
        frontmostPasteDenied
            ? "Paste is blocked for \(appName). Use Copy instead."
            : "Paste into \(appName)"
    }

    private func autoStopSummary(reason: AutoStopController.StopReason, at: Date) -> String {
        let duration = autoStopLastDurationText.map { "\($0) · " } ?? ""
        let recency = RelativeTimeFormatter.format(at)
        switch reason {
        case .silence:
            return "\(duration)Stopped \(recency) after \(autoStopThresholdMinutes) min of silence."
        case .hardCap:
            return "\(duration)Stopped \(recency) at the hard duration cap."
        case .captureStalled:
            return "\(duration)Stopped \(recency) — audio capture ended. What was captured is saved."
        }
    }

    // MARK: - Elapsed timer

    private func startTicker() {
        guard recordingState.isRecording else { return }
        updateElapsed()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in updateElapsed() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func updateElapsed() {
        guard let start = recordingState.recordingStartedAt else {
            elapsedText = "0:00"
            return
        }
        let total = Int(Date().timeIntervalSince(start))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        elapsedText = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private enum ReadinessStatus {
    case ready
    case warning
    case muted

    var color: Color {
        switch self {
        case .ready: return Color.green
        case .warning: return Color.yellow
        case .muted: return Color.secondary
        }
    }

    var textStyle: HierarchicalShapeStyle {
        switch self {
        case .ready, .warning: return .primary
        case .muted: return .secondary
        }
    }
}
