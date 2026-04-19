import SwiftUI
import AppKit

/// The top half of the popover: app header, live transcript preview, big Start/Stop button.
public struct RecordingControlsView: View {
    @EnvironmentObject private var state: RecordingState
    @State private var elapsedText: String = "0:00"
    @State private var ticker: Timer?

    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
            header
            previewArea
            toggleButton
        }
    }

    private var header: some View {
        HStack(spacing: HarcDesign.Space.sm) {
            RecordingIconTile(systemImage: "waveform", accent: .harcPrimary, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("Harc")
                    .font(HarcDesign.Font.titleLg)
                    .foregroundStyle(Color.harcOnSurface)
                Text("MENU BAR")
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .tracking(1.2)
            }
            Spacer()
            if state.isRecording {
                HStack(spacing: HarcDesign.Space.xxs) {
                    Circle()
                        .fill(Color.harcError)
                        .frame(width: 8, height: 8)
                    Text(elapsedText)
                        .font(HarcDesign.Font.labelMd.monospacedDigit())
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
            }
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if state.isRecording {
            ScrollView {
                Text(state.livePreviewText.isEmpty ? "Listening…" : state.livePreviewText)
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(state.livePreviewText.isEmpty ? Color.harcOnSurfaceVariant : Color.harcOnSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HarcDesign.Space.sm)
            }
            .frame(height: 80)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
        } else {
            EmptyView()
        }
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            HStack(spacing: HarcDesign.Space.xs) {
                Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(state.isRecording ? "Stop Recording" : "Start New Recording")
                    .font(HarcDesign.Font.titleSm)
                if !state.isRecording {
                    Spacer()
                    Image(systemName: "mic")
                        .font(.system(size: 14))
                        .opacity(0.8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, HarcDesign.Space.md)
            .background(
                state.isRecording
                    ? AnyShapeStyle(Color.harcError)
                    : AnyShapeStyle(HarcDesign.primaryGradient),
                in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .onChange(of: state.isRecording) { _, isRecording in
            if isRecording { startTicker() } else { stopTicker() }
        }
        .onAppear { if state.isRecording { startTicker() } }
    }

    private func startTicker() {
        updateElapsed()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in updateElapsed() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        elapsedText = "0:00"
    }

    private func updateElapsed() {
        guard let start = state.recordingStartedAt else {
            elapsedText = "0:00"
            return
        }
        let seconds = Int(Date().timeIntervalSince(start))
        let m = seconds / 60
        let s = seconds % 60
        elapsedText = String(format: "%d:%02d", m, s)
    }
}
