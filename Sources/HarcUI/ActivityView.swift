import SwiftUI
import AppKit
import HarcCore
import KeyboardShortcuts
import UniformTypeIdentifiers

public extension NSNotification.Name {
    /// Posted by AppDelegate when the menu-bar panel's status row asks for
    /// the full Activity surface. `HarcWindowRootView` observes it.
    static let harcLibraryShowActivity = NSNotification.Name("HarcLibraryShowActivity")
}

/// The one place system state is told in full.
///
/// Readiness used to be narrated four times — a collapsed summary row, an
/// expandable nine-row list in the menu-bar panel, the Settings panes, and a
/// recovery card — with suppression logic (`pendingRecoveryCount: 0`) whose
/// nine-line comment existed to stop the panel saying the same thing twice.
/// That comment was the bug report. The panel now shows one status row;
/// tapping it lands here, where readiness, recovery, and running jobs each
/// have a single renderer.
public struct ActivityView: View {
    @ObservedObject var bridge: HarcAppBridge
    @ObservedObject var importState: MediaImportState
    let onDismiss: () -> Void

    @EnvironmentObject private var postProcessing: RecordingPostProcessingState
    @State private var developerLogExpanded = false
    @State private var developerLogExportError: String?

    public init(
        bridge: HarcAppBridge,
        importState: MediaImportState,
        onDismiss: @escaping () -> Void
    ) {
        self.bridge = bridge
        self.importState = importState
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.harcTitle.weight(.semibold))
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: HarcSpacing.lg) {
                    jobsSection
                    if let clientState = bridge.clientRecoverSyncState {
                        clientRecoverSyncSection(clientState)
                        clientDeveloperLogSection
                    }
                    if let recovery = bridge.stopRecovery {
                        stopRecoverySection(recovery)
                    }
                    LocalStackHealthView(
                        items: LocalStackHealthModel.items(for: bridge.localStackHealthInput()),
                        compact: false,
                        onFix: { fix($0) }
                    )
                    if !bridge.recoveryArtifacts.isEmpty {
                        recoverySection
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 520)
    }

    // MARK: Client developer log

    private var clientDeveloperLogSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $developerLogExpanded) {
                VStack(alignment: .leading, spacing: HarcSpacing.md) {
                    Text("Operational facts only — no audio, transcript text, credentials, pairing secrets, or full file paths are recorded.")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: HarcSpacing.sm) {
                        Button("Copy Log") { copyDeveloperLog() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(bridge.clientDiagnosticLogEntries.isEmpty)
                        Button("Save…") { saveDeveloperLog() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(bridge.clientDiagnosticLogEntries.isEmpty)
                        Button("Clear") {
                            bridge.onClearClientDiagnosticLog()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(bridge.clientDiagnosticLogEntries.isEmpty)
                    }

                    if let developerLogExportError {
                        Text(developerLogExportError)
                            .font(.harcCaption)
                            .foregroundStyle(Color.harc(.failure))
                            .textSelection(.enabled)
                    }

                    if bridge.clientDiagnosticLogEntries.isEmpty {
                        Text("No Client diagnostic events yet.")
                            .font(.harcCaption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(
                            Array(bridge.clientDiagnosticLogEntries.suffix(60).reversed())
                        ) { entry in
                            developerLogRow(entry)
                        }
                    }
                }
                .padding(.top, HarcSpacing.sm)
            } label: {
                HStack(spacing: HarcSpacing.sm) {
                    Label("Developer Log", systemImage: "terminal")
                        .font(.harcCaption.weight(.semibold))
                    Spacer()
                    Text("\(bridge.clientDiagnosticLogEntries.count) events")
                        .font(.harcMono)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func developerLogRow(
        _ entry: HarcDiagnosticLogEntry
    ) -> some View {
        VStack(alignment: .leading, spacing: HarcSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
                Image(systemName: developerLogIcon(entry.severity))
                    .foregroundStyle(developerLogColor(entry.severity))
                Text("\(entry.area) · \(entry.stage)")
                    .font(.harcCaption.weight(.semibold))
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.harcMono)
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.harcCaption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.context.isEmpty {
                Text(entry.context.keys.sorted().map {
                    "\($0)=\(entry.context[$0] ?? "")"
                }.joined(separator: "  "))
                    .font(.harcMono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, HarcSpacing.xs)
    }

    private func developerLogIcon(_ severity: HarcDiagnosticSeverity) -> String {
        switch severity {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func developerLogColor(_ severity: HarcDiagnosticSeverity) -> Color {
        switch severity {
        case .info: Color.harc(.working)
        case .success: Color.harc(.ready)
        case .warning: Color.harc(.attention)
        case .error: Color.harc(.failure)
        }
    }

    private func developerLogText() -> String {
        HarcDiagnosticLogStore.formattedText(
            entries: bridge.clientDiagnosticLogEntries
        )
    }

    private func copyDeveloperLog() {
        developerLogExportError = nil
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(
            developerLogText(),
            forType: .string
        ) else {
            developerLogExportError = "The diagnostic log could not be copied."
            return
        }
    }

    private func saveDeveloperLog() {
        developerLogExportError = nil
        let panel = NSSavePanel()
        panel.title = "Save Client Diagnostic Log"
        panel.nameFieldStringValue = "Harc-Client-Diagnostic-Log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try developerLogText().write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            developerLogExportError = error.localizedDescription
        }
    }

    // MARK: Client archive recovery

    private func clientRecoverSyncSection(
        _ state: ClientRecoverSyncState
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Label("Client Recover & Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.harcCaption.weight(.semibold))
                if let transfer = bridge.clientTransferStatusText {
                    Text(transfer)
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                }
                switch state {
                case .ready:
                    Text("Inventory protected Client recordings, repair safe local metadata gaps, and retry Host transfer.")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                case .running:
                    HStack(spacing: HarcSpacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking ClientState/Captures…")
                            .font(.harcCaption)
                    }
                case .completed(let report):
                    Label(
                        report.headline,
                        systemImage: report.issues.isEmpty && report.securityBlocked == 0
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.harcCaption.weight(.semibold))
                    .foregroundStyle(
                        report.issues.isEmpty && report.securityBlocked == 0
                            ? Color.harc(.ready)
                            : Color.harc(.attention)
                    )
                    Text(report.detail)
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(report.issues) { issue in
                        VStack(alignment: .leading, spacing: HarcSpacing.xs) {
                            Text("Recording \(issue.recording)")
                                .font(.harcCaption.weight(.semibold))
                            Text(issue.message)
                                .font(.harcCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .failed(let message):
                    Label("Recover & Sync could not finish", systemImage: "exclamationmark.triangle.fill")
                        .font(.harcCaption.weight(.semibold))
                        .foregroundStyle(Color.harc(.attention))
                    Text(message)
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(state.isRunning ? "Recovering…" : "Recover & Sync") {
                    bridge.onRecoverAndSyncClient()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.isRunning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Jobs

    @ViewBuilder
    private var jobsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Label("Now", systemImage: "clock")
                    .font(.harcCaption.weight(.semibold))
                if let job = currentJobText {
                    HStack(spacing: HarcSpacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text(job)
                            .font(.harcCaption)
                    }
                } else {
                    Text("Nothing running")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentJobText: String? {
        if let job = importState.current {
            let phase = job.phaseText.isEmpty ? "Importing" : job.phaseText
            return "\(phase) — \(job.filename)"
        }
        if importState.isActive {
            return "Importing…"
        }
        if case .identifying = postProcessing.current?.phase {
            return "Identifying speakers…"
        }
        return nil
    }

    // MARK: Recovery — the single renderer for interrupted artifacts.

    private var recoverySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                Label("Recovery", systemImage: "arrow.counterclockwise.circle")
                    .font(.harcCaption.weight(.semibold))
                ForEach(RecoveryInboxModel.rows(for: bridge.recoveryArtifacts)) { row in
                    VStack(alignment: .leading, spacing: HarcSpacing.xs) {
                        HStack(spacing: HarcSpacing.sm) {
                            Text(row.title)
                                .font(.harcCaption.weight(.semibold))
                            Spacer()
                            Text(row.statusText)
                                .font(.harcCaption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(row.sourcePath)
                            .font(.harcCaption.monospaced())
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !row.detail.isEmpty, row.detail != row.title {
                            Text(row.detail)
                                .font(.harcCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: HarcSpacing.sm) {
                            Button("Recover") { bridge.onRecoverRecoveryArtifact(row.id) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!row.canRecover)
                            Button("Reveal") { bridge.onRevealRecoveryArtifact(row.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!row.canReveal)
                            Button("Discard") { bridge.onDiscardRecoveryArtifact(row.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!row.canDiscard)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A stop that failed mid-finalize — the most urgent thing this surface
    /// can show, since a recording is sitting in cache waiting to be saved.
    private func stopRecoverySection(_ recovery: StopRecoveryInfo) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Label(recovery.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.harcCaption.weight(.semibold))
                    .foregroundStyle(Color.harc(.attention))
                Text(recovery.message)
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HarcSpacing.sm) {
                    Button(recovery.isRecovering ? "Retrying…" : "Retry") { bridge.onRetryStopRecovery() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(recovery.isRecovering)
                    Button("Reveal") { bridge.onRevealStopRecovery() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Dismiss") { bridge.onDismissStopRecovery() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Fix routing — the same remedies the panel used to own.

    private func fix(_ item: LocalStackHealthItem) {
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
            NSApp.sendAction(Selector(("harcShowSettingsWindow:")), to: nil, from: nil)
            NSApp.activate()
        }
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension HarcAppBridge {
    /// The full readiness input, assembled once — the Activity view and the
    /// panel's status row both derive from this, so recovery is counted
    /// honestly everywhere and no renderer needs to zero a field to avoid
    /// contradicting another.
    func localStackHealthInput() -> LocalStackHealthInput {
        LocalStackHealthInput(
            destinationReady: destinationReady,
            destinationText: destinationReady
                ? "Saving to \(destinationPath.isEmpty ? "Harc" : (destinationPath as NSString).abbreviatingWithTildeInPath)"
                : "Destination missing",
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
            pendingRecoveryCount: RecoveryInboxModel.unresolvedCount(in: recoveryArtifacts)
        )
    }
}
