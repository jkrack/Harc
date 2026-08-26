import SwiftUI

/// Harc's cross-platform visual presence.
///
/// The blob reflects capture lifecycle state; it never owns or advances that
/// state. Callers must continue to provide text, controls, and recovery paths
/// because motion and color are supporting signals, not the only status UI.
public struct HarcPresenceBlob: View {
    public let state: HarcPresenceState
    public let size: HarcPresenceSize
    public let showsSymbol: Bool
    private let audioLevel: () -> Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: HarcPresenceState,
        size: HarcPresenceSize = .standard,
        showsSymbol: Bool = true,
        audioLevel: @escaping () -> Double = { 0 }
    ) {
        self.state = state
        self.size = size
        self.showsSymbol = showsSymbol
        self.audioLevel = audioLevel
    }

    public var body: some View {
        let style = HarcPresenceStyle(state: state)
        let metrics = HarcPresenceMetrics(size: size)

        TimelineView(
            .animation(
                minimumInterval: 1 / style.framesPerSecond,
                paused: reduceMotion || !style.animates
            )
        ) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0 : elapsed * style.phaseSpeed
            let sensedLevel = style.respondsToAudio
                ? min(max(audioLevel(), 0), 1)
                : 0
            let activity = reduceMotion ? 0 : sensedLevel
            let breath = reduceMotion || !style.animates
                ? 0
                : sin(elapsed * style.breathSpeed)
            let breathScale = 1 + (breath * style.breathAmplitude)

            ZStack {
                HarcPresenceShape(
                    phase: phase,
                    activity: activity + style.restingActivity
                )
                .fill(style.haloColor.opacity(metrics.haloOpacity))
                .blur(radius: metrics.haloBlur)
                .scaleEffect(
                    (1.07 + (activity * 0.05)) * breathScale
                )

                HarcPresenceShape(
                    phase: phase,
                    activity: activity + style.restingActivity
                )
                .fill(
                    AngularGradient(
                        colors: style.colors,
                        center: .center,
                        angle: .degrees(
                            reduceMotion
                                ? 0
                                : elapsed * style.gradientDegreesPerSecond
                        )
                    )
                )
                .overlay {
                    HarcPresenceShape(
                        phase: phase,
                        activity: activity + style.restingActivity
                    )
                    .stroke(.white.opacity(0.20), lineWidth: metrics.strokeWidth)
                }
                .shadow(
                    color: style.haloColor.opacity(metrics.shadowOpacity),
                    radius: metrics.shadowRadius,
                    y: metrics.shadowY
                )
                .scaleEffect(breathScale)

                if showsSymbol {
                    symbol(for: style, metrics: metrics)
                }
            }
            .frame(width: metrics.diameter, height: metrics.diameter)
            .contentShape(Circle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Harc")
        .accessibilityValue(state.accessibilityValue)
    }

    @ViewBuilder
    private func symbol(
        for style: HarcPresenceStyle,
        metrics: HarcPresenceMetrics
    ) -> some View {
        if state.isRecording {
            RoundedRectangle(
                cornerRadius: metrics.symbolSize * 0.22,
                style: .continuous
            )
            .fill(.white)
            .frame(width: metrics.symbolSize, height: metrics.symbolSize)
            .shadow(
                color: .black.opacity(0.18),
                radius: metrics.symbolShadowRadius,
                y: 1
            )
        } else {
            Image(systemName: style.symbol)
                .font(.system(
                    size: metrics.symbolSize,
                    weight: .semibold
                ))
                .foregroundStyle(.white)
                .shadow(
                    color: .black.opacity(0.18),
                    radius: metrics.symbolShadowRadius,
                    y: 1
                )
        }
    }
}

public enum HarcPresenceState: String, CaseIterable, Sendable {
    case ready
    case preparing
    case recording
    case recordingAttention
    case saving
    case saved
    case attention
    case failure

    public var accessibilityValue: String {
        switch self {
        case .ready: "Ready"
        case .preparing: "Starting"
        case .recording: "Recording"
        case .recordingAttention: "Recording needs attention"
        case .saving: "Saving"
        case .saved: "Saved"
        case .attention: "Needs attention"
        case .failure: "Unavailable"
        }
    }

    fileprivate var isRecording: Bool {
        self == .recording || self == .recordingAttention
    }
}

public enum HarcPresenceSize: Sendable {
    /// Status dots and floating compact chrome.
    case mini
    /// Dense cards and headers.
    case compact
    /// Menu-panel and empty-state presence.
    case standard
    /// Primary mobile capture control.
    case hero
}

struct HarcPresenceStyle {
    let colors: [Color]
    let haloColor: Color
    let symbol: String
    let phaseSpeed: Double
    let gradientDegreesPerSecond: Double
    let breathSpeed: Double
    let breathAmplitude: Double
    let restingActivity: Double
    let framesPerSecond: Double
    let animates: Bool
    let respondsToAudio: Bool

    init(state: HarcPresenceState) {
        switch state {
        case .ready:
            colors = [
                HarcPresencePalette.indigo,
                HarcPresencePalette.violet,
                HarcPresencePalette.cyan,
                HarcPresencePalette.indigo,
            ]
            haloColor = HarcPresencePalette.violet
            symbol = "mic.fill"
            phaseSpeed = 0.56
            gradientDegreesPerSecond = 7
            breathSpeed = 0.85
            breathAmplitude = 0.022
            restingActivity = 0.12
            framesPerSecond = 15
            animates = true
            respondsToAudio = false
        case .recording:
            colors = [
                HarcPresencePalette.coral,
                HarcPresencePalette.violet,
                HarcPresencePalette.warmCoral,
                HarcPresencePalette.coral,
            ]
            haloColor = HarcPresencePalette.coral
            symbol = "stop.fill"
            phaseSpeed = 0.72
            gradientDegreesPerSecond = 14
            breathSpeed = 1.4
            breathAmplitude = 0.012
            restingActivity = 0.10
            framesPerSecond = 24
            animates = true
            respondsToAudio = true
        case .recordingAttention:
            colors = [
                HarcPresencePalette.amber,
                HarcPresencePalette.coral,
                HarcPresencePalette.amber,
            ]
            haloColor = HarcPresencePalette.amber
            symbol = "stop.fill"
            phaseSpeed = 0.30
            gradientDegreesPerSecond = 5
            breathSpeed = 0.8
            breathAmplitude = 0.008
            restingActivity = 0.06
            framesPerSecond = 15
            animates = true
            respondsToAudio = false
        case .preparing, .saving:
            colors = [
                HarcPresencePalette.indigo,
                HarcPresencePalette.cyan,
                HarcPresencePalette.violet,
            ]
            haloColor = HarcPresencePalette.cyan
            symbol = state == .saving ? "arrow.down" : "ellipsis"
            phaseSpeed = 0.40
            gradientDegreesPerSecond = 10
            breathSpeed = 1.1
            breathAmplitude = 0.014
            restingActivity = 0.06
            framesPerSecond = 15
            animates = true
            respondsToAudio = false
        case .saved:
            colors = [
                HarcPresencePalette.success,
                HarcPresencePalette.cyan,
                HarcPresencePalette.success,
            ]
            haloColor = HarcPresencePalette.success
            symbol = "checkmark"
            phaseSpeed = 0
            gradientDegreesPerSecond = 0
            breathSpeed = 0
            breathAmplitude = 0
            restingActivity = 0
            framesPerSecond = 1
            animates = false
            respondsToAudio = false
        case .attention:
            colors = [
                HarcPresencePalette.amber,
                HarcPresencePalette.coral,
                HarcPresencePalette.amber,
            ]
            haloColor = HarcPresencePalette.amber
            symbol = "exclamationmark"
            phaseSpeed = 0
            gradientDegreesPerSecond = 0
            breathSpeed = 0
            breathAmplitude = 0
            restingActivity = 0
            framesPerSecond = 1
            animates = false
            respondsToAudio = false
        case .failure:
            colors = [
                HarcPresencePalette.failure,
                HarcPresencePalette.coral,
                HarcPresencePalette.failure,
            ]
            haloColor = HarcPresencePalette.failure
            symbol = "exclamationmark"
            phaseSpeed = 0
            gradientDegreesPerSecond = 0
            breathSpeed = 0
            breathAmplitude = 0
            restingActivity = 0
            framesPerSecond = 1
            animates = false
            respondsToAudio = false
        }
    }
}

private enum HarcPresencePalette {
    static let indigo = Color(red: 0.20, green: 0.18, blue: 0.55)
    static let violet = Color(red: 0.47, green: 0.22, blue: 0.72)
    static let cyan = Color(red: 0.10, green: 0.58, blue: 0.75)
    static let coral = Color(red: 0.91, green: 0.20, blue: 0.30)
    static let warmCoral = Color(red: 0.96, green: 0.35, blue: 0.28)
    static let amber = Color(red: 0.86, green: 0.47, blue: 0.08)
    static let success = Color(red: 0.08, green: 0.55, blue: 0.34)
    static let failure = Color(red: 0.78, green: 0.10, blue: 0.16)
}

private struct HarcPresenceMetrics {
    let diameter: CGFloat
    let haloBlur: CGFloat
    let haloOpacity: Double
    let shadowRadius: CGFloat
    let shadowOpacity: Double
    let shadowY: CGFloat
    let strokeWidth: CGFloat
    let symbolSize: CGFloat
    let symbolShadowRadius: CGFloat

    init(size: HarcPresenceSize) {
        switch size {
        case .mini:
            diameter = 24
            haloBlur = 3
            haloOpacity = 0.20
            shadowRadius = 3
            shadowOpacity = 0.16
            shadowY = 1
            strokeWidth = 0.5
            symbolSize = 6
            symbolShadowRadius = 1
        case .compact:
            diameter = 44
            haloBlur = 6
            haloOpacity = 0.22
            shadowRadius = 7
            shadowOpacity = 0.18
            shadowY = 3
            strokeWidth = 0.75
            symbolSize = 11
            symbolShadowRadius = 2
        case .standard:
            diameter = 68
            haloBlur = 9
            haloOpacity = 0.25
            shadowRadius = 11
            shadowOpacity = 0.22
            shadowY = 5
            strokeWidth = 1
            symbolSize = 17
            symbolShadowRadius = 3
        case .hero:
            diameter = 194
            haloBlur = 18
            haloOpacity = 0.28
            shadowRadius = 22
            shadowOpacity = 0.24
            shadowY = 10
            strokeWidth = 1
            symbolSize = 36
            symbolShadowRadius = 6
        }
    }
}

private struct HarcPresenceShape: Shape {
    var phase: Double
    var activity: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, activity) }
        set {
            phase = newValue.first
            activity = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let pointCount = 36
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) * 0.40
        let deformation = min(max(activity, 0), 1.1)
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for index in 0 ..< pointCount {
            let angle = (Double(index) / Double(pointCount)) * (.pi * 2)
            let organic = sin((angle * 3) + phase) * 0.045
                + sin((angle * 5) - (phase * 1.31)) * 0.025
            let voice = deformation * (
                0.060 + (sin((angle * 4) + (phase * 1.7)) * 0.035)
            )
            let radius = baseRadius * (1 + organic + voice)
            points.append(CGPoint(
                x: center.x + CGFloat(cos(angle) * radius),
                y: center.y + CGFloat(sin(angle) * radius)
            ))
        }

        guard let first = points.first, let last = points.last else {
            return Path()
        }
        var path = Path()
        path.move(to: midpoint(last, first))
        for index in points.indices {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(point, next), control: point)
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}
