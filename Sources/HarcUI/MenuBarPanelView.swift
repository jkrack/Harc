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
    /// Opens the Library's Activity surface — the destination for every
    /// conditional detail this panel no longer renders inline.
    let onOpenActivity: () -> Void
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
        onOpenActivity: @escaping () -> Void = {},
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
        self.onOpenActivity = onOpenActivity
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
        HStack(spacing: HarcSpacing.sm) {
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
        HStack(spacing: HarcSpacing.sm) {
            Image(systemName: "mic.fill")
                .foregroundStyle(dictationActive ? HarcBrand.live : .secondary)
            Text(dictationStatusText ?? "Dictation")
                .font(.harcBody)
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
        HStack(spacing: HarcSpacing.sm) {
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
            HStack(spacing: HarcSpacing.xs) {
                Image(systemName: "wand.and.stars")
                    .font(.harcCaption)
                Text(dictationModes.first { $0.id == activeDictationModeID }?.name ?? "Raw")
                    .font(.harcBody)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, HarcSpacing.sm)
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

    static func formatBanked(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        let remainder = whole % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.lg) {
                // Hero: state + waveform + the two primary actions.
                VStack(alignment: .leading, spacing: HarcSpacing.md) {
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

                // The budget: everything below is always visible, nothing
                // scrolls. Conditional detail — readiness rows, recovery,
                // capture paths, countdowns — lives behind the status row,
                // which opens the Library's Activity surface. A menu-bar
                // panel that scrolls is a window in denial.
                statusRow

                if recordingState.isRecording {
                    durabilityLine
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
        .padding(.horizontal, HarcSpacing.md)
        .padding(.top, HarcSpacing.md)
        .padding(.bottom, HarcSpacing.sm)
        .frame(width: 320)
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
        HStack(spacing: HarcSpacing.sm) {
            Circle()
                .fill(recordingState.isRecording ? HarcBrand.live : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(recordingState.isRecording ? "Recording" : "Idle")
                .font(.harcLabel)
            Spacer()
            if recordingState.isRecording {
                Text(elapsedText)
                    .font(.system(.subheadline, design: .monospaced)) // token-exempt: sized mono readout
                    .monospacedDigit()
            }
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
                .font(.harcCaption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, HarcSpacing.sm)
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
    // MARK: - Status row (the panel's one line of system state)

    private var healthItems: [LocalStackHealthItem] {
        LocalStackHealthModel.items(for: localStackInput)
    }

    private var statusSummary: String {
        LocalStackHealthModel.summary(for: healthItems)
    }

    private enum StatusTone { case ready, attention, broken }

    private var statusTone: StatusTone {
        switch statusSummary {
        case "Recording blocked": return .broken
        case "Ready to record", "Capture ready": return .ready
        default: return .attention
        }
    }

    /// The single most urgent transient, one line, under the summary. The
    /// full story lives in Activity; this is the trailer.
    private var statusSubtitle: String? {
        if let stopRecovery { return stopRecovery.title }
        let pending = RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts)
        if pending > 0 { return "\(Pluralize.count(pending, "recording")) awaiting recovery" }
        if case .failed(let reason) = preRollStatus { return "Retroactive record isn't running — \(reason)" }
        if showsAutoStopSurface { return "Auto-stop countdown running" }
        if case .listening(let banked) = preRollStatus {
            return "Holding the last \(Self.formatBanked(banked)) in memory"
        }
        return nil
    }

    private var statusRow: some View {
        Button {
            onOpenActivity()
        } label: {
            HStack(spacing: HarcSpacing.sm) {
                Image(systemName: statusTone == .ready
                      ? "checkmark.circle.fill"
                      : statusTone == .attention ? "exclamationmark.circle.fill" : "xmark.octagon.fill")
                    .font(.harcCaption)
                    .foregroundStyle(statusTone == .ready ? Color.harc(.ready)
                                     : statusTone == .attention ? Color.harc(.attention) : Color.harc(.failure))
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusSummary)
                        .font(.harcCaption)
                        .foregroundStyle(statusTone == .ready ? .secondary : .primary)
                    if let statusSubtitle {
                        Text(statusSubtitle)
                            .font(.harcCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                // The privacy escape hatch stays one tap deep: wiping the
                // retroactive buffer must not require opening a window.
                if case .listening = preRollStatus, let onClearPreRoll {
                    Button("Clear", action: onClearPreRoll)
                        .font(.harcCaption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.harcCaption)
                    .foregroundStyle(.tertiary)
            }
            .padding(HarcSpacing.sm)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open Activity — readiness, recovery, and running jobs")
    }

    /// P1-8: durability reassurance in words, not debug output. The full
    /// paths live in Settings › About › Storage, where they always did.
    private var durabilityLine: some View {
        HStack(spacing: HarcSpacing.sm) {
            Image(systemName: "internaldrive")
                .font(.harcCaption)
                .foregroundStyle(.secondary)
            Text("Saving to \(destinationDisplayText) — safe through a crash.")
                .font(.harcCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
            // Honest count. The zeroing hack that lived here — nine lines of
            // comment explaining why the panel had to lie to itself to avoid
            // stating recovery twice — died with the second renderer.
            pendingRecoveryCount: RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts)
        )
    }

    private func readinessRow(
        icon: String,
        text: String,
        status: ReadinessStatus,
        help: String? = nil
    ) -> some View {
        HStack(spacing: HarcSpacing.sm) {
            Image(systemName: icon)
                .font(.harcCaption.weight(.semibold))
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
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                if let outcome = trayState.lastOutcome {
                    stopOutcomeView(outcome)
                }
                Text(trayState.lastTitle ?? "Last recording")
                    .font(.harcTitle)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: HarcSpacing.sm) {
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

    private func autoStoppedBanner(reason: AutoStopController.StopReason, at: Date) -> some View {
        NativeStatusCallout(intent: .warning) {
            HStack(spacing: HarcSpacing.sm) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(Color.harc(.attention))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-stopped")
                        .font(.harcLabel.weight(.semibold))
                    Text(autoStopSummary(reason: reason, at: at))
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack(spacing: HarcSpacing.sm) {
                Button("Open") { onOpenLastRecording() }
                    .buttonStyle(.bordered)
                Button("Resume") { onStartStop() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }



    private var compactLastCapture: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            HStack(spacing: HarcSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last capture")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                    Text(trayState.lastTitle ?? "Last recording")
                        .font(.harcLabel)
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
            .font(.harcCaption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stopOutcomeView(_ outcome: StopOutcome) -> some View {
        HStack(alignment: .top, spacing: HarcSpacing.sm) {
            Image(systemName: stopOutcomeIcon(outcome.kind))
                .foregroundStyle(stopOutcomeColor(outcome.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title)
                    .font(.harcLabel.weight(.semibold))
                Text(outcome.detail)
                    .font(.harcCaption)
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
        elapsedText = ElapsedFormatter.string(since: start)
    }
}

private enum ReadinessStatus {
    case ready
    case warning
    case muted

    var color: Color {
        switch self {
        case .ready: return Color.harc(.ready)
        case .warning: return Color.harc(.attention)
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
