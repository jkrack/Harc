import SwiftUI

/// Shared Tide surface colors. Capture lifecycle colors remain owned by the
/// presence renderer; these colors describe surfaces and data visualization.
public enum HarcTideStyle {
    public static let cyan = Color(red: 92 / 255, green: 210 / 255, blue: 1)
    public static let ocean = Color(red: 47 / 255, green: 168 / 255, blue: 240 / 255)
    public static let navy = Color(red: 26 / 255, green: 33 / 255, blue: 64 / 255)
    public static let deepBlue = Color(red: 23 / 255, green: 54 / 255, blue: 90 / 255)
}

public struct HarcTideBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [HarcTideStyle.navy, HarcTideStyle.deepBlue]
                : [Color(red: 0.95, green: 0.97, blue: 1),
                   Color(red: 0.85, green: 0.92, blue: 0.98)],
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
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 14
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
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
            let values = samples.suffix(600)
            var trace = Path()
            for (index, value) in values.enumerated() {
                let finite = value.isFinite ? value : 0
                let point = CGPoint(
                    x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                    y: baseline - CGFloat(min(1, max(0, finite))) * size.height * 0.68
                )
                if index == 0 { trace.move(to: point) }
                else { trace.addLine(to: point) }
            }
            var fill = trace
            fill.addLine(to: CGPoint(x: size.width, y: baseline))
            fill.addLine(to: CGPoint(x: 0, y: baseline))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [HarcTideStyle.ocean.opacity(0.35), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: baseline)
            ))
            context.stroke(trace, with: .color(HarcTideStyle.ocean),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            if let progress = playbackProgress, progress.isFinite {
                let fraction = min(1, max(0, progress))
                let x = size.width * fraction
                var played = context
                played.clip(to: Path(CGRect(x: 0, y: 0, width: x, height: size.height)))
                played.stroke(trace, with: .color(.primary), lineWidth: 2.5)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: baseline))
                context.stroke(marker, with: .color(.primary.opacity(0.5)), lineWidth: 1)
            }
            if isLive, let last = values.last {
                let level = last.isFinite ? min(1, max(0, last)) : 0
                let dot = CGRect(x: size.width - 5,
                                 y: baseline - CGFloat(level) * size.height * 0.68 - 4,
                                 width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(HarcTideStyle.cyan))
            }
        }
        .accessibilityLabel("Microphone energy")
        .accessibilityValue(samples.isEmpty ? "Waiting for audio levels" : "Recent audio activity")
    }
}
