import SwiftUI

/// Slim MenuBarExtra panel: recording state + level bars + Start/Stop + Open + post-stop tray.
/// Replaces the 520-line PopoverRootView.
public struct MenuBarPanelView: View {
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var trayState: PostStopTrayState
    let scopeHistory: [Float]
    let onStartStop: () -> Void
    let onOpenWindow: () -> Void
    let onCopy: () -> Void
    let onPasteIntoFrontmost: () -> Void
    let frontmostAppName: String?

    @State private var elapsedText: String = "0:00"
    @State private var ticker: Timer?

    public init(
        recordingState: RecordingState,
        trayState: PostStopTrayState,
        scopeHistory: [Float] = [],
        onStartStop: @escaping () -> Void,
        onOpenWindow: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onPasteIntoFrontmost: @escaping () -> Void,
        frontmostAppName: String?
    ) {
        self.recordingState = recordingState
        self.trayState = trayState
        self.scopeHistory = scopeHistory
        self.onStartStop = onStartStop
        self.onOpenWindow = onOpenWindow
        self.onCopy = onCopy
        self.onPasteIntoFrontmost = onPasteIntoFrontmost
        self.frontmostAppName = frontmostAppName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stateLine
            LiveScopeView(history: scopeHistory, tint: recordingState.isRecording ? .live : .dimmed)
                .frame(height: 28)
            HStack(spacing: 8) {
                Button(recordingState.isRecording ? "Stop" : "Record") { onStartStop() }
                    .buttonStyle(.borderedProminent)
                    .tint(recordingState.isRecording ? HarcBrand.live : .accentColor)
                Button("Open") { onOpenWindow() }
                    .buttonStyle(.bordered)
            }

            if trayState.isVisible {
                Divider()
                tray
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: 280)
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

    private var tray: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trayState.lastTitle ?? "Last recording")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Copy") { onCopy() }
                    .buttonStyle(.bordered)
                if let frontmostAppName {
                    Button("Paste \u{2192} \(frontmostAppName)") { onPasteIntoFrontmost() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        // .glassEffect(in: RoundedRectangle(cornerRadius: 10))
        // TODO: re-enable once macOS 26 .glassEffect() API is verified at compile time
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
