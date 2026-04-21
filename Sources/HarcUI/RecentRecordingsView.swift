import SwiftUI
import HarcStore

public struct RecentRecordingsView: View {
    @EnvironmentObject private var vm: RecordingsViewModel

    let onOpen: (Recording) -> Void
    let onOpenLibrary: () -> Void

    public init(
        onOpen: @escaping (Recording) -> Void,
        onOpenLibrary: @escaping () -> Void = {}
    ) {
        self.onOpen = onOpen
        self.onOpenLibrary = onOpenLibrary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            filterPills
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if vm.recordings.isEmpty {
                emptyState
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vm.recordings.prefix(8)) { rec in
                            CaptureRow(recording: rec) { onOpen(rec) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Recent Captures")
                .font(HarcDesign.Font.label)
                .foregroundStyle(Color.harcInkTertiary)
                .tracking(0.6)
            Spacer()
            Button(action: onOpenLibrary) {
                Text("LIBRARY →")
                    .font(HarcDesign.Font.monoXs)
                    .tracking(0.8)
                    .foregroundStyle(Color.harcAccent)
            }
            .buttonStyle(.plain)
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                pill("All",       filter: .all)
                pill("Today",     filter: .today)
                pill("Yesterday", filter: .yesterday)
                pill("Week",      filter: .thisWeek)
                pill("Pinned",    filter: .pinned)
            }
        }
    }

    private func pill(_ label: String, filter: LibraryFilter) -> some View {
        let active = vm.filter == filter
        return Button { vm.filter = filter } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? .white : Color.harcInkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(active ? Color.harcAccent : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(active ? Color.clear : Color.harcBorderSubtle.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        Text(vm.filter == .all
             ? "No recordings yet. Press ⌘⇧R to begin."
             : "No recordings match this filter.")
            .font(HarcDesign.Font.body)
            .foregroundStyle(Color.harcInkTertiary)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Capture row

private struct CaptureRow: View {
    let recording: Recording
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                iconTile
                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.harcInkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if recording.preview.isEmpty {
                        Text("No transcript — audio only.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.harcInkQuaternary)
                            .lineLimit(1)
                    } else {
                        Text(recording.preview)
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .foregroundStyle(Color.harcInkTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !recording.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(recording.tags.prefix(3), id: \.self) { TagChip($0) }
                            if recording.tags.count > 3 {
                                TagOverflowChip(count: recording.tags.count - 3)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(durationText)
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.harcInkSecondary)
                    Text(RelativeTimeFormatter.format(recording.startedAt))
                        .font(HarcDesign.Font.monoXs)
                        .foregroundStyle(Color.harcInkTertiary)
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                    .fill(isHovered ? Color.harcSurface2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                .fill(isHovered ? Color.harcSurface3 : Color.harcSurface2)
                .overlay(
                    RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                        .stroke(isHovered ? Color.harcBorderStrong : Color.harcBorderSubtle, lineWidth: 1)
                )
                .frame(width: 32, height: 32)
            Image(systemName: recording.pinned ? "pin.fill" : "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(recording.pinned ? Color.harcTertiary : Color.harcAccent)
        }
        .padding(.top, 1)
    }

    private var durationText: String {
        guard let end = recording.endedAt else { return "—" }
        let seconds = Int(end.timeIntervalSince(recording.startedAt))
        let m = seconds / 60, s = seconds % 60
        if m >= 60 {
            let h = m / 60, mm = m % 60
            return String(format: "%d:%02d:%02d", h, mm, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
