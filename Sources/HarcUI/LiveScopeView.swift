import SwiftUI

/// Scrolling RMS oscilloscope — one bar per 150 ms window, 40 bars spanning
/// the last ~6 s. The newest bar enters from the right and the history
/// scrolls left. Heights come straight from `AutoStopController.scopeHistory`
/// (normalized smoothed dBFS in `[0, 1]`) with zero post-hoc animation —
/// every pixel corresponds to a real audio sample.
///
/// Styling: alternating accent / ink-tertiary bars, matching the static
/// waveform this replaced.
public struct LiveScopeView: View {
    public enum Tint { case live, warning, dimmed }

    let history: [Float]
    let tint: Tint

    public init(history: [Float], tint: Tint = .live) {
        self.history = history
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            let barCount = AutoStopController.scopeBarCapacity
            let spacing: CGFloat = 2
            let barWidth = max(1, (geo.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))
            let minH: CGFloat = 2

            // Left-pad with zeros so a short history is right-anchored (newest
            // bar flush with the right edge).
            let padded: [Float] = {
                if history.count >= barCount { return Array(history.suffix(barCount)) }
                return Array(repeating: 0, count: barCount - history.count) + history
            }()

            HStack(alignment: .center, spacing: spacing) {
                ForEach(padded.indices, id: \.self) { i in
                    let v = CGFloat(padded[i])
                    let h = max(minH, v * geo.size.height)
                    Capsule(style: .continuous)
                        .fill(color(for: i))
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
        }
    }

    private func color(for index: Int) -> Color {
        let accent: Color
        let rest: Color
        switch tint {
        case .live:
            accent = Color.harcAccent.opacity(0.75)
            rest = Color.harcInkTertiary
        case .warning:
            accent = HarcDesign.warning.opacity(0.9)
            rest = Color.harcInkTertiary
        case .dimmed:
            accent = Color.harcAccent.opacity(0.32)
            rest = Color.harcInkQuaternary
        }
        return index.isMultiple(of: 2) ? rest : accent
    }
}
