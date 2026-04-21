import SwiftUI
import AppKit

/// Hero rec card — single full-width gradient button that swaps state.
/// Width is pinned to .infinity so the popover never reflows with text changes.
public struct RecordingControlsView: View {
    @EnvironmentObject private var state: RecordingState
    @State private var elapsedText: String = "00:00:00"
    @State private var ticker: Timer?

    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .center) {
                if state.isRecording { liveBars }
                cardContent
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    .blendMode(.overlay)
            )
            .clipShape(RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous))
            .shadow(
                color: (state.isRecording ? Color.harcLive : Color.harcAccent).opacity(0.35),
                radius: 14, x: 0, y: 4
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onChange(of: state.isRecording) { _, isRecording in
            if isRecording { startTicker() } else { stopTicker() }
        }
        .onAppear { if state.isRecording { startTicker() } }
        .onDisappear { stopTicker() }
    }

    // MARK: - Card content

    private var cardContent: some View {
        HStack(spacing: 14) {
            iconCircle
            VStack(alignment: .leading, spacing: 2) {
                Text(state.isRecording ? "Stop Recording" : "Start New Recording")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subText)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)

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
    }

    private var subText: String {
        state.isRecording
            ? "REC · \(elapsedText)"
            : "microphone · built-in · 48kHz"
    }

    private var iconCircle: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 36, height: 36)
            Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if state.isRecording {
            LinearGradient(
                colors: [
                    Color(red: 0xE2/255.0, green: 0x4F/255.0, blue: 0x55/255.0),
                    Color(red: 0xC4/255.0, green: 0x37/255.0, blue: 0x44/255.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            HarcDesign.primaryGradient
        }
    }

    // MARK: - Animated bars (only when recording)

    @State private var liveTick: Bool = false

    private var liveBars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2, height: barHeight(at: i))
                    .opacity(0.55)
            }
        }
        .opacity(0.35)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear { startBarsAnimation() }
    }

    private func barHeight(at i: Int) -> CGFloat {
        // pseudo-random envelope, animated via liveTick toggle
        let phase = liveTick ? 1.0 : 0.0
        let base: [CGFloat] = [14, 22, 30, 40, 32, 24, 16, 28, 36, 22]
        let h = base[i % base.count]
        let osc = sin(Double(i) * 0.7 + phase * .pi)
        return max(4, h * (0.5 + 0.5 * CGFloat(abs(osc))))
    }

    private func startBarsAnimation() {
        Task { @MainActor in
            while state.isRecording {
                withAnimation(.easeInOut(duration: 0.6)) { liveTick.toggle() }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
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
        elapsedText = "00:00:00"
    }

    private func updateElapsed() {
        guard let start = state.recordingStartedAt else {
            elapsedText = "00:00:00"
            return
        }
        let total = Int(Date().timeIntervalSince(start))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        elapsedText = String(format: "%02d:%02d:%02d", h, m, s)
    }
}
