import SwiftUI
import HarcPresenceUI
import HarcCore

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
    let speakerSegments: [SpeakerSegment]
    let speakerColors: [Int: Color]

    // Owned externally when the caller needs to drive it (the detail pane's
    // ⌘-click-to-seek and playback word highlight); self-owned otherwise.
    @ObservedObject var model: WaveformPlayerModel

    @StateObject private var fallbackModel = WaveformPlayerModel()
    @State private var showsSpeakerTimeline = false

    public init(
        envelope: [Float],
        audioURL: URL?,
        tint: Color = HarcTideStyle.ocean,
        speakerSegments: [SpeakerSegment] = [],
        speakerColors: [Int: Color] = [:],
        model: WaveformPlayerModel? = nil
    ) {
        self.envelope = envelope
        self.audioURL = audioURL
        self.tint = tint
        self.speakerSegments = speakerSegments
        self.speakerColors = speakerColors
        if let model {
            self._model = ObservedObject(wrappedValue: model)
        } else {
            // A private stable instance per view identity; harmless when an
            // external model is supplied because it is simply never used.
            self._model = ObservedObject(wrappedValue: WaveformPlayerModel.shared(for: audioURL))
        }
    }

    public var body: some View {
        VStack(spacing: HarcSpacing.sm) {
            if !hasLevels && !showsSpeakerTimeline {
                HStack(spacing: HarcSpacing.md) {
                    if model.duration > 0 { playButton }
                    Text(model.duration <= 0 ? "No playable audio was saved"
                         : model.duration < 1 ? "Less than a second of audio"
                         : model.duration <= 1 ? "1 second of audio" : "Audio ready to play")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if model.duration > 1 {
                        Text(formatTime(model.duration)).font(.harcMono)
                    }
                }
            } else {
                Group {
                    if showsSpeakerTimeline {
                        speakerTimeline
                    } else if hasLevels {
                        waveform
                    } else {
                        Text("No audio levels for this recording")
                            .font(.harcCaption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: hasLevels || showsSpeakerTimeline ? 150 : 72) // token-exempt: Tide's primary data plot.
                if !speakerSegments.isEmpty {
                    speakerLane
                        .frame(height: 7)
                }
                if hasLevels || !speakerSegments.isEmpty {
                    HStack(spacing: 4) {
                        playButton
                        Text("0:00")
                        Spacer()
                        if model.duration > 0 {
                            Text(formatTime(model.duration / 4))
                            Spacer()
                        }
                        modeButton("Energy", selected: !showsSpeakerTimeline) {
                            showsSpeakerTimeline = false
                        }
                        if !speakerSegments.isEmpty {
                            modeButton("Speakers", selected: showsSpeakerTimeline) {
                                showsSpeakerTimeline = true
                            }
                        }
                        Spacer()
                        if model.duration > 0 {
                            Text(formatTime(model.duration * 3 / 4))
                            Spacer()
                            Text(formatTime(model.duration))
                        }
                    }
                    .font(.harcMono)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, HarcSpacing.lg)
        .padding(.vertical, HarcSpacing.md)
        .background(hasLevels ? HarcTideStyle.plotFill : HarcTideStyle.cardFill, in: RoundedRectangle(cornerRadius: HarcTideStyle.plotRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HarcTideStyle.plotRadius)
                .strokeBorder(HarcTideStyle.cardBorder, lineWidth: 1)
        }
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

    /// Duration alone is not an energy envelope. Subsecond audio stays playable
    /// in the compact row without a chart of repeated zero-second ticks.
    private var hasLevels: Bool {
        envelope.count > 1 && model.duration > 1
    }

    private var playButton: some View {
        Button {
            Task { await model.toggle() }
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.harcLabel.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isPlaying ? "Pause recording" : "Play recording")
        .disabled(audioURL == nil || model.duration <= 0)
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
                let fraction = max(0, min(1, (location.x - HarcTideStyle.curveInset)
                                             / max(1, geo.size.width - 2 * HarcTideStyle.curveInset)))
                let target = fraction * model.duration
                Task { await model.seek(to: target, andPlay: true) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        // Synchronize fixture captures with the real asynchronous envelope load.
        .accessibilityIdentifier(envelope.count > 1 ? "harc.player.waveform.ready" : "harc.player.waveform.loading")
        .accessibilityValue(formatRange(current: model.currentTime, total: model.duration))
        .accessibilityAdjustableAction { direction in
            let delta: Double = direction == .increment ? 10 : -10
            let target = min(model.duration, max(0, model.currentTime + delta))
            Task { await model.seek(to: target, andPlay: model.isPlaying) }
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.harcCaption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.primary.opacity(selected ? 0.13 : 0.035), in: Capsule())
            .buttonStyle(.plain)
    }

    private var speakerTimeline: some View {
        Canvas { context, size in
            guard model.duration > 0 else { return }
            let speakers = Array(Set(speakerSegments.map(\.speaker))).sorted()
            let rowHeight: CGFloat = 20
            let rowSpacing: CGFloat = 8
            let totalHeight = CGFloat(speakers.count) * rowHeight
                + CGFloat(max(0, speakers.count - 1)) * rowSpacing
            let top = max(0, (size.height - totalHeight) / 2)
            for segment in speakerSegments {
                let left = CGFloat(max(0, Double(segment.startMs) / 1000 / model.duration)) * size.width
                let right = CGFloat(min(1, Double(segment.endMs) / 1000 / model.duration)) * size.width
                guard right > left else { continue }
                guard let row = speakers.firstIndex(of: segment.speaker) else { continue }
                let rect = CGRect(x: left, y: top + CGFloat(row) * (rowHeight + rowSpacing),
                                  width: max(2, right - left), height: rowHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 5),
                             with: .color(speakerColor(segment.speaker).opacity(0.8)))
            }
        }
        .accessibilityLabel("Speaker turns across recording")
    }

    private var speakerLane: some View {
        Canvas { context, size in
            guard model.duration > 0 else { return }
            for segment in speakerSegments {
                let left = CGFloat(max(0, Double(segment.startMs) / 1000 / model.duration)) * size.width
                let right = CGFloat(min(1, Double(segment.endMs) / 1000 / model.duration)) * size.width
                guard right > left else { continue }
                context.fill(Path(CGRect(x: left, y: 0, width: max(2, right - left), height: size.height)),
                             with: .color(speakerColor(segment.speaker)))
            }
        }
        .clipShape(Capsule())
        .accessibilityLabel("Speaker timeline")
    }

    private func speakerColor(_ index: Int) -> Color {
        if let color = speakerColors[index] { return color }
        let colors: [Color] = [HarcTideStyle.cyan, .purple, .orange, .teal, .green, .pink]
        return colors[abs(index) % colors.count]
    }

    // MARK: - Drawing

    private func drawEnvelope(ctx: GraphicsContext, size: CGSize) {
        guard envelope.count > 1 else { return }
        let baseline = size.height - 8
        let trace = HarcTideCurve(samples: envelope, size: size,
                                  baseline: baseline, amplitude: baseline - 6,
                                  horizontalInset: HarcTideStyle.curveInset).path
        var p = trace
        p.addLine(to: CGPoint(x: size.width, y: baseline))
        p.addLine(to: CGPoint(x: 0, y: baseline))
        p.closeSubpath()
        ctx.fill(p, with: .linearGradient(
            Gradient(colors: [tint.opacity(0.35), .clear]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: baseline)
        ))
        ctx.stroke(trace, with: .color(tint), lineWidth: 2)
        if model.duration > 0 {
            var played = ctx
            let width = HarcTideStyle.curveInset + max(0, size.width - 2 * HarcTideStyle.curveInset)
                * min(1, max(0, model.currentTime / model.duration))
            played.clip(to: Path(CGRect(x: 0, y: 0, width: width, height: size.height)))
            played.stroke(trace, with: .color(HarcTideStyle.played), lineWidth: 2)
        }
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        guard model.duration > 0 else { return }
        let fraction = min(1, max(0, model.currentTime / model.duration))
        let x = HarcTideStyle.curveInset + CGFloat(fraction) * max(0, size.width - 2 * HarcTideStyle.curveInset)
        var p = Path()
        p.move(to: CGPoint(x: x, y: 0))
        p.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(p, with: .color(HarcTideStyle.played.opacity(0.5)), lineWidth: 1)
        let curve = HarcTideCurve(samples: envelope, size: size,
                                  baseline: size.height - 8, amplitude: size.height - 14,
                                  horizontalInset: HarcTideStyle.curveInset)
        HarcTideStyle.drawNowDot(in: ctx, at: curve.point(at: fraction), radius: 7)
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
public final class WaveformPlayerModel: ObservableObject {
    /// Stable per-URL instances for callers that don't inject a model, so a
    /// SwiftUI re-init doesn't reset playback mid-listen.
    private static var sharedModels: [String: WaveformPlayerModel] = [:]
    static func shared(for url: URL?) -> WaveformPlayerModel {
        let key = url?.path ?? "-"
        if let existing = sharedModels[key] { return existing }
        let created = WaveformPlayerModel()
        // Cap the cache — entries are tiny, but unbounded growth is a leak.
        if sharedModels.count > 16 { sharedModels.removeAll() }
        sharedModels[key] = created
        return created
    }

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
