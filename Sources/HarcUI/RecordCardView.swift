import SwiftUI
import KeyboardShortcuts

/// The permanent record panel at the top of the Library sidebar — design
/// 3e's four states in one card. This replaced the toolbar Record control:
/// capture is the app's primary action, and the sidebar's top is the one
/// place it can hold state (timer, envelope, banked pre-roll) instead of
/// being a button that mutates.
///
/// The primary button keeps the `harc.library.capture.recordButton`
/// identifier in every state, so the record→stop UI-test loop drives it
/// unchanged.
struct RecordCardView: View {
    @ObservedObject var bridge: HarcAppBridge
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var postProcessing: RecordingPostProcessingState

    var body: some View {
        Group {
            if recordingState.isRecording || recordingState.isPreparing {
                recordingCard
            } else if bridge.recordingStopInFlight || isIdentifying {
                finishingCard
            } else {
                idleCard
            }
        }
        .padding(.horizontal, HarcSpacing.md)
        .padding(.top, HarcSpacing.md)
        .padding(.bottom, HarcSpacing.xs)
    }

    private var isIdentifying: Bool {
        if case .identifying = postProcessing.current?.phase { return true }
        return false
    }

    // MARK: - Idle (+ retroactive armed)

    private var idleCard: some View {
        Button {
            bridge.onStartStop()
        } label: {
            HStack(spacing: HarcSpacing.sm) {
                Image(systemName: "record.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(HarcBrand.live)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Record")
                        .font(.harcBody.weight(.semibold))
                        .foregroundStyle(HarcBrand.live)
                    if let banked = bankedText {
                        HStack(spacing: 4) {
                            Text("\(banked) banked")
                                .font(.harcCaption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.harcCaption)
                                .foregroundStyle(.tertiary)
                            Text("Clear")
                                .font(.harcCaption)
                                .foregroundStyle(.secondary)
                                .underline()
                                .onTapGesture { bridge.onClearPreRoll() }
                        }
                    }
                }
                Spacer(minLength: 0)
                if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
                    Text(String(describing: shortcut))
                        .font(.harcMono)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(HarcSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("harc.library.capture.recordButton")
        .help(recordHelp)
    }

    private var bankedText: String? {
        guard case .listening(let seconds)? = bridge.preRollStatus, seconds >= 1 else { return nil }
        return MenuBarPanelView.formatBanked(seconds)
    }

    private var recordHelp: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return "Start recording (\(shortcut))"
        }
        return "Start recording"
    }

    // MARK: - Recording

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            HStack(spacing: HarcSpacing.sm) {
                Circle()
                    .fill(HarcBrand.live)
                    .frame(width: 8, height: 8)
                Text(bridge.activeCaptureTitle ?? "Recording")
                    .font(.harcBody.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let startedAt = recordingState.recordingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(ElapsedFormatter.string(since: startedAt, now: context.date))
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
            LiveWaveformView(
                history: bridge.amplitudeHistory,
                size: .pill,
                isActive: true,
                tint: HarcBrand.live
            )
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            HStack(spacing: HarcSpacing.sm) {
                Button {
                    bridge.onStartStop()
                } label: {
                    Text("Stop")
                        .font(.harcBody.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(HarcBrand.live, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("harc.library.capture.recordButton")
                Button {
                    bridge.onDiscardRecording()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 40, height: 30)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Discard (10s undo)")
            }
        }
        .padding(HarcSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(HarcBrand.live.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(HarcBrand.live.opacity(0.5), lineWidth: 1)
                )
        )
    }

    // MARK: - Finishing

    private var finishingCard: some View {
        HStack(spacing: HarcSpacing.sm) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(bridge.recordingStopInFlight ? "Saving…" : "Identifying speakers…")
                    .font(.harcBody)
                if let last = recordingState.lastResult {
                    Text("\(last.wavURL.deletingPathExtension().lastPathComponent) saved to disk")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(HarcSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityIdentifier("harc.library.capture.recordButton")
    }
}
