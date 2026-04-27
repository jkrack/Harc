import SwiftUI
import AppKit
import HarcStore
import HarcExport

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var vm: RecordingsViewModel
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var autoStop: AutoStopController
    @EnvironmentObject private var postProcessing: RecordingPostProcessingState

    let onToggle: () -> Void
    let onOpen: (Recording) -> Void
    let onOpenSettings: () -> Void
    let onOpenLibrary: () -> Void
    let onOpenLibraryAndSearch: () -> Void
    let onResumeAutoStopped: () -> Void
    let onRetryDiarize: (Int64) -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void,
        onOpenLibraryAndSearch: @escaping () -> Void,
        onResumeAutoStopped: @escaping () -> Void,
        onRetryDiarize: @escaping (Int64) -> Void = { _ in }
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
        self.onOpenLibrary = onOpenLibrary
        self.onOpenLibraryAndSearch = onOpenLibraryAndSearch
        self.onResumeAutoStopped = onResumeAutoStopped
        self.onRetryDiarize = onRetryDiarize
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

            if let entry = postProcessing.current,
               !state.isRecording,
               let rec = vm.recordings.first(where: { $0.id == entry.recordingID }) {
                RecordingStoppedTray(
                    recording: rec,
                    entry: entry,
                    onOpen: { onOpen(rec) },
                    onRetryDiarize: {
                        if let id = rec.id { onRetryDiarize(id) }
                    }
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
                onOpenLibraryAndSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
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

// MARK: - Recording stopped tray

/// Shown in the popover immediately after a recording finishes, driven by
/// `RecordingPostProcessingState`. Displays a diarization status row above
/// Copy-for-prompt / Copy-plain-text / Open buttons. Collapses automatically
/// ~1.5 s after the `.done` phase is reached.
private struct RecordingStoppedTray: View {
    let recording: Recording
    let entry: RecordingPostProcessingState.Entry
    let onOpen: () -> Void
    /// Called when the user taps Retry in the `.failed` phase.
    let onRetryDiarize: () -> Void

    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var postProcessing: RecordingPostProcessingState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            diarizationStatusRow
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                .fill(HarcDesign.success.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                .strokeBorder(HarcDesign.success.opacity(0.3), lineWidth: 1)
        )
        .onChange(of: postProcessing.current) { _, newValue in
            guard let newEntry = newValue,
                  newEntry.recordingID == entry.recordingID,
                  case .done = newEntry.phase else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                postProcessing.clear(recordingID: newEntry.recordingID)
            }
        }
    }

    @ViewBuilder
    private var diarizationStatusRow: some View {
        switch entry.phase {
        case .idle:
            EmptyView()
        case .identifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Identifying speakers…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.bottom, 6)
        case .done(let n):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(n) speaker\(n == 1 ? "" : "s") identified")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.bottom, 6)
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't identify speakers")
                    .font(.caption)
                Button("Retry") {
                    onRetryDiarize()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .help(msg)
            .padding(.bottom, 6)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                let s = ExportService.promptString(
                    for: recording,
                    includeSummary: prefs.includeSummaryInPrompt
                )
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(s, forType: .string)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .medium))
                    Text("Copy for Prompt")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(isIdentifyingSpeakers ? Color.harcInkTertiary : .white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isIdentifyingSpeakers ? Color.harcSurface3 : Color.harcAccent)
                )
            }
            .buttonStyle(.plain)
            .disabled(isIdentifyingSpeakers)

            Button {
                let input = ExportInputBuilder.build(from: recording)
                let text = input.segments.map { $0.text }.joined(separator: "\n\n")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 10, weight: .medium))
                    Text("Copy plain text")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Color.harcInkPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.harcSurface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.harcBorderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button(action: onOpen) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10, weight: .medium))
                    Text("Open")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Color.harcInkPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.harcSurface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.harcBorderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var isIdentifyingSpeakers: Bool {
        if case .identifying = entry.phase { return true }
        return false
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
