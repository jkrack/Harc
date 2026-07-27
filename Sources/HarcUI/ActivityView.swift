import SwiftUI
import AppKit
import KeyboardShortcuts

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
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    jobsSection
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

    // MARK: Jobs

    @ViewBuilder
    private var jobsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Now", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                if let job = currentJobText {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(job)
                            .font(.caption)
                    }
                } else {
                    Text("Nothing running")
                        .font(.caption)
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
            VStack(alignment: .leading, spacing: 10) {
                Label("Recovery", systemImage: "arrow.counterclockwise.circle")
                    .font(.caption.weight(.semibold))
                ForEach(RecoveryInboxModel.rows(for: bridge.recoveryArtifacts)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.caption.weight(.semibold))
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
                        if !row.detail.isEmpty, row.detail != row.title {
                            Text(row.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
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
            VStack(alignment: .leading, spacing: 8) {
                Label(recovery.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(recovery.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
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
            NSApp.activate(ignoringOtherApps: true)
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
