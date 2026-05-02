import SwiftUI

/// Fluid-water waveform renderer. Driven entirely by the parent: takes a
/// `history: [Float]` by value, smooths internally, and animates a slow
/// phase drift while `isActive`. Idle (`isActive == false`) collapses to
/// a flat horizontal line — recording state stays unambiguous.
///
/// Three size variants tune sample down-resolution and phase amplitude
/// to fit small (icon), medium (panel), and pill-capsule call sites.
public struct LiveWaveformView: View {

    public enum Size: Sendable, Equatable {
        case icon    // ~14pt, ~32 sample points
        case panel   // ~28pt, full 96 sample points
        case pill    // ~16pt, ~48 sample points
    }

    let history: [Float]
    let size: Size
    let isActive: Bool
    let tint: Color

    @State private var displayed: [Float] = []

    public init(
        history: [Float],
        size: Size,
        isActive: Bool,
        tint: Color = WavePalette.center
    ) {
        self.history = history
        self.size = size
        self.isActive = isActive
        self.tint = tint
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Canvas { ctx, sz in
                let smoothed = lowPass(toward: history, from: displayed, factor: 0.07)
                let target = downsample(smoothed, to: targetCount)
                draw(in: ctx, size: sz, samples: target, time: timeline.date.timeIntervalSinceReferenceDate)
            }
            .onChange(of: timeline.date) { _, _ in
                displayed = lowPass(toward: history, from: displayed, factor: 0.07)
            }
        }
        .onChange(of: history.count) { _, _ in
            if displayed.isEmpty { displayed = history }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                displayed = Array(repeating: 0, count: max(history.count, targetCount))
            }
        }
    }

    // MARK: - Drawing

    private var targetCount: Int {
        switch size {
        case .icon:  return 32
        case .panel: return 96
        case .pill:  return 48
        }
    }

    private var phaseAmplitude: CGFloat {
        switch size {
        case .icon:  return 0.4
        case .panel: return 0.8
        case .pill:  return 0.6
        }
    }

    private func draw(in ctx: GraphicsContext, size sz: CGSize, samples: [Float], time t: TimeInterval) {
        let count = samples.count
        guard count > 1 else { return }
        let midY = sz.height / 2
        let stepX = sz.width / CGFloat(count - 1)

        let phase1 = sin(t * 2 * .pi * 0.3) * phaseAmplitude
        let phase2 = sin(t * 2 * .pi * 0.5) * -phaseAmplitude

        let layer1 = wavePath(samples: samples, midY: midY + (isActive ? phase1 : 0), stepX: stepX, sz: sz, gain: 0.95)
        ctx.fill(layer1, with: .linearGradient(
            fillGradient(),
            startPoint: CGPoint(x: 0, y: midY),
            endPoint: CGPoint(x: 0, y: 0)
        ))

        let layer2 = wavePath(samples: samples, midY: midY + (isActive ? phase2 : 0), stepX: stepX, sz: sz, gain: 0.7)
        ctx.fill(layer2, with: .linearGradient(
            fillGradient(opacity: 0.7),
            startPoint: CGPoint(x: 0, y: midY),
            endPoint: CGPoint(x: 0, y: 0)
        ))
        if isActive {
            ctx.stroke(strokePath(samples: samples, midY: midY + phase2, stepX: stepX, sz: sz, gain: 0.7),
                       with: .color(WavePalette.stroke.opacity(0.7)),
                       lineWidth: 1)
        }
    }

    private func wavePath(samples: [Float], midY: CGFloat, stepX: CGFloat, sz: CGSize, gain: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * midY * gain))
        for i in 1..<samples.count {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(samples[i]) * midY * gain
            p.addLine(to: CGPoint(x: x, y: y))
        }
        for i in (0..<samples.count).reversed() {
            let x = CGFloat(i) * stepX
            let y = midY + CGFloat(samples[i]) * midY * gain
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        return p
    }

    private func strokePath(samples: [Float], midY: CGFloat, stepX: CGFloat, sz: CGSize, gain: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * midY * gain))
        for i in 1..<samples.count {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(samples[i]) * midY * gain
            p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }

    private func fillGradient(opacity: Double = 1.0) -> Gradient {
        if !isActive {
            return Gradient(colors: [
                tint.opacity(0.25 * opacity),
                tint.opacity(0.15 * opacity),
            ])
        }
        return Gradient(colors: [
            tint.opacity(0.85 * opacity),
            WavePalette.edge.opacity(0.55 * opacity),
            WavePalette.edge.opacity(0.0),
        ])
    }

    // MARK: - Sample handling

    private func downsample(_ src: [Float], to count: Int) -> [Float] {
        guard !src.isEmpty, count > 0 else { return Array(repeating: 0, count: count) }
        if src.count == count { return src }
        if src.count < count {
            return Array(repeating: 0, count: count - src.count) + src
        }
        var out = [Float](repeating: 0, count: count)
        let bin = Float(src.count) / Float(count)
        for i in 0..<count {
            let lo = Int(Float(i) * bin)
            let hi = min(src.count, Int(Float(i + 1) * bin))
            var peak: Float = 0
            for j in lo..<hi where src[j] > peak { peak = src[j] }
            out[i] = peak
        }
        return out
    }

    private func lowPass(toward target: [Float], from current: [Float], factor: Float) -> [Float] {
        if current.isEmpty { return target }
        if current.count != target.count { return target }
        var out = current
        for i in out.indices {
            out[i] += (target[i] - current[i]) * factor
        }
        return out
    }
}
