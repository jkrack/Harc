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

    @State private var elapsedText: String = "0:00"
    @State private var ticker: Timer?

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
        onClearDictationHistory: (() -> Void)? = nil
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
    }

    @ViewBuilder
    private func dictationRow(_ onStart: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(dictationActive ? HarcBrand.live : .secondary)
            // Status text renders for any non-idle phase — including the
            // done/error afterglow, which isn't "active".
            Text(dictationStatusText ?? "Dictation")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if dictationActive {
                if let onCancelDictation {
                    Button("Cancel") { onCancelDictation() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let onStopDictation {
                    Button("Stop") { onStopDictation() }
                        .buttonStyle(.borderedProminent)
                        .tint(HarcBrand.live)
                        .controlSize(.small)
                }
            } else {
                if let onCopyDictationHistoryEntry, !dictationHistory.isEmpty {
                    dictationHistoryMenu(onCopyDictationHistoryEntry)
                }
                if let onSelectDictationMode, !dictationModes.isEmpty {
                    dictationModePicker(onSelectDictationMode)
                }
                Button("Dictate") { onStart() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(recordingState.isRecording)
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
            Text(dictationModes.first { $0.id == activeDictationModeID }?.name ?? "Raw")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Dictation mode")
    }

    /// Recent dictations — click an entry to copy it back to the clipboard.
    private func dictationHistoryMenu(_ onCopy: @escaping (DictationHistoryEntry) -> Void) -> some View {
        Menu {
            ForEach(dictationHistory) { entry in
                Button {
                    onCopy(entry)
                } label: {
                    Text(Self.historyLabel(for: entry))
                        // Voice-vs-AI peek: raw transcript when a mode
                        // transformed the delivered text.
                        .help(entry.rawText.map { "Raw transcript: \($0)" } ?? "")
                }
            }
            if let onClearDictationHistory {
                Divider()
                Button("Clear History", role: .destructive) {
                    onClearDictationHistory()
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Recent dictations — click to copy")
    }

    static func historyLabel(for entry: DictationHistoryEntry) -> String {
        let preview = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = preview.count > 44 ? String(preview.prefix(44)) + "…" : preview
        let time = entry.date.formatted(.relative(presentation: .named))
        return "\(clipped) — \(entry.modeName), \(time)"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                stateLine
                LiveWaveformView(history: amplitudeHistory, size: .panel, isActive: recordingState.isRecording)
                    .frame(height: 28)
                HStack(spacing: 8) {
                    Button(recordingState.isRecording ? "Stop" : "Record") { onStartStop() }
                        .buttonStyle(.borderedProminent)
                        .tint(recordingState.isRecording ? HarcBrand.live : .accentColor)
                    Button {
                        onOpenWindow()
                    } label: {
                        Label("Open Library", systemImage: "books.vertical")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("l", modifiers: .command)
                }

                if let onStartDictation {
                    dictationRow(onStartDictation)
                }

                readinessSection

                if recordingState.isRecording, let activeCaptureStatus {
                    activeCaptureStatusView(activeCaptureStatus)
                }

                if showsAutoStopSurface {
                    autoStopSurface
                }

                if let stopRecovery {
                    stopRecoveryBanner(stopRecovery)
                }

                if RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts) > 0 {
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
            .padding(14)
        }
        .frame(width: 280)
        .frame(maxHeight: 460)
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 4) {
                        Text("Settings…")
                        Spacer()
                        Text("⌘,").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                Spacer(minLength: 12)
                Button {
                    NSApp.sendAction(Selector(("showWelcomeWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Welcome…")
                }
                .buttonStyle(.plain)
                Spacer(minLength: 12)
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Text("Quit Harc")
                        Spacer()
                        Text("⌘Q").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
            }

            Text(appVersionText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
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

    private var readinessSection: some View {
        LocalStackHealthView(
            items: LocalStackHealthModel.items(for: localStackInput),
            compact: true,
            onFix: { item in fixReadinessItem(item) }
        )
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
            summarizerText: summarizerReadinessText,
            speakerIDReady: speakerIDReady,
            speakerIDText: speakerIDReadinessText,
            notificationsReady: notificationsReady,
            notificationsText: notificationsReadinessText,
            accessibilityReady: accessibilityReady,
            accessibilityText: accessibilityReadinessText,
            dictationHotkeySet: KeyboardShortcuts.getShortcut(for: .pushToTalkDictation) != nil,
            pendingRecoveryCount: RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts)
        )
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
