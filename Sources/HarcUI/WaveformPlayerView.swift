import SwiftUI

/// Inline audio player for the library detail pane. Renders the recording's
/// amplitude envelope with a playhead, supports click-to-seek, and a
/// play/pause control. Wraps the same `TranscriptAudioPlayer` actor that
/// the full TranscriptEditor uses.
///
/// Loads the audio when `audioURL` becomes non-nil; reloads when the URL
/// changes (i.e., the user picks a different recording).
public struct WaveformPlayerView: View {
    let envelope: [Float]
    let audioURL: URL?
    let tint: Color

    @StateObject private var model = WaveformPlayerModel()

    public init(envelope: [Float], audioURL: URL?, tint: Color = WavePalette.center) {
        self.envelope = envelope
        self.audioURL = audioURL
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 10) {
            playButton
            waveform
            timeLabel
        }
        .frame(height: 44)
        .task(id: audioURL) {
            guard let audioURL else {
                await model.unload()
                return
            }
            await model.load(url: audioURL)
        }
        .onDisappear {
            Task { await model.pause() }
        }
    }

    // MARK: - Sub-views

    private var playButton: some View {
        Button {
            Task { await model.toggle() }
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint))
        }
        .buttonStyle(.plain)
        .disabled(audioURL == nil)
    }

    private var waveform: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawEnvelope(ctx: ctx, size: size)
                drawPlayhead(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard model.duration > 0 else { return }
                let fraction = max(0, min(1, location.x / geo.size.width))
                let target = fraction * model.duration
                Task { await model.seek(to: target, andPlay: true) }
            }
        }
    }

    private var timeLabel: some View {
        Text(formatRange(current: model.currentTime, total: model.duration))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(minWidth: 80, alignment: .trailing)
    }

    // MARK: - Drawing

    private func drawEnvelope(ctx: GraphicsContext, size: CGSize) {
        guard envelope.count > 1 else { return }
        let midY = size.height / 2
        let stepX = size.width / CGFloat(envelope.count - 1)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: midY - CGFloat(envelope[0]) * midY))
        for i in 1..<envelope.count {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(envelope[i]) * midY
            p.addLine(to: CGPoint(x: x, y: y))
        }
        for i in (0..<envelope.count).reversed() {
            let x = CGFloat(i) * stepX
            let y = midY + CGFloat(envelope[i]) * midY
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        ctx.fill(p, with: .linearGradient(
            Gradient(colors: [
                tint.opacity(0.7),
                WavePalette.edge.opacity(0.3),
                WavePalette.edge.opacity(0.0),
            ]),
            startPoint: CGPoint(x: 0, y: midY),
            endPoint: CGPoint(x: 0, y: 0)
        ))
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        guard model.duration > 0 else { return }
        let fraction = model.currentTime / model.duration
        let x = CGFloat(fraction) * size.width
        var p = Path()
        p.move(to: CGPoint(x: x, y: 0))
        p.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(p, with: .color(tint), lineWidth: 1.5)
    }

    private func formatRange(current: Double, total: Double) -> String {
        "\(formatTime(current)) / \(formatTime(total))"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Model

@MainActor
final class WaveformPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private let player = TranscriptAudioPlayer()
    private var pollTimer: Timer?
    private var loadedURL: URL?

    func load(url: URL) async {
        guard loadedURL != url else { return }
        await pause()
        do {
            try await player.load(url: url)
            loadedURL = url
            duration = await player.duration
            currentTime = 0
        } catch {
            loadedURL = nil
            duration = 0
            currentTime = 0
        }
    }

    func unload() async {
        await pause()
        loadedURL = nil
        currentTime = 0
        duration = 0
    }

    func toggle() async {
        if isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    func play() async {
        await player.play()
        isPlaying = true
        startPolling()
    }

    func pause() async {
        await player.pause()
        isPlaying = false
        stopPolling()
    }

    func seek(to seconds: Double, andPlay: Bool) async {
        await player.seek(to: seconds)
        currentTime = await player.currentTime
        if andPlay { await play() }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = await self.player.currentTime
                let stillPlaying = await self.player.isPlaying
                if !stillPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopPolling()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
