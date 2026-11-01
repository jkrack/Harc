import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared Tide surface colors. Capture lifecycle colors remain owned by the
/// presence renderer; these colors describe surfaces and data visualization.
public enum HarcTideStyle {
    public static let cyan = adaptive(
        light: Color(red: 0, green: 99 / 255, blue: 148 / 255),
        dark: Color(red: 92 / 255, green: 210 / 255, blue: 1)
    )
    public static let ocean = Color(red: 47 / 255, green: 168 / 255, blue: 240 / 255)
    public static let navy = Color(red: 26 / 255, green: 33 / 255, blue: 64 / 255)
    // Tide's surface and visualization roles are shared by both platforms.
    public static let mist = Color(red: 0.95, green: 0.97, blue: 1)
    public static let paleBlue = Color(red: 0.85, green: 0.92, blue: 0.98)
    public static let selection = cyan.opacity(0.14)
    public static let cardFill = Color.primary.opacity(0.06)
    public static let cardBorder = Color.primary.opacity(0.08)
    public static let plotFill = adaptive(light: deepBlue.opacity(0.55), dark: Color.primary.opacity(0.05))
    public static let onAccent = adaptive(light: .white, dark: navy)
    public static let played = Color.white
    public static let now = Color(red: 240 / 255, green: 85 / 255, blue: 77 / 255)
    public static let nowRing = Color.white
    // token-exempt: Tide's mock has rounded display roles beyond Harc's body roles.
    public static let title = Font.system(size: 30, weight: .bold, design: .rounded)
    public static let numeral = Font.system(size: 34, weight: .bold, design: .rounded)
    public static let metric = Font.system(size: 28, weight: .bold, design: .rounded)
    public static let heading = Font.system(size: 20, weight: .bold, design: .rounded)
    public static let callToAction = Font.system(.title2, design: .rounded, weight: .bold)
    // token-exempt: imported Tide card geometry (14pt insights, 18pt plots).
    public static let cardRadius: CGFloat = 14
    public static let plotRadius: CGFloat = 18
    public static let selectionRadius: CGFloat = 10
    public static let curveInset: CGFloat = 8
    // token-exempt: the recording mock's plot and Stop-control geometry.
    public static let recordingPlotHeight: CGFloat = 200
    public static let recordingControlDiameter: CGFloat = 96
    public static let recordingControlSymbolSize: CGFloat = 26
    public static let deepBlue = Color(red: 23 / 255, green: 54 / 255, blue: 90 / 255)

    private static func adaptive(light: Color, dark: Color) -> Color {
#if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
#else
        Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
#endif
    }
}

public struct HarcTideBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [HarcTideStyle.navy, HarcTideStyle.deepBlue]
                : [HarcTideStyle.mist, HarcTideStyle.paleBlue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

/// Displays the supplied authenticated phrase without changing its order or
/// substituting illustrative words from a mockup.
public struct HarcTideSecurityWords: View {
    private let phrase: String

    public init(_ phrase: String) { self.phrase = phrase }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(Array(phrase.split(whereSeparator: \.isWhitespace).enumerated()), id: \.offset) { _, word in
                Text(String(word))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(HarcTideStyle.ocean.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Security words")
        .accessibilityValue(phrase)
    }
}

/// Compact conditions use text as well as symbols; wrapping is delegated to
/// an adaptive layout so accessibility sizes never silently clip a status.
public struct HarcTideConditions<Content: View>: View {
    private let content: Content
#if os(macOS)
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 14
#else
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 13
#endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let layout = dynamicTypeSize > .large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            content
        }
        .font(.system(size: textSize, weight: .semibold, design: .rounded))
        .padding(.horizontal, 18) // token-exempt: mock conditions inset.
        .padding(.vertical, 8)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

/// A sampled energy trace, not a synthetic animation or transcript coverage.
/// Samples are normalized input levels ordered oldest to newest.
public struct HarcTideEnergyTrace: View {
    public let samples: [Float]
    public let isLive: Bool
    public let playbackProgress: Double?

    public init(samples: [Float], isLive: Bool = false, playbackProgress: Double? = nil) {
        self.samples = samples
        self.isLive = isLive
        self.playbackProgress = playbackProgress
    }

    public var body: some View {
        Canvas { context, size in
            let baseline = size.height * 0.82
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: baseline))
            axis.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(axis, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

            guard samples.count > 1 else { return }
            let curve = HarcTideCurve(samples: Array(samples.suffix(600)), size: size,
                                      baseline: baseline, amplitude: size.height * 0.68,
                                      horizontalInset: HarcTideStyle.curveInset)
            let trace = curve.path
            var fill = trace
            fill.addLine(to: CGPoint(x: size.width, y: baseline))
            fill.addLine(to: CGPoint(x: 0, y: baseline))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [HarcTideStyle.ocean.opacity(0.35), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: baseline)
            ))
            context.stroke(trace, with: .color(isLive ? HarcTideStyle.played : HarcTideStyle.ocean),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            if let progress = playbackProgress, progress.isFinite {
                let fraction = min(1, max(0, progress))
                let x = curve.point(at: fraction).x
                var played = context
                played.clip(to: Path(CGRect(x: 0, y: 0, width: x, height: size.height)))
                played.stroke(trace, with: .color(HarcTideStyle.played), lineWidth: 2.5)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: baseline))
                context.stroke(marker, with: .color(HarcTideStyle.played.opacity(0.5)), lineWidth: 1)
                HarcTideStyle.drawNowDot(in: context, at: curve.point(at: fraction), radius: 6)
            }
            if isLive {
                HarcTideStyle.drawNowDot(in: context, at: curve.point(at: 1), radius: 6)
            }
        }
        .accessibilityLabel("Microphone energy")
        .accessibilityValue(samples.isEmpty ? "Waiting for audio levels" : "Recent audio activity")
    }
}


public extension HarcTideStyle {
    static func drawNowDot(in context: GraphicsContext, at point: CGPoint, radius: CGFloat = 4) {
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                          width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(now))
        context.stroke(circle, with: .color(nowRing), lineWidth: 2)
    }
}

/// A bounded presentation of measured levels. Bin means remove subpixel noise;
/// monotone cubic joins remain inside the measured range instead of overshooting.
/// Playback markers evaluate the same cubic used to draw the visible curve.
public struct HarcTideCurve {
    private let points: [CGPoint]
    private let slopes: [CGFloat]

    public init(samples: [Float], size: CGSize, baseline: CGFloat, amplitude: CGFloat,
                horizontalInset: CGFloat = 0) {
        guard samples.count > 1 else {
            points = []; slopes = []
            return
        }
        let count = min(samples.count, max(2, min(96, Int(max(0, size.width) / 8))))
        var levels: [CGFloat] = []
        for bin in 0..<count {
            let lower = bin * samples.count / count
            let upper = (bin + 1) * samples.count / count
            let sum = samples[lower..<upper].reduce(Float.zero) {
                $0 + ($1.isFinite ? min(1, max(0, $1)) : 0)
            }
            levels.append(CGFloat(sum / Float(upper - lower)))
        }
        let inset = min(max(0, horizontalInset), max(0, size.width) / 2)
        points = levels.enumerated().map { index, level in
            CGPoint(x: inset + CGFloat(index) / CGFloat(count - 1) * max(0, size.width - 2 * inset),
                    y: baseline - level * amplitude)
        }
        let differences = zip(points, points.dropFirst()).map { left, right in
            (right.y - left.y) / max(1, right.x - left.x)
        }
        var tangents = [differences[0]]
        for index in 1..<(count - 1) {
            let left = differences[index - 1], right = differences[index]
            tangents.append(left * right <= 0 ? 0 : 2 * left * right / (left + right))
        }
        tangents.append(differences[count - 2])
        slopes = tangents
    }

    public var path: Path {
        var result = Path()
        guard let first = points.first else { return result }
        result.move(to: first)
        for index in 0..<(points.count - 1) {
            let left = points[index], right = points[index + 1]
            let third = (right.x - left.x) / 3
            result.addCurve(to: right,
                            control1: CGPoint(x: left.x + third, y: left.y + slopes[index] * third),
                            control2: CGPoint(x: right.x - third, y: right.y - slopes[index + 1] * third))
        }
        return result
    }

    public func point(at progress: Double) -> CGPoint {
        guard points.count > 1 else { return .zero }
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        let position = fraction * Double(points.count - 1)
        let index = min(points.count - 2, Int(position))
        let t = CGFloat(position - Double(index))
        let left = points[index], right = points[index + 1]
        let width = right.x - left.x
        let y = (2*t*t*t - 3*t*t + 1) * left.y
            + (t*t*t - 2*t*t + t) * width * slopes[index]
            + (-2*t*t*t + 3*t*t) * right.y
            + (t*t*t - t*t) * width * slopes[index + 1]
        return CGPoint(x: left.x + width * t, y: y)
    }
}
