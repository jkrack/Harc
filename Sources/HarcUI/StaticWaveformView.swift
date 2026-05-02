import SwiftUI

/// Frozen mirror-of-amplitude renderer for finished recordings. Same
/// visual family as `LiveWaveformView` but no animation, no second
/// layer, no stroke overlay. One filled shape, slightly transparent.
public struct StaticWaveformView: View {

    let envelope: [Float]
    let tint: Color

    public init(envelope: [Float], tint: Color = WavePalette.center) {
        self.envelope = envelope
        self.tint = tint
    }

    public var body: some View {
        Canvas { ctx, sz in
            guard envelope.count > 1 else { return }
            let midY = sz.height / 2
            let stepX = sz.width / CGFloat(envelope.count - 1)

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
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: envelope.isEmpty)
    }
}
