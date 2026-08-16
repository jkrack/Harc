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
        localRecordings: [HarcMobileLocalRecording]
    ) -> Self {
        let locallyPending = localRecordings.count {
            $0.transferState != .committed
        }
        let pending = max(pendingCount, locallyPending)

        switch state {
        case .encoding:
            return preparingTransfer("Preparing protected transfer")
        case .connecting:
            return preparingTransfer("Connecting securely to Host")
        case .uploading:
            return preparingTransfer("Sending lossless audio to Host")
        case .backgroundScheduled(_, let batches):
            return Self(
                title: "Host transfer scheduled",
                detail: count(batches, singular: "protected batch"),
                systemImage: "arrow.up.circle",
                tone: .checking,
                relativeMoment: nil
            )
        case .uploaded:
            return Self(
                title: "Saved on Host",
                detail: "Verified durable receipt received",
                systemImage: "checkmark.shield.fill",
                tone: .healthy,
                relativeMoment: nil
            )
        case .securityBlocked:
            return Self(
                title: "Transfer paused",
                detail: "Security review required; audio remains protected",
                systemImage: "lock.trianglebadge.exclamationmark",
                tone: .critical,
                relativeMoment: nil
            )
        case .codecQualificationRequired:
            let protectedCount = max(pending, localRecordings.count)
            return Self(
                title: "Transfers paused",
                detail: protectedCount > 0
                    ? count(protectedCount, singular: "recording")
                        + " safe on this iPhone"
                    : "New recordings stay safe on this iPhone",
                systemImage: "pause.circle.fill",
                tone: .caution,
                relativeMoment: nil
            )
        case .retryNeeded:
            return Self(
                title: count(pending, singular: "recording") + " safe here",
                detail: "Host transfer will retry",
                systemImage: "arrow.clockwise",
                tone: .caution,
                relativeMoment: nil
            )
        case .waitingForPairing(let waiting):
            return Self(
                title: count(waiting, singular: "recording") + " safe here",
                detail: "Pair a Host when you are ready",
                systemImage: "iphone",
                tone: .neutral,
                relativeMoment: nil
            )
        case .idle:
            if pending > 0 {
                return Self(
                    title: count(pending, singular: "recording") + " safe here",
                    detail: "Waiting for a verified Host receipt",
                    systemImage: "iphone",
                    tone: .caution,
                    relativeMoment: nil
                )
            }
            let verified = localRecordings.count {
                $0.transferState == .committed
            }
            return Self(
                title: "All caught up",
                detail: verified > 0
                    ? count(verified, singular: "local master")
                        + " verified by Host"
                    : "Nothing waiting to transfer",
                systemImage: "checkmark.circle.fill",
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

    private static func preparingTransfer(_ title: String) -> Self {
        Self(
            title: title,
            detail: "The local master stays protected",
            systemImage: "arrow.up.circle",
            tone: .checking,
            relativeMoment: nil
        )
    }

    private static func count(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}

struct HarcMobileCaptureHeroView: View {
    let state: HarcMobileCaptureCoordinator.State
    let audioLevel: () -> Double
    let start: () -> Void
    let stop: () -> Void
    let reset: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            control
            status
        }
        .frame(maxWidth: .infinity)
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
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
    private var status: some View {
        switch state {
        case .idle:
            Text("Ready to record locally")
                .font(.title2.weight(.semibold))
            Text(
                "Harc keeps a protected copy on this iPhone first. Host transfer happens separately."
            )
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
        case .requestingPermission:
            ProgressView("Waiting for microphone permission…")
        case .starting:
            ProgressView("Starting protected recording…")
        case .recording(let startedAt):
            Text("Recording")
                .font(.title2.weight(.semibold))
                .foregroundStyle(HarcMobilePalette.coral)
            HarcMobileElapsedTime(startedAt: startedAt)
            Text("Protected on this iPhone")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
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
        }
    }
}

struct HarcMobileCaptureStatusBoard: View {
    let host: HarcMobileCaptureStatusPresentation
    let transfer: HarcMobileCaptureStatusPresentation
    let library: HarcMobileCaptureStatusPresentation

    var body: some View {
        VStack(spacing: 0) {
            HarcMobileCaptureStatusRow(presentation: host)
                .accessibilityIdentifier(HarcMobileAccessibilityID.hostHealth)
            Divider().padding(.leading, 52)
            HarcMobileCaptureStatusRow(presentation: transfer)
            Divider().padding(.leading, 52)
            HarcMobileCaptureStatusRow(presentation: library)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct HarcMobileCaptureStatusRow: View {
    let presentation: HarcMobileCaptureStatusPresentation

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(presentation.detail)
                    relativeMoment
                }
                .font(.caption)
                .foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
            if presentation.tone == .checking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var relativeMoment: some View {
        switch presentation.relativeMoment {
        case .seen(let date):
            Text("· Seen")
            Text(date, style: .relative)
        case .checked(let date):
            Text("· Checked")
            Text(date, style: .relative)
        case .updated(let date):
            Text("· Updated")
            Text(date, style: .relative)
        case nil:
            EmptyView()
        }
    }

    private var tint: Color {
        switch presentation.tone {
        case .neutral:
            HarcMobilePalette.indigo
        case .checking:
            HarcMobilePalette.cyan
        case .healthy:
            HarcMobilePalette.success
        case .caution:
            HarcMobilePalette.amber
        case .critical:
            HarcMobilePalette.coral
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

                Image(systemName: style.symbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: style.busy && !reduceMotion)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            .frame(width: 190, height: 190)
            .contentShape(Circle())
        }
    }

    private var style: HarcMobileCaptureCoreStyle {
        HarcMobileCaptureCoreStyle(state: state)
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

private struct HarcMobileElapsedTime: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(from: startedAt, to: context.date))
                .font(.title3.monospacedDigit().weight(.medium))
                .accessibilityLabel("Recording duration")
        }
    }

    private static func text(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
