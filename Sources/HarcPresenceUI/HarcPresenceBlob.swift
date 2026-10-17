import SwiftUI

public enum HarcPresenceMotion: Equatable, Sendable {
    case classic
    case fluid
}

private struct HarcPresencePressedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var harcPresenceIsPressed: Bool {
        get { self[HarcPresencePressedEnvironmentKey.self] }
        set { self[HarcPresencePressedEnvironmentKey.self] = newValue }
    }
}

/// Harc's cross-platform visual presence.
///
/// The blob reflects capture lifecycle state; it never owns or advances that
/// state. Callers must continue to provide text, controls, and recovery paths
/// because motion and color are supporting signals, not the only status UI.
public struct HarcPresenceBlob: View {
    public let state: HarcPresenceState
    public let size: HarcPresenceSize
    public let showsSymbol: Bool
    public let motion: HarcPresenceMotion
    private let audioLevel: () -> Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.harcPresenceIsPressed) private var isPressed
    @State private var fluidSimulator = HarcFluidPresenceSimulator()
    @State private var lastFluidFrameDate: Date?

    public init(
        state: HarcPresenceState,
        size: HarcPresenceSize = .standard,
        showsSymbol: Bool = true,
        motion: HarcPresenceMotion = .classic,
        audioLevel: @escaping () -> Double = { 0 }
    ) {
        self.state = state
        self.size = size
        self.showsSymbol = showsSymbol
        self.motion = motion
        self.audioLevel = audioLevel
    }

    @ViewBuilder
    public var body: some View {
        switch motion {
        case .classic:
            classicBody
        case .fluid:
            fluidBody
        }
    }

    private var classicBody: some View {
        let style = HarcPresenceStyle(state: state)
        let metrics = HarcPresenceMetrics(size: size)

        return TimelineView(
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

    private var fluidBody: some View {
        let metrics = HarcPresenceMetrics(size: size)
        return TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let values = reduceMotion
                ? HarcFluidPresenceValues(
                    time: time,
                    morph: state.isRecording ? 1 : 0,
                    press: 1,
                    level: 0,
                    reduceMotion: true
                )
                : fluidSimulator.values(time: time, reduceMotion: false)
            ZStack {
                HarcFluidPresenceCanvas(
                    values: values,
                    diameter: metrics.diameter
                )
                if showsSymbol {
                    fluidSymbol(values: values, metrics: metrics)
                }
            }
            .frame(width: metrics.diameter, height: metrics.diameter)
            .contentShape(Circle())
            .animation(
                reduceMotion ? .easeInOut(duration: 0.16) : nil,
                value: state.rawValue
            )
            .onChange(of: context.date, initial: true) { _, date in
                let delta = lastFluidFrameDate.map {
                    date.timeIntervalSince($0)
                } ?? (1 / 60)
                lastFluidFrameDate = date
                fluidSimulator.step(
                    deltaTime: delta,
                    recording: state.isRecording,
                    pressed: isPressed,
                    rawAudioLevel: audioLevel(),
                    reduceMotion: reduceMotion
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Harc")
        .accessibilityValue(state.accessibilityValue)
    }

    @ViewBuilder
    private func fluidSymbol(
        values: HarcFluidPresenceValues,
        metrics: HarcPresenceMetrics
    ) -> some View {
        switch state {
        case .ready, .recording, .recordingAttention:
            Image(systemName: "mic.fill")
                .font(.system(size: metrics.symbolSize, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(1 - values.clampedMorph)
                .scaleEffect(
                    values.reduceMotion
                        ? 1
                        : 1 - (values.clampedMorph * 0.4)
                )
                .shadow(
                    color: .black.opacity(0.18),
                    radius: metrics.symbolShadowRadius,
                    y: 1
                )
            RoundedRectangle(
                cornerRadius: metrics.symbolSize * 0.22,
                style: .continuous
            )
            .fill(.white)
            .frame(width: metrics.symbolSize, height: metrics.symbolSize)
            .opacity(values.clampedMorph)
            .scaleEffect(
                values.reduceMotion
                    ? 1
                    : 0.6 + (values.clampedMorph * 0.4)
            )
            .shadow(
                color: .black.opacity(0.18),
                radius: metrics.symbolShadowRadius,
                y: 1
            )
        default:
            symbol(
                for: HarcPresenceStyle(state: state),
                metrics: metrics
            )
        }
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
            let radius = HarcClassicPresenceMath.radius(
                baseRadius: Double(baseRadius),
                angle: angle,
                phase: phase,
                activity: deformation
            )
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

enum HarcClassicPresenceMath {
    static func radius(
        baseRadius: Double,
        angle: Double,
        phase: Double,
        activity: Double
    ) -> Double {
        let deformation = min(max(activity, 0), 1.1)
        let organic = sin((angle * 3) + phase) * 0.045
            + sin((angle * 5) - (phase * 1.31)) * 0.025
        let voice = deformation * (
            0.060 + (sin((angle * 4) + (phase * 1.7)) * 0.035)
        )
        return baseRadius * (1 + organic + voice)
    }
}

struct HarcFluidSpring: Equatable, Sendable {
    var value: Double
    var velocity: Double = 0

    mutating func step(
        target: Double,
        stiffness: Double,
        damping: Double,
        deltaTime: Double
    ) {
        let deltaTime = min(max(deltaTime, 0), 0.05)
        guard deltaTime > 0 else { return }
        let acceleration = -stiffness * (value - target)
            - damping * velocity
        velocity += acceleration * deltaTime
        value += velocity * deltaTime
    }
}

struct HarcFluidAudioSmoother: Equatable, Sendable {
    private(set) var level: Double = 0

    mutating func step(rawLevel: Double, deltaTime: Double) {
        let rawLevel = min(max(rawLevel, 0), 1)
        let deltaTime = min(max(deltaTime, 0), 0.05)
        let rate = rawLevel > level ? 0.35 : 0.06
        let frameIndependentRate = 1
            - pow(1 - rate, deltaTime * 60)
        level += (rawLevel - level) * frameIndependentRate
    }

    mutating func reset() {
        level = 0
    }
}

struct HarcFluidPresenceValues: Equatable, Sendable {
    let time: Double
    let morph: Double
    let press: Double
    let level: Double
    let reduceMotion: Bool

    var clampedMorph: Double { min(max(morph, 0), 1) }
}

struct HarcFluidPresenceSimulator: Equatable, Sendable {
    private var morph = HarcFluidSpring(value: 0)
    private var press = HarcFluidSpring(value: 1)
    private var audio = HarcFluidAudioSmoother()

    mutating func step(
        deltaTime: Double,
        recording: Bool,
        pressed: Bool,
        rawAudioLevel: Double,
        reduceMotion: Bool
    ) {
        if reduceMotion {
            morph = HarcFluidSpring(value: recording ? 1 : 0)
            press = HarcFluidSpring(value: 1)
            audio.reset()
            return
        }
        morph.step(
            target: recording ? 1 : 0,
            stiffness: 38,
            damping: 10,
            deltaTime: deltaTime
        )
        press.step(
            target: pressed ? 0.93 : 1,
            stiffness: 520,
            damping: 13,
            deltaTime: deltaTime
        )
        audio.step(
            rawLevel: recording ? rawAudioLevel : 0,
            deltaTime: deltaTime
        )
    }

    func values(time: Double, reduceMotion: Bool) -> HarcFluidPresenceValues {
        HarcFluidPresenceValues(
            time: time,
            morph: morph.value,
            press: press.value,
            level: reduceMotion ? 0 : audio.level,
            reduceMotion: reduceMotion
        )
    }
}

enum HarcFluidPresenceMath {
    static let pointCount = 64
    static let referenceDiameter = 280.0
    static let referenceRadius = 96.0

    static func radius(
        angle: Double,
        time: Double,
        lag: Double = 0,
        morph: Double,
        level: Double,
        reduceMotion: Bool,
        fluidity: Double = 1,
        grow: Double = 1
    ) -> Double {
        guard !reduceMotion else { return referenceRadius * grow }
        let morph = min(max(morph, 0), 1)
        let level = min(max(level, 0), 1)
        let speed = 1 + (0.45 * morph)
        let waveTime = time - lag
        let breath = sin(time * 0.9 * speed) * 0.018
        let organic = (
            0.034 * sin((2 * angle) + (0.41 * waveTime * speed) + 0.3)
                + 0.028 * sin((3 * angle) - (0.57 * waveTime * speed) + 1.7)
                + 0.016 * sin((5 * angle) + (0.83 * waveTime * speed) + 4.1)
                + 0.008 * sin((7 * angle) - (1.21 * waveTime * speed))
        ) * fluidity * (1 + (0.5 * morph))
        let voice = level * (
            0.07 + (0.035 * sin((4 * angle) + (2.2 * waveTime)))
        )
        return referenceRadius * (1 + breath + organic + voice) * grow
    }

    static func points(
        in rect: CGRect,
        values: HarcFluidPresenceValues,
        lag: Double = 0,
        grow: Double = 1
    ) -> [CGPoint] {
        let scale = min(rect.width, rect.height) / referenceDiameter
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let press = values.reduceMotion ? 1 : values.press
        let scaleX = press * (1 + ((1 - press) * 0.45))
        let scaleY = press
        return (0 ..< pointCount).map { index in
            let angle = (Double(index) / Double(pointCount)) * (.pi * 2)
            let radius = radius(
                angle: angle,
                time: values.time,
                lag: lag,
                morph: values.morph,
                level: values.level,
                reduceMotion: values.reduceMotion,
                grow: grow
            ) * scale
            return CGPoint(
                x: center.x + CGFloat(cos(angle) * radius * scaleX),
                y: center.y + CGFloat(sin(angle) * radius * scaleY)
            )
        }
    }

    static func path(points: [CGPoint]) -> Path {
        guard points.count > 3 else { return Path() }
        var path = Path()
        path.move(to: points[0])
        for index in points.indices {
            let previous = points[(index - 1 + points.count) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let following = points[(index + 2) % points.count]
            let control1 = CGPoint(
                x: current.x + ((next.x - previous.x) / 6),
                y: current.y + ((next.y - previous.y) / 6)
            )
            let control2 = CGPoint(
                x: next.x - ((following.x - current.x) / 6),
                y: next.y - ((following.y - current.y) / 6)
            )
            path.addCurve(
                to: next,
                control1: control1,
                control2: control2
            )
        }
        path.closeSubpath()
        return path
    }
}

private struct HarcFluidPresenceCanvas: View {
    let values: HarcFluidPresenceValues
    let diameter: CGFloat

    private static let idlePools = [
        HarcFluidRGB(hex: 0x7838B8),
        HarcFluidRGB(hex: 0x1A94BF),
        HarcFluidRGB(hex: 0x4B3FD1),
        HarcFluidRGB(hex: 0xA04BD9),
    ]
    private static let recordingPools = [
        HarcFluidRGB(hex: 0xF0554D),
        HarcFluidRGB(hex: 0xFF8A5C),
        HarcFluidRGB(hex: 0x7838B8),
        HarcFluidRGB(hex: 0xE8334D),
    ]
    private static let orbits = [
        (x: 0.31, y: 0.47, xPhase: 0.0, yPhase: 1.1),
        (x: 0.43, y: 0.29, xPhase: 2.1, yPhase: 0.4),
        (x: 0.23, y: 0.37, xPhase: 4.2, yPhase: 2.9),
        (x: 0.52, y: 0.41, xPhase: 1.3, yPhase: 5.0),
    ]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let bodyPath = HarcFluidPresenceMath.path(
                points: HarcFluidPresenceMath.points(
                    in: rect,
                    values: values
                )
            )
            let haloPath = HarcFluidPresenceMath.path(
                points: HarcFluidPresenceMath.points(
                    in: rect,
                    values: values,
                    lag: 0.35,
                    grow: 1.1 + (values.level * 0.06)
                )
            )
            let morph = values.clampedMorph
            let scale = diameter / 280

            var haloContext = context
            haloContext.opacity = 0.60
            haloContext.addFilter(.blur(radius: 22 * scale))
            haloContext.fill(
                haloPath,
                with: .color(
                    HarcFluidRGB(hex: 0x7838B8)
                        .mixed(with: HarcFluidRGB(hex: 0xF0554D), amount: morph)
                        .color
                )
            )

            var bodyContext = context
            bodyContext.clip(to: bodyPath)
            bodyContext.fill(
                Path(rect),
                with: .color(
                    HarcFluidRGB(hex: 0x2A2580)
                        .mixed(with: HarcFluidRGB(hex: 0xB8283A), amount: morph)
                        .color
                )
            )

            let speed = 1 + (0.45 * morph)
            let orbitX = 50 * scale
            let orbitY = 44 * scale
            let poolDiameter = (190 + (CGFloat(values.level) * 40)) * scale
            for index in Self.orbits.indices {
                let orbit = Self.orbits[index]
                let center = CGPoint(
                    x: rect.midX + (values.reduceMotion ? 0 : orbitX * CGFloat(
                        sin((values.time * orbit.x * speed) + orbit.xPhase)
                    )),
                    y: rect.midY + (values.reduceMotion ? 0 : orbitY * CGFloat(
                        cos((values.time * orbit.y * speed) + orbit.yPhase)
                    ))
                )
                let pool = Self.idlePools[index].mixed(
                    with: Self.recordingPools[index],
                    amount: morph
                ).color
                bodyContext.fill(
                    Path(rect),
                    with: .radialGradient(
                        Gradient(colors: [
                            pool.opacity(0.95),
                            pool.opacity(0),
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: poolDiameter * 0.5
                    )
                )
            }

            let sheenRect = CGRect(
                x: 70 * scale,
                y: CGFloat(58 + ((1 - values.press) * 30)) * scale,
                width: 120 * scale,
                height: 80 * scale
            )
            bodyContext.fill(
                Path(ellipseIn: sheenRect),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.32),
                        Color.white.opacity(0),
                    ]),
                    center: CGPoint(x: sheenRect.midX, y: sheenRect.midY),
                    startRadius: 0,
                    endRadius: sheenRect.width * 0.5
                )
            )
            context.stroke(
                bodyPath,
                with: .color(.white.opacity(0.20)),
                lineWidth: max(0.5, scale)
            )
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct HarcFluidRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    func mixed(with other: Self, amount: Double) -> Self {
        let amount = min(max(amount, 0), 1)
        return Self(
            red: red + ((other.red - red) * amount),
            green: green + ((other.green - green) * amount),
            blue: blue + ((other.blue - blue) * amount)
        )
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}
