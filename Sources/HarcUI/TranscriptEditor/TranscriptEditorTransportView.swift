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
            skipButton(systemImage: "gobackward", label: "5", help: "Back 5s") {
                vm.skip(by: -5)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            playButton

            skipButton(systemImage: "goforward", label: "5", help: "Forward 5s") {
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
                Text(" / ").foregroundStyle(Color.harcInkQuaternary)
                Text(formatTime(vm.durationSec))
            }
            .font(HarcDesign.Font.mono)
            .monospacedDigit()
            .foregroundStyle(Color.harcInkSecondary)
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.harcSurface1)
    }

    private var playButton: some View {
        Button { vm.togglePlay() } label: {
            ZStack {
                Circle()
                    .fill(Color.harcAccent)
                    .frame(width: 34, height: 34)
                    .shadow(color: Color.harcAccent.opacity(0.5), radius: 8, x: 0, y: 3)
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: vm.isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(vm.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(
        systemImage: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.harcInkSecondary)
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.harcInkSecondary)
                    .offset(y: 1)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var playedFraction: Double {
        guard vm.durationSec > 0 else { return 0 }
        return min(1.0, max(0.0, vm.currentTimeSec / vm.durationSec))
    }

    private var audioMissingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 11))
                .foregroundStyle(Color.harcInkTertiary)
            Text("Audio file not found — editing still works; playback is disabled.")
                .font(HarcDesign.Font.body)
                .foregroundStyle(Color.harcInkSecondary)
            Spacer()
            if let wav = vm.document.wavURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([wav])
                } label: {
                    Text("Reveal in Finder")
                        .font(HarcDesign.Font.meta)
                        .foregroundStyle(Color.harcAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.harcSurface1)
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

    var body: some View {
        GeometryReader { geo in
            let total = 200
            let spacing: CGFloat = 1.5
            let barW = max(1, (geo.size.width - spacing * CGFloat(total - 1)) / CGFloat(total))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<total, id: \.self) { i in
                    Rectangle()
                        .fill(played(i, total: total) ? Color.harcAccent : Color.harcInkQuaternary)
                        .frame(width: barW, height: barHeight(i: i, height: geo.size.height))
                        .cornerRadius(0.5)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = max(0, min(1, v.location.x / max(geo.size.width, 1)))
                        onSeek(f)
                    }
            )
        }
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
