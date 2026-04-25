import SwiftUI
import HarcStore

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var vm: RecordingsViewModel
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var autoStop: AutoStopController

    let onToggle: () -> Void
    let onOpen: (Recording) -> Void
    let onOpenSettings: () -> Void
    let onOpenLibrary: () -> Void
    let onResumeAutoStopped: () -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void,
        onResumeAutoStopped: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
        self.onOpenLibrary = onOpenLibrary
        self.onResumeAutoStopped = onResumeAutoStopped
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if let bannerInfo = postStopBannerInfo {
                PostStopTrayBanner(
                    reason: bannerInfo.reason,
                    stoppedAt: bannerInfo.stoppedAt,
                    duration: bannerInfo.duration,
                    byteSize: bannerInfo.byteSize,
                    frozenScope: autoStop.scopeHistory,
                    onResume: onResumeAutoStopped,
                    onOpen: {
                        if let rec = vm.recordings.first { onOpen(rec) }
                    },
                    onDismiss: { autoStop.resetPostStop() }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            RecordingControlsView(onToggle: onToggle)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            if case .warning(let secondsLeft, let reason) = autoStop.phase {
                CountdownWarningPanel(
                    secondsLeft: secondsLeft,
                    totalSeconds: autoStop.config.warningSeconds,
                    reason: reason,
                    thresholdMinutes: prefs.silenceThresholdMinutes,
                    micDb: autoStop.lastMicDb,
                    systemDb: autoStop.lastSystemDb,
                    onKeepRecording: { autoStop.keepRecording() },
                    onStopNow: { onToggle() },
                    onOpenSettings: onOpenSettings
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            quickActions
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            Divider().background(Color.harcBorderSubtle)

            RecentRecordingsView(onOpen: onOpen, onOpenLibrary: onOpenLibrary)

            Divider().background(Color.harcBorderSubtle)

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 400)
        .background(Color.harcSurface1)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
    }

    // Stable key the animation modifier can react to without comparing the
    // whole enum (`Phase` carries associated values we don't want to animate on).
    private var phaseKey: String {
        switch autoStop.phase {
        case .idle: return "idle"
        case .watching: return "watching"
        case .warning: return "warning"
        case .stoppedBanner: return "stoppedBanner"
        }
    }

    private var postStopBannerInfo: (reason: AutoStopController.StopReason, stoppedAt: Date, duration: TimeInterval?, byteSize: Int64?)? {
        guard case .stoppedBanner(let reason, let at) = autoStop.phase,
              !state.isRecording else { return nil }
        let latest = vm.recordings.first
        let fm = FileManager.default
        var size: Int64? = nil
        if let path = latest?.wavPath,
           let attrs = try? fm.attributesOfItem(atPath: path),
           let s = attrs[.size] as? Int64 {
            size = s
        }
        var duration: TimeInterval? = nil
        if let latest, let ended = latest.endedAt {
            duration = ended.timeIntervalSince(latest.startedAt)
        }
        return (reason, at, duration, size)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            brandMark
            VStack(alignment: .leading, spacing: 2) {
                Text("Harc")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.harcInkPrimary)
                modelPill
            }
            Spacer(minLength: 0)
            siliconBadge
        }
    }

    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(HarcDesign.primaryGradient)
                .frame(width: 36, height: 36)
                .shadow(color: Color.harcAccent.opacity(0.5), radius: 8, x: 0, y: 2)
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var modelPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.harcSuccess)
                .frame(width: 5, height: 5)
            Text("parakeet-tdt-0.6b-v3")
                .font(HarcDesign.Font.monoXs)
                .foregroundStyle(Color.harcInkTertiary)
        }
    }

    private var siliconBadge: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(HardwareInfo.appleSiliconDisplayName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.harcInkPrimary)
            Text("NEURAL ENGINE")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.harcInkTertiary)
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickButton(label: "Library",      kbd: "⇧⌘L", systemImage: "rectangle.stack") {
                onOpenLibrary()
            }
            quickButton(label: "Last Capture", kbd: "⌘L", systemImage: "clock.arrow.circlepath") {
                openMostRecent()
            }
            quickButton(label: "Search",       kbd: "⌘F", systemImage: "magnifyingglass") {
                onOpenLibrary()
            }
        }
    }

    private func quickButton(
        label: String,
        kbd: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        QuickActionButton(
            label: label,
            kbd: kbd,
            systemImage: systemImage,
            action: action
        )
    }

    private func openMostRecent() {
        guard let rec = vm.recordings.first else { return }
        onOpen(rec)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            footerButton(label: "Settings", systemImage: "gearshape", action: onOpenSettings)
            footerButton(label: "Library",  systemImage: "rectangle.stack", action: onOpenLibrary)
            Spacer(minLength: 0)
            storageIndicator
        }
    }

    private func footerButton(
        label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.harcInkTertiary)
                Text(label)
                    .font(HarcDesign.Font.meta)
                    .foregroundStyle(Color.harcInkSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var storageIndicator: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.harcSurface3)
                    .frame(width: 44, height: 4)
                Capsule()
                    .fill(Color.harcAccent)
                    .frame(width: 44 * storageFraction, height: 4)
            }
            Text(storageText)
                .font(HarcDesign.Font.monoXs)
                .foregroundStyle(Color.harcInkTertiary)
        }
    }

    private var storageFraction: CGFloat {
        let used = storageBytes
        guard used > 0 else { return 0 }
        let values = try? prefs.destinationURL.resourceValues(forKeys: [.volumeTotalCapacityKey])
        guard let total = values?.volumeTotalCapacity, total > 0 else { return 0 }
        return CGFloat(min(1.0, Double(used) / Double(total)))
    }

    private var storageText: String {
        let count = vm.recordings.count
        let total = storageBytes
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return "\(fmt.string(fromByteCount: total)) · \(count) files"
    }

    private var storageBytes: Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for rec in vm.recordings {
            if let attrs = try? fm.attributesOfItem(atPath: rec.wavPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}

// MARK: - Quick action button

private struct QuickActionButton: View {
    let label: String
    let kbd: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHovered ? Color.harcAccent : Color.harcInkSecondary)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? Color.harcInkPrimary : Color.harcInkSecondary)
                Text(kbd)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.harcInkTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                    .fill(isHovered ? Color.harcSurface3 : Color.harcSurface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                            .stroke(Color.harcBorderSubtle, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Success token (temporary shim if not present in DesignTokens)

private extension Color {
    static var harcSuccess: Color { HarcDesign.success }
}
