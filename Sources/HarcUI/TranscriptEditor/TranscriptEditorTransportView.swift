import SwiftUI
import AppKit

struct TranscriptEditorTransportView: View {
    @ObservedObject var vm: TranscriptEditorViewModel

    var body: some View {
        if vm.audioMissing {
            audioMissingBanner
        } else {
            transport
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            skipButton(systemImage: "gobackward.5", help: "Back 5s") {
                vm.skip(by: -5)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            playButton

            skipButton(systemImage: "goforward.5", help: "Forward 5s") {
                vm.skip(by: 5)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            ScrubWaveform(
                seed: vm.recording.wavPath.hashValue,
                fraction: playedFraction,
                onSeek: { f in
                    let target = f * max(vm.durationSec, 0.001)
                    vm.seek(to: target)
                }
            )
            .frame(height: 28)
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                Text(formatTime(vm.currentTimeSec))
                Text(" / ").foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                Text(formatTime(vm.durationSec))
            }
            .font(.system(.callout, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.secondary)
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var playButton: some View {
        Button { vm.togglePlay() } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(.space, modifiers: [])
        .help(vm.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bordered)
        .help(help)
    }

    private var playedFraction: Double {
        guard vm.durationSec > 0 else { return 0 }
        return min(1.0, max(0.0, vm.currentTimeSec / vm.durationSec))
    }

    private var audioMissingBanner: some View {
        NativeStatusCallout(intent: .warning) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
                Text("Audio file not found. Editing still works; playback is disabled.")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
                Spacer()
                if let wav = vm.document.wavURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([wav])
                    } label: {
                        Label("Reveal", systemImage: "finder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Scrubbable waveform bar

private struct ScrubWaveform: View {
    let seed: Int
    let fraction: Double
    let onSeek: (Double) -> Void

    @State private var isHovering = false
    @State private var scrubX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = 200
            let spacing: CGFloat = 1.5
            let barW = max(1, (geo.size.width - spacing * CGFloat(total - 1)) / CGFloat(total))
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<total, id: \.self) { i in
                        Rectangle()
                            .fill(played(i, total: total) ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
                            .frame(width: barW, height: barHeight(i: i, height: geo.size.height))
                            .cornerRadius(0.5)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)

                if let x = scrubberX(width: geo.size.width) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: x)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .pointingHandCursor()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = max(0, min(1, v.location.x / max(geo.size.width, 1)))
                        scrubX = f * geo.size.width
                        onSeek(f)
                    }
                    .onEnded { _ in scrubX = nil }
            )
        }
    }

    private func scrubberX(width: CGFloat) -> CGFloat? {
        if let scrubX {
            return max(0, min(width, scrubX))
        }
        return isHovering ? width * min(1, max(0, fraction)) : nil
    }

    private func played(_ i: Int, total: Int) -> Bool {
        Double(i) / Double(total) <= fraction
    }

    private func barHeight(i: Int, height: CGFloat) -> CGFloat {
        let s = Double(seed &* 0x1F1F1F1F &+ i &* 9301 &+ 49297)
        let r = abs(sin(s))
        let envelope = 0.3 + 0.7 * abs(sin(Double(i) * 0.27 + Double(seed) * 0.11))
        let frac = 0.18 + 0.82 * (0.6 * envelope + 0.4 * r)
        return max(2, height * CGFloat(min(1.0, frac)))
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
