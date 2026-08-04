import SwiftUI

/// The recording island — a floating pill that exists only while a
/// recording does. One state at a time, by design:
/// - resting: pulsing dot · elapsed · live bars (34pt)
/// - hovered: expands to 52pt with Stop and Discard after a 120ms dwell,
///   so a cursor crossing the top of the screen doesn't trigger it
/// - mic silent: amber ring + label when ~2.4s of frames sit near zero
/// - stopping: spinner · "Saving m:ss → Library"
/// - discarded: "Discarded m:ss" · Undo · countdown
///
/// Hosted by a non-activating panel (RecordingIslandPanel in the app
/// target); this view never steals focus and keeps its body narrow — it
/// re-renders at the 10 Hz amplitude cadence.
public struct RecordingIslandView: View {
    @ObservedObject var bridge: HarcAppBridge
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var model: RecordingIslandModel

    @State private var hovering = false
    @State private var hoverDwellTask: Task<Void, Never>? = nil

    public init(bridge: HarcAppBridge, recordingState: RecordingState, model: RecordingIslandModel) {
        self.bridge = bridge
        self.recordingState = recordingState
        self.model = model
    }

    public var body: some View {
        Group {
            if let countdown = bridge.discardCountdown {
                discardedPill(countdown)
            } else if bridge.recordingStopInFlight {
                stoppingPill
            } else if recordingState.isRecording {
                if model.expanded {
                    expandedPill
                } else {
                    restingPill
                }
            } else if recordingState.isPreparing {
                // A cold daemon start takes a couple of seconds. Feedback-free
                // startup invited a second hotkey press that used to kill the
                // recording it was waiting for — the island now appears the
                // moment the start is requested.
                startingPill
            }
        }
        .onHover { inside in
            hovering = inside
            hoverDwellTask?.cancel()
            if inside {
                hoverDwellTask = Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled, hovering else { return }
                    withAnimation(.spring(duration: 0.22)) { model.expanded = true }
                }
            } else {
                withAnimation(.spring(duration: 0.22)) { model.expanded = false }
            }
        }
        .animation(.spring(duration: 0.22), value: bridge.recordingStopInFlight)
    }

    // MARK: - States

    private var micIsSilent: Bool {
        // 24 amplitude frames at 100ms each ≈ 2.4s of near-zero input.
        let history = bridge.microphoneAmplitudeHistory
        guard history.count >= 24 else { return false }
        return history.suffix(24).allSatisfy { $0 < 0.02 }
    }

    private var restingPill: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(micIsSilent ? Color.harc(.attention) : HarcBrand.live)
                .frame(width: 7, height: 7)
                .modifier(PulseWhile(active: !micIsSilent))
            elapsedText(font: .system(size: 12, weight: .semibold))
            if micIsSilent {
                Text("Mic is silent")
                    .font(.harcCaption)
                    .foregroundStyle(Color.harc(.attention))
            } else {
                LiveWaveformView(
                    history: bridge.microphoneAmplitudeHistory,
                    size: .pill,
                    isActive: true,
                    tint: HarcBrand.live
                )
                .frame(width: 44, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .fixedSize()
        .background(islandBackground(borderTint: micIsSilent ? Color.harc(.attention) : HarcBrand.live))
    }

    private var expandedPill: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(HarcBrand.live)
                .frame(width: 8, height: 8)
            elapsedText(font: .system(size: 15, weight: .semibold))
            Text(bridge.activeMicrophoneName ?? bridge.selectedMicrophoneName)
                .font(.harcCaption)
                .foregroundStyle(micIsSilent ? Color.harc(.attention) : .white.opacity(0.72))
                .lineLimit(1)
                .frame(maxWidth: 150)
            LiveWaveformView(
                history: bridge.microphoneAmplitudeHistory,
                size: .pill,
                isActive: true,
                tint: micIsSilent ? Color.harc(.attention) : HarcBrand.live
            )
            .frame(width: 96, height: 22)
            if micIsSilent {
                islandButton(
                    background: Color.harc(.attention),
                    help: "Save and choose another microphone"
                ) {
                    bridge.onStopAndChooseMicrophone()
                } label: {
                    Image(systemName: "mic.badge.xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Save and change microphone")
            }
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 24)
            islandButton(background: HarcBrand.live, help: "Stop and save") {
                bridge.onStartStop()
            } label: {
                RoundedRectangle(cornerRadius: 2.4)
                    .fill(.white)
                    .frame(width: 12, height: 12)
            }
            .accessibilityLabel("Stop recording")
            islandButton(background: Color.white.opacity(0.1), help: "Discard (10s undo)") {
                bridge.onDiscardRecording()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Discard recording")
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 52)
        .fixedSize()
        .background(islandBackground(borderTint: HarcBrand.live, cornerRadius: 26))
    }

    private var startingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Starting…")
                .font(.harcCaption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .fixedSize()
        .background(islandBackground(borderTint: HarcBrand.live.opacity(0.6)))
    }

    private var stoppingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Saving \(elapsedString) → Library")
                .font(.harcCaption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .fixedSize()
        .background(islandBackground(borderTint: Color.white.opacity(0.14)))
    }

    private func discardedPill(_ countdown: DiscardCountdown) -> some View {
        HStack(spacing: 12) {
            Text("Discarded \(countdown.durationText)")
                .font(.harcCaption)
                .foregroundStyle(.white.opacity(0.85))
            Button {
                bridge.onUndoDiscard()
            } label: {
                Text("Undo")
                    .font(.harcCaption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            Text("\(countdown.secondsRemaining)s")
                .font(.harcMono)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 34)
        .fixedSize()
        .background(islandBackground(borderTint: Color.white.opacity(0.14)))
    }

    // MARK: - Pieces

    private var elapsedString: String {
        guard let startedAt = recordingState.recordingStartedAt else { return "Recording" }
        return ElapsedFormatter.string(since: startedAt)
    }

    @ViewBuilder
    private func elapsedText(font: Font) -> some View {
        if let startedAt = recordingState.recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { _ in
                Text(ElapsedFormatter.string(since: startedAt))
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        } else {
            Text("Recording")
                .font(font)
                .foregroundStyle(.white)
        }
    }

    private func islandButton(
        background: Color,
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 34, height: 34)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func islandBackground(borderTint: Color, cornerRadius: CGFloat = 17) -> some View {
        Capsule()
            .fill(Color.black.opacity(0.82))
            .overlay(Capsule().strokeBorder(borderTint.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 15, y: 10)
    }
}

/// The resting dot's slow pulse — suspended when the amber silent state has
/// the stage, so the two signals never blend.
private struct PulseWhile: ViewModifier {
    let active: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && pulsing ? 1.25 : 0.9)
            .opacity(active && pulsing ? 1 : 0.75)
            .animation(
                active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

/// Panel-visible island state: the hosting panel can't see the view's
/// internal @State, but must refit when the pill grows from 34pt to 52pt.
@MainActor
public final class RecordingIslandModel: ObservableObject {
    @Published public var expanded = false
    public init() {}
}
