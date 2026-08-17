import Foundation
import SwiftUI
import UIKit

enum HarcMobilePalette {
    // White text on this blue exceeds the 4.5:1 normal-text contrast floor.
    static let action = Color(red: 0, green: 0.34, blue: 0.72)
    static let indigo = Color(red: 0.20, green: 0.18, blue: 0.55)
    static let violet = Color(red: 0.47, green: 0.22, blue: 0.72)
    static let cyan = Color(red: 0.10, green: 0.58, blue: 0.75)
    static let coral = Color(red: 0.91, green: 0.20, blue: 0.30)
    static let amber = Color(red: 0.86, green: 0.47, blue: 0.08)
    static let success = Color(red: 0.08, green: 0.55, blue: 0.34)
}

struct HarcMobileCaptureStatusPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case checking
        case healthy
        case caution
        case critical
    }

    enum RelativeMoment: Equatable {
        case seen(Date)
        case checked(Date)
        case updated(Date)
    }

    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone
    let relativeMoment: RelativeMoment?

    static func host(
        status: HarcMobileHostHealthStatus,
        hostName: String?,
        lastVerifiedAt: Date?
    ) -> Self {
        let name = hostName?.nonemptyTrimmed ?? "Harc Host"
        switch status {
        case .unpaired:
            return Self(
                title: "No Host paired",
                detail: "Recording stays protected on this iPhone",
                systemImage: "macmini",
                tone: .neutral,
                relativeMoment: nil
            )
        case .checking:
            return Self(
                title: "Checking \(name)…",
                detail: "Verifying an authenticated connection",
                systemImage: "checkmark.shield",
                tone: .checking,
                relativeMoment: lastVerifiedAt.map(RelativeMoment.seen)
            )
        case .connected(let verifiedAt):
            return Self(
                title: name,
                detail: "Authenticated Host",
                systemImage: "checkmark.shield.fill",
                tone: .healthy,
                relativeMoment: .seen(verifiedAt)
            )
        case .unavailable(let attemptedAt):
            return Self(
                title: "\(name) unavailable",
                detail: "Local recording remains ready",
                systemImage: "macmini",
                tone: .caution,
                relativeMoment: lastVerifiedAt.map(RelativeMoment.seen)
                    ?? .checked(attemptedAt)
            )
        }
    }

    static func transfer(
        state: HarcMobileTransferCoordinator.State,
        pendingCount: Int,
        localRecordings: [HarcMobileLocalRecording],
        hostName: String? = nil
    ) -> Self {
        let locallyPending = localRecordings.count {
            $0.transferState != .committed
        }
        let pending = max(pendingCount, locallyPending)
        let destination = hostName?.nonemptyTrimmed ?? "your Host"

        switch state {
        case .encoding:
            return preparingTransfer(
                pending: pending,
                detail: "Preparing to send to \(destination)…"
            )
        case .connecting:
            return preparingTransfer(
                pending: pending,
                detail: "Connecting securely to \(destination)…"
            )
        case .uploading:
            return preparingTransfer(
                pending: pending,
                detail: "Sending to \(destination)…"
            )
        case .backgroundScheduled(_, let taskCount):
            return preparingTransfer(
                pending: max(pending, taskCount),
                detail: "Sending to \(destination) in the background…"
            )
        case .uploaded:
            return Self(
                title: hostName?.nonemptyTrimmed.map {
                    "All recordings verified on \($0)"
                } ?? "All recordings verified on Host",
                detail: "Verified durable receipt received",
                systemImage: "checkmark",
                tone: .healthy,
                relativeMoment: nil
            )
        case .securityBlocked:
            return Self(
                title: "Transfer paused — security review required",
                detail: protectedTitle(max(pending, 1)),
                systemImage: "lock.trianglebadge.exclamationmark",
                tone: .critical,
                relativeMoment: nil
            )
        case .codecQualificationRequired:
            let protectedCount = max(pending, localRecordings.count)
            return Self(
                title: protectedCount > 0
                    ? protectedTitle(protectedCount)
                    : "New recordings stay safe on this iPhone",
                detail: "Transfers paused · they move to \(destination) when ready",
                systemImage: "iphone",
                tone: .neutral,
                relativeMoment: nil
            )
        case .retryNeeded:
            return Self(
                title: protectedTitle(max(pending, 1)),
                detail: "Transfers paused · Host transfer will retry",
                systemImage: "iphone",
                tone: .neutral,
                relativeMoment: nil
            )
        case .waitingForPairing(let waiting):
            return Self(
                title: protectedTitle(max(max(pending, waiting), 1)),
                detail: "Transfers paused · pair a Host when ready",
                systemImage: "iphone",
                tone: .neutral,
                relativeMoment: nil
            )
        case .idle:
            if pending > 0 {
                return Self(
                    title: protectedTitle(pending),
                    detail: "Transfers paused · they move to \(destination) when ready",
                    systemImage: "iphone",
                    tone: .neutral,
                    relativeMoment: nil
                )
            }
            return Self(
                title: hostName?.nonemptyTrimmed.map {
                    "All recordings verified on \($0)"
                } ?? "No recordings waiting to transfer",
                detail: hostName?.nonemptyTrimmed == nil
                    ? "New recordings stay protected on this iPhone"
                    : "Verified durable receipts are up to date",
                systemImage: "checkmark",
                tone: .healthy,
                relativeMoment: nil
            )
        }
    }

    static func library(
        state: HarcMobileLibraryCoordinator.State,
        recordingCount: Int,
        lastUpdatedAt: Date?
    ) -> Self {
        switch state {
        case .loadingCache, .refreshing:
            return Self(
                title: "Library",
                detail: "Refreshing protected index…",
                systemImage: "rectangle.stack",
                tone: .checking,
                relativeMoment: lastUpdatedAt.map(RelativeMoment.updated)
            )
        case .unpaired:
            return Self(
                title: "Library",
                detail: "Available after Host pairing",
                systemImage: "rectangle.stack",
                tone: .neutral,
                relativeMoment: nil
            )
        case .accessNotGranted:
            return Self(
                title: "Library access not granted",
                detail: "Recording and Host transfer remain available",
                systemImage: "lock",
                tone: .caution,
                relativeMoment: nil
            )
        case .ready:
            return Self(
                title: "Library",
                detail: count(recordingCount, singular: "recording"),
                systemImage: "rectangle.stack.fill",
                tone: .neutral,
                relativeMoment: lastUpdatedAt.map(RelativeMoment.updated)
            )
        case .offline:
            return Self(
                title: "Library available offline",
                detail: count(recordingCount, singular: "cached recording"),
                systemImage: "rectangle.stack",
                tone: .caution,
                relativeMoment: lastUpdatedAt.map(RelativeMoment.updated)
            )
        case .failed:
            return Self(
                title: "Library needs attention",
                detail: recordingCount > 0
                    ? count(recordingCount, singular: "cached recording")
                    : "No protected index is available",
                systemImage: "exclamationmark.triangle",
                tone: .caution,
                relativeMoment: lastUpdatedAt.map(RelativeMoment.updated)
            )
        }
    }

    static func effectivePendingCount(
        pendingCount: Int,
        localRecordings: [HarcMobileLocalRecording]
    ) -> Int {
        max(
            pendingCount,
            localRecordings.count { $0.transferState != .committed }
        )
    }

    private static func preparingTransfer(
        pending: Int,
        detail: String
    ) -> Self {
        Self(
            title: protectedTitle(max(pending, 1)),
            detail: detail,
            systemImage: "iphone",
            tone: .checking,
            relativeMoment: nil
        )
    }

    private static func protectedTitle(_ value: Int) -> String {
        count(value, singular: "recording") + " safe on this iPhone"
    }

    private static func count(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}

struct HarcMobileHostPillPresentation: Equatable {
    enum Tone: Equatable {
        case connected
        case unavailable
        case neutral
    }

    let title: String
    let accessibilityValue: String
    let tone: Tone

    static func make(
        status: HarcMobileHostHealthStatus,
        hostName: String?
    ) -> Self {
        let name = hostName?.nonemptyTrimmed ?? "Harc Host"
        switch status {
        case .unpaired:
            return Self(
                title: "Pair a Host",
                accessibilityValue: "No Host paired",
                tone: .neutral
            )
        case .checking:
            return Self(
                title: "Checking…",
                accessibilityValue: "Checking \(name)",
                tone: .neutral
            )
        case .connected:
            return Self(
                title: name,
                accessibilityValue: "\(name), connected",
                tone: .connected
            )
        case .unavailable:
            return Self(
                title: name,
                accessibilityValue: "\(name), unavailable",
                tone: .unavailable
            )
        }
    }
}

struct HarcMobileCaptureHeroView: View {
    let state: HarcMobileCaptureCoordinator.State
    let audioLevel: () -> Double
    let start: () -> Void
    let stop: () -> Void
    let reset: () -> Void

    var body: some View {
        Group {
            switch state {
            case .idle:
                VStack(spacing: 20) {
                    control
                    VStack(spacing: 6) {
                        Text("Tap to record")
                            .font(.title3.weight(.semibold))
                        Text("Records to protected storage on this iPhone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                }
            case .recording(let startedAt):
                VStack(spacing: 24) {
                    HarcMobileElapsedTime(
                        startedAt: startedAt,
                        presentation: .hero
                    )
                    control
                    VStack(spacing: 6) {
                        Text("Tap to stop")
                            .font(.subheadline.weight(.semibold))
                        Text("Protected on this iPhone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            default:
                VStack(spacing: 16) {
                    control
                    terminalStatus
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.24), value: state.presentationKey)
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .idle:
            Button {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                start()
            } label: {
                HarcMobileOrganicCaptureCore(
                    state: state,
                    audioLevel: audioLevel
                )
            }
            .buttonStyle(HarcMobileBlobButtonStyle())
            .accessibilityLabel("Start Recording")
            .accessibilityHint(
                "Starts a protected microphone recording on this iPhone."
            )
            .accessibilityIdentifier(HarcMobileAccessibilityID.startRecording)
        case .recording:
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                stop()
            } label: {
                HarcMobileOrganicCaptureCore(
                    state: state,
                    audioLevel: audioLevel
                )
            }
            .buttonStyle(HarcMobileBlobButtonStyle())
            .accessibilityLabel("Stop Recording")
            .accessibilityHint(
                "Stops and durably saves the recording on this iPhone."
            )
            .accessibilityIdentifier(HarcMobileAccessibilityID.stopRecording)
        default:
            HarcMobileOrganicCaptureCore(
                state: state,
                audioLevel: audioLevel
            )
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var terminalStatus: some View {
        switch state {
        case .requestingPermission:
            ProgressView("Waiting for microphone permission…")
        case .starting:
            ProgressView("Starting protected recording…")
        case .stopping:
            ProgressView("Saving durable recording…")
        case .saved:
            Label("Saved locally", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(HarcMobilePalette.success)
            Text("The protected master is ready for Host transfer.")
                .foregroundStyle(.primary)
            Button("Record Again", action: reset)
                .buttonStyle(.borderedProminent)
        case .storageExhausted:
            Label(
                "iPhone storage is full",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.title2.weight(.semibold))
            .foregroundStyle(HarcMobilePalette.amber)
            Text("Recording stopped. Harc saved the durable portion locally.")
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Button("Record Again", action: reset)
                .buttonStyle(.borderedProminent)
        case .failed(let message):
            Text("Recording ended")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Button("Record Again", action: reset)
                .buttonStyle(.borderedProminent)
        case .idle, .recording:
            EmptyView()
        }
    }
}

private struct HarcMobileBlobButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(
                .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

struct HarcMobileHostPill: View {
    let presentation: HarcMobileHostPillPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(presentation.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Host")
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint("Opens Host status and pairing.")
        .accessibilityIdentifier(HarcMobileAccessibilityID.hostHealth)
    }

    private var dotColor: Color {
        switch presentation.tone {
        case .connected:
            HarcMobilePalette.success
        case .unavailable:
            HarcMobilePalette.amber
        case .neutral:
            Color(uiColor: .systemGray)
        }
    }
}

enum HarcMobileTransferSummaryKind: Equatable {
    case pending
    case caughtUp
}

struct HarcMobileTransferSummaryView: View {
    let kind: HarcMobileTransferSummaryKind
    let presentation: HarcMobileCaptureStatusPresentation
    let action: () -> Void

    var body: some View {
        switch kind {
        case .pending:
            pendingCard
        case .caughtUp:
            caughtUpLine
        }
    }

    private var pendingCard: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 34, height: 34)
                    .background(iconColor.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(presentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if presentation.tone == .checking {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(cardBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(HarcMobileAccessibilityID.localRecordings)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var caughtUpLine: some View {
        HStack(spacing: 13) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(HarcMobilePalette.success)
            Text(presentation.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        presentation.tone == .critical
            ? HarcMobilePalette.amber
            : Color.secondary
    }

    private var cardBackground: AnyShapeStyle {
        if presentation.tone == .critical {
            return AnyShapeStyle(HarcMobilePalette.amber.opacity(0.08))
        }
        return AnyShapeStyle(.thinMaterial)
    }

    private var cardBorder: Color {
        if presentation.tone == .critical {
            return HarcMobilePalette.amber.opacity(0.28)
        }
        return Color.primary.opacity(0.08)
    }
}

struct HarcMobileRecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 24, paused: reduceMotion)
        ) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 3.5
            let pulse = reduceMotion ? 0 : ((sin(phase) + 1) / 2)
            HStack(spacing: 10) {
                Circle()
                    .fill(HarcMobilePalette.coral)
                    .frame(width: 11, height: 11)
                    .scaleEffect(0.9 + (pulse * 0.35))
                    .opacity(0.75 + (pulse * 0.25))
                Text("Recording")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HarcMobilePalette.coral)
            }
        }
    }
}

private struct HarcMobileOrganicCaptureCore: View {
    let state: HarcMobileCaptureCoordinator.State
    let audioLevel: () -> Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 24,
                paused: reduceMotion || !style.animates
            )
        ) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0 : elapsed * style.phaseSpeed
            let sensedLevel = style.respondsToAudio
                ? min(max(audioLevel(), 0), 1)
                : 0
            let activity = reduceMotion ? 0 : sensedLevel

            ZStack {
                HarcMobileOrganicBlobShape(
                    phase: phase,
                    activity: activity + style.restingActivity
                )
                .fill(style.haloColor.opacity(0.28))
                .blur(radius: 18)
                .scaleEffect(1.08 + (activity * 0.05))

                HarcMobileOrganicBlobShape(
                    phase: phase,
                    activity: activity + style.restingActivity
                )
                .fill(
                    AngularGradient(
                        colors: style.colors,
                        center: .center,
                        angle: .degrees(phase * 8)
                    )
                )
                .overlay {
                    HarcMobileOrganicBlobShape(
                        phase: phase,
                        activity: activity + style.restingActivity
                    )
                    .stroke(.white.opacity(0.20), lineWidth: 1)
                }
                .shadow(
                    color: style.haloColor.opacity(0.24),
                    radius: 22,
                    y: 10
                )

                if case .recording = state {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white)
                        .frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                } else {
                    Image(systemName: style.symbol)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: style.busy && !reduceMotion
                        )
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
    }

    private var style: HarcMobileCaptureCoreStyle {
        HarcMobileCaptureCoreStyle(state: state)
    }

    private var diameter: CGFloat {
        if case .recording = state { return 200 }
        return 190
    }
}

private struct HarcMobileCaptureCoreStyle {
    let colors: [Color]
    let haloColor: Color
    let symbol: String
    let phaseSpeed: Double
    let restingActivity: Double
    let animates: Bool
    let respondsToAudio: Bool
    let busy: Bool

    init(state: HarcMobileCaptureCoordinator.State) {
        switch state {
        case .idle:
            colors = [
                HarcMobilePalette.indigo,
                HarcMobilePalette.violet,
                HarcMobilePalette.cyan,
                HarcMobilePalette.indigo,
            ]
            haloColor = HarcMobilePalette.violet
            symbol = "mic.fill"
            phaseSpeed = 0.16
            restingActivity = 0.08
            animates = true
            respondsToAudio = false
            busy = false
        case .recording:
            colors = [
                HarcMobilePalette.coral,
                HarcMobilePalette.violet,
                Color(red: 0.96, green: 0.35, blue: 0.28),
                HarcMobilePalette.coral,
            ]
            haloColor = HarcMobilePalette.coral
            symbol = "stop.fill"
            phaseSpeed = 0.58
            restingActivity = 0.10
            animates = true
            respondsToAudio = true
            busy = false
        case .saved:
            colors = [
                HarcMobilePalette.success,
                HarcMobilePalette.cyan,
                HarcMobilePalette.success,
            ]
            haloColor = HarcMobilePalette.success
            symbol = "checkmark"
            phaseSpeed = 0
            restingActivity = 0
            animates = false
            respondsToAudio = false
            busy = false
        case .storageExhausted, .failed:
            colors = [
                HarcMobilePalette.amber,
                HarcMobilePalette.coral,
                HarcMobilePalette.amber,
            ]
            haloColor = HarcMobilePalette.amber
            symbol = "exclamationmark"
            phaseSpeed = 0
            restingActivity = 0
            animates = false
            respondsToAudio = false
            busy = false
        case .requestingPermission, .starting, .stopping:
            colors = [
                HarcMobilePalette.indigo,
                HarcMobilePalette.cyan,
                HarcMobilePalette.violet,
            ]
            haloColor = HarcMobilePalette.cyan
            symbol = "ellipsis"
            phaseSpeed = 0.34
            restingActivity = 0.06
            animates = true
            respondsToAudio = false
            busy = true
        }
    }
}

private struct HarcMobileOrganicBlobShape: Shape {
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

struct HarcMobileElapsedTime: View {
    enum Presentation {
        case hero
        case compact
    }

    let startedAt: Date
    var presentation: Presentation = .compact

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 56.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(from: startedAt, to: context.date))
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityLabel("Recording duration")
        }
    }

    static func text(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var font: Font {
        switch presentation {
        case .hero:
            .system(
                size: heroSize,
                weight: .ultraLight,
                design: .monospaced
            )
        case .compact:
            .body.monospacedDigit()
        }
    }
}

struct HarcMobileRecordTabLabel: View {
    let startedAt: Date?

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(
                    HarcMobileElapsedTime.text(
                        from: startedAt,
                        to: context.date
                    ),
                    systemImage: "mic.fill"
                )
            }
            .foregroundStyle(HarcMobilePalette.coral)
        } else {
            Label("Record", systemImage: "mic")
        }
    }
}

enum HarcMobileHostPresentationStore {
    private static let displayNamePrefix =
        "com.harc.mobile.host.display-name."
    private static let lastVerifiedPrefix =
        "com.harc.mobile.host.last-verified."

    static func displayName(hostAuthorityID: String) -> String? {
        UserDefaults.standard.string(
            forKey: displayNamePrefix + hostAuthorityID
        )?.nonemptyTrimmed
    }

    static func saveDisplayName(
        _ displayName: String,
        hostAuthorityID: String
    ) {
        guard let displayName = displayName.nonemptyTrimmed else { return }
        UserDefaults.standard.set(
            displayName,
            forKey: displayNamePrefix + hostAuthorityID
        )
    }

    static func lastVerifiedAt(hostAuthorityID: String) -> Date? {
        UserDefaults.standard.object(
            forKey: lastVerifiedPrefix + hostAuthorityID
        ) as? Date
    }

    static func saveLastVerifiedAt(
        _ date: Date,
        hostAuthorityID: String
    ) {
        UserDefaults.standard.set(
            date,
            forKey: lastVerifiedPrefix + hostAuthorityID
        )
    }
}

private extension String {
    var nonemptyTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension HarcMobileCaptureCoordinator.State {
    var presentationKey: Int {
        switch self {
        case .idle: 0
        case .requestingPermission: 1
        case .starting: 2
        case .recording: 3
        case .stopping: 4
        case .saved: 5
        case .storageExhausted: 6
        case .failed: 7
        }
    }
}
