import SwiftUI
import AppKit

/// Tray hero zone — swaps between two distinct layouts keyed on recording state:
///
/// - **Idle**: blue gradient "Start New Recording" card with mic glyph, title,
///   device subtitle, and the ⌘⇧R keyboard pill.
/// - **Recording**: a compact ~50px live strip — 32px red stop circle, animated
///   waveform, duration in mono + pulsing REC tag. A 2px breathing red leading
///   edge signals live without shouting.
///
/// Matches the "Menu Tray — Recording.html" handoff from the design system.
public struct RecordingControlsView: View {
    @EnvironmentObject private var state: RecordingState

    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        Group {
            if state.isRecording {
                LiveRecordingStrip(onStop: onToggle)
            } else {
                IdleRecordingCard(onStart: onToggle)
            }
        }
    }
}

// MARK: - Idle card

private struct IdleRecordingCard: View {
    let onStart: () -> Void

    var body: some View {
        Button(action: onStart) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start New Recording")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("microphone · built-in · 48kHz")
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("⌘⇧R")
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.15))
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HarcDesign.primaryGradient)
            .overlay(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    .blendMode(.overlay)
            )
            .clipShape(RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous))
            .shadow(color: Color.harcAccent.opacity(0.35), radius: 14, x: 0, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live recording strip

private struct LiveRecordingStrip: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var autoStop: AutoStopController
    let onStop: () -> Void

    @State private var elapsedText: String = "0:00"
    @State private var ticker: Timer?
    @State private var breathe: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            stopButton
            LiveScopeView(history: autoStop.scopeHistory, tint: scopeTint)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            meta
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(Color.harcSurface2)
        .overlay(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                .stroke(Color.harcBorderStrong, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // Breathing 2px leading edge — live signal without motion sickness.
            Rectangle()
                .fill(Color.harcLive)
                .frame(width: 2)
                .opacity(breathe ? 1.0 : 0.4)
        }
        .clipShape(RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous))
        .onAppear {
            startTicker()
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .onDisappear { stopTicker() }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(Color.harcLive)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
                            .blendMode(.overlay)
                    )
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
            }
            .shadow(color: Color.harcLive.opacity(0.5), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }

    private var meta: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(elapsedText)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.harcInkPrimary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.harcLive)
                    .frame(width: 5, height: 5)
                    .opacity(breathe ? 1.0 : 0.4)
                Text("REC")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.harcLive)
            }
        }
        .frame(minWidth: 62, alignment: .trailing)
    }

    // MARK: - Timer

    private func startTicker() {
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

    private var scopeTint: LiveScopeView.Tint {
        if case .warning = autoStop.phase { return .warning }
        return .live
    }

    private func updateElapsed() {
        guard let start = state.recordingStartedAt else {
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

// Previously: a hand-animated 42-bar decorative waveform. Replaced by
// `LiveScopeView` so the bars correspond to actual audio samples.
