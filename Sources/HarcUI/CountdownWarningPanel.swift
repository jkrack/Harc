import SwiftUI
import HarcAudio

/// Amber countdown card shown inside the tray popover when the auto-stop
/// watcher enters its warning window. Mirrors the `Auto-Stop Safety UX` design
/// — 52×52 progress ring, Keep Recording primary, Stop Now secondary,
/// aria-live announcement, and a microcopy footer that nudges the "do nothing"
/// safe default.
public struct CountdownWarningPanel: View {
    public let secondsLeft: Int
    public let totalSeconds: Int
    public let reason: AutoStopController.StopReason
    public let thresholdMinutes: Int
    public let micDb: Float
    public let systemDb: Float

    public let onKeepRecording: () -> Void
    public let onStopNow: () -> Void
    public let onOpenSettings: () -> Void

    public init(
        secondsLeft: Int,
        totalSeconds: Int,
        reason: AutoStopController.StopReason,
        thresholdMinutes: Int,
        micDb: Float,
        systemDb: Float,
        onKeepRecording: @escaping () -> Void,
        onStopNow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.secondsLeft = secondsLeft
        self.totalSeconds = totalSeconds
        self.reason = reason
        self.thresholdMinutes = thresholdMinutes
        self.micDb = micDb
        self.systemDb = systemDb
        self.onKeepRecording = onKeepRecording
        self.onStopNow = onStopNow
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CountdownRing(secondsLeft: secondsLeft, totalSeconds: totalSeconds)
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.harcLabel.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(subheadline)
                        .font(.harcCaption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    levelReadout
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(action: onKeepRecording) {
                    HStack(spacing: 6) {
                        Text("Keep Recording")
                            .font(.harcCaption.weight(.medium))
                        Text("Space")
                            .font(.harcCaption.monospaced())
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.white.opacity(0.15))
                            )
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(" ", modifiers: [])

                Button(action: onStopNow) {
                    Text("Stop Now")
                        .font(.harcCaption)
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Text("Or do nothing — recording will save and stop.")
                .font(.harcCaption)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(maxWidth: .infinity, alignment: .center)

            Divider().background(Color(nsColor: .separatorColor))

            HStack {
                Text(reason == .hardCap ? "hard cap reached" : "silence threshold · \(thresholdMinutes) min")
                    .font(.harcCaption.monospaced())
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                Spacer(minLength: 8)
                Button("Change in Settings →", action: onOpenSettings)
                    .buttonStyle(.plain)
                    .font(.harcCaption.monospaced())
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.harc(.attention).opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(voiceOverLabel))
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Subviews

    private var headline: String {
        switch reason {
        case .silence:
            return secondsLeft >= totalSeconds
                ? "About to auto-stop"
                : "Auto-stopping in \(secondsLeft)s"
        case .hardCap:
            return secondsLeft >= totalSeconds
                ? "Max recording length reached"
                : "Auto-stopping in \(secondsLeft)s"
        case .captureStalled:
            return secondsLeft >= totalSeconds
                ? "Audio capture stopped"
                : "Stopping in \(secondsLeft)s"
        }
    }

    private var subheadline: String {
        switch reason {
        case .silence:
            return "No audio from either stream for \(thresholdMinutes) min. Looks like the meeting ended."
        case .hardCap:
            return "You hit the hard duration cap. Recording will save and stop."
        case .captureStalled:
            // Names the likely causes, because unlike silence this one is
            // usually fixable in the moment — and "Keep Recording" is a real
            // option if the device came back.
            return "No audio is reaching Harc. A headset change, sleep, or a full disk can do this. "
                + "Everything captured so far is safe."
        }
    }

    @ViewBuilder
    private var levelReadout: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "mic")
                    .font(.harcCaption.weight(.medium))
                Text("mic \(dbText(micDb))")
                    .font(.harcCaption.monospaced())
            }
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2")
                    .font(.harcCaption.weight(.medium))
                Text("sys \(dbText(systemDb))")
                    .font(.harcCaption.monospaced())
            }
        }
        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }

    private func dbText(_ db: Float) -> String {
        if !db.isFinite || db <= -100 { return "−∞ dB" }
        return String(format: "%d dB", Int(db.rounded()))
    }

    private var voiceOverLabel: String {
        let noun = reason == .hardCap ? "the max duration" : "silence"
        return "Harc. Auto-stopping recording in \(secondsLeft) seconds because of \(noun). Press space to keep recording, escape to stop now."
    }
}

// MARK: - Ring

private struct CountdownRing: View {
    let secondsLeft: Int
    let totalSeconds: Int

    private var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return max(0, min(1, Double(secondsLeft) / Double(totalSeconds)))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.harc(.attention).opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.harc(.attention),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: progress)
            Text("\(secondsLeft)")
                .font(.harcTitle.monospaced().weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.harc(.attention))
        }
    }
}
