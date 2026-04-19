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
        HStack(spacing: HarcDesign.Space.sm) {
            Button { vm.skip(by: -5) } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.harcOnSurface)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Back 5 seconds")

            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.harcPrimary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(vm.isPlaying ? "Pause" : "Play")

            Button { vm.skip(by: 5) } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.harcOnSurface)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Forward 5 seconds")

            Slider(
                value: Binding(
                    get: { vm.currentTimeSec },
                    set: { vm.seek(to: $0) }
                ),
                in: 0...max(vm.durationSec, 0.001)
            )
            .tint(Color.harcPrimary)

            Text("\(formatTime(vm.currentTimeSec)) / \(formatTime(vm.durationSec))")
                .font(HarcDesign.Font.labelMd.monospacedDigit())
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.horizontal, HarcDesign.Space.md)
        .padding(.vertical, HarcDesign.Space.xs)
    }

    private var audioMissingBanner: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "speaker.slash")
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Text("Audio file not found — editing still works; playback is disabled.")
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Spacer()
            if let wav = vm.document.wavURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([wav])
                }
                .buttonStyle(.plain)
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcPrimary)
            }
        }
        .padding(.horizontal, HarcDesign.Space.md)
        .padding(.vertical, HarcDesign.Space.xs)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
