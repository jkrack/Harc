import SwiftUI
import HarcStore

public struct RecentRecordingsView: View {
    @EnvironmentObject private var vm: RecordingsViewModel

    let onOpen: (Recording) -> Void

    public init(onOpen: @escaping (Recording) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("RECENT CAPTURES")
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .tracking(1.2)
                Spacer()
            }

            filterPills

            if vm.recordings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: HarcDesign.Space.xxs) {
                        ForEach(vm.recordings.prefix(8)) { rec in
                            row(for: rec)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HarcDesign.Space.xxs) {
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
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(active ? Color.white : Color.harcOnSurface)
                .padding(.horizontal, HarcDesign.Space.xs)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Color.harcPrimary : Color.harcOutlineVariant.opacity(0.25))
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        Text(vm.filter == .all
             ? "No recordings yet. Press Start Recording to begin."
             : "No recordings match this filter.")
            .font(HarcDesign.Font.bodySm)
            .foregroundStyle(Color.harcOnSurfaceVariant)
            .padding(.vertical, HarcDesign.Space.sm)
    }

    private func row(for rec: Recording) -> some View {
        Button { onOpen(rec) } label: {
            HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
                RecordingIconTile(
                    systemImage: rec.pinned ? "pin.fill" : "waveform",
                    accent: rec.pinned ? .harcTertiary : .harcPrimary,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(rec.displayTitle)
                            .font(HarcDesign.Font.titleSm)
                            .foregroundStyle(Color.harcOnSurface)
                            .lineLimit(1)
                        Spacer()
                        Text(RelativeTimeFormatter.format(rec.startedAt))
                            .font(HarcDesign.Font.labelMd)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                    }
                    if !rec.preview.isEmpty {
                        Text(rec.preview)
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                            .lineLimit(2)
                    }
                    if !rec.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(rec.tags.prefix(3), id: \.self) { tag in
                                TagChip(tag)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, HarcDesign.Space.xxs)
            .padding(.horizontal, HarcDesign.Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
