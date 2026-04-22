import SwiftUI

/// Persistent green-tinted banner shown in the tray popover after an auto-stop,
/// so the user sees what happened even if the macOS notification was
/// suppressed by DND or missed. Dismisses via × or any Resume/Open action.
public struct PostStopTrayBanner: View {
    public let reason: AutoStopController.StopReason
    public let stoppedAt: Date
    public let duration: TimeInterval?
    public let byteSize: Int64?
    /// Tail of the live scope frozen at stop time. Displayed dimmed below the
    /// banner so the user sees the exact flatline the system acted on.
    public let frozenScope: [Float]

    public let onResume: () -> Void
    public let onOpen: () -> Void
    public let onDismiss: () -> Void

    public init(
        reason: AutoStopController.StopReason,
        stoppedAt: Date,
        duration: TimeInterval?,
        byteSize: Int64?,
        frozenScope: [Float],
        onResume: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.reason = reason
        self.stoppedAt = stoppedAt
        self.duration = duration
        self.byteSize = byteSize
        self.frozenScope = frozenScope
        self.onResume = onResume
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mainRow

            if !frozenScope.isEmpty {
                LiveScopeView(history: tailOfScope, tint: .dimmed)
                    .frame(height: 18)
                    .accessibilityLabel("Frozen recent audio — flatline that triggered auto-stop")
            }
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
    }

    /// Last ~3 s of scope = 20 bars × 150 ms.
    private var tailOfScope: [Float] {
        let tailCount = 20
        if frozenScope.count >= tailCount {
            return Array(frozenScope.suffix(tailCount))
        }
        return frozenScope
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(HarcDesign.success.opacity(0.2))
                    .frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(HarcDesign.success)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.harcInkPrimary)
                Text(metaLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.harcInkTertiary)

                HStack(spacing: 8) {
                    Button(action: { onResume(); onDismiss() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Resume")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.harcAccent)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: { onOpen(); onDismiss() }) {
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
                .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.harcInkTertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    private var headline: String {
        switch reason {
        case .silence: return "Auto-stopped after silence"
        case .hardCap: return "Auto-stopped at max duration"
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let duration {
            parts.append(formatDuration(duration))
        }
        if let byteSize {
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useMB, .useGB]
            fmt.countStyle = .file
            parts.append(fmt.string(fromByteCount: byteSize))
        }
        parts.append(Self.timeFormatter.string(from: stoppedAt))
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
