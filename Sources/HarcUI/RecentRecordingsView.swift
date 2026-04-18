import SwiftUI
import HarcStore

public struct RecentRecordingsView: View {
    @EnvironmentObject private var vm: RecordingsViewModel

    let onOpen: (Recording) -> Void

    public init(onOpen: @escaping (Recording) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            Text("Recent")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .textCase(.uppercase)
                .tracking(1.2)

            filterPills

            if vm.recordings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.recordings.prefix(8)) { rec in
                            row(for: rec)
                        }
                    }
                }
                .frame(maxHeight: 240)
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
                Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(rec.pinned ? Color.harcTertiary : Color.harcPrimary)
                    .frame(width: 24, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.displayTitle)
                        .font(HarcDesign.Font.titleSm)
                        .foregroundStyle(Color.harcOnSurface)
                        .lineLimit(1)
                    if !rec.preview.isEmpty {
                        Text(rec.preview)
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                            .lineLimit(2)
                    } else {
                        Text("(no transcript)")
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.vertical, HarcDesign.Space.xs)
            .padding(.horizontal, HarcDesign.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
